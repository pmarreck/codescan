# Plan

## 2026-07-30 — embedding-server probe bounds

- [x] Restore the full five-target CLI build contract before shipping the bounded-preflight work. (completed 2026-08-04 13:50 EDT)
  The Windows red build first exposed POSIX-only `localtime_r` and `tm_zone` in `writeLocalTime`. The new conversion uses Windows `localtime_s` or POSIX `localtime_r`, and standard `strftime("%Z")` supplies a zone only when it is valid UTF-8. A deterministic rendering test covers both present and absent zones.
  The repaired first error exposed a second one: `std.posix.pid_t` is opaque on Windows, even though the Unix-only watcher-list command returns an unsupported-platform error before using it. `WatcherInfo` and `LsofEntry` now use the project numeric PID type, so all callers compile. The two focused tests, `./test`, and `./build` pass. ReleaseFast builds pass for macOS ARM64, Linux ARM64/x86_64, and Windows ARM64/x86_64.
  Curiosity poke: cross-compilation proves source and linkage only. Run the normal Windows status command on a Windows host when one is available to observe local timezone rendering and the unsupported watcher-management message.
- [x] Retire the abandoned Jujutsu cheatsheet in its own commit, then push the repaired fleet and watch the exact head commit in Mechatron Prime. (completed 2026-08-04 13:52 EDT)
  `jj_cheatsheet.md` is an accepted deletion, not an accidental dirty change. It follows the portability repair as a separate documentation commit; both commits will be submitted in one push so it does not create a second CI run.

- [~] Bound startup preflight metadata calls at 10s, warning to stderr above 3s. **Implemented and proved on Linux; native macOS/Windows acceptance remains.**
  Peter asked for a 10s limit with a >3s warning (2026-07-30 15:16 EDT). `std.http.Client.ConnectTcpOptions.timeout` remains inert in Zig 0.16, and directly forwarding it reaches a `TODO implement netConnectIp* with timeout` panic. That patch remains disqualified.
  `HttpRequest.deadline_ns` now means a whole-request deadline. `StdHttpTransport` runs an opted-in request in `std.Io.concurrent`, waits on an owned completion word, and calls `Future.cancel` on expiry. `cancel` joins the task before return, so it cannot retain the request slices, allocator, or transport after its caller deinitializes them. Reachability plus `/api/tags` and `/api/ps` carry the 10s deadline. Embedding POSTs deliberately do not: a cold model may take minutes to load.
  Linux proof: a deterministic transport test observes cancellation and task teardown before the caller gets `Timeout`; the existing local IPv4 HTTP test succeeds through the deadline path; and a non-committed live acceptance probe to `10.255.255.1:80` returned `Timeout` at 500ms, where the original synchronous client remained stuck beyond 40s. `./test` and `./build` passed (2026-08-03 16:56 EDT). macOS aarch64, Linux aarch64, and Linux x86_64 cross-compiles passed. Windows cross-compilation is currently blocked before this change by `main.zig` using POSIX-only `localtime_r`.
  Curiosity poke: HTTPS/TLS cancellation, clock-boundary races, and native macOS/Windows behavior still need direct acceptance; cross-compilation proves only that the source compiles.
  - [x] TDD spike: prove a `std.Io.concurrent` HTTP task can be canceled at an owned deadline, joined safely, and reported as a timeout without a child process. (completed 2026-08-03 16:56 EDT)
  - [ ] Run the TCP-DROP deadline acceptance on native macOS and Windows once Windows builds again.
    Curiosity poke: Windows `Threaded` calls `NtCancelSynchronousIoFile`, while pthread platforms interrupt a blocked syscall with `SIGIO`; confirm the application-level `std.http.Client` result, not merely those implementation branches.
  - [ ] Assess exponential retry/backoff after an embedding transport failure. (Peter, 2026-08-02)
    Curiosity poke: retry policy can improve transient refusal/reset recovery but cannot bound a TCP-DROP connect already blocked inside Zig's synchronous client; keep those two failure classes separate rather than presenting retries as a timeout.
  - [x] Reject process isolation for the HTTP deadline. (completed 2026-08-03 16:56 EDT)
    `std.Io.Future.cancel` gives the needed join-before-return lifetime guarantee without subprocess IPC or platform-specific reaping.
  - [x] Establish why Zig 0.16 lacks a cancellable/timed threaded TCP connect, using current upstream evidence before selecting a workaround. (completed 2026-08-03 16:20 EDT)
    The current upstream source still panics for any non-none `IpAddress.ConnectOptions.timeout` on both POSIX and Windows, while `std.http.Client.connectTcpOptions` still omits the option when calling `HostName.connect`. This is incomplete integration from the 0.16 `std.Io` redesign, rather than an intentional no-deadlines policy: the same runtime provides cancellable `Future`s and has explicit blocked-syscall interruption paths. No maintainer rationale or tracked deadline implementation was found; do not promote that inference to a claim of intent.
  - [ ] Repair the pre-existing Windows build failure in `writeLocalTime`: `main.zig` calls POSIX-only `localtime_r`, absent from the Windows C import. First observed 2026-08-03 while compiling aarch64-windows-gnu; it is present unchanged in `d42d4ac13bed`.
    Curiosity poke: use the Windows-safe local-time API behind one platform adapter and compile both Windows targets before treating it as fixed.
- [x] Make `server.zig` `parseAddress` IPv6-capable; no hardcoded `localhost -> 127.0.0.1`. (completed 2026-07-30 15:40 EDT)
  Curiosity poke: this is a **bind**, so the family decided here decides who can reach the server. `localhost` was rewritten to `127.0.0.1` unconditionally, so `codescan serve` on localhost was unreachable to IPv6 clients no matter how the machine's own resolver was configured. Hostnames now resolve normally; literals are never resolved; `[::1]` bracket form is accepted since a host copied from a URL carries brackets. Tested as a classifier over the host set (v4, v6, wildcards of both families, bracketed, empty, malformed brackets) rather than one example. An empty host is rejected rather than defaulting to a wildcard bind, which would expose the server far wider than asked. Verified live: binds `[::1]` and answers `/health` over IPv6, and IPv4 still binds.
  Fixed in passing: the startup line printed `http://::1:18251/`, which is not a valid URL and cannot be pasted into curl or a browser. IPv6 literals are now bracketed for display.
  Still open: `http_host`/`http_port` are settable only via `.codescan/config.ini` — there is no `--host`/`--port` CLI flag, and `codescan serve --host ::1` currently fails with "unknown flag". Worth adding for parity with every other setting.


- [ ] Move update database preparation/rebuild policy and freshness reconciliation out of the CLI adapter.
  Curiosity poke: the two-phase open (inspect first, probe the live embedder's real dimension, only then recreate) is the invariant that must survive — never destroy an index before proving the replacement embedder produces the expected vector width.
  - [x] Extract the pure database-lifecycle decision (`decideDbAction`) and exhaust its probe × mode domain. (completed 2026-07-28 12:52 EDT)
  - [x] Move the two-phase orchestration into `update_service`, leaving `main.zig` rendering the report. (completed 2026-07-28 13:12 EDT)
    Curiosity poke: the invariant the handoff called most important — never destroy an index before the live embedder's real width is proven — turned out to have **no test at all**, because it lived in `runUpdateWithInvocation` and needed a CLI plus a live provider to reach. The RED phase stood `prepare` up as a recreate-without-probing stub and watched it wipe a seeded index; 3 of 5 new tests failed on exactly that. `(use_null_embedder, invocation)` became an explicit `RebuildPolicy` (refuse / recreate_unverified / verify_then_recreate), and the fake embedder counts calls so "never contacted the provider" is asserted, not assumed. Also deleted the duplicate `probeEmbeddingDim` from `main.zig` — the same second-implementation smell that produced the `serverReachable` bug.
  - [x] Repoint `SearchFreshnessContext` at the service; leave `freshness.ensureFresh` policy untouched. (completed 2026-07-28 13:31 EDT)
    Curiosity poke: `indexUsable` now lives in the service and is tested as a classifier over three states, not one — missing, present-but-empty, and populated. "Present but empty" is the case that matters: freshness policy may fall back to a stale index when reconciliation fails, so calling an empty index usable would turn a failed update into a silent zero-result search. A mutation that treated any openable database as usable was caught on exactly that assertion. `freshness.ensureFresh` untouched, as its policy and tests were already correct.
  - [x] Repoint HTTP + MCP adapters (and the watcher) at the one indexing entrypoint. (completed 2026-07-28 13:27 EDT)
    Curiosity poke: the 2026-07-24 "route indexing through one application service" item had only been done for the CLI. Four sites still called `indexer` directly — `server.zig` /index, both MCP index paths, and all four `watcher.zig` calls. MCP was worst: `mcp.Settings` had no `index_ext`/`index_type` fields at all, so that surface could not honor the config even in principle, and since its index tool recreates the DB first, a dimension mismatch would destroy the index and rebuild it at a width the provider never emits. Manual reading found three of the four; the mechanical sweep found `watcher.zig`. Hence `tests/unit/test-single-index-entrypoint` as a structural control rather than four one-off fixes.
    Deliberate choice: `watcher.zig` was arguably a false positive (its options came pre-resolved from `main.zig` via `buildIndexFilters`), but it was routed through the service anyway rather than exempted — a control carrying a standing exemption is one someone must re-justify forever, and a checker that flags good code stops being believed.
    Behavior change to watch: `index_ext`/`index_type` now actually apply to watcher passes and to both non-CLI surfaces.
- [x] Retire `CODE_MINIMAP.md`; migrate its per-file descriptions into `dirtree note` annotations (new official guidance). (completed 2026-07-28 12:47 EDT)
  Curiosity poke: it was worse than duplicated — 3 entries named files that no longer exist (`.jjignore`, `ZIG_RECENT_API_CHANGES_2025.md`, `src/ollama.zig`), 28 source files were documented in neither place, and live entries had drifted (`embedding.zig` was described as an "Ollama adapter" long after it became a dialect-aware `HttpEmbedder`/`NullEmbedder`; config moved to `config.ini` with a legacy fallback). Migrated by re-deriving each description from current code. Annotations went 43 → 139; no orphans.
- [x] Stop shipping a machine-specific MCP server path, and guard it. (completed 2026-07-28 12:46 EDT)
  Curiosity poke: `.mcp.json` is committed, so its absolute `/Users/pmarreck/Documents-CloudManaged/...` command was wrong on every machine but the one that wrote it — codescan's own MCP tools silently vanished from the agent with only an ENOENT in `claude mcp list`. This is precisely the "commands that report success while doing nothing" failure class the project treats as first-order. Fixed to a PATH-resolved `codescan`, with `tests/unit/test-portable-mcp-config` as a set classifier over every server's command and args, not a spot check.
- [x] Let codescan register itself as an MCP server for Claude and Codex if not already present. (completed 2026-07-28 13:01 EDT)
  Curiosity poke: idempotency turned out to be free rather than delicate — both agents expose `mcp get <name>` with a 0/non-zero exit, so membership is decided by the owning tool instead of by parsing a listing. That makes the `codescan-old` false-positive structurally impossible rather than merely tested against. `--force` must not escalate a first-time install into remove-then-add of a nonexistent entry; that case is in the exhausted domain and in the CLI suite. Agents beyond claude/codex (grok, opencode, gemini-cli) are a one-enum-entry addition.
- [x] Add a machine-wide config tier merged under each project's, applying to all settings. (completed 2026-07-28 13:46 EDT)
  Curiosity poke: per-key merge is the whole feature — a whole-file override would mean any project with a config at all stops inheriting the global one, defeating the "one embedding URL for 100 projects" motivation. The merge is a comptime sweep over `Config`'s fields so a setting added later participates automatically, and a field that is neither optional nor a list is a compile error rather than a silently skipped key. List settings accumulate (global ignores, then project) rather than replace.
  Correction to an earlier assumption: absent and empty global files are NOT meaningfully different here, since all fields are optional and an empty config contributes nothing. The case that actually bites is absent-vs-malformed: `FileNotFound`/`NotDir` are swallowed, everything else propagates, so a typo'd global config cannot be silently ignored.
  Defect fixed in the same change: adding the tier made `config show` misleading, since printing only the project file would let a user conclude their global settings were not applied. It now labels both tiers and states the precedence.
  Follow-up worth considering: `config show` prints the two files rather than the effective merged values, so a key set in both is shown twice with no indication which won.
- [ ] Implement the self-retiring watcher (idle-timeout after last successful index commit, never mid-index).
  Decisions from Peter (2026-07-28 12:40 EDT): global config tier applies to **all** settings (done); "never retire" IS required — accept `0` or the literal `never`; a never-indexed project times from **watcher start**, so it still eventually retires.
  - [x] Pure policy: `shouldRetire` over an injected clock reading, plus `parseIdleLimit`. (completed 2026-07-28 13:52 EDT)
    Curiosity poke: no sleeps and no real clock anywhere — the caller supplies `now_ns`, so boundary cases are exact. Cases pinned: an in-progress index dominates every other input; a null limit never retires (the systemd restart-loop case); idleness resets on each commit; a never-indexed project times from watcher start; and a marker **ahead of now** (clock skew, restored backup, file from another machine) keeps the watcher alive rather than letting an unsigned subtraction wrap and retire instantly. `parseIdleLimit` rejects typos rather than defaulting — a bad value must not silently become either "never" or "immediately". Mutations confirmed both parser branches bite.
  - [x] Integrate into both watch loops, with teardown and a logged reason. (completed 2026-07-28 14:04 EDT)
    Curiosity poke: the detail the whole feature turns on is that a no-op index pass must NOT reset the countdown. A polling watcher runs a pass every couple of seconds, so counting those as activity makes the idle limit unreachable and the watcher immortal — `countsAsActivity` exists solely to state that, and its first test is the all-zero case. A shared `RetirementTracker` owns the in-progress flag for both loops so they cannot drift on the race, and the decision is taken outside the index call so the flag can never be read mid-pass.
    Teardown was already covered by existing `defer`s (pidfile, progress file, watcher handle); what was missing was saying why, so retirement logs to both stderr and syslog.
  - [x] Live acceptance. (completed 2026-07-28 14:04 EDT)
    Differential rather than self-reported: with a 15s limit and a file touched at 10s, the watcher retired at **29s** rather than 15s, proving activity reset the countdown. Pidfile cleaned, exit 0.
    Two defects found and fixed by running it: a 10s limit rendered as "0 minute(s)" (now a real duration formatter, tested across units and the not-evenly-divisible cases), and a **pre-existing leak** in `progress.setup`/`clear` — the returned path was never freed. It had been invisible because the watcher previously only ever exited by signal, where nothing checks; making clean exit reachable surfaced it.
  Curiosity poke: introducing a global tier changes effective config for every existing project the moment the file exists, so precedence needs its own set-level tests (project overrides global, CLI overrides both, absent file is not an empty file).

## 2026-07-27 — one way to reach the embedding server

- [x] Unite every embedding-server connection on the shared `Transport` so reachability cannot contradict the code that embeds. (completed 2026-07-28 08:51 EDT)
  Curiosity poke: `codescan init` embedded happily against `http://localhost:11434` and `codescan watcher start` called the same URL unreachable 18 seconds later. Ollama binds `127.0.0.1` only; `localhost` resolves to `::1` first on dual-stack hosts. `std.http.Client` goes through `HostName.connect`, which races every resolved address (Happy Eyeballs) and wins on IPv4 — but `canConnectToEmbeddingServer` hand-rolled `IpAddress.resolve` + `connect`, got the single `::1` answer, and was refused in ~1ms (the reported 13ms total). The bug was a *direct consequence of there being a second implementation*; the fix is deletion, not repair.
  Second defect in the same code: a bare TCP connect only proves "something is listening", so it would green-light any unrelated process holding the port. Reachability now means "a server answered HTTP", with 401/404 counted as reachable.
  Watch: `serverReachable` has no timeout, so a firewall that DROPs (rather than refuses) can stall watcher start. The old probe had the same exposure, so this is not a regression — but it is now the single place to fix it.
- [x] Stop `watcher start` reporting success when the daemon is about to die, by checking model availability in preflight. (completed 2026-07-28 08:51 EDT)
  Curiosity poke: found only after the reachability fix above unmasked it — the preflight had been rejecting every start, so the daemon never got far enough to die. `spawn()` returning success only proves fork/exec worked; the daemon then runs with stdin/stdout/stderr closed, so its real error ("model not found") went nowhere and `watcher status` just said "No watcher running". `preflight` existed precisely to catch this class and already had `ensureModelAvailable` available to it — it simply never called it.
  Deliberate non-failure: `error.ModelLoading` (present but cold) must NOT block startup; the daemon loads on first embed. Blocking there would trade a silent failure for a false alarm. OpenAI-dialect servers expose no inventory, so absence of proof is never treated as proof of absence.
- [x] `watcher start` no longer reports success before the daemon has claimed its pidfile. (completed 2026-07-29 12:02 EDT)
  Curiosity poke: the parent now waits for the claim, bounded at 100 x 20ms, so "Started" means started. Reproduced first (`start` then immediate `status` said "No watcher running"), fixed, and re-verified (now reports the PID). Costs ~136ms on `watch start` — the honest price of a truthful message; it used to return faster by lying. The wait policy (`pidfile.awaitClaim`) is pure with an injected probe and tick: it probes before waiting at all, and gives up rather than hanging, because trading a confusing message for a wedge would be a worse bug than the one being fixed. Mutations confirmed both properties bite.
- [ ] Operational: never hand-start `ollama serve`. One instance only — Peter's fork as the systemd service on 11434, store `/var/lib/ollama/models`. `~/.ollama` is a dead 2023 store; seeing zephyr/mistral/everythinglm in `/api/tags` means you are on the wrong instance. Stock ollama returns HTTP 501 for Jina (no last-token pooling), which is why the fork exists. A second instance fails silently — it serves the wrong store and locks the real service out of the port.

## 2026-07-24 — lexical match quality

- [x] Suppress ANSI styling when human search output is not written to a terminal. (completed 2026-07-24 22:16 EDT)
  Curiosity poke: `NO_COLOR` was honored but stdout was never checked for TTY-ness, so every piped or agent-consumed search carried escape codes. Verified in both directions — plain under a pipe, styled under a forced pty.
- [x] Reject unknown CLI flags instead of folding them into the search query. (completed 2026-07-24 22:33 EDT)
  Curiosity poke: it was worse than "silently ignored" — `search` appended any unmatched argument to the query text, so a misspelled `--lexical-only` searched for a corrupted string and returned plausible weak results with exit 0. Rejecting flags required adding the POSIX `--` end-of-options separator first, otherwise flag-shaped text became unsearchable.
- [x] Add the conventional `--color <when>` plus `--simple` / `--no-color` / `--no-ansi` switches. (completed 2026-07-24 22:39 EDT)
  Curiosity poke: auto-suppression alone left a human piping into `less -R` with no way to get color back, so `--color always` is the counterpart that makes the auto default safe. Explicit `--color` deliberately overrides `NO_COLOR`, matching ripgrep/git.
- [x] Stop default search from pinning the language filter to the repo's most-populous language, which silently returned zero results in polyglot repositories. (completed 2026-07-24 22:08 EDT)
  Curiosity poke: the reporter's hypothesis (a query→language classifier) was wrong — the query text never participated. `buildSearchFilters` unconditionally applied `storage.primaryLanguage(db)` whenever no explicit filter was given, so the fix is to admit every *code* language (preserving doc exclusion) rather than to threshold a classifier that does not exist. Filters were re-tested as a classifier over a language set, not one query.
  Consequence to watch: per-language `weights.toml` entries apply only when `allowed_langs.len == 1`, so they now take effect on explicit `--lang` searches rather than on default searches. This is more coherent than applying whichever language happened to dominate the repository, but it is a real behavior change for anyone with a per-language weights table.

- [x] Keep empty normalized metadata/comments out of embedding batches and preserve YAML block-list frontmatter tags. (completed 2026-07-24 15:31 EDT)
  Curiosity poke: Ollama/Jina misleadingly reports empty input as a context overflow; classify empty, whitespace-only, and real comments as a set without weakening unrelated HTTP 400 failures.
- [x] Make live HTTP/integration tests default to the currently recommended local Jina model instead of the removed `bge-large` installation. (completed 2026-07-24 16:02 EDT)
  Curiosity poke: retain explicit `OLLAMA_MODEL` and `OLLAMA_EMBEDDING_DIM` overrides so alternate compatible providers remain testable.
- [ ] Boldly split command orchestration from CLI, HTTP, and MCP adapters after the context-overflow repair is committed green.
  Curiosity poke: preserve command/help/root semantics and API parity while moving behavior mechanically in independently tested slices rather than one unreviewable rewrite.
  - [x] Introduce one application-level search service that owns filter, weight, and search-option resolution. (completed 2026-07-24 15:45 EDT)
  - [x] Migrate HTTP search to the shared service and retain HTTP-only parsing/rendering in the adapter. (completed 2026-07-24 15:45 EDT)
  - [x] Migrate MCP search to the shared service and retain JSON-RPC diagnostics/rendering in the adapter. (completed 2026-07-24 15:57 EDT)
  - [x] Migrate CLI search to the shared service and retain terminal diagnostics/rendering in the adapter. (completed 2026-07-24 16:00 EDT)
  - [x] Route full and incremental indexing through one application service while keeping provider probing and terminal progress in adapters. (completed 2026-07-24 16:16 EDT)
  - [ ] Move update database preparation/rebuild policy and freshness reconciliation out of the CLI adapter.
- [x] Make `--root` order-independent for every project-root command and resolve `read-file` relative paths against the effective root. (completed 2026-07-24 12:35 EDT)
  Curiosity poke: later `--root` arguments must win, absolute paths must remain absolute, and neither ordering may silently fall back to search.
- [x] Trace unchanged pre-search reconciliation and prove the prior discovery fix keeps it subsecond on representative repositories. (completed 2026-07-24 12:34 EDT)
  Curiosity poke: separate filesystem/SQLite reconciliation from changed-file extraction and remote embedding so one aggregate duration cannot hide the real bottleneck.
- [x] Make `search --lexical-only` an explicit alias for `--mode lexical`, skipping semantic reconciliation while hybrid/vector searches retain fully fresh embeddings. (completed 2026-07-24 14:49 EDT)
  Curiosity poke: later mode switches must win, regex must remain non-semantic, and lexical-only search must never contact a configured embedding endpoint.
- [x] Switch rebuildable WAL indexes to `synchronous=NORMAL`, reducing a 1,000-symbol syscall oracle from 2,046 fsyncs to 32 without weakening incremental completion boundaries. (completed 2026-07-24 14:56 EDT)
  Curiosity poke: assert the connection's effective pragma rather than trusting configuration text; retain checkpoints and crash-consistent SQLite transactions.
- [x] Make cross-table symbol deletion atomic and harden hashline/FTS persistence paths identified by the independent deep review. (completed 2026-07-24 14:54 EDT)
  Curiosity poke: inject a final-delete failure to prove vectors roll back, round-trip distinct boundary hashes, and treat quotes inside FTS tokens as literal query text.
- [x] Route GitHub and Nix CI through the aggregated `test-unit` target so same-seed imported tests cannot contend across duplicate binaries. (completed 2026-07-24 10:39 EDT)
  Curiosity poke: the aggregate must still import every source module, and the Nix check must continue smoke-executing the release binary after tests pass.
- [x] Reject fake `.git` directories before Git file-list acceleration so scanners deterministically fall back to filesystem traversal. (completed 2026-07-24 10:51 EDT)
  Curiosity poke: real repositories require `.git/HEAD`, while worktrees and submodules use a regular `.git` marker file and must remain accelerated.
- [x] Rank canonical word/component matches above contained substrings without sacrificing snake_case, kebab-case, or camelCase recall. (completed 2026-07-24 09:27 EDT)
  Curiosity poke: `time` must outrank `runtime`, while `help height` must still find `help_fits_height`; BM25-backed and fallback-only candidates must use comparable lexical evidence.
- [x] Make weak-result CLI guidance concise while preserving structured confidence/evidence in JSON. (completed 2026-07-24 09:27 EDT)
  Curiosity poke: brevity must not hide that results remain best-effort rather than omitted.
- [ ] Establish a versioned relevance corpus from real agent queries and rank expected useful results with MRR, nDCG, and Recall@k.
  Curiosity poke: relevance judgments need an independent, auditable oracle and a held-out set so hand-tuned weights cannot merely overfit remembered failures.

## 2026-07-23 — script discovery and language expansion

- [x] Touch `.codescan/last_index_datetime` only after each full, incremental, or watcher single-file index commit succeeds. (completed 2026-07-23 23:40 EDT)
  Curiosity poke: a failed final embedding batch must leave the prior marker untouched so stale-watcher reaping never treats partial index state as recent success.
- [x] Make unchanged update/search reconciliation write-free and remove redundant Git executable PATH probing. (completed 2026-07-23 23:28 EDT)
  Curiosity poke: a current compatible schema must not rewrite identical metadata or force WAL fsyncs, while migrations, model changes, new files, and deletions must still commit normally.
- [x] Make every interactive confirmation/model prompt consume one submitted line immediately, honor its displayed default, and announce each potentially slow init phase before doing work. (completed 2026-07-23 23:08 EDT)
  Curiosity poke: an open TTY that has delivered `y\n` is not EOF; confirmation, cancellation, overlong input, model loading, and indexing must never depend on filling an arbitrary buffer.
- [x] Make interactive `codescan init` choose an Ollama embedding model when the configured model is unavailable, recommend locally patched Jina, validate a real non-empty embedding through Ollama or authenticated oMLX, and persist only the validated selection and returned dimension. (completed 2026-07-23 17:36 EDT)
  Curiosity poke: an installed completion-only model, a missing custom name, bad oMLX credentials, EOF/cancellation, or a failed probe must never leave an active model/dimension setting, schema, or watcher branded with unvalidated metadata.
- [x] Classify extensionless scripts consistently in discovery, full index, update, and watcher reindex paths using regular-text-file, executable-bit, and recognized-shebang evidence. (completed 2026-07-23 12:55 EDT)
  Curiosity poke: extension-bearing source remains governed by its plugin, while non-executable files and NUL-containing binary impostors must never enter through shebang fallback.
- [x] Preserve top-level Bash commands, assignments, and control flow as a searchable file-level module alongside extracted functions. (completed 2026-07-23 13:00 EDT)
  Curiosity poke: top-level literals such as `notarytool` need file provenance without pretending every command is a named function.
- [x] Add supported-language shebang aliases for existing extractors, beginning with Ruby and then explicitly reviewing Clojure/Babashka, Node-family JavaScript, Elixir/Escript, Haskell runners, Swift, Nim, Erlang, and OCaml. (completed 2026-07-23 14:05 EDT)
  Curiosity poke: an interpreter alias is valid only when its syntax is genuinely compatible with the selected extractor grammar; Nix multi-line shebangs and `env -S` need deliberate fixtures.
- [x] Fetch and pin the approved Tree-sitter grammars through the Nix flake; source builds deliberately require the flake-provided grammar root. (completed 2026-07-23 14:05 EDT)
  Curiosity poke: every pinned source must expose generated C parser/scanner inputs for all five supported target combinations without requiring Node or network access during the build.
- [x] Expand the supported-language matrix with Fish, Nushell, PowerShell, Tcl, Oil Shell (OSH/YSH distinctions), F#, Elm, Gleam, Racket/Scheme, Common Lisp, Standard ML, and WebAssembly Text; document grammar provenance, extensions, shebang aliases, extraction coverage, and limitations. (completed 2026-07-23 14:05 EDT)
  Curiosity poke: Clojure and OCaml are already supported; explicitly document Python and Scala as project-policy exclusions so they are not added accidentally.
- [x] Attach adjacent WAT `;;` and nested `(; ... ;)` comments to extracted symbols and prove comment-only vocabulary retrieves the associated symbol. (completed 2026-07-23 14:05 EDT)
  Curiosity poke: WAT is terse, so comment provenance must survive extraction and comment embedding without accidentally stealing a sibling declaration's trailing comment.
- [x] Parse leading Markdown YAML frontmatter as explicit search evidence, ranking `description` and exact `tags` matches above ordinary body text while preserving field provenance and metadata-only retrieval. (completed 2026-07-23 14:20 EDT)
  Curiosity poke: accept Peter's `.frontmatter.md` memory contract without requiring a general YAML dependency; malformed delimiters, multiline values, tag-vs-prose collisions, and accidental metadata duplication across every heading must remain deterministic.
- [x] Support global `--no-progress` across long-running CLI operations, beginning with a failing parser/CLI test and preserving final output, warnings, and errors. (completed 2026-07-23 14:20 EDT)
  Curiosity poke: later arguments must still override earlier conflicting progress flags, and non-TTY behavior must remain silent without changing JSON/stdout contracts.

## 2026-07-22 — fully local Jina via Ollama

- [x] Make watchers explicit and reconcile the index silently before every indexed search when no project watcher is active. (completed 2026-07-23 11:33 EDT)
  Curiosity poke: an unavailable embedding service must preserve useful stale search, while an absent/invalid index must fail honestly; recommend a watcher only after >1 second when the latest commit is ≤7 days old or Git reports >2 changed paths.
- [x] Give explicit `codescan update` phase-specific stderr feedback when its initial filesystem discovery/comparison exceeds one second. (completed 2026-07-23 11:33 EDT)
  Curiosity poke: inject the monotonic clock and assert exact threshold behavior without sleeps; keep fast updates and machine-readable stdout clean.
- [ ] Make each `codescan watch` process retire itself after a configurable idle interval, replacing the planned external stale-watcher reaper.
  Curiosity poke: define idleness from the last successful index commit, never exit during an active index, and use CLI override → project config → global config → one-day default precedence.
- [x] Change the sequential fleet job to `codescan update` every eligible Git repository except the three intentional exclusions. (completed 2026-07-23 11:33 EDT)
  Curiosity poke: the old completed-index resume list must not suppress update reconciliation, and the runner must never leave one implicit watcher per repository.
- [x] Make incremental completion crash-safe, recover partial/missing vectors, remove vanished files, and rebuild indexes whose stored embedding model differs. (completed 2026-07-23 11:33 EDT)
  Curiosity poke: a file marker is valid only after its final code and comment batches commit; interrupted cross-file batches must remain recoverable without sacrificing batching.
- [x] Label weak search hits without suppressing them, and expose lexical match provenance in human and JSON output. (completed 2026-07-23 11:33 EDT)
  Curiosity poke: a strong match in an undisplayed attached comment must remain strong and identify `comment` as its source; raw hybrid/RRF scores are not probabilities.
- [ ] Resume the sequential sweep at incomplete `entropy_shield` through the patched three-slot Ollama sidecar.
  Curiosity poke: skip every repository proven complete through `elm-posix`, but do not skip the partially rebuilt `entropy_shield`.
- [x] Audit every direct `~/Code/*/.codescan` configuration and make the effective model explicit Jina/1536. (completed 2026-07-23 09:23 EDT)
  Curiosity poke: a missing config silently falls back to BGE even when no file contains the literal `bge-large`; distinguish old metadata from stored vectors.
- [x] Add a sequential `~/Code` Git-project reindex runner with exact exclusions and percentage progress. (completed 2026-07-22 18:06 EDT)
  Curiosity poke: paths with spaces, `.git` files, failed indexes, and an empty candidate set must not corrupt traversal or hide failures.
- [x] Resume the interrupted sweep at `dirtree` by skipping only previously completed project names. (completed 2026-07-22 20:24 EDT)
  Curiosity poke: `dirtree` itself must remain eligible because its recreate-first index was interrupted.
- [ ] Reproduce the historical `codescan watch` heap growth with deterministic synthetic event batches and compare implicit versus explicit roots.
  Curiosity poke: distinguish an event-loop allocation leak from an unbounded cache without overnight sleeps or RSS-only assertions.
- [ ] Reproduce WAT indexing as a tracked-file classifier set before changing plugin coverage.
  Curiosity poke: `code.wat`, nested tracked modules, ignored files, and ordinary extensionless data must be classified together.
- [x] Import Jina GGUF with explicit last-token pooling metadata so Ollama exposes embedding capability. (completed 2026-07-22 17:00 EDT)
  Curiosity poke: model metadata must select Jina's required EOS/last pooling, not merely make the endpoint return numbers.
- [x] Point this repository at `127.0.0.1:11434` without an API key or Tailscale dependency. (completed 2026-07-22 17:00 EDT)
  Curiosity poke: preserve the prior oMLX configuration as a recoverable fallback rather than overwriting it.
- [x] Re-index a real bounded project with the local Ollama model and prove relevant semantic retrieval. (completed 2026-07-22 17:00 EDT)
  Curiosity poke: avoid disk-heavy fixture rebuilds; one real index plus model/dimension/count assertions is sufficient.
- [x] Document the complete RAM-backed, hash-verified local Ollama import procedure in README. (completed 2026-07-22 17:54 EDT)
  Curiosity poke: the runbook must verify pooling metadata and avoid both in-place Ollama blob edits and `/tmp` on spinning storage.
- [x] Correct `codescan setup-model` so its Ollama path uses the verified pooling-metadata guide, and make its recommendation the single code-level source consumed by interactive init. (completed 2026-07-23 17:36 EDT)
  Curiosity poke: changing the recommendation must update both CLI surfaces without reviving a raw GGUF pull that Ollama classifies as completion-only.

## 2026-07-21 — indexing environment and repository-boundary hardening

- [x] Preserve nonempty inherited Zig global/local cache paths through `nix develop -c`. (completed 2026-07-22 14:05 EDT)
  Curiosity poke: empty variables should still receive safe local defaults.
- [x] Enforce the selected bold root contract: implicit `.codescan` must be adjacent to the nearest `.git`/`.jj` marker. (completed 2026-07-22 14:05 EDT)
  Curiosity poke: `.git` files, nested repositories, and `.jj` roots must behave deliberately.
- [x] Remove the committed oMLX credential example and block tracked literal oMLX keys. (completed 2026-07-22 14:05 EDT)
  Curiosity poke: tests must report locations without echoing matched secrets.
- [x] Configure Thelio for the Mac Jina embedding service without persisting its API key. (completed 2026-07-22 14:05 EDT)
  Curiosity poke: a missing key fails clearly; an unavailable Mac still needs a tested local fallback.
- [x] Index one explicitly bounded repository to nonzero vectors and prove a semantic query. (completed 2026-07-22 14:05 EDT)
  Curiosity poke: symbol counts alone must not be mistaken for successful vector indexing.
- [x] Verify Mac Jina survives a clean app/server restart with persisted discovery/config/model checks. (completed 2026-07-22 14:05 EDT)
  Curiosity poke: upstream oMLX support and local patched state may diverge after restart.
- [ ] Document/test the `bge-m3` failover path without weakening the code-relevance oracle.
  Curiosity poke: provider failover must not silently accept materially worse semantic retrieval.
- [x] Move integration fixture clones and generated indexes under RAM-backed `TMPDIR` before another full integration run. (completed 2026-07-23 11:33 EDT)
  Curiosity poke: preserve reusable source fixtures without directing SQLite rebuild traffic to spinning storage.

- [x] Add command-specific CLI help topics (`codescan help <command>`, `<command> --help`) with focused usage text for search/index/update/config (completed 2026-02-21 EST)
- [x] Simplify main `--help` to 25-line overview; add 18 per-command help topics (symbols, replace-symbol, insert-*, replace-lines, insert-at, replace-content, references, rename, watch, serve, mcp-serve, status, clean, init) plus concept topics (hashlines, name-paths, languages, lsp) (completed 2026-02-22 EST)
- [x] Add unified search scope flag (`--scope code|docs|comments|all`) while preserving existing docs/comments flags and CLI precedence rules (completed 2026-02-21 EST)
- [x] Add stdin JSON request envelope support (stateless CLI args synthesis + JSON output path) and black-box CLI coverage (completed 2026-02-21 EST)
- [x] Investigate `zig build test` runtime/timeout behavior in `tests/unit/test-unit`; replace with aggregated `zig build test-unit` to avoid multi-binary test compile blowup (completed 2026-02-22 EST)
- [x] Fix embedding-mismatch metadata clobber in `initSchema` (do not overwrite stored embedding dim/model when mismatch is detected on populated index) and add regression test (completed 2026-02-21 EST)
- [x] Align `mk_test_db` default embedding dimension with CLI default (1024) so CLI/HTTP black-box tests use stable defaults (completed 2026-02-21 EST)
- [x] Complete schema-v3 metadata migration path: add nullable `symbol_kind`/`symbol_visibility`/`symbol_scope`/`symbol_arity` columns with backward-compatible auto-migration from schema v2, and add regression tests (completed 2026-02-19 17:24 EST)
- [x] Add `.codescan/weights.toml` language-specific search weighting (default + per-language sections) with CLI/server/MCP wiring and explicit-request override precedence (completed 2026-02-19 16:54 EST)
- [x] Populate symbol metadata during indexing (inferred kind/visibility/scope/arity when extractors omit fields) and add regression tests (completed 2026-02-20 EST)
- [x] Add per-language metadata weighting (`weight_symbol_kind`/`weight_symbol_visibility`/`weight_symbol_scope`/`weight_symbol_arity`) in `weights.toml`, apply in ranking, and wire through CLI/HTTP/MCP search paths (completed 2026-02-20 EST)
- [x] Stabilize intent-aware hybrid ranking (typed boosts + conceptual cue handling + local-binding regression recovery) and re-run full `./test` (completed 2026-02-19 16:22 EST)
- [x] Lower default search score dropoff threshold from 0.65 to 0.3 (completed 2026-02-19 15:10 EST)
- [x] Respect `.gitignore` during indexing by using git file allowlist semantics when scanning repo roots (completed 2026-02-19 15:10 EST)
- [x] Always ignore `.git` and `.jj` directories during scan/index traversal (completed 2026-02-19 15:10 EST)
- [x] Fix hybrid attribution bug so lexical-only rows receive zero vector contribution (completed 2026-02-19 14:56 EST)
- [x] Add regression test for hybrid lexical-only vector-credit bug (completed 2026-02-19 14:56 EST)
- [x] Apply CLI/HTTP-equivalent search filters in MCP search path (completed 2026-02-19 14:56 EST)
- [x] Add natural-language relevance heuristics to demote local/generic symbols and reduce duplicate crowding (completed 2026-02-19 14:56 EST)
- [x] Add regression tests for local/generic demotion and duplicate-signature diversity behavior (completed 2026-02-19 14:56 EST)
- [x] Re-run `./test`, then update CODE_MINIMAP with relevance work summary (completed 2026-02-19 14:56 EST)

- [x] Define CLI contract (subcommands, flags, output formats)
- [x] Establish project scaffolding (flake.nix, build.zig, ./test)
- [x] Implement config loading (repo-local .codescan/config)
- [x] Define storage schema (sqlite + sqlite-vec) and migrations
- [x] Build embedding pipeline (Ollama HTTP client, batching)
- [x] Implement indexing flow (scan -> extract -> embed -> store)
- [x] Implement search flow (query embed -> hybrid ranking -> format)
- [x] Define plugin interface + registry
- [x] Implement Zig extractor (function spans + comments)
- [x] Implement Elixir extractor (function spans + comments)
- [x] Restore HTTP server + endpoints (index/update/search/health) — DONE 2026-06-01. `server.serve()` now uses `std.Io.net.IpAddress.listen` + `std.http.Server` v2 (io-aware) per Zig 0.16. Accept-loop dispatches each connection through `handleRequest`, with per-connection 16 KB header/write buffers. Smoke-tested: `GET /health`, `GET /status`, `GET /help`, `POST /search` all return 200 with correct JSON/text from the codescan repo's own index.
- [x] Add JSON output + human output formatting
- [x] Wire main CLI (config merge, commands, .codescan setup)
- [x] Add hybrid weight knobs (CLI/config/HTTP) + tests
- [x] Normalize hybrid weights automatically
- [x] Add FTS5 lexical search with fallback to LIKE
- [x] Index bash/lua shebang scripts without extension (2026-01-25 EST)
- [x] Reorganize test scripts under ./tests (2026-01-25 EST)
- [x] Prefer static link for pcre2 dependency
- [x] Add plugin-specific ignore globs with PCRE2-backed matcher
- [x] Support ignore config overrides (global + per-language) in .codescan/config
- [x] Replace sqlite-vec runtime extension with static init
- [x] Add sqlite-vec git dependency (build.zig.zon)
- [x] Fetch sqlite amalgamation via flake for sqlite-vec build
- [x] Evaluate/tune weights on example repo queries
- [x] Add C plugin (tree-sitter runtime + grammar, extractor, registry wiring)
- [x] Skip over max_file_size files during indexing (no hard error)
- [x] Add C plugin default ignores for Zig build caches
- [x] Ensure pcre2 headers/libs are available via flake env
- [x] Update documentation (CODE_MINIMAP.md, PROJECT_PLAN.md, PROJECT_STATE.md)
- [x] Add min_score search threshold (CLI/config/HTTP) + tests
- [x] Add integration test suite across Zig/Elixir/C fixture repos
- [x] Add basic HTTP server /health test
- [x] Update runtime CLI examples to avoid nix develop prefix
- [x] Default root to nearest .codescan ancestor when --root omitted
- [x] Verify default root/db path behavior when running from subdirectory
- [x] Add new language plugins (TypeScript, Rust, Lean4, Idris2, Nix, Nim, Bash, LuaJIT, Haskell)
- [x] Vendor or fetch tree-sitter grammars for new languages (best-effort AST)
- [x] Improve human output formatting (alignment + colors) and doc-comment gating (--verbose/--comments)
- [x] Add markdown/text/log plugins with semantic chunking
- [x] Add --ext/--type/--lang filters and --include-docs default behavior
- [x] Determine primary language by file counts and use for default search
- [x] Add comment-only embeddings + `--comments`/`--only-comments` search mode
- [x] Add `--only-docs` synonym + config keys for docs/comments filters
- [x] Ensure HTTP API parity for docs/comments/ext/type/lang filters
- [x] Add black-box CLI + HTTP test scripts with mk_test_db fixture
- [x] Add OLLAMA_MODEL env override + model-availability check with helpful error
- [x] Truncate embedding inputs (~1600 bytes) using sentence/line-aware boundaries
- [x] Recreate DB on reindex (delete file before init)
- [x] Add DEBUG-index logging + built-in ignore globs for common dirs
- [x] Add config show/edit commands
- [x] Add include_node_modules opt-in for indexing
- [x] Show TTY progress for index/update
- [ ] Add tests for edge cases and filters; keep tests fast/deterministic

## Semantic Editing (see SEMANTIC_EDITING_PLAN.md for full details)

### Phase 1: Tree-sitter Read-Only
- [x] `codescan symbols [pattern] [--file ...]` — unified symbol listing/search (multi-file, optional pattern)
- [x] Merged `find-symbol` into `symbols` (`find-symbol` kept as CLI/HTTP alias)
- [x] `query` added as alias for `search` (CLI, HTTP, MCP)
- [x] Hashline output format (3-char base-36 per-symbol chain hashes on code lines)
- [x] Name path resolution from tree-sitter AST hierarchy

### Phase 2: Tree-sitter Editing
- [x] `codescan replace-symbol <name_path> --file <path>` — byte-precise symbol body replacement
- [x] `codescan insert-after <name_path> --file <path>` — insert code after named symbol
- [x] `codescan insert-before <name_path> --file <path>` — insert code before named symbol
- [x] `codescan replace-lines --from <line:hash> --to <line:hash>` — hashline-anchored edits
- [x] `codescan insert-at <line:hash> --file <path>` — hashline-anchored insertion
- [x] Stdin body input for all editing commands

### Phase 3: Optional LSP Integration
- [x] `codescan references <name_path> --file <path>` — cross-file reference lookup
- [x] `codescan rename <name_path> --file <path> --to <new_name>` — cross-file rename
- [x] Auto-detect language and lazy-start appropriate LSP server

### Phase 4: Background Auto-Indexing
- [x] File watcher (kqueue/FSEvents) for incremental reindex on changes

### Phase 4b: MCP Server
- [x] `codescan mcp-serve` — JSON-RPC 2.0 stdio MCP server exposing all tools
- [x] String + integer JSON-RPC ID support (required by Claude Code)
- [x] Single-line JSON responses (newline-delimited protocol compliance)
- [x] Wire `codescan_search` and `codescan_index` through MCP (with auto-index)
- [x] Wire `codescan_config` through MCP (returns live settings as JSON)
- [x] MCP protocol compliance test suite (string IDs, single-line JSON, full handshake)
- [x] Project `.mcp.json` for Claude Code auto-discovery

### Phase 5: Enhancements
- [ ] `codescan symbols --depth N` — limit nesting depth in output (e.g. struct methods without reading bodies)
- [ ] CamelCase/snake_case normalization in lexical search (so `nameRelevance` matches `name_relevance`)
- [x] Audit daemon/watcher entry paths to confirm each one calls `io_singleton.set(init.io)` early enough — DONE 2026-06-02. The watcher daemon is spawned via `std.process.spawn(...self_exe..."watch"...)` (see `maybeStartWatcher` in main.zig) which re-enters `pub fn main` in a fresh process; `io_singleton.set(io)` is the 3rd statement of `main`, before any user-controlled code path. No comptime or module-init code touches io before that. Documented as an inline CONTRACT comment at the call site.
- [ ] (Optional) Adopt sibling project `validate`'s `runtime.zig` convenience wrappers — `openFile(path, opts)`, `openDir(path, opts)`, `access(path, opts)`, `statFile(path)`, `nanoTimestamp()` — to collapse the 461 `io_singleton.getOrInit()` call sites in 23 files. Pure call-site brevity refactor, no semantic change. Path: define wrappers in `io_singleton.zig`, sed-sweep call sites.
- [x] Fix silent test/prod Io divergence in `io_singleton.getOrInit()` — DONE 2026-05-31. Fallback now constructs a real `std.Io.Threaded.init(page_allocator, .{})` so tests exercise the same concurrent runtime as production (parallel `connectMany`, functional Happy Eyeballs). Root cause of earlier worker-thread crash was `resetForTesting()` nulling `_fallback_threaded` out from under live workers — fixed by keeping the threaded struct process-stable and only clearing `current_io`. Parity test in `src/io_singleton.zig` now asserts concurrent ops SUCCEED (previously locked the divergence). All 51 test binaries pass.
- [x] Watcher syslog logging + `codescan log` subcommand and MCP tool (completed 2026-04-18 EST) — OS-managed logs so we can diagnose watcher stops after the fact; filterable by project root via `log show` / `journalctl -t codescan`. Spec: `docs/superpowers/specs/2026-04-18-watcher-syslog-logging-design.md`. Plan: `docs/superpowers/plans/2026-04-18-watcher-syslog-logging.md`.
- [x] Env-var expansion in config file values (`$VAR`, `${VAR}`, `${VAR:-default}`, `${VAR-default}`, nested to depth 10) with raw-preservation on save for `embedding_api_key` (completed 2026-04-19 EST) — spec: `docs/superpowers/specs/2026-04-19-config-env-var-expansion-design.md`. Plan: `docs/superpowers/plans/2026-04-19-config-env-var-expansion.md`. Reference impl in docscan `cli/main.c:1344-1509`.
- [x] Auto-reindex after CLI edits (skip re-embedding, daemon catches up on vectors)
- [x] `codescan rename` applies edits by default (`--dry-run` for preview-only)
- [x] Hashlines in `codescan references` output for stale-edit protection
- [x] Auto-detect embedding server (Ollama/oMLX) on init, graceful lexical-only fallback when unavailable, `--lexical-only` flag (completed 2026-04-11 EST)
### Phase 5b: Code Review Followups (fleet review 2026-06-01)

Captured from the 9 dimension review notes in `inbox/`. Items that landed in this batch are checked; deferred items keep their context for the next session.

**Landed (commits on yolo, 2026-06-01):**
- [x] fd-leak in `ensureConfigWithDefaults` / `ensureWeightsWithDefaults` — moved close to `defer` so a `stat` failure can't leak the descriptor. (`src/main.zig`)
- [x] `codescan serve` user-facing message — prints redirect to `codescan search` / `codescan mcp-serve` on stderr before returning `error.HttpServerNotMigrated`. (`src/server.zig`)
- [x] Consolidate 6 byte-identical helpers — `ensureParentDir`, `envOrDefault` → `io_singleton.zig`; `vectorToJson` → `storage.zig`; `stripQuotes` → `config.zig`; `splitLines` + `joinLines` → `extract_util.zig`. Removed 9 local fn copies, switched ~30 call sites.
- [x] Hybrid search merge O(N²) → O(1) per dedup hit — `seen` map switched from `AutoHashMap(i64, void)` to `AutoHashMap(i64, usize)` storing the index into `results.items`; bm25 write-back is now a single map lookup + array index. (`src/search.zig:163-206`)
- [x] Arena allocator for `findAndPrintMatchCheck` recursion — replaces `std.heap.page_allocator` (which 4 KB-rounds every `namePath` allocation) with an `ArenaAllocator` created at the caller. (`src/main.zig`)
- [x] Document `bindText` lifetime contract — Zig 0.16 rejects the SQLITE_TRANSIENT sentinel construction, so the existing null-destructor (SQLITE_STATIC) approach stays. Added explicit `LIFETIME CONTRACT` docblock so the caller-owns-buffer invariant is loud at the API surface. (`src/storage.zig`)

**Deferred (multi-session or judgment-call):**
- [ ] Split `src/main.zig` (7331 lines, fn main spans 1311 lines) — extract subcommands into `cmd/<name>.zig` modules; main.zig becomes argparse dispatch + shared bootstrap helpers (resolveSettings, findRepoRoot, embedding-server detection). Each `cmd/*.zig` would be 100-500 lines and individually testable. Reviewer: `unclear-files` + `disorganized` (CRITICAL).
- [~] Decompose `fn search` — PARTIAL 2026-06-02. Extracted `gatherCandidates` (mode-dispatch + bm25 merge) and `filterCandidates` (comments_only + lang/ext/kind) helpers. fn search now 214 lines (was 312). The intricate per-result scoring + intent inference + duplicate penalty + sort + dropoff remains inline — high risk to extract without a much larger surface refactor. Reviewer: `disorganized` (WARN).
- [x] Extract stderr-writer boilerplate helper — DONE 2026-06-01. Added `pub const STDERR_BUF_SIZE = 4096` and `pub fn stderrWriter(buf: []u8) std.Io.File.Writer` to `io_singleton.zig`; mechanical regex sweep replaced 39 call sites across 7 files. Reviewer: `disorganized` (WARN).
- [x] Windows watcher-mgmt: surface typed error instead of silent empties — DONE 2026-06-02. `discoverWatchers` / `getActiveCwds` / `stopWatcher` now return `error.WatcherNotSupportedOnPlatform` on Windows; `.list` and `.prune` watch-dispatch branches in main.zig catch and print a clear user-facing message. Reviewer: `incomplete-undefined` (WARN).
- [x] Restore HTTP server functionality — DONE 2026-06-01. Migrated `serve()` to `std.Io.net.IpAddress.listen` + `std.http.Server` v2; smoke-tested end-to-end with curl. Reviewer: `incomplete-undefined` (CRITICAL).
- [x] Test coverage gaps for language extractors — DONE 2026-06-02. Added smoke-matrix tests across all 9 extractors: empty source, no-doc declaration, doc-attached declaration, UTF-8 content for the 6 code extractors (lua/nix/bash/haskell/idris/nim/lean); empty/non-empty/UTF-8 for text/log. lua also got `local function`/method/block-comment tests. 36 new tests; all pass. Reviewer: `inadequate-tests` (WARN).
- [x] Enum-value stability test for `src/kind.zig` `Kind` enum — DONE 2026-06-02. Added 5 tests: locked `name()` user-facing strings (CLI/config persistence contract), `parse()` roundtrip for every variant via inline-for, parse-null for unknown values, exhaustive coverage check, and `@intFromEnum` values pinned (0=code, 1=doc, 2=text, 3=log). Reviewer: `inadequate-tests` (WARN).
- [x] Strengthen 4 weak-assertion tests — DONE 2026-06-02:
  - `fs_watch.zig:344` — exception-swallows `error.{OpenFrameworkFailed,MissingSymbol,FanotifyInitFailed}`; split into "init succeeds on supported platform" (hard fail) + "init returns sentinel error on unsupported platform" (`expectError`).
  - `embedding_http.zig:650` — `ensureModelAvailable` only asserts no-error; extend `MockTransportCtx` with request counters, assert `/api/tags` AND `/api/ps` were both called.
  - `syslog.zig:75` — "no-op and does not crash" only proves non-crash; rename to "does not crash" OR capture syslog output via a hook to prove the no-op claim.
  - `pidfile.zig:234` — `tryAcquirePid` succeeds-on-stale-PID test only asserts no-error; also assert the pidfile contents after acquisition contain the current process's PID (not the stale `99999999`). Reviewer: `futile-tests` (INFO).
- [x] CLI dispatch table refactor — DONE 2026-06-02. Replaced the ~150-line `else if (mem.eql(...))` chain with a comptime `[_]CommandEntry{...}` table where each entry binds `{names, tag, help_topic, positional}`. Aliases live in `names` (search/query, symbols/find-symbol, watch/watcher, clean/clear). Positional consumption is a single switch on the `.positional` enum field. Dispatcher dropped from ~150 lines to ~60. Reviewer: `language-features` (INFO).
- [x] Replace migration-scaffold `@panic` in `src/io_singleton.zig:61` — DONE 2026-06-02. Resolved by deleting the unused `pub fn get()` entirely (zero external callers; every real call site used `getOrInit()`). No more migration-scaffold wording. Reviewer: `incomplete-undefined` (INFO).

### Phase 6: New Language Grammars
- [x] Add Clojure tree-sitter grammar + symbol mappings (`.clj`, `.cljs`, `.cljc`, `.edn`) — custom list_lit extraction for defn/def/ns/etc.
- [x] Add Assembly tree-sitter grammar + symbol mappings (`.s`, `.S`, `.asm`) — labels + constants via RubixDev/tree-sitter-asm
- [x] Add LLVM IR indexer plugin (`extract_llvm.zig`) — `.ll` files indexed with function/global extraction

### Go Language Support
- [x] Add Go extractor (`extract_go.zig`) for embedding/indexing pipeline — function_declaration, method_declaration, type_spec with `//` and `/* */` comment extraction
- [x] Add Go plugin module (`plugins/go/mod.zig`) with `.go` extension and `**/vendor/**` ignore
- [x] Register Go plugin in `plugin.zig` defaultRegistry

### Phase 7: LLM-Generated Code Comments
- [ ] `codescan add-relevant-comments <file>` — use local Ollama LLM to generate descriptive comments for symbols lacking them
  - Walks symbols in the file, skips those already having a comment above
  - Generates a concise comment describing the symbol's purpose via a code-understanding LLM (e.g. CodeLlama, DeepSeek-Coder)
  - Inserts the comment into the actual source file (language-appropriate comment syntax)
  - Output is a modified file — developer reviews diff and commits what they like
- [ ] `codescan add-relevant-comments <file> <hashline>` — target a single symbol definition
  - Hashline must be the head of a symbol definition, errors otherwise
  - Generates and inserts a comment for just that symbol
- [ ] Config: `describe.model` — which Ollama model to use for description generation
- [ ] Config: `describe.language` — natural language for comments (default: English)
- [ ] Respect existing comments — if a symbol already has a comment block above it, skip or offer to enhance
- [ ] `--dry-run` flag — print generated comments to stdout without modifying files
- [ ] `--force` flag — regenerate even for symbols that already have comments

### Refactor: Vendored deps → proper dependencies
- [ ] Move tree-sitter grammars from `deps/` to Zig package dependencies (build.zig.zon) or Nix flake inputs
- Currently: 20+ tree-sitter grammars are raw vendored C source in `deps/tree-sitter-*/`
- Problem: patches to vendored code (like the tree-sitter-swift UB fix) are fragile and can be overwritten
- Approach options:
  1. **Zig packages**: Fork each grammar to add `build.zig.zon`, add as `.dependencies` in `build.zig.zon`. Most correct but high maintenance (20+ forks).
  2. **Nix flake inputs**: Add each grammar repo as a flake input, pass source paths to the Zig build. Works for Nix builds, but non-Nix builds still need vendored copies.
  3. **Git submodules**: Pin each grammar to a commit. Standard approach, but submodules are notoriously annoying.
  4. **Hybrid**: Use Nix flake inputs for the Nix build path, keep vendored copies as fallback for non-Nix builds. Apply patches via Nix overlay.
- Recommendation: Option 4 (hybrid) — Nix users get pinned+patched deps automatically, non-Nix users use vendored copies with a `scripts/update-deps.sh` that fetches and patches.
- Also consider: tree-sitter core itself (`deps/tree-sitter/`) should be a proper dependency too.
- Filed upstream: alex-pinkus/tree-sitter-swift#558 (UB fix)
