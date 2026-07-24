const std = @import("std");
const io_singleton = @import("io_singleton.zig");

pub const relative_path = ".codescan/last_index_datetime";

/// Records the last successful index commit as an empty file whose filesystem
/// mtime is the timestamp, avoiding a second clock representation to parse.
pub fn record(root_path: []const u8) !void {
	const io = io_singleton.getOrInit();
	var root = try std.Io.Dir.cwd().openDir(io, root_path, .{});
	defer root.close(io);
	try root.createDirPath(io, ".codescan");
	const marker = try root.createFile(io, relative_path, .{ .truncate = true });
	marker.close(io);
}
