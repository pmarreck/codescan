const std = @import("std");
const cli = @import("cli.zig");
const search = @import("search.zig");
const hashline = @import("hashline.zig");
const model = @import("model.zig");

pub const OutputOptions = struct {
	show_comments: bool = false,
	use_color: bool = true,
	total_relevant: usize = 0,
	top_n: usize = 10,
};

pub fn writeResults(
	allocator: std.mem.Allocator,
	writer: *std.Io.Writer,
	format: cli.OutputFormat,
	results: []const search.Result,
	options: OutputOptions,
) !void {
	switch (format) {
		.human => try writeHuman(writer, results, options),
		.json => try writeJson(allocator, writer, results, options),
	}
}

fn writeHuman(writer: *std.Io.Writer, results: []const search.Result, options: OutputOptions) !void {
	if (options.total_relevant > results.len) {
		try writer.print("Showing {d} of {d} results (use --top {d} to see all)\n", .{
			results.len, options.total_relevant, options.total_relevant,
		});
	}
	const idx_width = countDigits(results.len);
	var path_width: usize = 0;
	var range_width: usize = 0;
	for (results) |res| {
		path_width = @max(path_width, res.symbol.file_path.len);
		var tmp_buf: [128]u8 = undefined;
		const tmp_range = formatRange(&tmp_buf, res.symbol);
		range_width = @max(range_width, tmp_range.len);
	}

	for (results, 0..) |res, idx| {
		try writeIndex(writer, idx + 1, idx_width);
		try writer.writeAll(". ");
		try writeColored(writer, options.use_color, "\x1b[36m", res.symbol.file_path);
		try writePadding(writer, path_width - res.symbol.file_path.len);
		try writer.writeAll(" ");

		var range_buf: [128]u8 = undefined;
		const range = formatRange(&range_buf, res.symbol);
		try writeColored(writer, options.use_color, "\x1b[33m", range);
		try writePadding(writer, range_width - range.len);
		try writer.writeAll("  ");

		try writeColored(writer, options.use_color, "\x1b[1m", res.symbol.signature);
		try writer.writeAll("\n");

		if (options.use_color) try writer.writeAll("\x1b[2m");
		try writer.print(
			"   score {d:.3}  vec {d:.3}  lex {d:.3}\n",
			.{ res.score, 1.0 / (1.0 + res.distance), res.lexical },
		);
		if (options.use_color) try writer.writeAll("\x1b[0m");

		if (options.show_comments) {
			if (res.symbol.doc_comment) |doc| {
				try writer.print("   doc: {s}\n", .{doc});
			}
		}
	}
}

fn writeJson(allocator: std.mem.Allocator, writer: *std.Io.Writer, results: []const search.Result, options: OutputOptions) !void {
	const JsonResult = struct {
		language: []const u8,
		file_path: []const u8,
		start_line: usize,
		start_hash: ?[]const u8,
		end_line: usize,
		end_hash: ?[]const u8,
		name: []const u8,
		signature: []const u8,
		doc_comment: ?[]const u8,
		symbol_kind: ?[]const u8,
		symbol_visibility: ?[]const u8,
		symbol_scope: ?[]const u8,
		symbol_arity: ?i32,
		score: f32,
		distance: f32,
		lexical: f32,
		bm25: f32,
	};

	const Payload = struct {
		total_relevant: usize,
		showing: usize,
		results: []const JsonResult,
	};

	var rows = try allocator.alloc(JsonResult, results.len);
	defer allocator.free(rows);

	for (results, 0..) |res, idx| {
		rows[idx] = .{
			.language = res.symbol.language,
			.file_path = res.symbol.file_path,
			.start_line = res.symbol.start_line,
			.start_hash = if (res.symbol.start_hash) |*h| @as([]const u8, h) else null,
			.end_line = res.symbol.end_line,
			.end_hash = if (res.symbol.end_hash) |*h| @as([]const u8, h) else null,
			.name = res.symbol.name,
			.signature = res.symbol.signature,
			.doc_comment = res.symbol.doc_comment,
			.symbol_kind = res.symbol.symbol_kind,
			.symbol_visibility = res.symbol.symbol_visibility,
			.symbol_scope = res.symbol.symbol_scope,
			.symbol_arity = res.symbol.symbol_arity,
			.score = res.score,
			.distance = res.distance,
			.lexical = res.lexical,
			.bm25 = res.bm25,
		};
	}

	var stream: std.json.Stringify = .{ .writer = writer, .options = .{} };
	try stream.write(Payload{
		.total_relevant = options.total_relevant,
		.showing = results.len,
		.results = rows,
	});
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
		.bm25 = 0,
	};
	defer res.deinit(allocator);

	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	try writeResults(allocator, &out.writer, .json, &[_]search.Result{res}, .{});
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
		.bm25 = 0,
	};
	defer res.deinit(allocator);

	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	try writeResults(allocator, &out.writer, .human, &[_]search.Result{res}, .{ .use_color = false });
	const payload = try out.toOwnedSlice();
	defer allocator.free(payload);

	try std.testing.expect(std.mem.indexOf(u8, payload, "src/a.zig") != null);
	try std.testing.expect(std.mem.indexOf(u8, payload, "1-2") != null);
}

test "writeResults hides doc comments by default" {
	const allocator = std.testing.allocator;

	var res = search.Result{
		.id = 1,
		.symbol = .{
			.language = try allocator.dupe(u8, "zig"),
			.file_path = try allocator.dupe(u8, "src/a.zig"),
			.name = try allocator.dupe(u8, "add"),
			.signature = try allocator.dupe(u8, "fn add() void"),
			.doc_comment = try allocator.dupe(u8, "adds"),
			.start_line = 1,
			.end_line = 2,
		},
		.score = 0.9,
		.distance = 0.1,
		.lexical = 1.0,
		.bm25 = 0,
	};
	defer res.deinit(allocator);

	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	try writeResults(allocator, &out.writer, .human, &[_]search.Result{res}, .{ .use_color = false });
	const payload = try out.toOwnedSlice();
	defer allocator.free(payload);

	try std.testing.expect(std.mem.indexOf(u8, payload, "doc:") == null);
}

test "writeResults includes doc comments when enabled" {
	const allocator = std.testing.allocator;

	var res = search.Result{
		.id = 1,
		.symbol = .{
			.language = try allocator.dupe(u8, "zig"),
			.file_path = try allocator.dupe(u8, "src/a.zig"),
			.name = try allocator.dupe(u8, "add"),
			.signature = try allocator.dupe(u8, "fn add() void"),
			.doc_comment = try allocator.dupe(u8, "adds"),
			.start_line = 1,
			.end_line = 2,
		},
		.score = 0.9,
		.distance = 0.1,
		.lexical = 1.0,
		.bm25 = 0,
	};
	defer res.deinit(allocator);

	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	try writeResults(allocator, &out.writer, .human, &[_]search.Result{res}, .{
		.show_comments = true,
		.use_color = false,
	});
	const payload = try out.toOwnedSlice();
	defer allocator.free(payload);

	try std.testing.expect(std.mem.indexOf(u8, payload, "doc: adds") != null);
}

fn countDigits(value: usize) usize {
	var n = value;
	var digits: usize = 1;
	while (n >= 10) : (n /= 10) digits += 1;
	return digits;
}

/// Formats a line range as "start:hash-end:hash" when hashes present, or "start-end" without.
fn formatRange(buf: []u8, sym: model.Symbol) []const u8 {
	if (sym.start_hash) |sh| {
		if (sym.end_hash) |eh| {
			return std.fmt.bufPrint(buf, "{d}:{s}-{d}:{s}", .{
				sym.start_line, &sh, sym.end_line, &eh,
			}) catch "?-?";
		}
	}
	return std.fmt.bufPrint(buf, "{d}-{d}", .{ sym.start_line, sym.end_line }) catch "?-?";
}

fn writeIndex(writer: *std.Io.Writer, value: usize, width: usize) !void {
	var buf: [32]u8 = undefined;
	const rendered = try std.fmt.bufPrint(&buf, "{d}", .{value});
	try writePadding(writer, width - rendered.len);
	try writer.writeAll(rendered);
}

fn writePadding(writer: *std.Io.Writer, count: usize) !void {
	var i: usize = 0;
	while (i < count) : (i += 1) {
		try writer.writeAll(" ");
	}
}

fn writeColored(writer: *std.Io.Writer, use_color: bool, code: []const u8, text: []const u8) !void {
	if (use_color) try writer.writeAll(code);
	try writer.writeAll(text);
	if (use_color) try writer.writeAll("\x1b[0m");
}

test "human output includes hashlines when hashes present" {
	const allocator = std.testing.allocator;

	var res = search.Result{
		.id = 1,
		.symbol = .{
			.language = try allocator.dupe(u8, "zig"),
			.file_path = try allocator.dupe(u8, "src/a.zig"),
			.name = try allocator.dupe(u8, "add"),
			.signature = try allocator.dupe(u8, "fn add() void"),
			.doc_comment = null,
			.start_line = 10,
			.end_line = 20,
			.start_hash = .{ 'k', '7', 'm' },
			.end_hash = .{ 'x', '9', 'a' },
		},
		.score = 0.9,
		.distance = 0.1,
		.lexical = 1.0,
		.bm25 = 0,
	};
	defer res.deinit(allocator);

	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	try writeResults(allocator, &out.writer, .human, &[_]search.Result{res}, .{ .use_color = false });
	const payload = try out.toOwnedSlice();
	defer allocator.free(payload);

	// Line ranges must include hashline format: "10:k7m-20:x9a"
	try std.testing.expect(std.mem.indexOf(u8, payload, "10:k7m-20:x9a") != null);
}

test "json output includes hashlines when hashes present" {
	const allocator = std.testing.allocator;

	var res = search.Result{
		.id = 1,
		.symbol = .{
			.language = try allocator.dupe(u8, "zig"),
			.file_path = try allocator.dupe(u8, "src/a.zig"),
			.name = try allocator.dupe(u8, "add"),
			.signature = try allocator.dupe(u8, "fn add() void"),
			.doc_comment = null,
			.start_line = 10,
			.end_line = 20,
			.start_hash = .{ 'k', '7', 'm' },
			.end_hash = .{ 'x', '9', 'a' },
		},
		.score = 0.9,
		.distance = 0.1,
		.lexical = 1.0,
		.bm25 = 0,
	};
	defer res.deinit(allocator);

	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	try writeResults(allocator, &out.writer, .json, &[_]search.Result{res}, .{});
	const payload = try out.toOwnedSlice();
	defer allocator.free(payload);

	// JSON should include start_hash and end_hash fields
	try std.testing.expect(std.mem.indexOf(u8, payload, "\"start_hash\":\"k7m\"") != null);
	try std.testing.expect(std.mem.indexOf(u8, payload, "\"end_hash\":\"x9a\"") != null);
}

test "human output shows plain line range when hashes absent" {
	const allocator = std.testing.allocator;

	var res = search.Result{
		.id = 1,
		.symbol = .{
			.language = try allocator.dupe(u8, "zig"),
			.file_path = try allocator.dupe(u8, "src/a.zig"),
			.name = try allocator.dupe(u8, "add"),
			.signature = try allocator.dupe(u8, "fn add() void"),
			.doc_comment = null,
			.start_line = 10,
			.end_line = 20,
		},
		.score = 0.9,
		.distance = 0.1,
		.lexical = 1.0,
		.bm25 = 0,
	};
	defer res.deinit(allocator);

	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	try writeResults(allocator, &out.writer, .human, &[_]search.Result{res}, .{ .use_color = false });
	const payload = try out.toOwnedSlice();
	defer allocator.free(payload);

	// Without hashes, plain range format
	try std.testing.expect(std.mem.indexOf(u8, payload, "10-20") != null);
}
