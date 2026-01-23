const std = @import("std");
const plugin = @import("plugin.zig");

pub fn findFiles(
	allocator: std.mem.Allocator,
	root_path: []const u8,
	registry: plugin.Registry,
) ![]const []const u8 {
	var dir = try std.fs.cwd().openDir(root_path, .{ .iterate = true });
	defer dir.close();

	var walker = try dir.walk(allocator);
	defer walker.deinit();

	var results = std.ArrayListUnmanaged([]const u8){};
	errdefer {
		for (results.items) |path| allocator.free(path);
		results.deinit(allocator);
	}

	while (try walker.next()) |entry| {
		if (entry.kind != .file) continue;
		if (registry.find(entry.path) == null) continue;
		try results.append(allocator, try allocator.dupe(u8, entry.path));
	}

	return results.toOwnedSlice(allocator);
}

test "findFiles finds supported extensions" {
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	try tmp.dir.makePath("src");
	try tmp.dir.makePath("lib");
	try tmp.dir.writeFile(.{ .sub_path = "src/main.zig", .data = "" });
	try tmp.dir.writeFile(.{ .sub_path = "lib/demo.ex", .data = "" });
	try tmp.dir.writeFile(.{ .sub_path = "README.md", .data = "" });

	const allocator = std.testing.allocator;
	const root = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(root);

	const files = try findFiles(allocator, root, plugin.defaultRegistry());
	defer {
		for (files) |path| allocator.free(path);
		allocator.free(files);
	}

	try std.testing.expectEqual(@as(usize, 2), files.len);
	var found_zig = false;
	var found_ex = false;
	for (files) |path| {
		if (std.mem.eql(u8, path, "src/main.zig")) found_zig = true;
		if (std.mem.eql(u8, path, "lib/demo.ex")) found_ex = true;
	}
	try std.testing.expect(found_zig);
	try std.testing.expect(found_ex);
}
