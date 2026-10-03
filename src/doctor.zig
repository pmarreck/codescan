const std = @import("std");
const cli = @import("cli.zig");

pub const Status = enum {
	pass,
	fail,
	note,
	skipped,
};

pub const Check = struct {
	name: []const u8,
	status: Status,
	message: []const u8,
};

pub const Report = struct {
	allocator: std.mem.Allocator,
	checks: std.ArrayListUnmanaged(Check) = .empty,

	pub fn init(allocator: std.mem.Allocator) Report {
		return .{ .allocator = allocator };
	}

	pub fn deinit(self: *Report) void {
		for (self.checks.items) |check| self.allocator.free(check.message);
		self.checks.deinit(self.allocator);
		self.* = undefined;
	}

	pub fn add(self: *Report, status: Status, name: []const u8, message: []const u8) !void {
		try self.checks.append(self.allocator, .{
			.name = name,
			.status = status,
			.message = try self.allocator.dupe(u8, message),
		});
	}

	pub fn addFmt(self: *Report, status: Status, name: []const u8, comptime fmt: []const u8, args: anytype) !void {
		const message = try std.fmt.allocPrint(self.allocator, fmt, args);
		errdefer self.allocator.free(message);
		try self.checks.append(self.allocator, .{
			.name = name,
			.status = status,
			.message = message,
		});
	}
};

pub fn hasFailures(checks: []const Check) bool {
	for (checks) |check| {
		if (check.status == .fail) return true;
	}
	return false;
}

/// Pure rendering boundary for CLI and MCP callers.
pub fn render(allocator: std.mem.Allocator, root_path: []const u8, checks: []const Check, format: cli.OutputFormat) ![]u8 {
	var out: std.Io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	switch (format) {
		.human => {
			try out.writer.print("Doctor: {s}\n", .{root_path});
			for (checks) |check| {
				const label = switch (check.status) {
					.pass => "OK",
					.fail => "ERROR",
					.note => "NOTE",
					.skipped => "SKIP",
				};
				try out.writer.print("{s} {s}: {s}\n", .{ label, check.name, check.message });
			}
			try out.writer.print("Health: {s}\n", .{if (hasFailures(checks)) "FAILED" else "OK"});
		},
		.json => {
			const Payload = struct {
				root: []const u8,
				ok: bool,
				checks: []const Check,
			};
			var stream: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
			try stream.write(Payload{
				.root = root_path,
				.ok = !hasFailures(checks),
				.checks = checks,
			});
			try out.writer.writeAll("\n");
		},
	}

	return out.toOwnedSlice();
}

test "a stopped watcher is a note rather than a doctor failure" {
	const checks = [_]Check{
		.{ .name = "Settings", .status = .pass, .message = "valid" },
		.{ .name = "Watcher", .status = .note, .message = "stopped" },
	};
	try std.testing.expect(!hasFailures(&checks));

	const text = try render(std.testing.allocator, "/project", &checks, .human);
	defer std.testing.allocator.free(text);
	try std.testing.expect(std.mem.indexOf(u8, text, "NOTE Watcher: stopped") != null);
	try std.testing.expect(std.mem.indexOf(u8, text, "Health: OK") != null);
}

test "JSON report exposes a stopped watcher as a note" {
	const checks = [_]Check{
		.{ .name = "Watcher", .status = .note, .message = "stopped" },
	};
	const text = try render(std.testing.allocator, "/project", &checks, .json);
	defer std.testing.allocator.free(text);
	try std.testing.expect(std.mem.indexOf(u8, text, "\"ok\":true") != null);
	try std.testing.expect(std.mem.indexOf(u8, text, "\"status\":\"note\"") != null);
}
