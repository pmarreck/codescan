const std = @import("std");
const model = @import("model.zig");
const util = @import("extract_util.zig");

const ts = @cImport({
	@cInclude("tree_sitter/api.h");
});
extern fn tree_sitter_go() *ts.TSLanguage;

pub fn extract(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	source: []const u8,
) ![]model.Symbol {
	const parser = ts.ts_parser_new() orelse return error.ParseFailed;
	defer ts.ts_parser_delete(parser);

	if (!ts.ts_parser_set_language(parser, tree_sitter_go())) {
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
		if (isFunctionDecl(node) or isMethodDecl(node)) {
			if (try extractFunction(allocator, file_path, source, lines.items, node)) |symbol| {
				try results.append(allocator, symbol);
			}
		} else if (isTypeSpec(node)) {
			if (try extractTypeSpec(allocator, file_path, source, lines.items, node)) |symbol| {
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

fn isFunctionDecl(node: ts.TSNode) bool {
	const ty = std.mem.span(ts.ts_node_type(node));
	return std.mem.eql(u8, ty, "function_declaration");
}

fn isMethodDecl(node: ts.TSNode) bool {
	const ty = std.mem.span(ts.ts_node_type(node));
	return std.mem.eql(u8, ty, "method_declaration");
}

fn isTypeSpec(node: ts.TSNode) bool {
	const ty = std.mem.span(ts.ts_node_type(node));
	return std.mem.eql(u8, ty, "type_spec");
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
		.line_prefixes = &[_][]const u8{ "//", "///" },
		.block_start = "/*",
		.block_end = "*/",
	});

	const start_point = ts.ts_node_start_point(node);
	const end_point = ts.ts_node_end_point(node);

	return model.Symbol{
		.language = try allocator.dupe(u8, "go"),
		.file_path = try allocator.dupe(u8, file_path),
		.name = try allocator.dupe(u8, name),
		.signature = signature,
		.doc_comment = doc_comment,
		.start_line = start_point.row + 1,
		.end_line = end_point.row + 1,
	};
}

fn extractTypeSpec(
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

	// For type specs, use the full text up to the body (if any) as signature
	const signature = try extractSignature(allocator, source, node);

	// type_spec is nested inside type_declaration; look for comments above the type_declaration
	const parent = ts.ts_node_parent(node);
	const comment_line = if (!ts.ts_node_is_null(parent) and
		std.mem.eql(u8, std.mem.span(ts.ts_node_type(parent)), "type_declaration"))
		@as(usize, @intCast(ts.ts_node_start_point(parent).row))
	else
		@as(usize, @intCast(ts.ts_node_start_point(node).row));

	const doc_comment = try util.extractDocComment(allocator, lines, comment_line, .{
		.line_prefixes = &[_][]const u8{ "//", "///" },
		.block_start = "/*",
		.block_end = "*/",
	});

	// Use the type_declaration span if available (includes the `type` keyword)
	const start_point = if (!ts.ts_node_is_null(parent) and
		std.mem.eql(u8, std.mem.span(ts.ts_node_type(parent)), "type_declaration"))
		ts.ts_node_start_point(parent)
	else
		ts.ts_node_start_point(node);
	const end_point = if (!ts.ts_node_is_null(parent) and
		std.mem.eql(u8, std.mem.span(ts.ts_node_type(parent)), "type_declaration"))
		ts.ts_node_end_point(parent)
	else
		ts.ts_node_end_point(node);

	return model.Symbol{
		.language = try allocator.dupe(u8, "go"),
		.file_path = try allocator.dupe(u8, file_path),
		.name = try allocator.dupe(u8, name),
		.signature = signature,
		.doc_comment = doc_comment,
		.start_line = start_point.row + 1,
		.end_line = end_point.row + 1,
	};
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

test "extract finds go functions" {
	const allocator = std.testing.allocator;
	const source =
		"// Add adds two integers.\n" ++
		"func Add(a, b int) int {\n" ++
		"    return a + b\n" ++
		"}\n";

	const symbols = try extract(allocator, "main.go", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expectEqual(@as(usize, 1), symbols.len);
	try std.testing.expectEqualStrings("Add", symbols[0].name);
	try std.testing.expectEqualStrings("go", symbols[0].language);
	try std.testing.expectEqualStrings("Add adds two integers.", symbols[0].doc_comment.?);
}

test "extract finds go methods" {
	const allocator = std.testing.allocator;
	const source =
		"package main\n" ++
		"\n" ++
		"// String returns the string representation.\n" ++
		"func (p Point) String() string {\n" ++
		"    return fmt.Sprintf(\"(%d, %d)\", p.X, p.Y)\n" ++
		"}\n";

	const symbols = try extract(allocator, "point.go", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expectEqual(@as(usize, 1), symbols.len);
	try std.testing.expectEqualStrings("String", symbols[0].name);
	try std.testing.expectEqualStrings("String returns the string representation.", symbols[0].doc_comment.?);
}

test "extract finds go type declarations" {
	const allocator = std.testing.allocator;
	const source =
		"package main\n" ++
		"\n" ++
		"// Point represents a 2D point.\n" ++
		"type Point struct {\n" ++
		"    X int\n" ++
		"    Y int\n" ++
		"}\n" ++
		"\n" ++
		"// Handler is a function type.\n" ++
		"type Handler func(w http.ResponseWriter, r *http.Request)\n";

	const symbols = try extract(allocator, "types.go", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expectEqual(@as(usize, 2), symbols.len);
	try std.testing.expectEqualStrings("Point", symbols[0].name);
	try std.testing.expectEqualStrings("Point represents a 2D point.", symbols[0].doc_comment.?);
	try std.testing.expectEqualStrings("Handler", symbols[1].name);
	try std.testing.expectEqualStrings("Handler is a function type.", symbols[1].doc_comment.?);
}

test "extract finds go interfaces" {
	const allocator = std.testing.allocator;
	const source =
		"package io\n" ++
		"\n" ++
		"// Reader is the interface that wraps the Read method.\n" ++
		"type Reader interface {\n" ++
		"    Read(p []byte) (n int, err error)\n" ++
		"}\n";

	const symbols = try extract(allocator, "io.go", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expectEqual(@as(usize, 1), symbols.len);
	try std.testing.expectEqualStrings("Reader", symbols[0].name);
	try std.testing.expectEqualStrings("Reader is the interface that wraps the Read method.", symbols[0].doc_comment.?);
}
