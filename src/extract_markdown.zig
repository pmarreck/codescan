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

	var section_start: usize = 0;
	var section_heading: ?[]const u8 = null;
	var section_lines = @as(std.ArrayListUnmanaged([]const u8), .empty);
	defer section_lines.deinit(allocator);

	for (lines.items, 0..) |line, idx| {
		if (isHeading(line)) {
			if (section_lines.items.len > 0) {
				try emitSection(allocator, file_path, section_heading, section_start, section_lines.items, &symbols);
				section_lines.clearRetainingCapacity();
			}
			section_heading = headingText(line);
			section_start = idx;
		}
		try section_lines.append(allocator, line);
	}

	if (section_lines.items.len > 0) {
		try emitSection(allocator, file_path, section_heading, section_start, section_lines.items, &symbols);
	}

	return symbols.toOwnedSlice(allocator);
}

fn emitSection(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	heading: ?[]const u8,
	start_idx: usize,
	lines: []const []const u8,
	out: *std.ArrayListUnmanaged(model.Symbol),
) !void {
	const trimmed_len = trimTrailingBlank(lines);
	if (trimmed_len == 0) return;
	const trimmed_lines = lines[0..trimmed_len];

	const name = if (heading) |value|
		try allocator.dupe(u8, std.mem.trim(u8, value, " \t\r"))
	else
		try allocator.dupe(u8, std.fs.path.basename(file_path));

	const full = try joinLines(allocator, trimmed_lines);
	const preview = firstNonEmptyContentLine(trimmed_lines) orelse trimmed_lines[0];
	const signature = try allocator.dupe(u8, std.mem.trim(u8, preview, " \t\r"));

	const symbol = model.Symbol{
		.language = try allocator.dupe(u8, "markdown"),
		.file_path = try allocator.dupe(u8, file_path),
		.name = name,
		.signature = signature,
		.doc_comment = full,
		.start_line = start_idx + 1,
		.end_line = start_idx + trimmed_len,
	};

	try out.append(allocator, symbol);
}

fn isHeading(line: []const u8) bool {
	var idx: usize = 0;
	while (idx < line.len and line[idx] == '#') : (idx += 1) {}
	if (idx == 0) return false;
	if (idx >= line.len) return false;
	return line[idx] == ' ' or line[idx] == '\t';
}

fn headingText(line: []const u8) []const u8 {
	var idx: usize = 0;
	while (idx < line.len and line[idx] == '#') : (idx += 1) {}
	if (idx < line.len and (line[idx] == ' ' or line[idx] == '\t')) idx += 1;
	return std.mem.trim(u8, line[idx..], " \t\r");
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

fn firstNonEmptyContentLine(lines: []const []const u8) ?[]const u8 {
	if (lines.len == 0) return null;
	var start: usize = 0;
	if (isHeading(lines[0])) start = 1;
	for (lines[start..]) |line| {
		const trimmed = std.mem.trim(u8, line, " \t\r");
		if (trimmed.len > 0) return trimmed;
	}
	return null;
}

fn trimTrailingBlank(lines: []const []const u8) usize {
	var len = lines.len;
	while (len > 0) : (len -= 1) {
		if (!isBlank(lines[len - 1])) break;
	}
	return len;
}

fn isBlank(line: []const u8) bool {
	return std.mem.trim(u8, line, " \t\r").len == 0;
}

test "extract splits markdown by heading" {
	const allocator = std.testing.allocator;
	const source =
		"# Title\n" ++
		"Intro line.\n" ++
		"\n" ++
		"## Sub\n" ++
		"Detail.\n";

	const symbols = try extract(allocator, "README.md", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expectEqual(@as(usize, 2), symbols.len);
	try std.testing.expectEqualStrings("Title", symbols[0].name);
	try std.testing.expectEqualStrings("Intro line.", symbols[0].signature);
	try std.testing.expectEqual(@as(usize, 1), symbols[0].start_line);
	try std.testing.expectEqual(@as(usize, 2), symbols[0].end_line);
	try std.testing.expectEqualStrings("Sub", symbols[1].name);
	try std.testing.expectEqualStrings("Detail.", symbols[1].signature);
	try std.testing.expectEqual(@as(usize, 4), symbols[1].start_line);
	try std.testing.expectEqual(@as(usize, 5), symbols[1].end_line);
}

test "extract uses file basename when no heading" {
	const allocator = std.testing.allocator;
	const source = "plain text\nsecond line\n";

	const symbols = try extract(allocator, "docs/notes.md", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expectEqual(@as(usize, 1), symbols.len);
	try std.testing.expectEqualStrings("notes.md", symbols[0].name);
}
