const std = @import("std");
const model = @import("model.zig");

pub fn extract(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	source: []const u8,
) ![]model.Symbol {
	var results = std.ArrayListUnmanaged(model.Symbol){};
	errdefer {
		for (results.items) |*sym| sym.deinit(allocator);
		results.deinit(allocator);
	}

	var doc_comment: ?[]const u8 = null;
	defer if (doc_comment) |value| allocator.free(value);

	var lines = std.mem.splitScalar(u8, source, '\n');
	var line_no: usize = 0;
	while (lines.next()) |line| {
		line_no += 1;
		const trimmed = std.mem.trimLeft(u8, line, " \t\r");
		if (trimmed.len == 0) continue;

		if (std.mem.startsWith(u8, trimmed, "@doc")) {
			if (doc_comment) |value| {
				allocator.free(value);
				doc_comment = null;
			}
			const parsed = try parseDocString(allocator, trimmed, &lines, &line_no);
			doc_comment = parsed;
			continue;
		}

		if (isDefLine(trimmed)) {
			const name = extractName(trimmed) orelse continue;
			const signature = try allocator.dupe(u8, extractSignature(trimmed));
			const start_line = line_no;
			const end_line = try findEndLine(trimmed, &lines, &line_no);

			const symbol = model.Symbol{
				.language = try allocator.dupe(u8, "elixir"),
				.file_path = try allocator.dupe(u8, file_path),
				.name = try allocator.dupe(u8, name),
				.signature = signature,
				.doc_comment = doc_comment,
				.start_line = start_line,
				.end_line = end_line,
			};
			doc_comment = null;
			try results.append(allocator, symbol);
		}
	}

	return results.toOwnedSlice(allocator);
}

fn isDefLine(line: []const u8) bool {
	return std.mem.startsWith(u8, line, "def ") or std.mem.startsWith(u8, line, "defp ");
}

fn extractName(line: []const u8) ?[]const u8 {
	const start: usize = if (std.mem.startsWith(u8, line, "defp ")) 5 else 4;
	if (line.len <= start) return null;
	const rest = line[start..];
	const end_idx = std.mem.indexOfAny(u8, rest, "( \t,") orelse rest.len;
	if (end_idx == 0) return null;
	return rest[0..end_idx];
}

fn extractSignature(line: []const u8) []const u8 {
	const idx = std.mem.indexOf(u8, line, " do") orelse std.mem.indexOf(u8, line, " do:");
	if (idx) |pos| {
		return std.mem.trimRight(u8, line[0..pos], " \t\r");
	}
	return std.mem.trimRight(u8, line, " \t\r");
}

fn findEndLine(
	first_line: []const u8,
	lines: *std.mem.SplitIterator(u8, .scalar),
	line_no: *usize,
) !usize {
	var depth: isize = countWord(first_line, "do") - countWord(first_line, "end");
	if (depth <= 0) return line_no.*;

	while (lines.next()) |line| {
		line_no.* += 1;
		depth += countWord(line, "do") - countWord(line, "end");
		if (depth <= 0) return line_no.*;
	}

	return line_no.*;
}

fn countWord(line: []const u8, word: []const u8) isize {
	var count: isize = 0;
	var idx: usize = 0;
	while (idx < line.len) {
		const found = std.mem.indexOfPos(u8, line, idx, word) orelse break;
		if (isWordBoundary(line, found, word.len)) count += 1;
		idx = found + word.len;
	}
	return count;
}

fn isWordBoundary(line: []const u8, start: usize, len: usize) bool {
	const before_ok = start == 0 or !isIdentChar(line[start - 1]);
	const after_idx = start + len;
	const after_ok = after_idx >= line.len or !isIdentChar(line[after_idx]);
	return before_ok and after_ok;
}

fn isIdentChar(ch: u8) bool {
	return std.ascii.isAlphabetic(ch) or std.ascii.isDigit(ch) or ch == '_';
}

fn parseDocString(
	allocator: std.mem.Allocator,
	line: []const u8,
	lines: *std.mem.SplitIterator(u8, .scalar),
	line_no: *usize,
) !?[]const u8 {
	if (std.mem.indexOf(u8, line, "\"\"") != null) {
		return parseDocHeredoc(allocator, line, lines, line_no);
	}
	return parseDocSingleLine(allocator, line);
}

fn parseDocSingleLine(allocator: std.mem.Allocator, line: []const u8) !?[]const u8 {
	const first = std.mem.indexOfScalar(u8, line, '"') orelse return null;
	const rest = line[first + 1 ..];
	const last = std.mem.lastIndexOfScalar(u8, rest, '"') orelse return null;
	const owned = try allocator.dupe(u8, rest[0..last]);
	return @as(?[]const u8, owned);
}

fn parseDocHeredoc(
	allocator: std.mem.Allocator,
	line: []const u8,
	lines: *std.mem.SplitIterator(u8, .scalar),
	line_no: *usize,
) !?[]const u8 {
	const start_idx = std.mem.indexOf(u8, line, "\"\"") orelse return null;
	var content = std.ArrayListUnmanaged([]const u8){};
	defer content.deinit(allocator);

	const after = line[start_idx + 3 ..];
	if (std.mem.indexOf(u8, after, "\"\"") ) |end_idx| {
		try content.append(allocator, after[0..end_idx]);
		const joined = try joinLines(allocator, content.items);
		return @as(?[]const u8, joined);
	}
	try content.append(allocator, after);

	while (lines.next()) |next_line| {
		line_no.* += 1;
		if (std.mem.indexOf(u8, next_line, "\"\"") ) |end_idx| {
			try content.append(allocator, next_line[0..end_idx]);
			break;
		}
		try content.append(allocator, next_line);
	}

	const joined = try joinLines(allocator, content.items);
	return @as(?[]const u8, joined);
}

fn joinLines(allocator: std.mem.Allocator, lines: []const []const u8) ![]const u8 {
	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	for (lines, 0..) |line, idx| {
		if (idx != 0) try out.writer.writeAll("\n");
		try out.writer.writeAll(std.mem.trimRight(u8, line, "\r"));
	}

	return out.toOwnedSlice();
}

test "extract finds elixir defs" {
	const allocator = std.testing.allocator;
	const source =
		"defmodule Demo do\n" ++
		"  @doc \"adds\"\n" ++
		"  def add(a, b) do\n" ++
		"    a + b\n" ++
		"  end\n" ++
		"\n" ++
		"  defp hidden(), do: :ok\n" ++
		"end\n";

	const symbols = try extract(allocator, "lib/demo.ex", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expectEqual(@as(usize, 2), symbols.len);
	try std.testing.expectEqualStrings("add", symbols[0].name);
	try std.testing.expectEqualStrings("adds", symbols[0].doc_comment.?);
	try std.testing.expectEqual(@as(usize, 3), symbols[0].start_line);
	try std.testing.expectEqual(@as(usize, 5), symbols[0].end_line);
}
