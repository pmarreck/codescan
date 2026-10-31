const std = @import("std");

pub const Found = struct {
	project_root: []const u8,
	root: []const u8,
	db_path: []const u8,
	watcher_pid: ?i64,
	watcher_status: []const u8,
	walk_up_steps: usize,
};

/// Pure JSON rendering; the adapter owns filesystem observations and newlines.
pub fn found(allocator: std.mem.Allocator, report: Found) ![]u8 {
	return std.json.Stringify.valueAlloc(allocator, report, .{});
}

pub fn missing(allocator: std.mem.Allocator, start_path: []const u8) ![]u8 {
	const message = try std.fmt.allocPrint(allocator, "no .codescan/ directory found walking up from {s}", .{start_path});
	defer allocator.free(message);
	return std.json.Stringify.valueAlloc(allocator, .{ .root = @as(?[]const u8, null), .@"error" = message }, .{});
}

const paths = [_][]const u8{ "ordinary", "quoted\"path", "backslash\\path", "line\nbreak\ttab\rcarriage\x01", "unicode-λ-雪" };

fn foundOwnership(allocator: std.mem.Allocator) !void {
	const rendered = try found(allocator, .{
		.project_root = paths[1], .root = paths[2], .db_path = paths[3],
		.watcher_pid = null, .watcher_status = "stopped", .walk_up_steps = 0,
	});
	defer allocator.free(rendered);
}

fn missingOwnership(allocator: std.mem.Allocator) !void {
	const rendered = try missing(allocator, paths[1]);
	defer allocator.free(rendered);
}

test "found root reports preserve JSON paths and metadata with complete ownership" {
	const allocator = std.testing.allocator;
	for (paths) |path| {
		for ([_][]const u8{ "stopped", "running", "stale" }, 0..) |status, index| {
			const report: Found = .{
				.project_root = path, .root = "state\"\\\t", .db_path = "database-雪",
				.watcher_pid = if (index == 0) null else 42, .watcher_status = status, .walk_up_steps = index,
			};
			const rendered = try found(allocator, report);
			defer allocator.free(rendered);
			var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
			defer parsed.deinit();
			const fields = parsed.value.object;
			try std.testing.expectEqual(@as(usize, 6), fields.count());
			try std.testing.expectEqualStrings(report.project_root, fields.get("project_root").?.string);
			try std.testing.expectEqualStrings(report.root, fields.get("root").?.string);
			try std.testing.expectEqualStrings(report.db_path, fields.get("db_path").?.string);
			try std.testing.expectEqualStrings(status, fields.get("watcher_status").?.string);
			try std.testing.expectEqual(@as(i64, @intCast(index)), fields.get("walk_up_steps").?.integer);
			if (report.watcher_pid) |pid| {
				try std.testing.expectEqual(pid, fields.get("watcher_pid").?.integer);
			} else try std.testing.expect(fields.get("watcher_pid").? == .null);
		}
	}
	try std.testing.checkAllAllocationFailures(allocator, foundOwnership, .{});
}

test "missing root reports preserve JSON diagnostics with complete ownership" {
	const allocator = std.testing.allocator;
	for (paths) |path| {
		const rendered = try missing(allocator, path);
		defer allocator.free(rendered);
		var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
		defer parsed.deinit();
		const expected = try std.fmt.allocPrint(allocator, "no .codescan/ directory found walking up from {s}", .{path});
		defer allocator.free(expected);
		try std.testing.expectEqual(@as(usize, 2), parsed.value.object.count());
		try std.testing.expect(parsed.value.object.get("root").? == .null);
		try std.testing.expectEqualStrings(expected, parsed.value.object.get("error").?.string);
	}
	try std.testing.checkAllAllocationFailures(allocator, missingOwnership, .{});
}
