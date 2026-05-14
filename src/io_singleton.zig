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
    const env_map = current_env_map orelse @panic("io_singleton.getEnvVarOwned: setEnvMap() not called yet");
    const v = env_map.get(name) orelse return error.EnvironmentVariableNotFound;
    return try allocator.dupe(u8, v);
}
