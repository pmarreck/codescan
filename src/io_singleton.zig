//! Global Io singleton for the codescan CLI.
//!
//! Zig 0.16 made Io explicit and threaded through every I/O-touching function.
//! Codescan currently exposes init.io process-wide via this module; the proper
//! long-term fix is to thread `std.Io` through callers explicitly (PLAN.md
//! Phase 5, flagged 2026-05-31). Until that refactor lands, code paths that
//! run outside main's lifetime (daemon, watcher, background tasks) must call
//! `io_singleton.set(init.io)` early enough or risk the `get()` panic.
//!
//! Tests call `set(io)` with a fresh `Io.Threaded` if they need real
//! concurrency. Tests that don't `set()` fall back to `getOrInit()`, which
//! returns a single-threaded Io — concurrent ops on it return
//! `error.ConcurrencyUnavailable`. See the divergence-lock test at the
//! bottom of this file.

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

/// Lazy default: returns the set io, or sets up and returns a single-threaded
/// blocking Io on first call.
///
/// TEST/PROD DIVERGENCE (flagged 2026-05-31, see PLAN.md Phase 5):
/// This fallback uses `init_single_threaded`, which ships with
/// `allocator=.failing` and `concurrent_limit=.nothing`. Any test path that
/// reaches concurrency code through this fallback gets
/// `error.ConcurrencyUnavailable` (often surfacing as OOM mapped to that),
/// while production uses a full `Io.Threaded.init` that races address
/// candidates in parallel (functional Happy Eyeballs).
///
/// Naively swapping in `Io.Threaded.init(page_alloc, .{})` here breaks the
/// test suite: it spawns worker threads + installs SIGIO/SIGPIPE handlers
/// process-wide, and the process-singleton lifecycle has no clean tear-down
/// across the ~500 call sites that go through this fallback. Worker threads
/// race with later test bodies and panic on `busy_count` underflow.
///
/// Fixing this properly requires the explicit `std.Io` threading refactor
/// PLAN.md Phase 5 calls for. Until then, the regression test below LOCKS
/// the current divergent behavior — if someone "fixes" this fallback without
/// also doing the refactor, the test fails loudly.
var _fallback_threaded: ?std.Io.Threaded = null;
pub fn getOrInit() std.Io {
    if (current_io) |io| return io;
    if (_fallback_threaded == null) {
        _fallback_threaded = .init_single_threaded;
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

/// Resets module-private state so an isolated test can re-exercise the lazy
/// fallback path. Tests only.
pub fn resetForTesting() void {
	current_io = null;
	_fallback_threaded = null;
}

test "getOrInit fallback is currently single-threaded (locks known test/prod divergence)" {
	// THIS TEST DOCUMENTS A LIMITATION, NOT A WIN.
	//
	// Production runs `init.io` (real `Io.Threaded.init` from `start.zig`)
	// which gives parallel `connectMany` — functional Happy Eyeballs. The
	// test fallback below uses `init_single_threaded`, so any code path
	// reaching this fallback returns `error.ConcurrencyUnavailable` from
	// concurrent ops. This is a test/prod divergence flagged 2026-05-31
	// (PLAN.md Phase 5).
	//
	// Fixing the divergence requires explicit `std.Io` threading instead of
	// the process-singleton — a multi-session refactor across ~500 call
	// sites. Until then, this test LOCKS the current behavior. If it starts
	// failing because someone made `getOrInit()` return a real threaded Io
	// without doing the broader refactor, expect the broader test suite to
	// crash in worker threads (busy_count underflow on process tear-down).
	resetForTesting();
	defer resetForTesting();

	const io = getOrInit();
	var group: std.Io.Group = .init;
	const Runner = struct {
		fn noop() std.Io.Cancelable!void { return; }
	};
	const err = group.concurrent(io, Runner.noop, .{});
	try std.testing.expectError(error.ConcurrencyUnavailable, err);
}
