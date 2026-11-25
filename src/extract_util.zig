const std = @import("std");

/// C uses the same aggregate node for declarations and type references.
/// Preserve standalone forward declarations as well as definitions with bodies.
pub fn isCTypeReference(comptime ts: type, node: ts.TSNode) bool {
	const kind = std.mem.span(ts.ts_node_type(node));
	if (!std.mem.eql(u8, kind, "struct_specifier") and !std.mem.eql(u8, kind, "enum_specifier") and !std.mem.eql(u8, kind, "union_specifier")) return false;
	if (!ts.ts_node_is_null(ts.ts_node_child_by_field_name(node, "body", "body".len))) return false;
	const parent = ts.ts_node_parent(node);
	if (ts.ts_node_is_null(parent)) return true;
	const parent_kind = std.mem.span(ts.ts_node_type(parent));
	if (std.mem.eql(u8, parent_kind, "translation_unit")) return false;
	if (std.mem.eql(u8, parent_kind, "declaration") and ts.ts_node_is_null(ts.ts_node_child_by_field_name(parent, "declarator", "declarator".len))) return false;
	return true;
}

pub const DocStyle = struct {
	line_prefixes: []const []const u8,
	block_start: ?[]const u8 = null,
	block_end: ?[]const u8 = null,
};

pub fn splitLines(allocator: std.mem.Allocator, source: []const u8) !std.ArrayListUnmanaged([]const u8) {
	var lines = @as(std.ArrayListUnmanaged([]const u8), .empty);
	errdefer lines.deinit(allocator);
	var it = std.mem.splitScalar(u8, source, '\n');
	while (it.next()) |line| {
		try lines.append(allocator, line);
	}
	return lines;
}

pub fn extractDocComment(
	allocator: std.mem.Allocator,
	lines: []const []const u8,
	start_line_idx: usize,
	style: DocStyle,
) !?[]const u8 {
	if (start_line_idx == 0 or start_line_idx > lines.len) return null;

	var collected = @as(std.ArrayListUnmanaged([]const u8), .empty);
	defer collected.deinit(allocator);

	var idx = start_line_idx;
	while (idx > 0) : (idx -= 1) {
		const line = lines[idx - 1];
		const trimmed = std.mem.trimStart(u8, line, " \t\r");
		if (trimmed.len == 0) break;

		if (matchLinePrefix(trimmed, style.line_prefixes)) |prefix| {
			try collected.append(allocator, cleanLineComment(trimmed, prefix));
			continue;
		}

		if (style.block_start) |block_start| {
			if (std.mem.startsWith(u8, trimmed, block_start)) {
				const cleaned = cleanBlockCommentLine(trimmed, block_start, style.block_end);
				try collected.append(allocator, cleaned);
				break;
			}
		}

		break;
	}

	if (collected.items.len == 0) return null;

	var out: std.Io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	var i: usize = collected.items.len;
	while (i > 0) : (i -= 1) {
		if (i != collected.items.len) try out.writer.writeAll("\n");
		try out.writer.writeAll(collected.items[i - 1]);
	}

	const owned = try out.toOwnedSlice();
	return @as(?[]const u8, owned);
}

fn matchLinePrefix(line: []const u8, prefixes: []const []const u8) ?[]const u8 {
	for (prefixes) |prefix| {
		if (std.mem.startsWith(u8, line, prefix)) return prefix;
	}
	return null;
}

fn cleanLineComment(line: []const u8, prefix: []const u8) []const u8 {
	const trimmed = line[prefix.len..];
	return std.mem.trimStart(u8, trimmed, " \t");
}

fn cleanBlockCommentLine(line: []const u8, start: []const u8, end: ?[]const u8) []const u8 {
	var trimmed = line;
	if (std.mem.startsWith(u8, trimmed, start)) trimmed = trimmed[start.len..];
	if (end) |end_marker| {
		if (std.mem.endsWith(u8, trimmed, end_marker)) {
			trimmed = trimmed[0 .. trimmed.len - end_marker.len];
		}
	}
	return std.mem.trim(u8, trimmed, " \t\r");
}

test "extractDocComment collects line comments" {
	const allocator = std.testing.allocator;
	const source =
		"// one\n" ++
		"// two\n" ++
		"fn main() {}\n";
	var lines = try splitLines(allocator, source);
	defer lines.deinit(allocator);

	const doc = try extractDocComment(allocator, lines.items, 2, .{
		.line_prefixes = &[_][]const u8{ "//" },
	});
	defer if (doc) |value| allocator.free(value);

	try std.testing.expect(doc != null);
	try std.testing.expectEqualStrings("one\ntwo", doc.?);
}

test "extractDocComment handles block comment" {
	const allocator = std.testing.allocator;
	const source =
		"/** doc */\n" ++
		"fn main() {}\n";
	var lines = try splitLines(allocator, source);
	defer lines.deinit(allocator);

	const doc = try extractDocComment(allocator, lines.items, 1, .{
		.line_prefixes = &[_][]const u8{ "//" },
		.block_start = "/**",
		.block_end = "*/",
	});
	defer if (doc) |value| allocator.free(value);

	try std.testing.expect(doc != null);
	try std.testing.expectEqualStrings("doc", doc.?);
}

/// Join `lines` with `\n` separators and return owned slice, or `null` when
/// `lines` is empty. The optional return distinguishes "no input" from "empty
/// joined result" for callers that want to skip null bodies.
pub fn joinLines(allocator: std.mem.Allocator, lines: []const []const u8) !?[]const u8 {
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
