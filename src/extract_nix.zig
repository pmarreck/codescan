const std = @import("std");
const model = @import("model.zig");
const util = @import("extract_util.zig");

const ts = @cImport({
	@cInclude("tree_sitter/api.h");
});
extern fn tree_sitter_nix() *ts.TSLanguage;

pub fn extract(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	source: []const u8,
) ![]model.Symbol {
	const parser = ts.ts_parser_new() orelse return error.ParseFailed;
	defer ts.ts_parser_delete(parser);

	if (!ts.ts_parser_set_language(parser, tree_sitter_nix())) {
		return error.ParseFailed;
	}

	const tree = ts.ts_parser_parse_string(
		parser,
		null,
		source.ptr,
		@intCast(source.len),
	) orelse return error.ParseFailed;
	defer ts.ts_tree_delete(tree);

	var results = std.ArrayListUnmanaged(model.Symbol){};
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
		if (isBinding(node)) {
			if (try extractBinding(allocator, file_path, source, lines.items, node)) |symbol| {
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

fn isBinding(node: ts.TSNode) bool {
	const ty = std.mem.span(ts.ts_node_type(node));
	return std.mem.eql(u8, ty, "binding");
}

fn extractBinding(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	source: []const u8,
	lines: []const []const u8,
	node: ts.TSNode,
) !?model.Symbol {
	const expr = ts.ts_node_child_by_field_name(node, "expression", "expression".len);
	if (ts.ts_node_is_null(expr)) return null;
	if (!isFunctionExpression(expr)) return null;

	const name_node = ts.ts_node_child_by_field_name(node, "attrpath", "attrpath".len);
	if (ts.ts_node_is_null(name_node)) return null;
	const name = nodeText(source, name_node);
	if (name.len == 0) return null;

	const signature = try extractSignature(allocator, source, name, expr);
	const doc_comment = try util.extractDocComment(allocator, lines, @intCast(ts.ts_node_start_point(node).row), .{
		.line_prefixes = &[_][]const u8{ "#" },
		.block_start = "/*",
		.block_end = "*/",
	});

	const start_point = ts.ts_node_start_point(node);
	const end_point = ts.ts_node_end_point(node);

	const symbol = model.Symbol{
		.language = try allocator.dupe(u8, "nix"),
		.file_path = try allocator.dupe(u8, file_path),
		.name = try allocator.dupe(u8, name),
		.signature = signature,
		.doc_comment = doc_comment,
		.start_line = start_point.row + 1,
		.end_line = end_point.row + 1,
	};
	return symbol;
}

fn isFunctionExpression(node: ts.TSNode) bool {
	const ty = std.mem.span(ts.ts_node_type(node));
	return std.mem.eql(u8, ty, "function_expression");
}

fn extractSignature(
	allocator: std.mem.Allocator,
	source: []const u8,
	name: []const u8,
	expr: ts.TSNode,
) ![]const u8 {
	const text = nodeText(source, expr);
	const trimmed = std.mem.trimRight(u8, text, " \t\r\n");
	const line_end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;
	return std.fmt.allocPrint(allocator, "{s} = {s}", .{ name, trimmed[0..line_end] });
}

fn nodeText(source: []const u8, node: ts.TSNode) []const u8 {
	const start = @as(usize, @intCast(ts.ts_node_start_byte(node)));
	const end = @as(usize, @intCast(ts.ts_node_end_byte(node)));
	if (start >= source.len or end <= start or end > source.len) return "";
	return source[start..end];
}

test "extract finds nix function bindings" {
	const allocator = std.testing.allocator;
	const source =
		"{\n" ++
		"  # adds\n" ++
		"  add = x: x + 1;\n" ++
		"}\n";

	const symbols = try extract(allocator, "default.nix", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expectEqual(@as(usize, 1), symbols.len);
	try std.testing.expectEqualStrings("add", symbols[0].name);
	try std.testing.expectEqualStrings("adds", symbols[0].doc_comment.?);
}
