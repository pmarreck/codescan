const std = @import("std");
const model = @import("model.zig");
const util = @import("extract_util.zig");

pub fn extract(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	source: []const u8,
) ![]model.Symbol {
	var lines = try util.splitLines(allocator, source);
	defer lines.deinit(allocator);

	var symbols = @as(std.ArrayListUnmanaged(model.Symbol), .empty);
	errdefer {
		for (symbols.items) |*sym| sym.deinit(allocator);
		symbols.deinit(allocator);
	}

	var paragraph_lines = @as(std.ArrayListUnmanaged([]const u8), .empty);
	defer paragraph_lines.deinit(allocator);

	var start_idx: usize = 0;
	for (lines.items, 0..) |line, idx| {
		if (isBlank(line)) {
			if (paragraph_lines.items.len > 0) {
				try emitParagraph(allocator, file_path, start_idx, idx - 1, paragraph_lines.items, &symbols);
				paragraph_lines.clearRetainingCapacity();
			}
			continue;
		}
		if (paragraph_lines.items.len == 0) start_idx = idx;
		try paragraph_lines.append(allocator, line);
	}

	if (paragraph_lines.items.len > 0) {
		try emitParagraph(allocator, file_path, start_idx, lines.items.len - 1, paragraph_lines.items, &symbols);
	}

	return symbols.toOwnedSlice(allocator);
}

fn emitParagraph(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	start_idx: usize,
	end_idx: usize,
	lines: []const []const u8,
	out: *std.ArrayListUnmanaged(model.Symbol),
) !void {
	const paragraph = try joinLines(allocator, lines);
	const preview = firstNonEmptyLine(lines) orelse lines[0];

	const symbol = model.Symbol{
		.language = try allocator.dupe(u8, "text"),
		.file_path = try allocator.dupe(u8, file_path),
		.name = try allocator.dupe(u8, "paragraph"),
		.signature = try allocator.dupe(u8, std.mem.trim(u8, preview, " \t\r")),
		.doc_comment = paragraph,
		.start_line = start_idx + 1,
		.end_line = end_idx + 1,
	};
	try out.append(allocator, symbol);

	try emitLines(allocator, file_path, start_idx, lines, out);
	if (paragraph) |text| {
		try emitSentences(allocator, file_path, start_idx, end_idx, text, out);
	}
}

fn emitLines(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	start_idx: usize,
	lines: []const []const u8,
	out: *std.ArrayListUnmanaged(model.Symbol),
) !void {
	for (lines, 0..) |line, idx| {
		const trimmed = std.mem.trim(u8, line, " \t\r");
		if (trimmed.len == 0) continue;
		var name_buf: [64]u8 = undefined;
		const name = try std.fmt.bufPrint(&name_buf, "line {d}", .{start_idx + idx + 1});
		const symbol = model.Symbol{
			.language = try allocator.dupe(u8, "text"),
			.file_path = try allocator.dupe(u8, file_path),
			.name = try allocator.dupe(u8, name),
			.signature = try allocator.dupe(u8, trimmed),
			.doc_comment = null,
			.start_line = start_idx + idx + 1,
			.end_line = start_idx + idx + 1,
		};
		try out.append(allocator, symbol);
	}
}

fn emitSentences(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	start_idx: usize,
	end_idx: usize,
	paragraph: []const u8,
	out: *std.ArrayListUnmanaged(model.Symbol),
) !void {
	var start: usize = 0;
	var idx: usize = 0;
	while (idx < paragraph.len) : (idx += 1) {
		const ch = paragraph[idx];
		if (ch == '.' or ch == '!' or ch == '?') {
			const next = idx + 1;
			if (next == paragraph.len or paragraph[next] == ' ' or paragraph[next] == '\n') {
				const sentence = std.mem.trim(u8, paragraph[start .. idx + 1], " \t\r\n");
				if (sentence.len > 0) {
					const symbol = model.Symbol{
						.language = try allocator.dupe(u8, "text"),
						.file_path = try allocator.dupe(u8, file_path),
						.name = try allocator.dupe(u8, "sentence"),
						.signature = try allocator.dupe(u8, sentence),
						.doc_comment = null,
						.start_line = start_idx + 1,
						.end_line = end_idx + 1,
					};
					try out.append(allocator, symbol);
				}
				start = idx + 1;
			}
		}
	}
	const tail = std.mem.trim(u8, paragraph[start..], " \t\r\n");
	if (tail.len > 0) {
		const symbol = model.Symbol{
			.language = try allocator.dupe(u8, "text"),
			.file_path = try allocator.dupe(u8, file_path),
			.name = try allocator.dupe(u8, "sentence"),
			.signature = try allocator.dupe(u8, tail),
			.doc_comment = null,
			.start_line = start_idx + 1,
			.end_line = end_idx + 1,
		};
		try out.append(allocator, symbol);
	}
}

fn isBlank(line: []const u8) bool {
	return std.mem.trim(u8, line, " \t\r").len == 0;
}

fn joinLines(allocator: std.mem.Allocator, lines: []const []const u8) !?[]const u8 {
	if (lines.len == 0) return null;
	var out: std.Io.Writer.Allocating = .init(allocator);
	defer out.deinit();
	for (lines, 0..) |line, idx| {
		if (idx > 0) try out.writer.writeAll("\n");
		try out.writer.writeAll(line);
	}
	const owned = try out.toOwnedSlice();
	return @as(?[]const u8, owned);
}

fn firstNonEmptyLine(lines: []const []const u8) ?[]const u8 {
	for (lines) |line| {
		const trimmed = std.mem.trim(u8, line, " \t\r");
		if (trimmed.len > 0) return trimmed;
	}
	return null;
}

test "extract text emits paragraph and sentence symbols" {
	const allocator = std.testing.allocator;
	const source =
		"First sentence. Second sentence.\n" ++
		"Next line.\n\n" ++
		"Another paragraph here.\n";

	const symbols = try extract(allocator, "notes.txt", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	var found_paragraph = false;
	var found_sentence = false;
	var found_line = false;
	for (symbols) |sym| {
		if (std.mem.eql(u8, sym.name, "paragraph")) found_paragraph = true;
		if (std.mem.eql(u8, sym.signature, "First sentence.")) found_sentence = true;
		if (std.mem.eql(u8, sym.signature, "Next line.")) found_line = true;
	}
	try std.testing.expect(found_paragraph);
	try std.testing.expect(found_sentence);
	try std.testing.expect(found_line);
}
