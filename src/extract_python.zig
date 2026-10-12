const std = @import("std");
const model = @import("model.zig");
const util = @import("extract_util.zig");
const ts = @cImport({
	@cInclude("tree_sitter/api.h");
});
extern fn tree_sitter_python() *ts.TSLanguage;

/// Index Python declarations without executing source or importing its dependencies.
/// Tree-sitter supplies indentation-aware spans; AST ancestors supply name paths.
pub fn extract(allocator: std.mem.Allocator, file_path: []const u8, source: []const u8) ![]model.Symbol {
	const parser = ts.ts_parser_new() orelse return error.ParseFailed;
	defer ts.ts_parser_delete(parser);
	if (!ts.ts_parser_set_language(parser, tree_sitter_python())) return error.ParseFailed;
	const tree = ts.ts_parser_parse_string(parser, null, source.ptr, @intCast(source.len)) orelse return error.ParseFailed;
	defer ts.ts_tree_delete(tree);
	var lines = try util.splitLines(allocator, source);
	defer lines.deinit(allocator);
	var out: std.ArrayListUnmanaged(model.Symbol) = .empty;
	errdefer {
		for (out.items) |*item| item.deinit(allocator);
		out.deinit(allocator);
	}
	var cursor = ts.ts_tree_cursor_new(ts.ts_tree_root_node(tree));
	defer ts.ts_tree_cursor_delete(&cursor);
	while (true) {
		const node = ts.ts_tree_cursor_current_node(&cursor);
		if (isDefinition(node)) {
			var item = try makeSymbol(allocator, file_path, source, lines.items, node);
			out.append(allocator, item) catch |err| {
				item.deinit(allocator);
				return err;
			};
		}
		if (ts.ts_tree_cursor_goto_first_child(&cursor)) continue;
		if (ts.ts_tree_cursor_goto_next_sibling(&cursor)) continue;
		while (true) {
			if (!ts.ts_tree_cursor_goto_parent(&cursor)) return out.toOwnedSlice(allocator);
			if (ts.ts_tree_cursor_goto_next_sibling(&cursor)) break;
		}
	}
}

fn hasType(node: ts.TSNode, expected: []const u8) bool {
	return !ts.ts_node_is_null(node) and std.mem.eql(u8, std.mem.span(ts.ts_node_type(node)), expected);
}

fn isDefinition(node: ts.TSNode) bool {
	return hasType(node, "function_definition") or hasType(node, "class_definition");
}

fn text(source: []const u8, node: ts.TSNode) []const u8 {
	return source[ts.ts_node_start_byte(node)..ts.ts_node_end_byte(node)];
}

fn field(node: ts.TSNode, name: [:0]const u8) ts.TSNode {
	return ts.ts_node_child_by_field_name(node, name, @intCast(name.len));
}

/// Keep index metadata aligned with editable definitions: ancestors name the
/// scope, the declaration supplies its signature, and decorators extend its span.
fn makeSymbol(allocator: std.mem.Allocator, file_path: []const u8, source: []const u8, lines: []const []const u8, node: ts.TSNode) !model.Symbol {
	const parent = ts.ts_node_parent(node);
	const span = if (hasType(parent, "decorated_definition")) parent else node;
	var names: std.ArrayListUnmanaged([]const u8) = .empty;
	defer names.deinit(allocator);
	var ancestor = node;
	var scope: []const u8 = "top_level";
	while (!ts.ts_node_is_null(ancestor)) : (ancestor = ts.ts_node_parent(ancestor)) {
		if (!isDefinition(ancestor)) continue;
		if (names.items.len == 1) scope = if (hasType(ancestor, "class_definition"))
			(if (hasType(node, "function_definition")) "method" else "member")
		else "local";
		try names.insert(allocator, 0, text(source, field(ancestor, "name")));
	}
	var signature_end = ts.ts_node_end_byte(node);
	for (0..ts.ts_node_child_count(node)) |i| {
		const child = ts.ts_node_child(node, @intCast(i));
		if (hasType(child, ":")) {
			signature_end = ts.ts_node_end_byte(child);
			break;
		}
	}
	const language = try allocator.dupe(u8, "python");
	errdefer allocator.free(language);
	const path = try allocator.dupe(u8, file_path);
	errdefer allocator.free(path);
	const name = try std.mem.join(allocator, "/", names.items);
	errdefer allocator.free(name);
	const signature = try allocator.dupe(u8, source[ts.ts_node_start_byte(node)..signature_end]);
	errdefer allocator.free(signature);
	const doc = try docstring(allocator, source, field(node, "body")) orelse
		try util.extractDocComment(allocator, lines, ts.ts_node_start_point(span).row, .{ .line_prefixes = &.{"#"} });
	errdefer if (doc) |value| allocator.free(value);
	const kind = try allocator.dupe(u8, if (hasType(node, "class_definition")) "class" else "fn");
	errdefer allocator.free(kind);
	const owned_scope = try allocator.dupe(u8, scope);
	return .{
		.language = language, .file_path = path, .name = name,
		.signature = signature, .doc_comment = doc, .symbol_kind = kind,
		.symbol_scope = owned_scope,
		.symbol_arity = parameterCount(node),
		.start_line = ts.ts_node_start_point(span).row + 1,
		.end_line = ts.ts_node_end_point(span).row + 1,
	};
}

fn parameterCount(node: ts.TSNode) ?i32 {
	if (!hasType(node, "function_definition")) return null;
	const parameters = field(node, "parameters");
	var count: i32 = 0;
	for (0..ts.ts_node_named_child_count(parameters)) |i| {
		const child = ts.ts_node_named_child(parameters, @intCast(i));
		if (!hasType(child, "keyword_separator") and !hasType(child, "positional_separator") and !hasType(child, "comment")) count += 1;
	}
	return count;
}

/// A docstring is the first statement's plain string literal, with comments skipped.
/// Reject bytes and interpolation, and retain relative indentation after dedenting.
fn docstring(allocator: std.mem.Allocator, source: []const u8, body: ts.TSNode) !?[]const u8 {
	for (0..ts.ts_node_named_child_count(body)) |i| {
		const statement = ts.ts_node_named_child(body, @intCast(i));
		if (hasType(statement, "comment")) continue;
		if (!hasType(statement, "expression_statement") or ts.ts_node_named_child_count(statement) != 1) return null;
		const string = ts.ts_node_named_child(statement, 0);
		if (!hasType(string, "string")) return null;
		const literal = text(source, string);
		const quote = std.mem.indexOfAny(u8, literal, "'\"") orelse return null;
		for (literal[0..quote]) |byte| if (std.ascii.toLower(byte) == 'b' or std.ascii.toLower(byte) == 'f') return null;
		const quote_len: usize = if (literal.len >= quote + 6 and literal[quote] == literal[quote + 1] and literal[quote] == literal[quote + 2]) 3 else 1;
		return try cleanDocstring(allocator, literal[quote + quote_len .. literal.len - quote_len]);
	}
	return null;
}

/// Preserve examples in searchable documentation by expanding tabs and removing
/// the common indentation of nonblank lines after the summary line.
fn cleanDocstring(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
	var expanded: std.ArrayListUnmanaged(u8) = .empty;
	defer expanded.deinit(allocator);
	const tab_width = 8;
	var column: usize = 0;
	for (raw) |byte| {
		if (byte == '\t') {
			const count = tab_width - column % tab_width;
			try expanded.appendNTimes(allocator, ' ', count);
			column += count;
		} else {
			try expanded.append(allocator, byte);
			column = if (byte == '\n' or byte == '\r') 0 else column + 1;
		}
	}
	var lines = try util.splitLines(allocator, expanded.items);
	defer lines.deinit(allocator);
	var indent: usize = std.math.maxInt(usize);
	for (lines.items[1..]) |line| {
		const trimmed = std.mem.trim(u8, line, " \t\r");
		if (trimmed.len != 0) indent = @min(indent, line.len - std.mem.trimStart(u8, line, " \t").len);
	}
	var out: std.ArrayListUnmanaged(u8) = .empty;
	defer out.deinit(allocator);
	for (lines.items, 0..) |line, i| {
		if (i != 0) try out.append(allocator, '\n');
		const normalized = if (i == 0) std.mem.trimStart(u8, line, " \t") else line[@min(indent, line.len)..];
		try out.appendSlice(allocator, std.mem.trimEnd(u8, normalized, " \t\r"));
	}
	return allocator.dupe(u8, std.mem.trim(u8, out.items, "\n"));
}

fn freeSymbols(allocator: std.mem.Allocator, items: []model.Symbol) void {
	for (items) |*item| item.deinit(allocator);
	allocator.free(items);
}

test "Python indexes decorated classes, async methods, nested definitions, and docstrings" {
	const source =
		"# A fallback comment\n" ++
		"@registry.register(\n    name='café',\n)\n" ++
		"class Café(Base):\n" ++
		"    \"\"\"A café client.\n\n    Fetches cached responses.\n    \"\"\"\n" ++
		"    @staticmethod\n" ++
		"    async def fetch(\n        url: str,\n        *, limit: int = 2,\n    ) -> bytes:\n" ++
		"        \"\"\"Fetch a response.\"\"\"\n" ++
		"        def decode(data):\n" ++
		"            return data\n" ++
		"        return decode(await read(url))\n" ++
		"\n" ++
		"def adjacent(): return 42\n";
	const allocator = std.testing.allocator;
	const found = try extract(allocator, "path with spaces/client.py", source);
	defer freeSymbols(allocator, found);
	try std.testing.expectEqual(@as(usize, 4), found.len);
	const names = [_][]const u8{ "Café", "Café/fetch", "Café/fetch/decode", "adjacent" };
	for (found, names) |sym, name| {
		try std.testing.expectEqualStrings(name, sym.name);
		try std.testing.expectEqualStrings("python", sym.language);
	}
	try std.testing.expectEqualStrings("class", found[0].symbol_kind.?);
	try std.testing.expectEqualStrings("class Café(Base):", found[0].signature);
	try std.testing.expectEqualStrings("A café client.\n\nFetches cached responses.", found[0].doc_comment.?);
	try std.testing.expectEqual(@as(usize, 2), found[0].start_line);
	try std.testing.expectEqual(@as(usize, 18), found[0].end_line);
	try std.testing.expectEqualStrings("fn", found[1].symbol_kind.?);
	try std.testing.expectEqualStrings("method", found[1].symbol_scope.?);
	try std.testing.expectEqualStrings("local", found[2].symbol_scope.?);
	try std.testing.expectEqual(@as(?i32, 2), found[1].symbol_arity);
	try std.testing.expectEqualStrings("async def fetch(\n        url: str,\n        *, limit: int = 2,\n    ) -> bytes:", found[1].signature);
	try std.testing.expectEqualStrings("Fetch a response.", found[1].doc_comment.?);
	try std.testing.expectEqual(@as(usize, 10), found[1].start_line);
	try std.testing.expectEqual(@as(usize, 18), found[1].end_line);
	try std.testing.expectEqualStrings("def adjacent():", found[3].signature);
	try std.testing.expectEqual(@as(?i32, 0), found[3].symbol_arity);
}

test "Python ignores fake declarations and distinguishes docstrings from expressions" {
	const source =
		"# def fake(): pass\n" ++
		"def real():\n" ++
		"    # before documentation\n" ++
		"    r'''A raw docstring.'''\n" ++
		"    text = \"\"\"\ndef counterfeit(): pass\n\"\"\"\n" ++
		"    return text\n" ++
		"\n" ++
		"# Fallback documentation\n" ++
		"def undocumented():\n" ++
		"    f'not a docstring'\n" ++
		"    'not the first expression'\n" ++
		"    pass\n";
	const allocator = std.testing.allocator;
	const found = try extract(allocator, "strings.py", source);
	defer freeSymbols(allocator, found);
	try std.testing.expectEqual(@as(usize, 2), found.len);
	try std.testing.expectEqualStrings("real", found[0].name);
	try std.testing.expectEqualStrings("A raw docstring.", found[0].doc_comment.?);
	try std.testing.expectEqualStrings("Fallback documentation", found[1].doc_comment.?);
}

test "Python accepts stub overloads, CRLF, and empty input" {
	const allocator = std.testing.allocator;
	const source = "@overload\r\ndef parse(value: str) -> int: ...\r\n@overload\r\ndef parse(value: bytes) -> int: ...\r\n";
	const found = try extract(allocator, "api.pyi", source);
	defer freeSymbols(allocator, found);
	try std.testing.expectEqual(@as(usize, 2), found.len);
	try std.testing.expectEqualStrings("def parse(value: str) -> int:", found[0].signature);
	try std.testing.expectEqual(@as(usize, 1), found[0].start_line);
	try std.testing.expectEqual(@as(usize, 2), found[0].end_line);
	const empty = try extract(allocator, "empty.py", "");
	defer freeSymbols(allocator, empty);
	try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "Python docstring cleanup preserves indentation, expands tabs, and handles empty strings" {
	const allocator = std.testing.allocator;
	const found = try extract(allocator, "docs.py",
		"def example():\n    \"\"\"Example.\n\tDetails:\n\t\treturn café\n\t\"\"\"\n" ++
		"def empty():\n    ''\n");
	defer freeSymbols(allocator, found);
	try std.testing.expectEqual(@as(usize, 2), found.len);
	try std.testing.expectEqualStrings("Example.\nDetails:\n        return café", found[0].doc_comment.?);
	try std.testing.expectEqualStrings("", found[1].doc_comment.?);
}

test "Python preserves complete definitions while a later declaration is being edited" {
	const allocator = std.testing.allocator;
	const incomplete = [_][]const u8{
		"def unfinished():\n    \"\n",
		"def unfinished():\n    \"\"\"unfinished\n",
		"@decorator(\n",
		"def unfinished(\n",
	};
	for (incomplete) |suffix| {
		const source = try std.mem.concat(allocator, u8, &.{ "def intact(): pass\n\n", suffix });
		defer allocator.free(source);
		const found = try extract(allocator, "editing.py", source);
		defer freeSymbols(allocator, found);
		try std.testing.expect(found.len >= 1);
		try std.testing.expectEqualStrings("intact", found[0].name);
	}
}
