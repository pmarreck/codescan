const std = @import("std");
const model = @import("model.zig");
const util = @import("extract_util.zig");

const ts = @cImport({
	@cInclude("tree_sitter/api.h");
});
extern fn tree_sitter_rust() *ts.TSLanguage;

pub fn extract(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	source: []const u8,
) ![]model.Symbol {
	const parser = ts.ts_parser_new() orelse return error.ParseFailed;
	defer ts.ts_parser_delete(parser);

	if (!ts.ts_parser_set_language(parser, tree_sitter_rust())) {
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
		if (isFunctionItem(node)) {
			if (try extractFunction(allocator, file_path, source, lines.items, node)) |symbol| {
				try results.append(allocator, symbol);
			}
		} else if (isNamedDecl(node)) {
			if (try extractNamedDecl(allocator, file_path, source, lines.items, node)) |symbol| {
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

fn isFunctionItem(node: ts.TSNode) bool {
	const ty = std.mem.span(ts.ts_node_type(node));
	return std.mem.eql(u8, ty, "function_item");
}

fn isNamedDecl(node: ts.TSNode) bool {
	const ty = std.mem.span(ts.ts_node_type(node));
	return std.mem.eql(u8, ty, "struct_item") or
		std.mem.eql(u8, ty, "enum_item") or
		std.mem.eql(u8, ty, "trait_item") or
		std.mem.eql(u8, ty, "impl_item") or
		std.mem.eql(u8, ty, "type_item") or
		std.mem.eql(u8, ty, "const_item") or
		std.mem.eql(u8, ty, "static_item") or
		std.mem.eql(u8, ty, "mod_item");
}

fn extractNamedDecl(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	source: []const u8,
	lines: []const []const u8,
	node: ts.TSNode,
) !?model.Symbol {
	// Try "name" field first, then "type" for impl items
	var name_node = ts.ts_node_child_by_field_name(node, "name", "name".len);
	if (ts.ts_node_is_null(name_node)) {
		name_node = ts.ts_node_child_by_field_name(node, "type", "type".len);
	}
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

	return model.Symbol{
		.language = try allocator.dupe(u8, "rust"),
		.file_path = try allocator.dupe(u8, file_path),
		.name = try allocator.dupe(u8, name),
		.signature = signature,
		.doc_comment = doc_comment,
		.start_line = start_point.row + 1,
		.end_line = end_point.row + 1,
	};
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
		.language = try allocator.dupe(u8, "rust"),
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

test "extract finds rust structs and enums" {
	const allocator = std.testing.allocator;
	const source =
		"/// A color\n" ++
		"enum Color {\n" ++
		"    Red,\n" ++
		"    Green,\n" ++
		"}\n" ++
		"\n" ++
		"struct Point {\n" ++
		"    x: f64,\n" ++
		"    y: f64,\n" ++
		"}\n";

	const symbols = try extract(allocator, "src/types.rs", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expectEqual(@as(usize, 2), symbols.len);
	try std.testing.expectEqualStrings("Color", symbols[0].name);
	try std.testing.expectEqualStrings("A color", symbols[0].doc_comment.?);
	try std.testing.expectEqualStrings("Point", symbols[1].name);
}

test "extract finds rust functions" {
	const allocator = std.testing.allocator;
	const source =
		"/// adds\n" ++
		"fn add(a: i32, b: i32) -> i32 { a + b }\n";

	const symbols = try extract(allocator, "src/lib.rs", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expectEqual(@as(usize, 1), symbols.len);
	try std.testing.expectEqualStrings("add", symbols[0].name);
	try std.testing.expectEqualStrings("adds", symbols[0].doc_comment.?);
}
