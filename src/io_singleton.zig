//! Global Io singleton for the codescan CLI.
//!
//! 0.16 made Io explicit and threaded through every I/O-touching function.
//! For codescan's CLI (single entry point, all calls within main's lifetime),
//! we capture init.io at main() entry and expose it process-wide. This is a
//! pragmatic shortcut the migration doc warns against but is acceptable for
//! a CLI binary where all I/O is during main's lifetime.
//!
//! Tests use `setForTesting(io)` (typically with a fresh `Io.Threaded`) before
//! exercising any code path that calls `get()`.

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
/// blocking Io on first call. Useful inside tests that don't want to manually
/// init.
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
