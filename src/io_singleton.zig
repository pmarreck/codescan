//! Global Io singleton for the codescan CLI.
//!
//! Zig 0.16 made Io explicit and threaded through every I/O-touching function.
//! Codescan currently exposes init.io process-wide via this module; the proper
//! long-term fix is to thread `std.Io` through callers explicitly (PLAN.md
//! Phase 5, flagged 2026-05-31). Until that refactor lands, code paths that
//! run outside main's lifetime (daemon, watcher, background tasks) must call
//! `io_singleton.set(init.io)` early enough or risk the `get()` panic.
//!
//! Tests call `set(io)` with a fresh `Io.Threaded`, or rely on
//! `getOrInit()` to lazily construct a real `Io.Threaded` (worker pool,
//! full concurrency) — both paths exercise the same kind of Io as
//! production. See the parity test at the bottom of this file.

const std = @import("std");

var current_io: ?std.Io = null;
var current_env_map: ?*std.process.Environ.Map = null;

/// Set during main() and from tests. Must be called before any get().
pub fn set(io: std.Io) void {
    current_io = io;
}

pub fn setEnvMap(env_map: *std.process.Environ.Map) void {
    current_env_map = env_map;
}

pub fn getEnvMap() ?*std.process.Environ.Map {
    return current_env_map;
}

/// Lazy default: returns the set env map, or initializes one from the
/// running process env for tests/contexts where setEnvMap() was not called.
/// Production main() always calls setEnvMap() during init so this lazy path
/// is only reached from unit tests that touch env-expansion code paths
/// transitively (e.g. config.parseText reaching env_expand.expand).
///
/// In a test context we use std.testing.environ (populated by the test
/// runner) to grab the real process env. Outside tests we fall back to an
/// empty map. The fallback map uses a process-wide page allocator (NOT the
/// caller's allocator, which is often std.testing.allocator and would flag
/// the long-lived map as a leak).
var _fallback_env_map: ?std.process.Environ.Map = null;
pub fn getEnvMapOrInit(_: std.mem.Allocator) *std.process.Environ.Map {
    if (current_env_map) |em| return em;
    if (_fallback_env_map == null) {
        const persist_alloc = std.heap.page_allocator;
        if (@import("builtin").is_test) {
            _fallback_env_map = std.testing.environ.createMap(persist_alloc) catch std.process.Environ.Map.init(persist_alloc);
        } else {
            _fallback_env_map = std.process.Environ.Map.init(persist_alloc);
        }
    }
    current_env_map = &_fallback_env_map.?;
    return current_env_map.?;
}

/// Returns the global io. Panics if unset (programmer error).
pub fn get() std.Io {
    return current_io orelse @panic("io_singleton.get() before set(); this is a codescan migration scaffold — call io_singleton.set(init.io) in main, or set up an Io.Threaded in your test");
}

/// Lazy default: returns the set io, or constructs a real `Io.Threaded`
/// (allocator=page_allocator, full concurrency) on first call.
///
/// TEST/PROD PARITY: this returns the same kind of Io that `main()` would
/// have given via `set(init.io)` — worker-thread pool, real concurrency,
/// real `connectMany` Happy Eyeballs. Tests exercise the same runtime as
/// production. (Flagged 2026-05-31; the prior `init_single_threaded`
/// fallback caused silent ConcurrencyUnavailable in tests while prod ran
/// fully concurrent — the exact environmental divergence the maintainer
/// rules against.)
///
/// LIFETIME: `_fallback_threaded` is process-lived and intentionally never
/// deinit'd from outside this module — workers stay parked on condvar wait
/// for the life of the process. Process exit reaps them at the OS level.
/// `resetForTesting()` clears only `current_io`, NOT `_fallback_threaded`,
/// because nulling the optional storage out from under live workers
/// underflows `busy_count` in `Threaded.zig:1799`.
var _fallback_threaded: ?std.Io.Threaded = null;
pub fn getOrInit() std.Io {
    if (current_io) |io| return io;
    if (_fallback_threaded == null) {
        _fallback_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    }
    current_io = _fallback_threaded.?.io();
    return current_io.?;
}

/// Shim for 0.15-style io_singleton.readToEndAlloc(file, alloc, max).
/// Internally builds a buffered reader and uses allocRemaining.
pub fn readToEndAlloc(file: std.Io.File, allocator: std.mem.Allocator, max: usize) ![]u8 {
    const io = getOrInit();
    var buf: [4096]u8 = undefined;
    var r = file.reader(io, &buf);
    return r.interface.allocRemaining(allocator, .limited(max));
}

/// Shim for 0.15-style io_singleton.getEnvVarOwned(alloc, name).
/// Returns owned slice or `error.EnvironmentVariableNotFound`.
pub const GetEnvVarError = error{ EnvironmentVariableNotFound } || std.mem.Allocator.Error;
pub fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) GetEnvVarError![]u8 {
    // Production main() always calls setEnvMap() early. Tests that touch this
    // path without setting an env map get a lazy empty map back so they see
    // EnvironmentVariableNotFound for everything (matching "no env var set").
    const env_map = getEnvMapOrInit(allocator);
    const v = env_map.get(name) orelse return error.EnvironmentVariableNotFound;
    return try allocator.dupe(u8, v);
}


// ============================================================================
// Tests
// ============================================================================

/// Resets `current_io` so an isolated test can re-exercise the lazy
/// fallback path. Intentionally does NOT touch `_fallback_threaded` — see
/// the LIFETIME comment on `getOrInit`. Tests only.
pub fn resetForTesting() void {
	current_io = null;
}

test "getOrInit returns Io with real concurrency (test/prod parity)" {
	// Tests exercise the same kind of Io as production — real `Io.Threaded`
	// with worker threads. Concurrent ops must succeed, not return
	// `error.ConcurrencyUnavailable`. If this test ever fails, the fallback
	// regressed to `init_single_threaded` and the environmental divergence
	// the maintainer rules against is back.
	resetForTesting();
	defer resetForTesting();

	const io = getOrInit();
	var group: std.Io.Group = .init;
	const Runner = struct {
		fn noop() std.Io.Cancelable!void { return; }
	};
	try group.concurrent(io, Runner.noop, .{});
	try group.await(io);
}
