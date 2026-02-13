const std = @import("std");
const model = @import("model.zig");
const util = @import("extract_util.zig");

const ts = @cImport({
	@cInclude("tree_sitter/api.h");
});
extern fn tree_sitter_typescript() *ts.TSLanguage;
extern fn tree_sitter_tsx() *ts.TSLanguage;

pub fn extract(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	source: []const u8,
) ![]model.Symbol {
	const parser = ts.ts_parser_new() orelse return error.ParseFailed;
	defer ts.ts_parser_delete(parser);

	const language = if (std.mem.endsWith(u8, file_path, ".tsx")) tree_sitter_tsx() else tree_sitter_typescript();
	if (!ts.ts_parser_set_language(parser, language)) {
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
		if (isFunctionLike(node) or isTypeLike(node)) {
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

fn isFunctionLike(node: ts.TSNode) bool {
	const ty = std.mem.span(ts.ts_node_type(node));
	return std.mem.eql(u8, ty, "function_declaration") or
		std.mem.eql(u8, ty, "generator_function_declaration") or
		std.mem.eql(u8, ty, "method_definition");
}

fn isTypeLike(node: ts.TSNode) bool {
	const ty = std.mem.span(ts.ts_node_type(node));
	return std.mem.eql(u8, ty, "class_declaration") or
		std.mem.eql(u8, ty, "interface_declaration") or
		std.mem.eql(u8, ty, "enum_declaration") or
		std.mem.eql(u8, ty, "type_alias_declaration");
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
		.line_prefixes = &[_][]const u8{ "///", "//" },
		.block_start = "/**",
		.block_end = "*/",
	});

	const start_point = ts.ts_node_start_point(node);
	const end_point = ts.ts_node_end_point(node);

	const symbol = model.Symbol{
		.language = try allocator.dupe(u8, "typescript"),
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
		return allocator.dupe(u8, std.mem.trimRight(u8, slice, " \t\r\n"));
	}
	const start = @as(usize, @intCast(ts.ts_node_start_byte(node)));
	const end = @as(usize, @intCast(ts.ts_node_start_byte(body)));
	if (end <= start or end > source.len) {
		const slice = nodeText(source, node);
		return allocator.dupe(u8, std.mem.trimRight(u8, slice, " \t\r\n"));
	}
	const slice = std.mem.trimRight(u8, source[start..end], " \t\r\n");
	return allocator.dupe(u8, slice);
}

fn nodeText(source: []const u8, node: ts.TSNode) []const u8 {
	const start = @as(usize, @intCast(ts.ts_node_start_byte(node)));
	const end = @as(usize, @intCast(ts.ts_node_end_byte(node)));
	if (start >= source.len or end <= start or end > source.len) return "";
	return source[start..end];
}

test "extract finds typescript functions" {
	const allocator = std.testing.allocator;
	const source =
		"/** adds */\n" ++
		"function add(a: number, b: number): number { return a + b; }\n" ++
		"class Box { method(x: number) { return x; } }\n";

	const symbols = try extract(allocator, "src/app.ts", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	// Now extracts function, class, and method inside class
	try std.testing.expect(symbols.len >= 2);
	try std.testing.expectEqualStrings("add", symbols[0].name);
	try std.testing.expectEqualStrings("adds", symbols[0].doc_comment.?);
}

test "extract finds typescript classes and interfaces" {
	const allocator = std.testing.allocator;
	const source =
		"interface Shape {\n" ++
		"    area(): number;\n" ++
		"}\n" ++
		"\n" ++
		"enum Direction {\n" ++
		"    Up,\n" ++
		"    Down,\n" ++
		"}\n" ++
		"\n" ++
		"type Point = { x: number; y: number };\n";

	const symbols = try extract(allocator, "src/types.ts", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expectEqual(@as(usize, 3), symbols.len);
	try std.testing.expectEqualStrings("Shape", symbols[0].name);
	try std.testing.expectEqualStrings("Direction", symbols[1].name);
	try std.testing.expectEqualStrings("Point", symbols[2].name);
}
