const std = @import("std");
const io_singleton = @import("io_singleton.zig");

/// Manages a progress file as a symlink to TMPDIR for low-wear status reporting.
/// The .codescan/watcher-progress path is a symlink to $TMPDIR/codescan-progress-<hash>.
/// codescan status reads this file to show watcher activity.

pub fn setup(allocator: std.mem.Allocator, codescan_dir: []const u8) ?[]const u8 {
	const tmpdir = blk: {
		const env_map = io_singleton.getEnvMap() orelse break :blk "/tmp";
		break :blk env_map.get("TMPDIR") orelse env_map.get("TMP") orelse "/tmp";
	};

	// Build unique tmp path based on codescan_dir
	var hasher = std.hash.XxHash64.init(0);
	hasher.update(codescan_dir);
	const hash = hasher.final();

	const tmp_path = std.fmt.allocPrint(allocator, "{s}/codescan-progress-{x}", .{ tmpdir, hash }) catch return null;
	errdefer allocator.free(tmp_path);

	const link_path = std.fmt.allocPrint(allocator, "{s}/watcher-progress", .{codescan_dir}) catch {
		allocator.free(tmp_path);
		return null;
	};
	defer allocator.free(link_path);

	// Clean up any stale symlink or file
	std.Io.Dir.cwd().deleteFile(io_singleton.getOrInit(), link_path) catch {};
	std.Io.Dir.cwd().deleteFile(io_singleton.getOrInit(), tmp_path) catch {};

	// Create symlink: .codescan/watcher-progress -> $TMPDIR/codescan-progress-<hash>
	std.Io.Dir.cwd().symLink(io_singleton.getOrInit(), tmp_path, link_path, .{}) catch {
		// If symlink fails, just use the tmp_path directly
		return tmp_path;
	};

	return tmp_path;
}

pub fn write(path: ?[]const u8, msg: []const u8) void {
	const p = path orelse return;
	const file = std.Io.Dir.cwd().createFile(io_singleton.getOrInit(), p, .{}) catch return;
	defer file.close(io_singleton.getOrInit());
	file.writeStreamingAll(io_singleton.getOrInit(), msg) catch {};
}

pub fn clear(allocator: std.mem.Allocator, path: ?[]const u8, codescan_dir: ?[]const u8) void {
	if (path) |p| {
		std.Io.Dir.cwd().deleteFile(io_singleton.getOrInit(), p) catch {};
		// `setup` returns an allocator-owned path; freeing it here keeps the
		// setup/clear pair symmetric. This leaked unnoticed for as long as the
		// watcher only ever exited by signal, where nothing checks.
		allocator.free(p);
	}
	if (codescan_dir) |dir| {
		const link_path = std.fmt.allocPrint(allocator, "{s}/watcher-progress", .{dir}) catch return;
		defer allocator.free(link_path);
		std.Io.Dir.cwd().deleteFile(io_singleton.getOrInit(), link_path) catch {};
	}
}


/// Read the progress file (follows symlink). Returns owned string or null.
pub fn read(allocator: std.mem.Allocator, codescan_dir: []const u8) ?[]const u8 {
	const link_path = std.fmt.allocPrint(allocator, "{s}/watcher-progress", .{codescan_dir}) catch return null;
	defer allocator.free(link_path);
	return std.Io.Dir.cwd().readFileAlloc(io_singleton.getOrInit(), link_path, allocator, .limited(256)) catch null;
}
