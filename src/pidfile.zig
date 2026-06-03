const std = @import("std");
const io_singleton = @import("io_singleton.zig");
const builtin = @import("builtin");

const is_posix = switch (builtin.os.tag) {
	.windows => false,
	else => true,
};

/// Writes the current process PID to `.codescan/watcher.pid` under the given codescan dir.
pub fn writePid(allocator: std.mem.Allocator, codescan_dir: []const u8) !void {
	if (!is_posix) return;
	const path = try pidPath(allocator, codescan_dir);
	defer allocator.free(path);

	const pid = std.c.getpid();
	var buf: [20]u8 = undefined;
	const pid_str = std.fmt.bufPrint(&buf, "{d}", .{pid}) catch unreachable;

	const file = try std.Io.Dir.cwd().createFile(io_singleton.getOrInit(), path, .{});
	defer file.close(io_singleton.getOrInit());
	try file.writeStreamingAll(io_singleton.getOrInit(), pid_str);
}

/// Removes the PID file. Safe to call if file doesn't exist.
pub fn removePid(allocator: std.mem.Allocator, codescan_dir: []const u8) void {
	if (!is_posix) return;
	const path = pidPath(allocator, codescan_dir) catch return;
	defer allocator.free(path);
	std.Io.Dir.cwd().deleteFile(io_singleton.getOrInit(), path) catch {};
}

/// Reads the PID from the file and checks if the process is alive.
/// Returns the PID if alive, null if file missing, unreadable, or process dead.
pub fn readAndCheckPid(allocator: std.mem.Allocator, codescan_dir: []const u8) !?PidType {
	if (!is_posix) return null;
	const path = try pidPath(allocator, codescan_dir);
	defer allocator.free(path);

	const contents = std.Io.Dir.cwd().readFileAlloc(io_singleton.getOrInit(), path, allocator, .limited(64)) catch return null;
	defer allocator.free(contents);

	const trimmed = std.mem.trim(u8, contents, &std.ascii.whitespace);
	const pid = std.fmt.parseInt(PidType, trimmed, 10) catch return null;

	if (pid <= 0) return null;

	// kill(pid, 0) checks if process exists without sending a signal
	const result = std.c.kill(pid, @enumFromInt(0));
	if (result == 0) return pid;

	// Check errno: EPERM means process exists but we lack permission (still alive)
	if (result == -1) {
		const err = std.c._errno().*;
		if (err == 1) return pid; // EPERM = 1 on both Linux and macOS
	}

	// ESRCH or other error — process doesn't exist, treat as dead
	return null;
}

pub const PidType = if (is_posix) std.posix.pid_t else i32;

/// Convenience: returns true if a watcher process is currently running.
pub fn isWatcherRunning(allocator: std.mem.Allocator, codescan_dir: []const u8) bool {
	const pid = readAndCheckPid(allocator, codescan_dir) catch return false;
	return pid != null;
}

/// Atomically checks for an existing watcher and writes the current PID.
/// Returns error.WatcherAlreadyRunning if another live watcher owns the pidfile.
pub fn tryAcquirePid(allocator: std.mem.Allocator, codescan_dir: []const u8) !void {
	if (!is_posix) return;
	if (readAndCheckPid(allocator, codescan_dir) catch null) |existing_pid| {
		// Another live process holds the pidfile — check it's not us
		if (existing_pid != std.c.getpid()) {
			return error.WatcherAlreadyRunning;
		}
	}
	try writePid(allocator, codescan_dir);
}

fn pidPath(allocator: std.mem.Allocator, codescan_dir: []const u8) ![]u8 {
	return std.fs.path.join(allocator, &.{ codescan_dir, "watcher.pid" });
}

// Tests

test "writePid creates file with current PID" {
	if (!is_posix) return;
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	const dir_path = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
	defer allocator.free(dir_path);

	try writePid(allocator, dir_path);

	const contents = try tmp.dir.readFileAlloc(io_singleton.getOrInit(), "watcher.pid", allocator, .limited(64));
	defer allocator.free(contents);

	const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, contents, &std.ascii.whitespace), 10);
	try std.testing.expectEqual(std.c.getpid(), pid);
}

test "readAndCheckPid returns current PID when alive" {
	if (!is_posix) return;
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	const dir_path = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
	defer allocator.free(dir_path);

	try writePid(allocator, dir_path);

	const pid = try readAndCheckPid(allocator, dir_path);
	try std.testing.expect(pid != null);
	try std.testing.expectEqual(std.c.getpid(), pid.?);
}

test "readAndCheckPid returns null for missing file" {
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	const dir_path = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
	defer allocator.free(dir_path);

	const pid = try readAndCheckPid(allocator, dir_path);
	try std.testing.expectEqual(null, pid);
}

test "readAndCheckPid returns null for stale PID" {
	if (!is_posix) return;
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	const dir_path = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
	defer allocator.free(dir_path);

	// Write a PID that almost certainly doesn't exist (max PID range)
	const file = try tmp.dir.createFile(io_singleton.getOrInit(), "watcher.pid", .{});
	defer file.close(io_singleton.getOrInit());
	try file.writeStreamingAll(io_singleton.getOrInit(), "99999999");

	const pid = try readAndCheckPid(allocator, dir_path);
	try std.testing.expectEqual(null, pid);
}

test "removePid cleans up file" {
	if (!is_posix) return;
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	const dir_path = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
	defer allocator.free(dir_path);

	try writePid(allocator, dir_path);

	// Verify file exists
	_ = try tmp.dir.statFile(io_singleton.getOrInit(), "watcher.pid", .{});

	removePid(allocator, dir_path);

	// Verify file is gone
	const result = tmp.dir.statFile(io_singleton.getOrInit(), "watcher.pid", .{});
	try std.testing.expectError(error.FileNotFound, result);
}

test "isWatcherRunning returns true for current process" {
	if (!is_posix) return;
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	const dir_path = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
	defer allocator.free(dir_path);

	try writePid(allocator, dir_path);
	try std.testing.expect(isWatcherRunning(allocator, dir_path));
}

test "isWatcherRunning returns false for missing file" {
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	const dir_path = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
	defer allocator.free(dir_path);

	try std.testing.expect(!isWatcherRunning(allocator, dir_path));
}

test "tryAcquirePid succeeds when no watcher running" {
	if (!is_posix) return;
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	const dir_path = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
	defer allocator.free(dir_path);

	try tryAcquirePid(allocator, dir_path);

	// Verify our PID was written
	const pid = try readAndCheckPid(allocator, dir_path);
	try std.testing.expect(pid != null);
	try std.testing.expectEqual(std.c.getpid(), pid.?);
}

test "tryAcquirePid fails when watcher already running" {
	if (!is_posix) return;
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	const dir_path = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
	defer allocator.free(dir_path);

	// Write PID 1 (init/launchd — always alive, not us)
	const file = try tmp.dir.createFile(io_singleton.getOrInit(), "watcher.pid", .{});
	defer file.close(io_singleton.getOrInit());
	try file.writeStreamingAll(io_singleton.getOrInit(), "1");

	// Acquire should fail since PID 1 is alive and not our process
	const result = tryAcquirePid(allocator, dir_path);
	try std.testing.expectError(error.WatcherAlreadyRunning, result);
}

test "tryAcquirePid succeeds when stale PID in file and overwrites with current PID" {
	if (!is_posix) return;
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	const dir_path = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
	defer allocator.free(dir_path);

	// Write a stale PID (process that doesn't exist)
	{
		const file = try tmp.dir.createFile(io_singleton.getOrInit(), "watcher.pid", .{});
		defer file.close(io_singleton.getOrInit());
		try file.writeStreamingAll(io_singleton.getOrInit(), "99999999");
	}

	// Should succeed since stale PID's process is dead
	try tryAcquirePid(allocator, dir_path);

	// STRONGER ASSERTION (2026-06-02): after acquisition, the pidfile must
	// contain THIS process's PID, not the stale 99999999. A regression where
	// `tryAcquirePid` early-returned success without writing would pass the
	// bare `try` above but fail this check.
	const stored = (try readAndCheckPid(allocator, dir_path)) orelse {
		std.debug.print("expected stored PID, got null\n", .{});
		return error.TestFailed;
	};
	try std.testing.expectEqual(@as(PidType, std.c.getpid()), stored);
	try std.testing.expect(stored != 99999999);
}
