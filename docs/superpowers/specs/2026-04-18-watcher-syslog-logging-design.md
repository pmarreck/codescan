# Watcher Syslog Logging + `codescan log` Subcommand

Date: 2026-04-18

## Problem

`codescan`'s background watcher is spawned as a daemon with all three stdio streams closed (`src/main.zig:2051-2053`). When it self-terminates for reasons like `max_consecutive_errors` (5 consecutive embedding failures → shutdown) or a config change, its stderr messages go to `/dev/null`. The user has no way to know *why* the watcher stopped. This has already caused a real incident (watcher stopped unexpectedly for the `validate` project).

## Goals

1. Persist watcher error and lifecycle events to an OS-managed log that's automatically rotated and compressed (no per-project log file to manage).
2. Make those logs cross-platform and filterable by project.
3. Provide a `codescan log` subcommand and MCP tool so the filtered logs can be read from the CLI and from LLMs, even after the watcher has died.

## Non-Goals

- Structured logging (JSON fields, etc.). Plain-text messages are sufficient.
- Log-ingestion-style features (search, aggregation, retention policy config). The OS owns those.
- Replacing the existing stderr output for the foreground `codescan watch` invocation. Syslog is additive; stderr still prints to the terminal.

## Approach

POSIX `syslog(3)` via a small Zig C-FFI wrapper. Works identically on macOS and Linux. Rejected alternatives:

- **`os_log` + `sd_journal_send`** — more modern, structured fields, but two code paths plus a libsystemd dependency on Linux. Not worth it for error+lifecycle events.
- **Custom log file in `.codescan/`** — would need our own rotation and compression; loses the ability to correlate with other OS-level events.

## Design

### 1. Log message format

Every message embeds the project root as a prefix so it's greppable/predicate-filterable:

```
<root>: <message>
```

Example:
```
/Users/pmarreck/Documents-CloudManaged/validate: watcher started
/Users/pmarreck/Documents-CloudManaged/validate: index error: EmbeddingServerUnavailable (3/5)
/Users/pmarreck/Documents-CloudManaged/validate: watcher stopping: too many consecutive errors
```

- Syslog ident: `codescan`
- Facility: `LOG_DAEMON`
- `openlog` options: `LOG_PID | LOG_NDELAY` (PID added by syslog; immediate connection)

### 2. Events logged (option B: errors + lifecycle)

| Event | Priority | Source location |
|---|---|---|
| `watcher started` | `LOG_NOTICE` | entry of `watch` subcommand |
| `watcher stopping: <reason>` | `LOG_NOTICE` | each exit path in `watchLoopNative` / `watchLoopPolling` |
| `index error: <err> (N/5)` | `LOG_WARNING` | on consecutive-error accumulation in both watch loops |
| `watcher: too many consecutive errors, stopping` | `LOG_ERR` | when threshold hit |
| `failed to start watcher: <err>` | `LOG_ERR` | in `maybeStartWatcher` spawn path |

Exit reasons to distinguish in `watcher stopping: <reason>`:
- `config changed`
- `too many consecutive errors`
- `signal received` (if the SIGINT/SIGTERM path is reachable)

### 3. C-FFI wrapper module

New file `src/syslog.zig` exposes:

- POSIX constants: `LOG_PID`, `LOG_NDELAY`, `LOG_DAEMON`, `LOG_ERR`, `LOG_WARNING`, `LOG_NOTICE` (identical values on macOS + Linux).
- `extern "c"` decls for `openlog`, `syslog`, `closelog`.
- A process-global `initialized: bool` flag.
- `init(ident: [*:0]const u8)` — calls `openlog(ident, LOG_PID | LOG_NDELAY, LOG_DAEMON)`. The `ident` pointer must live for the process lifetime (POSIX doesn't copy it); callers pass a string literal.
- `deinit()` — calls `closelog()` if initialized.
- `log(priority, message)` — always invokes `syslog(priority, "%s", cstr)` so user-provided paths can't inject format specifiers. No-op if not initialized.
- `logWithRoot(priority, root, message)` — formats `"<root>: <message>"` into a 1024-byte stack buffer (truncating if needed, with ellipsis), then calls `log`.

No-op behavior when `init` was never called lets unit tests and non-watch subcommands skip syslog entirely without extra guards.

### 4. Init location

- `init("codescan")` at the top of the `watch` subcommand handler in `src/main.zig` (both foreground and daemon invocations); `defer syslog.deinit();`. This runs in the spawned watcher process, so it's independent of whatever the parent (`codescan status`, `codescan index`, etc.) was doing.
- In `maybeStartWatcher` (the *parent* process's spawn helper), open syslog briefly around the spawn attempt so a `failed to start watcher` can be logged even though the watcher never came up, then `closelog()`. The ident is the same literal `"codescan"`.

### 5. `codescan log` subcommand

Usage:
```
codescan log [--root <path>] [--since <duration>] [--follow] [--all] [--limit <n>]
```

Defaults:
- `--root` = detected project root (same logic as `codescan status`). If not in a codescan project, defaults to `--all`.
- `--since` = `1h`
- `--all` = disables root-substring filter (show any codescan project)
- `--limit` = no default. When set, we cap in-process after reading from the OS tool (take the last N lines), since `log show` has no line-count flag and `journalctl -n` applies before filtering.
- `--follow` = live tail mode (CLI only, not MCP)

Dispatch:

**macOS (`uname -s` = Darwin):**
```
log show --predicate 'process == "codescan"' --last <since> [--last ... with --follow → log stream]
```
The output is then filtered in-process by substring match on `<root>:` (because `log show`'s predicate language doesn't match on arbitrary message substrings reliably).

**Linux:**
```
journalctl -t codescan --since "<since>" [--follow]
```
Output filtered by substring match on `<root>:`. (We could use `journalctl --grep` but string matching in-process is simpler and identical across platforms.)

**Other platforms:** print a clear error: `codescan log: unsupported platform (supported: macOS, Linux)`. Exit 1.

Retrieval works even when the watcher process is dead — the logs are in the OS log store.

### 6. MCP tool

Add `logs` handler to `src/mcp.zig`:

- Tool name: `logs`
- Description: "Read recent watcher logs from the OS log (macOS unified log / Linux journald), filtered to codescan and optionally to a project root."
- Params:
  - `root?: string` — absolute path; defaults to server's project root
  - `since?: string` — defaults to `1h`
  - `limit?: integer` — defaults to 200
  - `all?: boolean` — if true, disables root filter
- Returns: plain-text log lines (one MCP text content block). No streaming / `--follow` over MCP.

Internally shares a `readLogs(allocator, opts) ![]u8` function with the CLI.

### 7. Testing

- **Unit:** `syslog.zig` has a `log`/`logWithRoot` that no-ops when uninitialized; assert no crash, no call-through.
- **Integration (gated):** a test that initializes syslog with a unique tag (e.g. `codescan-test-<pid>`) and verifies the platform's log tool finds the message. Gate on `CODESCAN_RUN_SYSLOG_TESTS=1` to keep the default `zig build test` fast and hermetic.
- **CLI:** table-test `codescan log --since <x>` invocations by mocking the underlying command dispatcher (inject the command-runner seam).
- **MCP:** existing MCP tests already stub the handler layer; add one for `logs`.

### 8. Build system

`build.zig` already links libc for the main binary (needed for SQLite). No additional deps. Confirm by grep; adjust only if needed.

### 9. Help text and README

- `codescan --help` gets a `log` entry under `Commands`.
- `codescan log --help` describes flags and shows platform-specific examples.
- README adds a one-paragraph blurb pointing users at `codescan log` when the watcher has stopped unexpectedly.

## Risks and Mitigations

- **`syslog(3)` variadic FFI on different Zig targets** — mitigated by always calling `syslog(priority, "%s", cstr)`; no variadic args from our side beyond the single `%s`.
- **macOS unified log can lag** — messages may take a few seconds to appear in `log show`. Acceptable for the use case (post-mortem inspection).
- **Message size** — POSIX `syslog` truncates around 1024 bytes on many platforms. We pre-truncate to 1024 to avoid silent cutoffs mid-UTF-8.
- **Log tool not in PATH** (e.g. minimal Linux container without `journalctl`) — `codescan log` prints a helpful error pointing at the raw log location.

## Rollout

Single PR on `yolo`. No migration needed. No config changes required.
