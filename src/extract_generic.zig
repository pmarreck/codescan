const std = @import("std");
const model = @import("model.zig");
const util = @import("extract_util.zig");
const ts_symbols = @import("ts_symbols.zig");

const ts = @cImport({
	@cInclude("tree_sitter/api.h");
});

// Extern tree-sitter language functions (declared here to use this file's cImport types)
extern fn tree_sitter_ruby() *ts.TSLanguage;
extern fn tree_sitter_erlang() *ts.TSLanguage;
extern fn tree_sitter_ocaml() *ts.TSLanguage;
extern fn tree_sitter_swift() *ts.TSLanguage;
extern fn tree_sitter_llvm() *ts.TSLanguage;
extern fn tree_sitter_clojure() *ts.TSLanguage;
extern fn tree_sitter_asm() *ts.TSLanguage;

fn getTsLanguage(comptime lang: ts_symbols.Language) *ts.TSLanguage {
	return switch (lang) {
		.ruby => tree_sitter_ruby(),
		.erlang => tree_sitter_erlang(),
		.ocaml => tree_sitter_ocaml(),
		.swift => tree_sitter_swift(),
		.llvm => tree_sitter_llvm(),
		.clojure => tree_sitter_clojure(),
		.assembly => tree_sitter_asm(),
		else => @compileError("unsupported language for generic extractor"),
	};
}

// ─── Public Extractors (one per language) ────────────────────────────

pub fn extractRuby(allocator: std.mem.Allocator, file_path: []const u8, source: []const u8) anyerror![]model.Symbol {
	return genericExtract(allocator, file_path, source, .ruby, "ruby", .{ .line_prefixes = &[_][]const u8{"#"} });
}

pub fn extractErlang(allocator: std.mem.Allocator, file_path: []const u8, source: []const u8) anyerror![]model.Symbol {
	return genericExtract(allocator, file_path, source, .erlang, "erlang", .{ .line_prefixes = &[_][]const u8{"%"} });
}

pub fn extractOcaml(allocator: std.mem.Allocator, file_path: []const u8, source: []const u8) anyerror![]model.Symbol {
	return genericExtract(allocator, file_path, source, .ocaml, "ocaml", .{ .line_prefixes = &[_][]const u8{}, .block_start = "(*", .block_end = "*)" });
}

pub fn extractSwift(allocator: std.mem.Allocator, file_path: []const u8, source: []const u8) anyerror![]model.Symbol {
	return genericExtract(allocator, file_path, source, .swift, "swift", .{ .line_prefixes = &[_][]const u8{ "///", "//" }, .block_start = "/*", .block_end = "*/" });
}

pub fn extractLlvm(allocator: std.mem.Allocator, file_path: []const u8, source: []const u8) anyerror![]model.Symbol {
	return genericExtract(allocator, file_path, source, .llvm, "llvm", .{ .line_prefixes = &[_][]const u8{";"} });
}

pub fn extractClojure(allocator: std.mem.Allocator, file_path: []const u8, source: []const u8) anyerror![]model.Symbol {
	return genericExtract(allocator, file_path, source, .clojure, "clojure", .{ .line_prefixes = &[_][]const u8{ ";;", ";" } });
}

pub fn extractAssembly(allocator: std.mem.Allocator, file_path: []const u8, source: []const u8) anyerror![]model.Symbol {
	return genericExtract(allocator, file_path, source, .assembly, "assembly", .{ .line_prefixes = &[_][]const u8{ ";", "#" } });
}

fn genericExtract(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	source: []const u8,
	comptime lang: ts_symbols.Language,
	comptime lang_name: []const u8,
	comptime doc_style: util.DocStyle,
) ![]model.Symbol {
	const parser = ts.ts_parser_new() orelse return error.ParseFailed;
	defer ts.ts_parser_delete(parser);

	if (!ts.ts_parser_set_language(parser, getTsLanguage(lang))) {
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

	const mappings = lang.mappings();

	var cursor = ts.ts_tree_cursor_new(ts.ts_tree_root_node(tree));
	defer ts.ts_tree_cursor_delete(&cursor);

	var done = false;
	while (!done) {
		const node = ts.ts_tree_cursor_current_node(&cursor);
		const node_type = std.mem.span(ts.ts_node_type(node));

		if (lang == .clojure) {
			if (try extractClojureSymbol(allocator, file_path, source, lines.items, node, doc_style)) |symbol| {
				try results.append(allocator, symbol);
			}
		} else if (findMapping(mappings, node_type)) |mapping| {
			if (try extractSymbol(allocator, file_path, source, lines.items, node, mapping, lang_name, doc_style)) |symbol| {
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

fn findMapping(mappings: []const ts_symbols.SymbolMapping, node_type: []const u8) ?ts_symbols.SymbolMapping {
	for (mappings) |m| {
		if (std.mem.eql(u8, m.node_type, node_type)) return m;
	}
	return null;
}

fn extractSymbol(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	source: []const u8,
	lines: []const []const u8,
	node: ts.TSNode,
	mapping: ts_symbols.SymbolMapping,
	comptime lang_name: []const u8,
	comptime doc_style: util.DocStyle,
) !?model.Symbol {
	const name = extractName(source, node, mapping.name_field) orelse return null;
	if (name.len == 0) return null;

	const signature = try extractSignature(allocator, source, node);
	const doc_comment = try util.extractDocComment(allocator, lines, @intCast(ts.ts_node_start_point(node).row), doc_style);

	const start_point = ts.ts_node_start_point(node);
	const end_point = ts.ts_node_end_point(node);

	return model.Symbol{
		.language = try allocator.dupe(u8, lang_name),
		.file_path = try allocator.dupe(u8, file_path),
		.name = try allocator.dupe(u8, name),
		.signature = signature,
		.doc_comment = doc_comment,
		.start_line = start_point.row + 1,
		.end_line = end_point.row + 1,
	};
}

// ─── Clojure Special Case ────────────────────────────────────────────

fn extractClojureSymbol(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	source: []const u8,
	lines: []const []const u8,
	node: ts.TSNode,
	comptime doc_style: util.DocStyle,
) !?model.Symbol {
	const node_type = std.mem.span(ts.ts_node_type(node));
	if (!std.mem.eql(u8, node_type, "list_lit")) return null;

	const count = ts.ts_node_child_count(node);
	var form_name: ?[]const u8 = null;
	var sym_name: ?[]const u8 = null;
	var sym_count: u32 = 0;

	var i: u32 = 0;
	while (i < count) : (i += 1) {
		const child = ts.ts_node_child(node, i);
		const child_type = std.mem.span(ts.ts_node_type(child));
		if (std.mem.eql(u8, child_type, "sym_lit")) {
			if (sym_count == 0) {
				form_name = nodeText(source, child);
			} else if (sym_count == 1) {
				sym_name = nodeText(source, child);
				break;
			}
			sym_count += 1;
		}
	}

	const form = form_name orelse return null;
	const name = sym_name orelse return null;
	if (!isClojureDefForm(form)) return null;

	const signature = try extractSignature(allocator, source, node);
	const doc_comment = try util.extractDocComment(allocator, lines, @intCast(ts.ts_node_start_point(node).row), doc_style);

	const start_point = ts.ts_node_start_point(node);
	const end_point = ts.ts_node_end_point(node);

	return model.Symbol{
		.language = try allocator.dupe(u8, "clojure"),
		.file_path = try allocator.dupe(u8, file_path),
		.name = try allocator.dupe(u8, name),
		.signature = signature,
		.doc_comment = doc_comment,
		.start_line = start_point.row + 1,
		.end_line = end_point.row + 1,
	};
}

fn isClojureDefForm(form: []const u8) bool {
	const forms = [_][]const u8{
		"defn", "defn-", "defmacro", "defmulti", "defmethod",
		"def", "defonce", "ns", "defprotocol", "defrecord", "deftype",
	};
	for (&forms) |f| {
		if (std.mem.eql(u8, form, f)) return true;
	}
	return false;
}

// ─── Name Extraction ─────────────────────────────────────────────────

fn extractName(source: []const u8, node: ts.TSNode, strategy: ts_symbols.NameField) ?[]const u8 {
	return switch (strategy) {
		.name => fieldText(source, node, "name"),
		.declarator => extractDeclaratorName(source, node),
		.attrpath => fieldText(source, node, "attrpath"),
		.first_identifier => findFirstIdentifier(source, node),
		.word => fieldText(source, node, "name") orelse fieldText(source, node, "word"),
	};
}

fn fieldText(source: []const u8, node: ts.TSNode, field: [:0]const u8) ?[]const u8 {
	const child = ts.ts_node_child_by_field_name(node, field.ptr, @intCast(field.len));
	if (ts.ts_node_is_null(child)) return null;
	return nodeText(source, child);
}

fn extractDeclaratorName(source: []const u8, node: ts.TSNode) ?[]const u8 {
	var decl = ts.ts_node_child_by_field_name(node, "declarator", "declarator".len);
	if (ts.ts_node_is_null(decl)) return null;

	var limit: usize = 10;
	while (limit > 0) : (limit -= 1) {
		const ty = std.mem.span(ts.ts_node_type(decl));
		if (std.mem.eql(u8, ty, "identifier")) return nodeText(source, decl);
		const inner = ts.ts_node_child_by_field_name(decl, "declarator", "declarator".len);
		if (ts.ts_node_is_null(inner)) {
			const count = ts.ts_node_child_count(decl);
			var i: u32 = 0;
			while (i < count) : (i += 1) {
				const child = ts.ts_node_child(decl, i);
				if (std.mem.eql(u8, std.mem.span(ts.ts_node_type(child)), "identifier"))
					return nodeText(source, child);
			}
			return nodeText(source, decl);
		}
		decl = inner;
	}
	return null;
}

fn isIdentifierLike(ty: []const u8) bool {
	const ident_types = [_][]const u8{
		"identifier",       "qualified_identifier", "double_quoted_name",
		"value_name",       "module_name",          "class_name",
		"atom",             "global_var",           "local_var",
		"ident",
	};
	for (&ident_types) |t| {
		if (std.mem.eql(u8, ty, t)) return true;
	}
	return false;
}

fn findFirstIdentifier(source: []const u8, root: ts.TSNode) ?[]const u8 {
	const count = ts.ts_node_child_count(root);
	var i: u32 = 0;
	while (i < count) : (i += 1) {
		const child = ts.ts_node_child(root, i);
		if (isIdentifierLike(std.mem.span(ts.ts_node_type(child))))
			return nodeText(source, child);
	}
	// Recurse one level deeper
	i = 0;
	while (i < count) : (i += 1) {
		const child = ts.ts_node_child(root, i);
		const gc_count = ts.ts_node_child_count(child);
		var j: u32 = 0;
		while (j < gc_count) : (j += 1) {
			const gc = ts.ts_node_child(child, j);
			if (isIdentifierLike(std.mem.span(ts.ts_node_type(gc))))
				return nodeText(source, gc);
		}
	}
	return null;
}

// ─── Signature & Text Helpers ────────────────────────────────────────

fn extractSignature(allocator: std.mem.Allocator, source: []const u8, node: ts.TSNode) ![]const u8 {
	const body = ts.ts_node_child_by_field_name(node, "body", "body".len);
	if (ts.ts_node_is_null(body)) {
		const slice = nodeText(source, node) orelse "";
		return allocator.dupe(u8, std.mem.trimEnd(u8, slice, " \t\r\n"));
	}
	const start = @as(usize, @intCast(ts.ts_node_start_byte(node)));
	const end = @as(usize, @intCast(ts.ts_node_start_byte(body)));
	if (end <= start or end > source.len) {
		const slice = nodeText(source, node) orelse "";
		return allocator.dupe(u8, std.mem.trimEnd(u8, slice, " \t\r\n"));
	}
	return allocator.dupe(u8, std.mem.trimEnd(u8, source[start..end], " \t\r\n"));
}

fn nodeText(source: []const u8, node: ts.TSNode) ?[]const u8 {
	const start = @as(usize, @intCast(ts.ts_node_start_byte(node)));
	const end = @as(usize, @intCast(ts.ts_node_end_byte(node)));
	if (start >= source.len or end <= start or end > source.len) return null;
	return source[start..end];
}

// ─── Tests ───────────────────────────────────────────────────────────

test "ruby: extracts class with methods" {
	const allocator = std.testing.allocator;
	const source =
		"# A greeter class.\n" ++
		"class Greeter\n" ++
		"  # Says hello.\n" ++
		"  def greet\n" ++
		"    puts \"hello\"\n" ++
		"  end\n" ++
		"end\n";

	const symbols = try extractRuby(allocator, "greeter.rb", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expect(symbols.len >= 2);
	try std.testing.expectEqualStrings("Greeter", symbols[0].name);
	try std.testing.expectEqualStrings("ruby", symbols[0].language);
	try std.testing.expectEqualStrings("A greeter class.", symbols[0].doc_comment.?);
	try std.testing.expectEqualStrings("greet", symbols[1].name);
	try std.testing.expectEqualStrings("Says hello.", symbols[1].doc_comment.?);
}

test "erlang: extracts functions" {
	const allocator = std.testing.allocator;
	const source =
		"% Adds two numbers.\n" ++
		"add(A, B) ->\n" ++
		"    A + B.\n";

	const symbols = try extractErlang(allocator, "math.erl", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expect(symbols.len >= 1);
	try std.testing.expectEqualStrings("add", symbols[0].name);
	try std.testing.expectEqualStrings("erlang", symbols[0].language);
	try std.testing.expectEqualStrings("Adds two numbers.", symbols[0].doc_comment.?);
}

test "ocaml: extracts let bindings and types" {
	const allocator = std.testing.allocator;
	const source =
		"(* Greets a person. *)\n" ++
		"let greet name =\n" ++
		"  print_endline (\"Hello \" ^ name)\n" ++
		"\n" ++
		"type point = { x: int; y: int }\n";

	const symbols = try extractOcaml(allocator, "main.ml", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expect(symbols.len >= 2);
	try std.testing.expectEqualStrings("greet", symbols[0].name);
	try std.testing.expectEqualStrings("ocaml", symbols[0].language);
	try std.testing.expectEqualStrings("Greets a person.", symbols[0].doc_comment.?);
	try std.testing.expectEqualStrings("point", symbols[1].name);
}

test "swift: extracts functions and classes" {
	const allocator = std.testing.allocator;
	const source =
		"// Greets someone.\n" ++
		"func greet(name: String) -> String {\n" ++
		"    return \"Hello, \" + name\n" ++
		"}\n" ++
		"\n" ++
		"class Greeter {\n" ++
		"    func sayHi() {}\n" ++
		"}\n";

	const symbols = try extractSwift(allocator, "main.swift", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expect(symbols.len >= 2);
	try std.testing.expectEqualStrings("greet", symbols[0].name);
	try std.testing.expectEqualStrings("swift", symbols[0].language);
	try std.testing.expectEqualStrings("Greets someone.", symbols[0].doc_comment.?);
	try std.testing.expectEqualStrings("Greeter", symbols[1].name);
}

test "llvm: extracts functions and globals" {
	const allocator = std.testing.allocator;
	const source =
		"; Entry point.\n" ++
		"define i32 @main() {\n" ++
		"entry:\n" ++
		"  ret i32 0\n" ++
		"}\n" ++
		"\n" ++
		"declare void @printf(ptr, ...)\n";

	const symbols = try extractLlvm(allocator, "main.ll", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expect(symbols.len >= 2);
	try std.testing.expectEqualStrings("@main", symbols[0].name);
	try std.testing.expectEqualStrings("llvm", symbols[0].language);
	try std.testing.expectEqualStrings("Entry point.", symbols[0].doc_comment.?);
	try std.testing.expectEqualStrings("@printf", symbols[1].name);
}

test "clojure: extracts defn and def" {
	const allocator = std.testing.allocator;
	const source =
		";; The main namespace.\n" ++
		"(ns myapp.core)\n" ++
		"\n" ++
		";; Greets a person.\n" ++
		"(defn greet [name]\n" ++
		"  (str \"Hello, \" name))\n";

	const symbols = try extractClojure(allocator, "core.clj", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expect(symbols.len >= 2);
	try std.testing.expectEqualStrings("myapp.core", symbols[0].name);
	try std.testing.expectEqualStrings("clojure", symbols[0].language);
	try std.testing.expectEqualStrings("The main namespace.", symbols[0].doc_comment.?);
	try std.testing.expectEqualStrings("greet", symbols[1].name);
	try std.testing.expectEqualStrings("Greets a person.", symbols[1].doc_comment.?);
}

test "assembly: extracts labels" {
	const allocator = std.testing.allocator;
	const source =
		"; Program entry.\n" ++
		"_start:\n" ++
		"  mov rax, 60\n" ++
		"  xor rdi, rdi\n" ++
		"  syscall\n";

	const symbols = try extractAssembly(allocator, "boot.s", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expect(symbols.len >= 1);
	try std.testing.expectEqualStrings("_start", symbols[0].name);
	try std.testing.expectEqualStrings("assembly", symbols[0].language);
	try std.testing.expectEqualStrings("Program entry.", symbols[0].doc_comment.?);
}
