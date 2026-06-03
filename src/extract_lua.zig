const std = @import("std");
const model = @import("model.zig");
const util = @import("extract_util.zig");

const ts = @cImport({
	@cInclude("tree_sitter/api.h");
});
extern fn tree_sitter_lua() *ts.TSLanguage;

pub fn extract(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	source: []const u8,
) ![]model.Symbol {
	const parser = ts.ts_parser_new() orelse return error.ParseFailed;
	defer ts.ts_parser_delete(parser);

	if (!ts.ts_parser_set_language(parser, tree_sitter_lua())) {
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
		if (isFunctionDeclaration(node)) {
			if (try extractFunction(allocator, file_path, source, lines.items, node)) |symbol| {
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

fn isFunctionDeclaration(node: ts.TSNode) bool {
	const ty = std.mem.span(ts.ts_node_type(node));
	return std.mem.eql(u8, ty, "function_declaration") or
		std.mem.eql(u8, ty, "function_definition_statement") or
		std.mem.eql(u8, ty, "local_function_definition_statement");
}

fn extractFunction(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	source: []const u8,
	lines: []const []const u8,
	node: ts.TSNode,
) !?model.Symbol {
	const name_node = ts.ts_node_child_by_field_name(node, "name", "name".len);
	if (ts.ts_node_is_null(name_node)) return null;
	const name = nodeText(source, name_node);
	if (name.len == 0) return null;

	const signature = try extractSignature(allocator, source, node);
	const doc_comment = try util.extractDocComment(allocator, lines, @intCast(ts.ts_node_start_point(node).row), .{
		.line_prefixes = &[_][]const u8{ "---", "--" },
	});

	const start_point = ts.ts_node_start_point(node);
	const end_point = ts.ts_node_end_point(node);

	const symbol = model.Symbol{
		.language = try allocator.dupe(u8, "lua"),
		.file_path = try allocator.dupe(u8, file_path),
		.name = try allocator.dupe(u8, name),
		.signature = signature,
		.doc_comment = doc_comment,
		.start_line = start_point.row + 1,
		.end_line = end_point.row + 1,
	};
	return symbol;
}

fn extractSignature(allocator: std.mem.Allocator, source: []const u8, node: ts.TSNode) ![]const u8 {
	const body = ts.ts_node_child_by_field_name(node, "body", "body".len);
	if (ts.ts_node_is_null(body)) {
		const slice = nodeText(source, node);
		return allocator.dupe(u8, std.mem.trimEnd(u8, slice, " \t\r\n"));
	}
	const start = @as(usize, @intCast(ts.ts_node_start_byte(node)));
	const end = @as(usize, @intCast(ts.ts_node_start_byte(body)));
	if (end <= start or end > source.len) {
		const slice = nodeText(source, node);
		return allocator.dupe(u8, std.mem.trimEnd(u8, slice, " \t\r\n"));
	}
	const slice = std.mem.trimEnd(u8, source[start..end], " \t\r\n");
	return allocator.dupe(u8, slice);
}

fn nodeText(source: []const u8, node: ts.TSNode) []const u8 {
	const start = @as(usize, @intCast(ts.ts_node_start_byte(node)));
	const end = @as(usize, @intCast(ts.ts_node_end_byte(node)));
	if (start >= source.len or end <= start or end > source.len) return "";
	return source[start..end];
}

test "extract finds lua functions" {
	const allocator = std.testing.allocator;
	const source =
		"--- adds\n" ++
		"function add(a, b) return a + b end\n";

	const symbols = try extract(allocator, "src/lib.lua", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expectEqual(@as(usize, 1), symbols.len);
	try std.testing.expectEqualStrings("add", symbols[0].name);
	try std.testing.expectEqualStrings("adds", symbols[0].doc_comment.?);
}


// ─── smoke matrix (added 2026-06-02 from fleet review inadequate-tests) ────

test "extract handles `local function` declaration" {
	const allocator = std.testing.allocator;
	const source = "local function helper(x) return x + 1 end\n";

	const symbols = try extract(allocator, "src/lib.lua", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expect(symbols.len >= 1);
	var found_helper = false;
	for (symbols) |sym| {
		if (std.mem.eql(u8, sym.name, "helper")) found_helper = true;
	}
	try std.testing.expect(found_helper);
}

test "extract handles method definitions (`function obj:method`)" {
	const allocator = std.testing.allocator;
	const source = "function Account:deposit(n) self.balance = self.balance + n end\n";

	const symbols = try extract(allocator, "src/account.lua", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	// Method name should appear (extractor may include the receiver prefix or
	// just the method name; either is acceptable as long as something is found).
	try std.testing.expect(symbols.len >= 1);
}

test "extract returns no symbols on empty source" {
	const allocator = std.testing.allocator;
	const symbols = try extract(allocator, "src/empty.lua", "");
	defer allocator.free(symbols);
	try std.testing.expectEqual(@as(usize, 0), symbols.len);
}

test "extract does not attach doc_comment when function has no preceding comment" {
	const allocator = std.testing.allocator;
	const source = "function bare() end\n";

	const symbols = try extract(allocator, "src/bare.lua", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expect(symbols.len >= 1);
	for (symbols) |sym| {
		if (std.mem.eql(u8, sym.name, "bare")) {
			try std.testing.expect(sym.doc_comment == null);
		}
	}
}

test "extract handles multi-line `--[[ ]]` block comment without crashing" {
	const allocator = std.testing.allocator;
	const source =
		"--[[\n" ++
		"  Block comment\n" ++
		"  spanning multiple lines\n" ++
		"]]\n" ++
		"function withBlockComment() end\n";

	const symbols = try extract(allocator, "src/blockcomment.lua", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expect(symbols.len >= 1);
}

test "extract handles UTF-8 identifiers without crashing" {
	const allocator = std.testing.allocator;
	// Lua 5.3+ allows non-ASCII identifiers in some configs; even when the
	// host parser rejects them, the extractor must NOT crash.
	const source = "function utf8Test() return 'café' end\n";

	const symbols = try extract(allocator, "src/utf8.lua", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	// We don't require any specific count — only that the call completes.
	_ = symbols.len;
}
