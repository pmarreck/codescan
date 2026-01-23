const std = @import("std");
const cli = @import("cli.zig");
const search = @import("search.zig");

pub fn writeResults(
	allocator: std.mem.Allocator,
	writer: *std.Io.Writer,
	format: cli.OutputFormat,
	results: []const search.Result,
) !void {
	switch (format) {
		.human => try writeHuman(writer, results),
		.json => try writeJson(allocator, writer, results),
	}
}

fn writeHuman(writer: *std.Io.Writer, results: []const search.Result) !void {
	for (results, 0..) |res, idx| {
		try writer.print(
			"{d}. {s}:{d}-{d} {s}\n",
			.{ idx + 1, res.symbol.file_path, res.symbol.start_line, res.symbol.end_line, res.symbol.signature },
		);
		try writer.print(
			"   score={d:.3} vector={d:.3} lexical={d:.3}\n",
			.{ res.score, 1.0 / (1.0 + res.distance), res.lexical },
		);
		if (res.symbol.doc_comment) |doc| {
			try writer.print("   doc: {s}\n", .{doc});
		}
	}
}

fn writeJson(allocator: std.mem.Allocator, writer: *std.Io.Writer, results: []const search.Result) !void {
	const JsonResult = struct {
		language: []const u8,
		file_path: []const u8,
		start_line: usize,
		end_line: usize,
		name: []const u8,
		signature: []const u8,
		doc_comment: ?[]const u8,
		score: f32,
		distance: f32,
		lexical: f32,
	};

	const Payload = struct {
		results: []const JsonResult,
	};

	var rows = try allocator.alloc(JsonResult, results.len);
	defer allocator.free(rows);

	for (results, 0..) |res, idx| {
		rows[idx] = .{
			.language = res.symbol.language,
			.file_path = res.symbol.file_path,
			.start_line = res.symbol.start_line,
			.end_line = res.symbol.end_line,
			.name = res.symbol.name,
			.signature = res.symbol.signature,
			.doc_comment = res.symbol.doc_comment,
			.score = res.score,
			.distance = res.distance,
			.lexical = res.lexical,
		};
	}

	var stream: std.json.Stringify = .{ .writer = writer, .options = .{} };
	try stream.write(Payload{ .results = rows });
}

test "writeResults emits json payload" {
	const allocator = std.testing.allocator;

	var res = search.Result{
		.id = 1,
		.symbol = .{
			.language = try allocator.dupe(u8, "zig"),
			.file_path = try allocator.dupe(u8, "src/a.zig"),
			.name = try allocator.dupe(u8, "add"),
			.signature = try allocator.dupe(u8, "fn add() void"),
			.doc_comment = null,
			.start_line = 1,
			.end_line = 2,
		},
		.score = 0.9,
		.distance = 0.1,
		.lexical = 1.0,
	};
	defer res.deinit(allocator);

	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	try writeResults(allocator, &out.writer, .json, &[_]search.Result{res});
	const payload = try out.toOwnedSlice();
	defer allocator.free(payload);

	var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
	defer parsed.deinit();

	const obj = parsed.value.object;
	const results = obj.get("results") orelse return error.TestExpectedEqual;
	try std.testing.expect(results.array.items.len == 1);
	const first = results.array.items[0].object;
	try std.testing.expectEqualStrings("src/a.zig", first.get("file_path").?.string);
}

test "writeResults emits human output" {
	const allocator = std.testing.allocator;

	var res = search.Result{
		.id = 1,
		.symbol = .{
			.language = try allocator.dupe(u8, "zig"),
			.file_path = try allocator.dupe(u8, "src/a.zig"),
			.name = try allocator.dupe(u8, "add"),
			.signature = try allocator.dupe(u8, "fn add() void"),
			.doc_comment = null,
			.start_line = 1,
			.end_line = 2,
		},
		.score = 0.9,
		.distance = 0.1,
		.lexical = 1.0,
	};
	defer res.deinit(allocator);

	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	try writeResults(allocator, &out.writer, .human, &[_]search.Result{res});
	const payload = try out.toOwnedSlice();
	defer allocator.free(payload);

	try std.testing.expect(std.mem.indexOf(u8, payload, "src/a.zig:1-2") != null);
}
