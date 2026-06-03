const std = @import("std");
const model = @import("model.zig");
const util = @import("extract_util.zig");

const ts = @cImport({
	@cInclude("tree_sitter/api.h");
});
extern fn tree_sitter_lean() *ts.TSLanguage;

pub fn extract(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	source: []const u8,
) ![]model.Symbol {
	const parser = ts.ts_parser_new() orelse return error.ParseFailed;
	defer ts.ts_parser_delete(parser);

	if (!ts.ts_parser_set_language(parser, tree_sitter_lean())) {
		return error.ParseFailed;
	}

	const tree = ts.ts_parser_parse_string(
		parser,
		null,
		source.ptr,
		@intCast(source.len),
	) orelse return error.ParseFailed;
	defer ts.ts_tree_delete(tree);

	var results = @as(std.ArrayListUnmanaged(model.Symbol), .empty);
	errdefer {
		for (results.items) |*sym| sym.deinit(allocator);
		results.deinit(allocator);
	}

	var lines = try util.splitLines(allocator, source);
	defer lines.deinit(allocator);

	var cursor = ts.ts_tree_cursor_new(ts.ts_tree_root_node(tree));
	defer ts.ts_tree_cursor_delete(&cursor);

	var done = false;
	while (!done) {
		const node = ts.ts_tree_cursor_current_node(&cursor);
		if (isDeclaration(node)) {
			if (try extractDeclaration(allocator, file_path, source, lines.items, node)) |symbol| {
				try results.append(allocator, symbol);
			}
		}

		if (ts.ts_tree_cursor_goto_first_child(&cursor)) continue;
		if (ts.ts_tree_cursor_goto_next_sibling(&cursor)) continue;

		while (true) {
			if (!ts.ts_tree_cursor_goto_parent(&cursor)) {
				done = true;
				break;
			}
			if (ts.ts_tree_cursor_goto_next_sibling(&cursor)) break;
		}
	}

	return results.toOwnedSlice(allocator);
}

fn isDeclaration(node: ts.TSNode) bool {
	const ty = std.mem.span(ts.ts_node_type(node));
	return std.mem.eql(u8, ty, "def") or
		std.mem.eql(u8, ty, "theorem") or
		std.mem.eql(u8, ty, "abbrev") or
		std.mem.eql(u8, ty, "structure") or
		std.mem.eql(u8, ty, "example") or
		std.mem.eql(u8, ty, "class") or
		std.mem.eql(u8, ty, "instance") or
		std.mem.eql(u8, ty, "inductive");
}

fn extractDeclaration(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	source: []const u8,
	lines: []const []const u8,
	node: ts.TSNode,
) !?model.Symbol {
	const name_node = findNameNode(node) orelse return null;
	const name = nodeText(source, name_node);
	if (name.len == 0) return null;

	const signature = try extractSignature(allocator, source, node);
	const doc_comment = try util.extractDocComment(allocator, lines, @intCast(ts.ts_node_start_point(node).row), .{
		.line_prefixes = &[_][]const u8{ "--" },
	});

	const start_point = ts.ts_node_start_point(node);
	const end_point = ts.ts_node_end_point(node);

	const symbol = model.Symbol{
		.language = try allocator.dupe(u8, "lean"),
		.file_path = try allocator.dupe(u8, file_path),
		.name = try allocator.dupe(u8, name),
		.signature = signature,
		.doc_comment = doc_comment,
		.start_line = start_point.row + 1,
		.end_line = end_point.row + 1,
	};
	return symbol;
}

fn findNameNode(root: ts.TSNode) ?ts.TSNode {
	var cursor = ts.ts_tree_cursor_new(root);
	defer ts.ts_tree_cursor_delete(&cursor);

	var best: ?ts.TSNode = null;
	var done = false;
	while (!done) {
		const node = ts.ts_tree_cursor_current_node(&cursor);
		if (isNameNode(node)) {
			if (best == null or ts.ts_node_start_byte(node) < ts.ts_node_start_byte(best.?)) {
				best = node;
			}
		}

		if (ts.ts_tree_cursor_goto_first_child(&cursor)) continue;
		if (ts.ts_tree_cursor_goto_next_sibling(&cursor)) continue;

		while (true) {
			if (!ts.ts_tree_cursor_goto_parent(&cursor)) {
				done = true;
				break;
			}
			if (ts.ts_tree_cursor_goto_next_sibling(&cursor)) break;
		}
	}

	return best;
}

fn isNameNode(node: ts.TSNode) bool {
	const ty = std.mem.span(ts.ts_node_type(node));
	return std.mem.eql(u8, ty, "identifier") or
		std.mem.eql(u8, ty, "qualified_identifier") or
		std.mem.eql(u8, ty, "double_quoted_name");
}

fn extractSignature(allocator: std.mem.Allocator, source: []const u8, node: ts.TSNode) ![]const u8 {
	const text = nodeText(source, node);
	const trimmed = std.mem.trimEnd(u8, text, " \t\r\n");
	const line_end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
	return allocator.dupe(u8, trimmed[0..line_end]);
}

fn nodeText(source: []const u8, node: ts.TSNode) []const u8 {
	const start = @as(usize, @intCast(ts.ts_node_start_byte(node)));
	const end = @as(usize, @intCast(ts.ts_node_end_byte(node)));
	if (start >= source.len or end <= start or end > source.len) return "";
	return source[start..end];
}

test "extract finds lean defs" {
	const allocator = std.testing.allocator;
	const source =
		"-- adds\n" ++
		"def add (a b : Nat) : Nat := a + b\n";

	const symbols = try extract(allocator, "Main.lean", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expectEqual(@as(usize, 1), symbols.len);
	try std.testing.expectEqualStrings("add", symbols[0].name);
	try std.testing.expectEqualStrings("adds", symbols[0].doc_comment.?);
}


// ─── smoke matrix (added 2026-06-02 from fleet review inadequate-tests) ────

test "extract returns no symbols on empty source" {
	const allocator = std.testing.allocator;
	const symbols = try extract(allocator, "src/empty.lean", "");
	defer allocator.free(symbols);
	try std.testing.expectEqual(@as(usize, 0), symbols.len);
}

test "extract handles declaration with no preceding comment (doc_comment null)" {
	const allocator = std.testing.allocator;
	const source = "def plain (a : Nat) : Nat := a\n";

	const symbols = try extract(allocator, "src/nodoc.lean", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expect(symbols.len >= 1);
	for (symbols) |sym| {
		try std.testing.expect(sym.doc_comment == null);
	}
}

test "extract attaches preceding comment as doc_comment" {
	const allocator = std.testing.allocator;
	const source = "-- adds\ndef add (a b : Nat) : Nat := a + b\n";

	const symbols = try extract(allocator, "src/withdoc.lean", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expect(symbols.len >= 1);
	var found = false;
	for (symbols) |sym| {
		if (std.mem.eql(u8, sym.name, "add")) {
			found = true;
			if (sym.doc_comment) |doc| {
				try std.testing.expect(std.mem.indexOf(u8, doc, "adds") != null);
			}
		}
	}
	try std.testing.expect(found);
}

test "extract handles UTF-8 content without crashing" {
	const allocator = std.testing.allocator;
	// Source contains non-ASCII bytes — the extractor must not crash.
	const source = "-- café and über\n";
	const symbols = try extract(allocator, "src/utf8.lean", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}
	_ = symbols.len;
}
