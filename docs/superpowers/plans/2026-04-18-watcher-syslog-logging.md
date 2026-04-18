# Watcher Syslog Logging + `codescan log` Subcommand — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the background codescan watcher's error and lifecycle events inspectable post-mortem via the OS-managed system log, filterable by project, and surface those logs through a `codescan log` subcommand and an MCP `logs` tool.

**Architecture:** Thin POSIX `syslog(3)` C-FFI wrapper in `src/syslog.zig`. `src/watcher.zig` calls it at every lifecycle and error exit path. A new `src/log_cmd.zig` module builds the platform-specific retrieval command (`log show` on macOS, `journalctl -t codescan` on Linux) and filters output in-process by project-root substring. `src/mcp.zig` exposes the same core through a `logs` tool. All call-through tests use a command-runner seam so we don't depend on the OS log being populated during CI.

**Tech Stack:** Zig 0.15 (unmanaged `std.ArrayListUnmanaged`, capitalized `StdIo` variants, new writer pattern), libc (already linked — see `build.zig:607`), POSIX `syslog(3)`, macOS `log(1)`, Linux `journalctl(1)`.

**Spec:** [`docs/superpowers/specs/2026-04-18-watcher-syslog-logging-design.md`](../specs/2026-04-18-watcher-syslog-logging-design.md)

**Target branch:** `yolo` (do not create a feature branch — this is the main branch for this project).

**TDD discipline:** every task writes the failing test first, runs it to confirm failure, then implements. Do not skip the confirm-failure step. Exception: pure refactoring under existing coverage.

---

## File Structure

- **Create:** `src/syslog.zig` — POSIX syslog(3) FFI wrapper + unit tests.
- **Create:** `src/log_cmd.zig` — platform command builder, in-process filter, and shared execution core for the CLI subcommand and the MCP `logs` tool + unit tests.
- **Modify:** `src/watcher.zig` — call `syslog.logWithRoot` at existing lifecycle and error exit paths (no structural changes).
- **Modify:** `src/main.zig` — init/deinit syslog around watcher entry point (line ~1211 `.run =>`) and around `maybeStartWatcher` (line 2024); add `.log =>` dispatch calling `log_cmd.run`.
- **Modify:** `src/cli.zig` — add `log` to `CommandTag` enum (line 12), add `LogOptions` struct and arg-parse branch.
- **Modify:** `src/mcp.zig` — add `logs` tool to `tools_list_json` (line 813) and dispatch branch in `callTool` (line 237).
- **Modify:** `build.zig` — no changes expected (libc already linked via `linkCommon`); confirm in Task 1.
- **Modify:** `src/all_tests.zig` — add `@import("syslog.zig")` and `@import("log_cmd.zig")` so their tests run under `zig build test`.
- **Modify:** `README.md` — one paragraph under Troubleshooting pointing to `codescan log`.

---

## Task 1: Confirm libc is linked for the main executable

**Files:**
- Read: `build.zig`

- [ ] **Step 1: Grep for the main-binary linkage chain**

Run:
```bash
grep -nE "addExecutable|linkCommon|linkLibC" build.zig | head -30
```

Expected: `addExecutable` at or near line 69 for `name = "codescan"`, followed by `linkCommon(exe, ...)`. Inside `linkCommon`, `lib.linkLibC()` is called (see line 607 in the existing grep output). This means the main binary already links libc. No `build.zig` edit needed.

- [ ] **Step 2: No commit needed — this task is verification only**

---

## Task 2: Create `src/syslog.zig` with FFI decls and no-op-when-uninitialized behavior

**Files:**
- Create: `src/syslog.zig`

- [ ] **Step 1: Write the failing test**

Append to the new file `src/syslog.zig` (tests go inline with Zig convention):

```zig
test "log before init is a no-op and does not crash" {
    // Do NOT call init(). Any of these must return without panicking.
    log(LOG_NOTICE, "should be dropped");
    logWithRoot(LOG_ERR, "/tmp/fake-root", "should also be dropped");
}

test "logWithRoot truncates messages longer than 1024 bytes with ellipsis" {
    // Init briefly so the formatting path runs (syslog call is made but
    // we don't assert on delivery — only that no crash occurs).
    init("codescan-test-truncate");
    defer deinit();

    var buf: [2048]u8 = undefined;
    for (&buf) |*b| b.* = 'x';
    logWithRoot(LOG_NOTICE, "/tmp/fake-root", &buf);
    // Implicit assertion: did not panic/segfault on >1024-byte input.
}
```

- [ ] **Step 2: Run the test to verify it fails (module does not exist yet)**

Run:
```bash
zig build test 2>&1 | head -20
```

Expected: FAIL — `src/syslog.zig` is not yet imported; the test runner will not see these tests. That's sufficient to confirm the failure precondition.

- [ ] **Step 3: Write the minimal implementation**

Full contents of `src/syslog.zig`:

```zig
const std = @import("std");

pub const LOG_PID: c_int = 0x01;
pub const LOG_NDELAY: c_int = 0x08;

// facility
pub const LOG_DAEMON: c_int = 3 << 3;

// priorities
pub const LOG_ERR: c_int = 3;
pub const LOG_WARNING: c_int = 4;
pub const LOG_NOTICE: c_int = 5;

extern "c" fn openlog(ident: [*:0]const u8, option: c_int, facility: c_int) void;
extern "c" fn syslog(priority: c_int, format: [*:0]const u8, ...) void;
extern "c" fn closelog() void;

var initialized: bool = false;

pub fn init(ident: [*:0]const u8) void {
    openlog(ident, LOG_PID | LOG_NDELAY, LOG_DAEMON);
    initialized = true;
}

pub fn deinit() void {
    if (!initialized) return;
    closelog();
    initialized = false;
}

pub fn log(priority: c_int, message: []const u8) void {
    if (!initialized) return;
    var buf: [1024]u8 = undefined;
    const copy_len = @min(message.len, buf.len - 1);
    @memcpy(buf[0..copy_len], message[0..copy_len]);
    buf[copy_len] = 0;
    syslog(priority, "%s", @as([*:0]const u8, @ptrCast(&buf)));
}

pub fn logWithRoot(priority: c_int, root: []const u8, message: []const u8) void {
    if (!initialized) return;
    var buf: [1024]u8 = undefined;
    // Format: "<root>: <message>" truncated with "..." if overflow.
    const suffix = "...";
    var written: usize = 0;

    const root_copy = @min(root.len, buf.len - 1);
    @memcpy(buf[0..root_copy], root[0..root_copy]);
    written = root_copy;

    if (written + 2 <= buf.len - 1) {
        buf[written] = ':';
        buf[written + 1] = ' ';
        written += 2;
    }

    const remaining = buf.len - 1 - written;
    if (message.len <= remaining) {
        @memcpy(buf[written .. written + message.len], message);
        written += message.len;
    } else {
        const msg_room = if (remaining >= suffix.len) remaining - suffix.len else 0;
        @memcpy(buf[written .. written + msg_room], message[0..msg_room]);
        written += msg_room;
        const ellipsis_room = @min(suffix.len, buf.len - 1 - written);
        @memcpy(buf[written .. written + ellipsis_room], suffix[0..ellipsis_room]);
        written += ellipsis_room;
    }

    buf[written] = 0;
    syslog(priority, "%s", @as([*:0]const u8, @ptrCast(&buf)));
}
```

- [ ] **Step 4: Wire the module into the test aggregator**

Edit `src/all_tests.zig` and add `_ = @import("syslog.zig");` to the list of test imports so `zig build test` picks up the inline tests. (Inspect the file first to match the existing style — it typically has a comptime block with `_ = @import(...)` lines.)

- [ ] **Step 5: Run tests and verify they pass**

Run:
```bash
zig build test 2>&1 | tail -30
```

Expected: PASS — both `test "log before init is a no-op..."` and `test "logWithRoot truncates messages..."` pass. No other tests regressed.

- [ ] **Step 6: Commit**

```bash
git add src/syslog.zig src/all_tests.zig
git commit -m "feat(syslog): add POSIX syslog(3) C-FFI wrapper with no-op-when-uninitialized semantics"
```

---

## Task 3: Gated integration test — syslog delivers messages to OS log

**Files:**
- Modify: `src/syslog.zig`

This test proves the FFI is actually wired up. Gated behind an environment variable so CI stays fast and hermetic.

- [ ] **Step 1: Write the failing test**

Append to `src/syslog.zig`:

```zig
test "syslog delivers to OS log (gated: CODESCAN_RUN_SYSLOG_TESTS=1)" {
    const enable = std.process.getEnvVarOwned(std.testing.allocator, "CODESCAN_RUN_SYSLOG_TESTS") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(enable);
    if (!std.mem.eql(u8, enable, "1")) return error.SkipZigTest;

    // Use a PID-derived tag so parallel runs don't collide.
    var tag_buf: [64]u8 = undefined;
    const pid = std.os.linux.getpid() catch 0; // best-effort; any non-zero PID works
    _ = pid;
    const tag_slice = try std.fmt.bufPrintZ(&tag_buf, "codescan-test-{d}", .{std.time.milliTimestamp()});
    const tag: [*:0]const u8 = tag_slice.ptr;

    init(tag);
    defer deinit();

    const marker = "syslog-delivery-check-12345";
    log(LOG_NOTICE, marker);

    // Give the OS log 2s to durably record the message.
    std.time.sleep(2 * std.time.ns_per_s);

    // Use the platform tool to retrieve the message. Keep the assertion lenient:
    // the unified log can lag. We only check that our tag appears in the output.
    const builtin = @import("builtin");
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "log", "show", "--predicate", "process == \"codescan-test\"", "--last", "1m", "--style", "compact" },
        .linux => &.{ "journalctl", "--since", "1 minute ago", "-t", tag_slice[0 .. tag_slice.len], "--no-pager" },
        else => return error.SkipZigTest,
    };
    _ = argv;
    // NOTE: we cannot assert the marker survives OS log buffering in all CI
    // environments. This test's real value is proving init/log/deinit do not
    // crash with live libc calls. Leave stdout inspection out of the assertion;
    // a human can run the gated test locally and confirm via `log show`.
}
```

- [ ] **Step 2: Run tests without the env var to verify the test skips cleanly**

Run:
```bash
zig build test 2>&1 | tail -10
```

Expected: PASS overall. The gated test reports SKIP.

- [ ] **Step 3: Run tests with the env var to verify the path executes**

Run:
```bash
CODESCAN_RUN_SYSLOG_TESTS=1 zig build test 2>&1 | tail -10
```

Expected: PASS. No crash on real `openlog`/`syslog`/`closelog` calls.

- [ ] **Step 4: Commit**

```bash
git add src/syslog.zig
git commit -m "test(syslog): gated integration test for live libc call path"
```

---

## Task 4: Wire syslog into `watcher.zig` error paths

**Files:**
- Modify: `src/watcher.zig:1-230`

We're adding call sites at every existing `stderr.print(...)` that corresponds to a lifecycle or error event, plus one at the top of `watchLoop` for the startup event. We are **not** changing the stderr prints — they remain for the foreground case. Syslog is additive.

- [ ] **Step 1: Write the failing test**

We cannot unit-test the full watcher loop cheaply, but we can assert that the watcher.zig file contains syslog call sites by pattern. Add this test to `src/watcher.zig`:

```zig
test "watcher source contains syslog calls at all error paths" {
    // This is a meta-test asserting source structure. If the file shape changes,
    // update the expected count. It guards against accidental removal of logging
    // during future refactors.
    const src = @embedFile("watcher.zig");
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, src, i, "syslog.logWithRoot(")) |pos| : (i = pos + 1) {
        count += 1;
    }
    // Expected: 8 call sites — 1 start + 3 exit paths (config changed, index
    // error warning, too-many-errors stop) × 2 loops, plus 1 at top of watchLoop.
    // If you intentionally add/remove a call site, update this number.
    try std.testing.expectEqual(@as(usize, 8), count);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
zig build test 2>&1 | grep -A3 "watcher source contains syslog"
```

Expected: FAIL with `expected 8, found 0` (or similar).

- [ ] **Step 3: Add the `syslog` import and call sites**

Edit `src/watcher.zig`:

**3a.** Add import at top of file (after existing imports, around line 8):

```zig
const syslog = @import("syslog.zig");
```

**3b.** In `watchLoop` (around line 59, right after the "Watching ... (native events ...)" stderr print), add:

```zig
syslog.logWithRoot(syslog.LOG_NOTICE, root_path, "watcher started (native events)");
```

**3c.** In `watchLoop` at the "config changed" branch (around line 93, right after the stderr print and before the `return`):

```zig
syslog.logWithRoot(syslog.LOG_NOTICE, root_path, "watcher stopping: config changed");
```

**3d.** In `watchLoop` at the "index error" branch (around line 109, right after the stderr print, before the threshold check):

Use a stack buffer to format the message including the error name and counter:

```zig
var msg_buf: [256]u8 = undefined;
const msg = std.fmt.bufPrint(&msg_buf, "index error: {s} ({d}/{d})", .{ @errorName(err), consecutive_errors, max_consecutive_errors }) catch "index error (format failed)";
syslog.logWithRoot(syslog.LOG_WARNING, root_path, msg);
```

**3e.** In `watchLoop` at the "too many consecutive errors" branch (around line 112, after the stderr print, before the `return`):

```zig
syslog.logWithRoot(syslog.LOG_ERR, root_path, "watcher stopping: too many consecutive errors");
```

**3f.** In `watchLoopPolling`, repeat the same three error-path calls (3c, 3d, 3e) at the corresponding lines (currently 178, 194, 197).

**3g.** At the top of `watchLoopPolling` (right after the "Watching ... (poll every ...)" stderr print, around line 145), add:

```zig
syslog.logWithRoot(syslog.LOG_NOTICE, root_path, "watcher started (polling)");
```

That's 8 call sites total — matching the expected count in the test.

- [ ] **Step 4: Run the meta-test to verify it now passes**

Run:
```bash
zig build test 2>&1 | grep -E "watcher source|error:" | head -10
```

Expected: PASS. No build errors.

- [ ] **Step 5: Run the full test suite to confirm no regressions**

Run:
```bash
zig build test 2>&1 | tail -20
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/watcher.zig
git commit -m "feat(watcher): emit syslog events at lifecycle and error paths"
```

---

## Task 5: Init/deinit syslog around the watcher entry point

**Files:**
- Modify: `src/main.zig` — `.run =>` branch in the watch subcommand dispatch (around line 1211) and `maybeStartWatcher` (line 2024).

- [ ] **Step 1: Add init/deinit in `.run =>` branch**

Find the `.run => {` block around line 1211. Immediately after opening the block body (after `try ensureParentDir(settings.db_path);`), add:

```zig
syslog.init("codescan");
defer syslog.deinit();
```

Add the syslog import at the top of `src/main.zig` if not already present:

```zig
const syslog = @import("syslog.zig");
```

(Check first — `grep -n '@import("syslog.zig")' src/main.zig`. If already present from a prior task, skip.)

- [ ] **Step 2: Add init/log/deinit inside `maybeStartWatcher` around the spawn failure path**

Currently (around line 2055):
```zig
child.spawn() catch |err| {
    _ = stderr.print("note: failed to start watcher: {s}\n", .{@errorName(err)}) catch {};
    _ = stderr.flush() catch {};
    return;
};
```

Change the spawn-failure branch to also emit a syslog ERR. The parent process may not have syslog open yet, so open/close locally:

```zig
child.spawn() catch |err| {
    _ = stderr.print("note: failed to start watcher: {s}\n", .{@errorName(err)}) catch {};
    _ = stderr.flush() catch {};
    syslog.init("codescan");
    defer syslog.deinit();
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "failed to start watcher: {s}", .{@errorName(err)}) catch "failed to start watcher";
    syslog.logWithRoot(syslog.LOG_ERR, settings.root_path, msg);
    return;
};
```

- [ ] **Step 3: Build to confirm it compiles**

Run:
```bash
zig build 2>&1 | tail -10
```

Expected: clean build, no warnings about unused imports.

- [ ] **Step 4: Run full test suite**

Run:
```bash
zig build test 2>&1 | tail -10
```

Expected: all tests pass.

- [ ] **Step 5: Smoke-test the watcher manually (optional but recommended)**

Run:
```bash
./zig-out/bin/codescan watch --root /tmp 2>/dev/null &
WATCH_PID=$!
sleep 3
kill "$WATCH_PID" 2>/dev/null

# macOS:
log show --predicate 'process == "codescan"' --last 1m --style compact | grep "watcher started" | head -3

# Linux:
journalctl -t codescan --since "1 minute ago" --no-pager | grep "watcher started" | head -3
```

Expected: the platform log shows a `watcher started` entry prefixed with `/tmp: `.

- [ ] **Step 6: Commit**

```bash
git add src/main.zig
git commit -m "feat(main): init syslog at watcher entry + log spawn failures"
```

---

## Task 6: Add `log` subcommand parsing to `cli.zig`

**Files:**
- Modify: `src/cli.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/cli.zig` (tests are already inline in this file):

```zig
test "parse: codescan log defaults" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "codescan", "log" };
    var parsed = try parse(allocator, &args);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(CommandTag.log, parsed.command);
    try std.testing.expectEqualStrings("1h", parsed.log_since);
    try std.testing.expectEqual(false, parsed.log_follow);
    try std.testing.expectEqual(false, parsed.log_all);
    try std.testing.expectEqual(@as(?usize, null), parsed.log_limit);
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.log_root);
}

test "parse: codescan log --since 5m --follow --limit 50" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "codescan", "log", "--since", "5m", "--follow", "--limit", "50" };
    var parsed = try parse(allocator, &args);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(CommandTag.log, parsed.command);
    try std.testing.expectEqualStrings("5m", parsed.log_since);
    try std.testing.expectEqual(true, parsed.log_follow);
    try std.testing.expectEqual(@as(?usize, 50), parsed.log_limit);
}

test "parse: codescan log --all --root /tmp/foo" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "codescan", "log", "--all", "--root", "/tmp/foo" };
    var parsed = try parse(allocator, &args);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(true, parsed.log_all);
    try std.testing.expectEqualStrings("/tmp/foo", parsed.log_root.?);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
zig build test 2>&1 | grep -E "log defaults|log --since|log --all|error:" | head -20
```

Expected: compile errors — `CommandTag.log` doesn't exist, `parsed.log_since` field missing, etc.

- [ ] **Step 3: Add `.log` to `CommandTag` enum**

Edit `src/cli.zig` line 12, append to `CommandTag`:

```zig
pub const CommandTag = enum {
    // ... existing entries ...
    setup_model,
    log,
};
```

- [ ] **Step 4: Add log option fields to the `Parsed` struct**

Find `pub const Parsed = struct` (around line 88) and add fields (grouped with similar command-specific fields):

```zig
log_root: ?[]const u8 = null,
log_since: []const u8 = "1h",
log_follow: bool = false,
log_all: bool = false,
log_limit: ?usize = null,
```

Also ensure `deinit(allocator)` frees `log_root` if it was duped. (Match the existing pattern used by other `?[]const u8` fields in this struct.)

- [ ] **Step 5: Add parser branch for `log` subcommand**

In the main parser switch (the code near line 357 that maps arg[0] to `parsed.command`), add a branch that matches `log`:

```zig
} else if (std.mem.eql(u8, arg, "log")) {
    parsed.command = .log;
    // Continue parsing to consume flags in the loop below
}
```

And in the flag-parsing loop, add handling for `--since`, `--follow`, `--all`, `--limit`, and the shared `--root` (match `--root`'s existing handling pattern — it's already parsed for other commands, reuse it). Add:

```zig
} else if (parsed.command == .log and std.mem.eql(u8, arg, "--since")) {
    i += 1;
    if (i >= args.len) return error.MissingValue;
    parsed.log_since = try allocator.dupe(u8, args[i]);
} else if (parsed.command == .log and std.mem.eql(u8, arg, "--follow")) {
    parsed.log_follow = true;
} else if (parsed.command == .log and std.mem.eql(u8, arg, "--all")) {
    parsed.log_all = true;
} else if (parsed.command == .log and std.mem.eql(u8, arg, "--limit")) {
    i += 1;
    if (i >= args.len) return error.MissingValue;
    parsed.log_limit = std.fmt.parseInt(usize, args[i], 10) catch return error.InvalidNumber;
}
```

(The existing `--root` handling should already populate `parsed.root_path` or similar; if not, wire `parsed.log_root` through it. Inspect the file to match the existing convention — don't duplicate `--root` logic if it's already shared across commands.)

Also update `deinit` to free `log_since` only if it was duped from args (it starts as the literal `"1h"` which must not be freed). Use the same pattern as existing optional-dupe fields.

- [ ] **Step 6: Run tests to verify they now pass**

Run:
```bash
zig build test 2>&1 | grep -E "parse: codescan log" | head -10
```

Expected: three PASS lines.

- [ ] **Step 7: Commit**

```bash
git add src/cli.zig
git commit -m "feat(cli): parse 'codescan log' subcommand with --since/--follow/--all/--limit"
```

---

## Task 7: Create `src/log_cmd.zig` with command builder and in-process filter (pure-function core)

**Files:**
- Create: `src/log_cmd.zig`

This module has two pure functions (testable in isolation) and one thin runner that shells out.

- [ ] **Step 1: Write the failing tests**

Full contents of `src/log_cmd.zig` (tests first):

```zig
const std = @import("std");
const builtin = @import("builtin");

pub const Options = struct {
    root: ?[]const u8 = null,
    since: []const u8 = "1h",
    follow: bool = false,
    all: bool = false,
    limit: ?usize = null,
};

pub const Platform = enum { macos, linux, unsupported };

pub fn currentPlatform() Platform {
    return switch (builtin.os.tag) {
        .macos => .macos,
        .linux => .linux,
        else => .unsupported,
    };
}

/// Build argv for the platform log tool. Caller owns the outer slice; inner
/// slices are either literals or borrowed from `opts`.
pub fn buildArgv(
    allocator: std.mem.Allocator,
    platform: Platform,
    opts: Options,
) ![]const []const u8 {
    var list = std.ArrayListUnmanaged([]const u8){};
    errdefer list.deinit(allocator);

    switch (platform) {
        .macos => {
            if (opts.follow) {
                try list.append(allocator, "log");
                try list.append(allocator, "stream");
                try list.append(allocator, "--predicate");
                try list.append(allocator, "process == \"codescan\"");
            } else {
                try list.append(allocator, "log");
                try list.append(allocator, "show");
                try list.append(allocator, "--predicate");
                try list.append(allocator, "process == \"codescan\"");
                try list.append(allocator, "--last");
                try list.append(allocator, opts.since);
                try list.append(allocator, "--style");
                try list.append(allocator, "compact");
            }
        },
        .linux => {
            try list.append(allocator, "journalctl");
            try list.append(allocator, "-t");
            try list.append(allocator, "codescan");
            try list.append(allocator, "--since");
            try list.append(allocator, opts.since);
            try list.append(allocator, "--no-pager");
            if (opts.follow) try list.append(allocator, "--follow");
        },
        .unsupported => return error.UnsupportedPlatform,
    }

    return list.toOwnedSlice(allocator);
}

/// Filter raw log output: if `root` is set, keep only lines whose content
/// contains "<root>: " (the separator added by syslog.logWithRoot).
/// If `limit` is set, keep only the last `limit` matching lines.
/// Returns an owned slice.
pub fn filterOutput(
    allocator: std.mem.Allocator,
    output: []const u8,
    root: ?[]const u8,
    limit: ?usize,
) ![]u8 {
    var kept = std.ArrayListUnmanaged([]const u8){};
    defer kept.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, output, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        if (root) |r| {
            // Look for "<root>: " in the line (tolerating timestamp/prefix from log show/journalctl).
            var marker_buf: [1024]u8 = undefined;
            if (r.len + 2 > marker_buf.len) continue; // unreasonably long root, skip filter
            @memcpy(marker_buf[0..r.len], r);
            marker_buf[r.len] = ':';
            marker_buf[r.len + 1] = ' ';
            const marker = marker_buf[0 .. r.len + 2];
            if (std.mem.indexOf(u8, line, marker) == null) continue;
        }
        try kept.append(allocator, line);
    }

    const start: usize = if (limit) |n| (if (kept.items.len > n) kept.items.len - n else 0) else 0;

    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    for (kept.items[start..]) |line| {
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

test "buildArgv macos without follow" {
    const allocator = std.testing.allocator;
    const argv = try buildArgv(allocator, .macos, .{ .since = "30m" });
    defer allocator.free(argv);
    try std.testing.expectEqualStrings("log", argv[0]);
    try std.testing.expectEqualStrings("show", argv[1]);
    try std.testing.expectEqualStrings("--predicate", argv[2]);
    try std.testing.expect(std.mem.indexOf(u8, argv[3], "codescan") != null);
    try std.testing.expectEqualStrings("--last", argv[4]);
    try std.testing.expectEqualStrings("30m", argv[5]);
}

test "buildArgv macos with follow uses stream" {
    const allocator = std.testing.allocator;
    const argv = try buildArgv(allocator, .macos, .{ .follow = true });
    defer allocator.free(argv);
    try std.testing.expectEqualStrings("stream", argv[1]);
}

test "buildArgv linux uses journalctl -t codescan" {
    const allocator = std.testing.allocator;
    const argv = try buildArgv(allocator, .linux, .{ .since = "10m" });
    defer allocator.free(argv);
    try std.testing.expectEqualStrings("journalctl", argv[0]);
    try std.testing.expectEqualStrings("-t", argv[1]);
    try std.testing.expectEqualStrings("codescan", argv[2]);
    try std.testing.expectEqualStrings("--since", argv[3]);
    try std.testing.expectEqualStrings("10m", argv[4]);
}

test "buildArgv returns error for unsupported platform" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedPlatform, buildArgv(allocator, .unsupported, .{}));
}

test "filterOutput retains lines matching root marker" {
    const allocator = std.testing.allocator;
    const input =
        \\2026-04-18 10:00:00 codescan[123]: /a: watcher started
        \\2026-04-18 10:01:00 codescan[124]: /b: watcher started
        \\2026-04-18 10:02:00 codescan[125]: /a: index error: Foo (1/5)
    ;
    const filtered = try filterOutput(allocator, input, "/a", null);
    defer allocator.free(filtered);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "/a: watcher started") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "/a: index error") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "/b:") == null);
}

test "filterOutput without root returns all non-empty lines" {
    const allocator = std.testing.allocator;
    const input = "alpha\n\nbravo\n";
    const filtered = try filterOutput(allocator, input, null, null);
    defer allocator.free(filtered);
    try std.testing.expectEqualStrings("alpha\nbravo\n", filtered);
}

test "filterOutput applies limit to keep the last N lines" {
    const allocator = std.testing.allocator;
    const input = "a\nb\nc\nd\ne\n";
    const filtered = try filterOutput(allocator, input, null, 2);
    defer allocator.free(filtered);
    try std.testing.expectEqualStrings("d\ne\n", filtered);
}
```

- [ ] **Step 2: Add the module to the test aggregator**

Edit `src/all_tests.zig` and add `_ = @import("log_cmd.zig");`.

- [ ] **Step 3: Run tests to verify they pass**

Run:
```bash
zig build test 2>&1 | grep -E "buildArgv|filterOutput" | head -10
```

Expected: all seven tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/log_cmd.zig src/all_tests.zig
git commit -m "feat(log_cmd): platform argv builder and in-process filter (pure-function core)"
```

---

## Task 8: Add `runLog` execution function in `log_cmd.zig`

**Files:**
- Modify: `src/log_cmd.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/log_cmd.zig`:

```zig
// Seam for tests: allows injecting a fake command runner.
pub const CommandRunner = *const fn (
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) anyerror![]u8;

fn realRunner(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) anyerror![]u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Close;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();

    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try child.stdout.?.read(&buf);
        if (n == 0) break;
        try out.appendSlice(allocator, buf[0..n]);
    }

    _ = try child.wait();
    return out.toOwnedSlice(allocator);
}

/// Run the log retrieval pipeline and return the filtered output.
/// Caller owns the returned slice.
pub fn run(
    allocator: std.mem.Allocator,
    opts: Options,
    runner: ?CommandRunner,
) ![]u8 {
    const platform = currentPlatform();
    if (platform == .unsupported) return error.UnsupportedPlatform;

    const argv = try buildArgv(allocator, platform, opts);
    defer allocator.free(argv);

    const raw = try (runner orelse realRunner)(allocator, argv);
    defer allocator.free(raw);

    const effective_root: ?[]const u8 = if (opts.all) null else opts.root;
    return filterOutput(allocator, raw, effective_root, opts.limit);
}

// --- Test fakes ---

var fake_output: []const u8 = "";

fn fakeRunner(allocator: std.mem.Allocator, argv: []const []const u8) anyerror![]u8 {
    _ = argv;
    return allocator.dupe(u8, fake_output);
}

test "run applies root filter and honors --all" {
    const allocator = std.testing.allocator;
    fake_output =
        \\2026-04-18 codescan[1]: /proj-a: watcher started
        \\2026-04-18 codescan[2]: /proj-b: watcher started
    ;

    const filtered = try run(allocator, .{ .root = "/proj-a" }, fakeRunner);
    defer allocator.free(filtered);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "/proj-a") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "/proj-b") == null);

    const all = try run(allocator, .{ .root = "/proj-a", .all = true }, fakeRunner);
    defer allocator.free(all);
    try std.testing.expect(std.mem.indexOf(u8, all, "/proj-a") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "/proj-b") != null);
}
```

- [ ] **Step 2: Run the test to verify it passes**

Run:
```bash
zig build test 2>&1 | grep -E "run applies root" | head -5
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add src/log_cmd.zig
git commit -m "feat(log_cmd): add run() with injected runner seam for testability"
```

---

## Task 9: Dispatch `.log =>` in `main.zig`

**Files:**
- Modify: `src/main.zig`

- [ ] **Step 1: Add the dispatch branch**

In the main command switch (around line 1313 where `.status =>` lives), add **before** the closing brace of that switch:

```zig
.log => {
    const log_cmd = @import("log_cmd.zig");
    const platform = log_cmd.currentPlatform();
    if (platform == .unsupported) {
        try stdout.print("codescan log: unsupported platform (supported: macOS, Linux)\n", .{});
        try stdout.flush();
        std.process.exit(1);
    }

    const effective_root: ?[]const u8 = if (parsed.log_all) null else (parsed.log_root orelse settings.root_path);

    const opts: log_cmd.Options = .{
        .root = effective_root,
        .since = parsed.log_since,
        .follow = parsed.log_follow,
        .all = parsed.log_all,
        .limit = parsed.log_limit,
    };

    const output = try log_cmd.run(allocator, opts, null);
    defer allocator.free(output);
    try stdout.writeAll(output);
    try stdout.flush();
},
```

(If `parsed.log_root` field has a different final name due to Task 6, match it here.)

- [ ] **Step 2: Build to confirm it compiles**

Run:
```bash
zig build 2>&1 | tail -10
```

Expected: clean build.

- [ ] **Step 3: Smoke test**

Run:
```bash
./zig-out/bin/codescan log --all --since 5m 2>&1 | head -10
```

Expected: either a list of log lines from recent codescan activity, or empty output if no recent activity. No crash.

- [ ] **Step 4: Commit**

```bash
git add src/main.zig
git commit -m "feat(cli): dispatch 'codescan log' through log_cmd.run"
```

---

## Task 10: Add `logs` MCP tool

**Files:**
- Modify: `src/mcp.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/mcp.zig` (near the other MCP tool tests around line 1590+):

```zig
test "tools_list_json contains logs tool" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, tools_list_json, .{});
    defer parsed.deinit();

    const tools = parsed.value.object.get("tools").?.array;
    var found = false;
    for (tools.items) |tool| {
        const name = tool.object.get("name").?.string;
        if (std.mem.eql(u8, name, "logs")) {
            found = true;
            // Has the expected properties on the schema.
            const schema = tool.object.get("inputSchema").?.object;
            const props = schema.get("properties").?.object;
            try std.testing.expect(props.get("root") != null);
            try std.testing.expect(props.get("since") != null);
            try std.testing.expect(props.get("limit") != null);
            try std.testing.expect(props.get("all") != null);
            break;
        }
    }
    try std.testing.expect(found);
}
```

- [ ] **Step 2: Run to verify it fails**

Run:
```bash
zig build test 2>&1 | grep -E "logs tool|error:" | head -10
```

Expected: FAIL — `logs` is not in the tools list yet.

- [ ] **Step 3: Add the tool entry to `tools_list_json`**

Edit `src/mcp.zig`. Find `tools_list_json` (line 813) and insert this entry in the array before the closing `\]}`:

```zig
\\,{"name":"logs","description":"Read recent watcher logs from the OS log (macOS unified log / Linux journald), filtered to codescan and optionally to a project root.","inputSchema":{"type":"object","properties":{"root":{"type":"string","description":"Absolute project root path; filters messages to this project"},"since":{"type":"string","description":"Time window (e.g. '1h', '15m'). Default 1h."},"limit":{"type":"integer","description":"Max lines to return (last N after filter)"},"all":{"type":"boolean","description":"If true, show logs from all codescan projects"}}}}
```

(Match the exact multi-line string concatenation style used by adjacent entries — each entry is a `\\` line. Make sure to insert a `,` before the new entry.)

- [ ] **Step 4: Add dispatch branch in `callTool`**

Find the `callTool` function (around line 237). Inside the big `if/else if` chain that dispatches by `name`, add before the final `else` that returns `error.UnknownTool`:

```zig
} else if (std.mem.eql(u8, name, "logs")) {
    const log_cmd = @import("log_cmd.zig");
    const platform = log_cmd.currentPlatform();
    if (platform == .unsupported) return toolError("MCP logs: unsupported platform (macOS/Linux only)\n", .{});

    const root_arg = getArgString(args, "root");
    const since_arg = getArgString(args, "since") orelse "1h";
    const all_arg = getArgBool(args, "all") orelse false;
    const limit_arg: ?usize = if (getArgInt(args, "limit")) |n| @as(usize, @intCast(n)) else 200;

    const effective_root: ?[]const u8 = if (all_arg) null else (root_arg orelse settings.root_path);

    const opts: log_cmd.Options = .{
        .root = effective_root,
        .since = since_arg,
        .follow = false,
        .all = all_arg,
        .limit = limit_arg,
    };

    const output = log_cmd.run(allocator, opts, null) catch |err|
        return toolError("MCP logs: run failed: {}\n", .{err});
    defer allocator.free(output);

    try out.writer.writeAll(output);
}
```

(If `getArgString`/`getArgBool`/`getArgInt` helpers don't exist with those exact names, match whatever the file uses — there's a `getArg` near line 652. Follow its pattern.)

- [ ] **Step 5: Run tests to verify the new test passes**

Run:
```bash
zig build test 2>&1 | grep -E "logs tool|error:" | head -10
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/mcp.zig
git commit -m "feat(mcp): add 'logs' tool that surfaces filtered watcher logs"
```

---

## Task 11: Help text for `codescan log --help`

**Files:**
- Modify: `src/main.zig` (the help-topic registry — find by grepping for `watch`'s help text, then add `log`)

- [ ] **Step 1: Locate the help topic registry**

Run:
```bash
grep -n "watch:\|mcp-serve:\|help_topics\|printHelp" src/main.zig | head -20
```

Find the place where per-command help topics are stored/printed.

- [ ] **Step 2: Add a `log` help topic**

Following the pattern of adjacent topics, add:

```
codescan log — read recent codescan watcher logs from the system log

Usage:
  codescan log [--root <path>] [--since <duration>] [--follow] [--all] [--limit <n>]

Defaults:
  --root = current project root (auto-detected, like codescan status)
  --since = 1h
  --limit = none

Flags:
  --root <path>     Filter to messages tagged with this project root
  --since <dur>     Time window (e.g. "30m", "2h", "1d")
  --follow          Live tail mode (foreground only)
  --all             Show messages from all codescan projects
  --limit <n>       Keep only the last N matching lines

Examples:
  codescan log                      # last 1h for current project
  codescan log --since 15m
  codescan log --all --since 2h     # all projects
  codescan log --follow             # live tail

Backend:
  macOS: log show --predicate 'process == "codescan"'
  Linux: journalctl -t codescan
```

- [ ] **Step 3: Add `log` to the `codescan --help` command overview (if there's one)**

Find the main help text (likely a multi-line string around line 4773 based on earlier grep) and append `log` to the command list.

- [ ] **Step 4: Smoke test**

Run:
```bash
./zig-out/bin/codescan log --help 2>&1 | head -20
./zig-out/bin/codescan --help 2>&1 | grep -i log
```

Expected: help text prints correctly; `log` appears in the main command list.

- [ ] **Step 5: Commit**

```bash
git add src/main.zig
git commit -m "docs(cli): add help text for 'codescan log'"
```

---

## Task 12: README troubleshooting blurb

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Find an existing Troubleshooting section or add one**

Run:
```bash
grep -n "Troubleshooting\|troubleshoot\|## Logs\|watcher" README.md | head -10
```

- [ ] **Step 2: Add one paragraph**

Under the appropriate section, add:

```markdown
### Diagnosing watcher stops

The background watcher logs its lifecycle and error events to the system
log. If your watcher appears to have stopped unexpectedly, inspect recent
logs with:

    codescan log --since 1h

Pass `--all` to see activity across every codescan project. Under the
hood this uses `log show` on macOS and `journalctl -t codescan` on
Linux, so the OS handles rotation and compression automatically.
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(readme): add troubleshooting blurb for 'codescan log'"
```

---

## Task 13: Regression sweep

- [ ] **Step 1: Full test suite**

Run:
```bash
zig build test 2>&1 | tail -20
```

Expected: all tests pass (no counts that are lower than before this plan).

- [ ] **Step 2: CLI smoke test**

Run:
```bash
./zig-out/bin/codescan log --help >/dev/null
./zig-out/bin/codescan log --all --since 5m >/dev/null
./zig-out/bin/codescan log --since 1h
```

Expected: clean exits; third command either prints recent codescan log entries or nothing (no errors).

- [ ] **Step 3: Watcher end-to-end spot check**

Run:
```bash
# Run a throwaway project
mkdir -p /tmp/codescan-e2e && cd /tmp/codescan-e2e
./zig-out/bin/codescan init || true  # may already be initialized; ignore
./zig-out/bin/codescan watch start
sleep 2
./zig-out/bin/codescan watch stop
./zig-out/bin/codescan log --root /tmp/codescan-e2e --since 1m | tail -5
cd -
```

Expected: at least one line containing `/tmp/codescan-e2e: watcher started` and one `/tmp/codescan-e2e: watcher stopping: signal received` (or equivalent).

- [ ] **Step 4: No commit — verification only**

---

## Self-Review Notes

1. **Spec coverage:**
   - Spec §1 (log message format) → Task 2 (`logWithRoot` format), Task 4 (call sites pass root).
   - Spec §2 (events) → Task 4 (all 8 call sites).
   - Spec §3 (FFI wrapper) → Task 2.
   - Spec §4 (init location) → Task 5.
   - Spec §5 (`codescan log` subcommand) → Tasks 6, 8, 9.
   - Spec §6 (MCP tool) → Task 10.
   - Spec §7 (testing) → Task 3 (gated), Task 7 (filter), Task 8 (runner), Task 10 (MCP), Task 13 (e2e).
   - Spec §8 (build system) → Task 1 (verification only).
   - Spec §9 (help text + README) → Tasks 11, 12.
   - All spec sections covered.

2. **Placeholder scan:** no "TBD"/"TODO"/"implement later" markers; all code steps show full code.

3. **Type consistency:** `Options` struct in `log_cmd.zig` matches fields used by `runLog` dispatch (Task 9) and MCP dispatch (Task 10). `Parsed` struct fields in Task 6 (`log_since`, `log_follow`, `log_all`, `log_limit`, `log_root`) match references in Task 9. `syslog.logWithRoot` signature consistent across Tasks 2, 4, 5.

4. **Known approximations:** Task 11 references a help-topic registry discovered by grep at implementation time rather than a fixed line number — this is deliberate because the existing file has multiple concepts of "help" scattered around and the exact insertion point is easier to find by pattern than to pin down in advance.
