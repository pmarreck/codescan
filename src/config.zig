const std = @import("std");
const cli = @import("cli.zig");

pub const Config = struct {
	output: ?cli.OutputFormat = null,
	top_n: ?usize = null,
	root_path: ?[]const u8 = null,
	db_path: ?[]const u8 = null,
	ollama_url: ?[]const u8 = null,

	pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
		if (self.root_path) |value| allocator.free(value);
		if (self.db_path) |value| allocator.free(value);
		if (self.ollama_url) |value| allocator.free(value);
		self.* = .{};
	}
};

pub fn parseText(allocator: std.mem.Allocator, text: []const u8) !Config {
	var config = Config{};
	var lines = std.mem.splitScalar(u8, text, '\n');
	while (lines.next()) |line| {
		const trimmed = std.mem.trim(u8, line, " \t\r");
		if (trimmed.len == 0) continue;
		if (trimmed[0] == '#') continue;
		if (trimmed.len >= 2 and trimmed[0] == '/' and trimmed[1] == '/') continue;

		var kv = std.mem.splitScalar(u8, trimmed, '=');
		const key_raw = kv.next() orelse return error.InvalidLine;
		const value_raw = kv.next() orelse return error.InvalidLine;
		if (kv.next() != null) return error.InvalidLine;

		const key = std.mem.trim(u8, key_raw, " \t");
		const value_untrimmed = std.mem.trim(u8, value_raw, " \t");
		const value = stripQuotes(value_untrimmed);

		if (std.mem.eql(u8, key, "output")) {
			if (std.mem.eql(u8, value, "json")) {
				config.output = .json;
			} else if (std.mem.eql(u8, value, "human")) {
				config.output = .human;
			} else {
				return error.InvalidValue;
			}
			continue;
		}

		if (std.mem.eql(u8, key, "top")) {
			config.top_n = try std.fmt.parseInt(usize, value, 10);
			continue;
		}

		if (std.mem.eql(u8, key, "root")) {
			config.root_path = try allocator.dupe(u8, value);
			continue;
		}

		if (std.mem.eql(u8, key, "db")) {
			config.db_path = try allocator.dupe(u8, value);
			continue;
		}

		if (std.mem.eql(u8, key, "ollama_url")) {
			config.ollama_url = try allocator.dupe(u8, value);
			continue;
		}

		return error.UnknownKey;
	}

	return config;
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !Config {
	const file = try std.fs.cwd().openFile(path, .{});
	defer file.close();
	const data = try file.readToEndAlloc(allocator, 1024 * 1024);
	defer allocator.free(data);
	return parseText(allocator, data);
}

fn stripQuotes(value: []const u8) []const u8 {
	if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
		return value[1 .. value.len - 1];
	}
	return value;
}

test "parseText empty yields defaults" {
	const allocator = std.testing.allocator;
	var cfg = try parseText(allocator, "\n\n# comment\n");
	defer cfg.deinit(allocator);
	try std.testing.expect(cfg.output == null);
	try std.testing.expect(cfg.top_n == null);
	try std.testing.expect(cfg.root_path == null);
	try std.testing.expect(cfg.db_path == null);
	try std.testing.expect(cfg.ollama_url == null);
}

test "parseText reads values" {
	const allocator = std.testing.allocator;
	const text =
		"output=json\n" ++
		"top=7\n" ++
		"root=/repo\n" ++
		"db=.codescan/db.sqlite3\n" ++
		"ollama_url=http://127.0.0.1:11434\n";
	var cfg = try parseText(allocator, text);
	defer cfg.deinit(allocator);
	try std.testing.expectEqual(cli.OutputFormat.json, cfg.output.?);
	try std.testing.expectEqual(@as(usize, 7), cfg.top_n.?);
	try std.testing.expectEqualStrings("/repo", cfg.root_path.?);
	try std.testing.expectEqualStrings(".codescan/db.sqlite3", cfg.db_path.?);
	try std.testing.expectEqualStrings("http://127.0.0.1:11434", cfg.ollama_url.?);
}

test "parseText errors on invalid line" {
	const allocator = std.testing.allocator;
	try std.testing.expectError(error.InvalidLine, parseText(allocator, "nope\n"));
}

test "parseText errors on unknown key" {
	const allocator = std.testing.allocator;
	try std.testing.expectError(error.UnknownKey, parseText(allocator, "nope=1\n"));
}

test "loadFromPath reads file" {
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	try tmp.dir.writeFile(.{ .sub_path = "config", .data = "top=3\n" });
	const allocator = std.testing.allocator;
	const path = try tmp.dir.realpathAlloc(allocator, "config");
	defer allocator.free(path);
	var cfg = try loadFromPath(allocator, path);
	defer cfg.deinit(allocator);
	try std.testing.expectEqual(@as(usize, 3), cfg.top_n.?);
}
