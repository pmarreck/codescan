const std = @import("std");
const model = @import("model.zig");
const util = @import("extract_util.zig");

const ts = @cImport({
	@cInclude("tree_sitter/api.h");
});
extern fn tree_sitter_c() *ts.TSLanguage;

pub fn extract(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	source: []const u8,
) ![]model.Symbol {
	const parser = ts.ts_parser_new() orelse return error.ParseFailed;
	defer ts.ts_parser_delete(parser);

	if (!ts.ts_parser_set_language(parser, tree_sitter_c())) {
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
		if (isFunctionDefinition(node)) {
			if (try extractFunction(allocator, file_path, source, lines.items, node)) |symbol| {
				try results.append(allocator, symbol);
			}
		} else if (isStructOrEnumDecl(node)) {
			if (try extractTypeDecl(allocator, file_path, source, lines.items, node)) |symbol| {
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

fn extractFunction(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	source: []const u8,
	lines: []const []const u8,
	node: ts.TSNode,
) !?model.Symbol {
	const name_node = findIdentifierInDeclarator(node) orelse return null;
	const name = nodeText(source, name_node);
	if (name.len == 0) return null;

	const signature = try extractSignature(allocator, source, node);
	const doc_comment = try extractDocComment(allocator, lines, node);

	const start_point = ts.ts_node_start_point(node);
	const end_point = ts.ts_node_end_point(node);

	const symbol = model.Symbol{
		.language = try allocator.dupe(u8, "c"),
		.file_path = try allocator.dupe(u8, file_path),
		.name = try allocator.dupe(u8, name),
		.signature = signature,
		.doc_comment = doc_comment,
		.start_line = start_point.row + 1,
		.end_line = end_point.row + 1,
	};
	return symbol;
}

fn isFunctionDefinition(node: ts.TSNode) bool {
	const ty = std.mem.span(ts.ts_node_type(node));
	return std.mem.eql(u8, ty, "function_definition");
}

fn isStructOrEnumDecl(node: ts.TSNode) bool {
	const ty = std.mem.span(ts.ts_node_type(node));
	// In C, "struct foo { ... };" parses as type_definition or declaration
	// containing a struct_specifier or enum_specifier
	return std.mem.eql(u8, ty, "type_definition") or
		std.mem.eql(u8, ty, "struct_specifier") or
		std.mem.eql(u8, ty, "enum_specifier");
}

fn extractTypeDecl(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	source: []const u8,
	lines: []const []const u8,
	node: ts.TSNode,
) !?model.Symbol {
	const ty = std.mem.span(ts.ts_node_type(node));

	// For type_definition (typedef struct { ... } Name;), get the name from the declarator
	if (std.mem.eql(u8, ty, "type_definition")) {
		const declarator = ts.ts_node_child_by_field_name(node, "declarator", "declarator".len);
		if (ts.ts_node_is_null(declarator)) return null;
		const name = nodeText(source, declarator);
		if (name.len == 0) return null;

		const signature = try extractFirstLine(allocator, source, node);
		const doc_comment = try extractDocComment(allocator, lines, node);
		const start_point = ts.ts_node_start_point(node);
		const end_point = ts.ts_node_end_point(node);

		return model.Symbol{
			.language = try allocator.dupe(u8, "c"),
			.file_path = try allocator.dupe(u8, file_path),
			.name = try allocator.dupe(u8, name),
			.signature = signature,
			.doc_comment = doc_comment,
			.start_line = start_point.row + 1,
			.end_line = end_point.row + 1,
		};
	}

	// For struct_specifier / enum_specifier (e.g., "struct Foo { ... };")
	const name_node = ts.ts_node_child_by_field_name(node, "name", "name".len);
	if (ts.ts_node_is_null(name_node)) return null;
	const name = nodeText(source, name_node);
	if (name.len == 0) return null;

	const signature = try extractFirstLine(allocator, source, node);
	const doc_comment = try extractDocComment(allocator, lines, node);
	const start_point = ts.ts_node_start_point(node);
	const end_point = ts.ts_node_end_point(node);

	return model.Symbol{
		.language = try allocator.dupe(u8, "c"),
		.file_path = try allocator.dupe(u8, file_path),
		.name = try allocator.dupe(u8, name),
		.signature = signature,
		.doc_comment = doc_comment,
		.start_line = start_point.row + 1,
		.end_line = end_point.row + 1,
	};
}

fn extractFirstLine(allocator: std.mem.Allocator, source: []const u8, node: ts.TSNode) ![]const u8 {
	const start = @as(usize, @intCast(ts.ts_node_start_byte(node)));
	if (start >= source.len) return allocator.dupe(u8, "");
	const remaining = source[start..];
	const newline_pos = std.mem.indexOfScalar(u8, remaining, '\n') orelse remaining.len;
	return allocator.dupe(u8, std.mem.trimEnd(u8, remaining[0..newline_pos], " \t\r{"));
}

fn findIdentifierInDeclarator(node: ts.TSNode) ?ts.TSNode {
	const decl = ts.ts_node_child_by_field_name(node, "declarator", "declarator".len);
	if (ts.ts_node_is_null(decl)) return null;
	return findIdentifier(decl);
}

fn findIdentifier(root: ts.TSNode) ?ts.TSNode {
	var cursor = ts.ts_tree_cursor_new(root);
	defer ts.ts_tree_cursor_delete(&cursor);

	var done = false;
	while (!done) {
		const node = ts.ts_tree_cursor_current_node(&cursor);
		const ty = std.mem.span(ts.ts_node_type(node));
		if (std.mem.eql(u8, ty, "identifier")) return node;

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
	return null;
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

fn extractDocComment(
	allocator: std.mem.Allocator,
	lines: []const []const u8,
	node: ts.TSNode,
) !?[]const u8 {
	const start_line = @as(usize, @intCast(ts.ts_node_start_point(node).row));
	if (start_line == 0 or start_line > lines.len) return null;

	var collected = @as(std.ArrayListUnmanaged([]const u8), .empty);
	defer collected.deinit(allocator);

	var idx = start_line;
	while (idx > 0) : (idx -= 1) {
		const line = lines[idx - 1];
		const trimmed = std.mem.trimStart(u8, line, " \t\r");
		if (trimmed.len == 0) break;
		if (std.mem.startsWith(u8, trimmed, "//")) {
			try collected.append(allocator, cleanLineComment(trimmed));
			continue;
		}
		if (std.mem.startsWith(u8, trimmed, "/*")) {
			try collected.append(allocator, cleanBlockCommentLine(trimmed));
			break;
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

fn cleanLineComment(line: []const u8) []const u8 {
	var trimmed = line;
	if (std.mem.startsWith(u8, trimmed, "///")) {
		trimmed = trimmed[3..];
	} else if (std.mem.startsWith(u8, trimmed, "//")) {
		trimmed = trimmed[2..];
	}
	return std.mem.trimStart(u8, trimmed, " \t");
}

fn cleanBlockCommentLine(line: []const u8) []const u8 {
	var trimmed = line;
	if (std.mem.startsWith(u8, trimmed, "/*")) trimmed = trimmed[2..];
	if (std.mem.endsWith(u8, trimmed, "*/")) trimmed = trimmed[0 .. trimmed.len - 2];
	return std.mem.trim(u8, trimmed, " \t\r");
}

fn nodeText(source: []const u8, node: ts.TSNode) []const u8 {
	const start = @as(usize, @intCast(ts.ts_node_start_byte(node)));
	const end = @as(usize, @intCast(ts.ts_node_end_byte(node)));
	if (start >= source.len or end <= start or end > source.len) return "";
	return source[start..end];
}


test "extract finds C struct declarations" {
	const allocator = std.testing.allocator;
	const source =
		"// A point in 2D space\n" ++
		"typedef struct {\n" ++
		"    int x;\n" ++
		"    int y;\n" ++
		"} Point;\n";

	const symbols = try extract(allocator, "src/geom.h", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expectEqual(@as(usize, 1), symbols.len);
	try std.testing.expectEqualStrings("Point", symbols[0].name);
	try std.testing.expectEqualStrings("A point in 2D space", symbols[0].doc_comment.?);
}

test "extract finds C enum declarations" {
	const allocator = std.testing.allocator;
	const source =
		"enum Color {\n" ++
		"    RED,\n" ++
		"    GREEN,\n" ++
		"    BLUE\n" ++
		"};\n";

	const symbols = try extract(allocator, "src/color.h", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expectEqual(@as(usize, 1), symbols.len);
	try std.testing.expectEqualStrings("Color", symbols[0].name);
}

test "extract finds c functions" {
	const allocator = std.testing.allocator;
	const source =
		"// Adds two ints\n" ++
		"int add(int a, int b) { return a + b; }\n" ++
		"\n" ++
		"static void helper(void) {}\n";

	const symbols = try extract(allocator, "src/math.c", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expectEqual(@as(usize, 2), symbols.len);
	try std.testing.expectEqualStrings("add", symbols[0].name);
	try std.testing.expectEqualStrings("Adds two ints", symbols[0].doc_comment.?);
}
