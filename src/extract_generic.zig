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
extern fn tree_sitter_bash() *ts.TSLanguage;
extern fn tree_sitter_fish() *ts.TSLanguage;
extern fn tree_sitter_nu() *ts.TSLanguage;
extern fn tree_sitter_powershell() *ts.TSLanguage;
extern fn tree_sitter_tcl() *ts.TSLanguage;
extern fn tree_sitter_fsharp() *ts.TSLanguage;
extern fn tree_sitter_elm() *ts.TSLanguage;
extern fn tree_sitter_gleam() *ts.TSLanguage;
extern fn tree_sitter_scheme() *ts.TSLanguage;
extern fn tree_sitter_commonlisp() *ts.TSLanguage;
extern fn tree_sitter_sml() *ts.TSLanguage;
extern fn tree_sitter_wat() *ts.TSLanguage;

fn getTsLanguage(comptime lang: ts_symbols.Language) *ts.TSLanguage {
    return switch (lang) {
        .ruby => tree_sitter_ruby(),
        .erlang => tree_sitter_erlang(),
        .ocaml => tree_sitter_ocaml(),
        .swift => tree_sitter_swift(),
        .llvm => tree_sitter_llvm(),
        .clojure => tree_sitter_clojure(),
        .assembly => tree_sitter_asm(),
        .fish => tree_sitter_fish(),
        .nushell => tree_sitter_nu(),
        .powershell => tree_sitter_powershell(),
        .tcl => tree_sitter_tcl(),
        .oil => tree_sitter_bash(),
        .fsharp => tree_sitter_fsharp(),
        .elm => tree_sitter_elm(),
        .gleam => tree_sitter_gleam(),
        .scheme, .racket => tree_sitter_scheme(),
        .common_lisp => tree_sitter_commonlisp(),
        .sml => tree_sitter_sml(),
        .wat => tree_sitter_wat(),
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

pub fn extractFish(allocator: std.mem.Allocator, file_path: []const u8, source: []const u8) anyerror![]model.Symbol {
    return genericExtract(allocator, file_path, source, .fish, "fish", .{ .line_prefixes = &[_][]const u8{"#"} });
}

pub fn extractNushell(allocator: std.mem.Allocator, file_path: []const u8, source: []const u8) anyerror![]model.Symbol {
    return genericExtract(allocator, file_path, source, .nushell, "nushell", .{ .line_prefixes = &[_][]const u8{"#"} });
}

pub fn extractPowerShell(allocator: std.mem.Allocator, file_path: []const u8, source: []const u8) anyerror![]model.Symbol {
    return genericExtract(allocator, file_path, source, .powershell, "powershell", .{ .line_prefixes = &[_][]const u8{"#"}, .block_start = "<#", .block_end = "#>" });
}

pub fn extractTcl(allocator: std.mem.Allocator, file_path: []const u8, source: []const u8) anyerror![]model.Symbol {
    return genericExtract(allocator, file_path, source, .tcl, "tcl", .{ .line_prefixes = &[_][]const u8{"#"} });
}

/// Parses OSH's shell-compatible syntax with Tree-sitter Bash, then supplements
/// it with YSH's native `proc`/`func` definitions until a maintained YSH grammar exists.
pub fn extractOil(allocator: std.mem.Allocator, file_path: []const u8, source: []const u8) anyerror![]model.Symbol {
    const shell_symbols = try genericExtract(allocator, file_path, source, .oil, "oil", .{ .line_prefixes = &[_][]const u8{"#"} });
    errdefer deinitTestSymbols(allocator, shell_symbols);
    const native_symbols = try extractOilNativeDefinitions(allocator, file_path, source);
    errdefer deinitTestSymbols(allocator, native_symbols);

    const merged = try allocator.alloc(model.Symbol, shell_symbols.len + native_symbols.len);
    @memcpy(merged[0..shell_symbols.len], shell_symbols);
    @memcpy(merged[shell_symbols.len..], native_symbols);
    allocator.free(shell_symbols);
    allocator.free(native_symbols);
    return merged;
}

pub fn extractFsharp(allocator: std.mem.Allocator, file_path: []const u8, source: []const u8) anyerror![]model.Symbol {
    return genericExtract(allocator, file_path, source, .fsharp, "fsharp", .{ .line_prefixes = &[_][]const u8{ "///", "//" }, .block_start = "(*", .block_end = "*)" });
}

pub fn extractElm(allocator: std.mem.Allocator, file_path: []const u8, source: []const u8) anyerror![]model.Symbol {
    return genericExtract(allocator, file_path, source, .elm, "elm", .{ .line_prefixes = &[_][]const u8{"--"}, .block_start = "{-", .block_end = "-}" });
}

pub fn extractGleam(allocator: std.mem.Allocator, file_path: []const u8, source: []const u8) anyerror![]model.Symbol {
    return genericExtract(allocator, file_path, source, .gleam, "gleam", .{ .line_prefixes = &[_][]const u8{ "///", "//" } });
}

pub fn extractScheme(allocator: std.mem.Allocator, file_path: []const u8, source: []const u8) anyerror![]model.Symbol {
    return genericExtract(allocator, file_path, source, .scheme, "scheme", .{ .line_prefixes = &[_][]const u8{ ";;", ";" }, .block_start = "#|", .block_end = "|#" });
}

pub fn extractRacket(allocator: std.mem.Allocator, file_path: []const u8, source: []const u8) anyerror![]model.Symbol {
    return genericExtract(allocator, file_path, source, .racket, "racket", .{ .line_prefixes = &[_][]const u8{ ";;", ";" }, .block_start = "#|", .block_end = "|#" });
}

pub fn extractCommonLisp(allocator: std.mem.Allocator, file_path: []const u8, source: []const u8) anyerror![]model.Symbol {
    return genericExtract(allocator, file_path, source, .common_lisp, "common-lisp", .{ .line_prefixes = &[_][]const u8{ ";;;", ";;", ";" }, .block_start = "#|", .block_end = "|#" });
}

pub fn extractSml(allocator: std.mem.Allocator, file_path: []const u8, source: []const u8) anyerror![]model.Symbol {
    return genericExtract(allocator, file_path, source, .sml, "sml", .{ .line_prefixes = &[_][]const u8{}, .block_start = "(*", .block_end = "*)" });
}

pub fn extractWat(allocator: std.mem.Allocator, file_path: []const u8, source: []const u8) anyerror![]model.Symbol {
    const wat_symbols = try genericExtract(allocator, file_path, source, .wat, "wat", .{ .line_prefixes = &[_][]const u8{";;"} });
    if (!std.mem.endsWith(u8, file_path, ".wast")) return wat_symbols;
    errdefer deinitTestSymbols(allocator, wat_symbols);

    const assertion_symbols = try extractWastAssertions(allocator, file_path, source);
    errdefer deinitTestSymbols(allocator, assertion_symbols);
    const merged = try allocator.alloc(model.Symbol, wat_symbols.len + assertion_symbols.len);
    @memcpy(merged[0..wat_symbols.len], wat_symbols);
    @memcpy(merged[wat_symbols.len..], assertion_symbols);
    allocator.free(wat_symbols);
    allocator.free(assertion_symbols);
    return merged;
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
        } else if (lang == .scheme or lang == .racket) {
            if (try extractSchemeSymbol(allocator, file_path, source, lines.items, node, lang_name, doc_style)) |symbol| {
                try results.append(allocator, symbol);
            }
        } else if (lang == .common_lisp) {
            if (try extractCommonLispSymbol(allocator, file_path, source, lines.items, node, doc_style)) |symbol| {
                try results.append(allocator, symbol);
            }
        } else if (lang == .wat) {
            if (findMapping(mappings, node_type)) |mapping| {
                if (try extractWatSymbol(allocator, file_path, source, lines.items, node, mapping, doc_style)) |symbol| {
                    try results.append(allocator, symbol);
                }
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
        .symbol_kind = try allocator.dupe(u8, mapping.kind.label()),
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
        "defn",    "defn-",   "defmacro", "defmulti",    "defmethod",
        "def",     "defonce", "ns",       "defprotocol", "defrecord",
        "deftype",
    };
    for (&forms) |f| {
        if (std.mem.eql(u8, form, f)) return true;
    }
    return false;
}

// ─── Lisp, Oil, and WAT Special Cases ───────────────────────────────

fn extractSchemeSymbol(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    source: []const u8,
    lines: []const []const u8,
    node: ts.TSNode,
    comptime lang_name: []const u8,
    comptime doc_style: util.DocStyle,
) !?model.Symbol {
    if (!std.mem.eql(u8, std.mem.span(ts.ts_node_type(node)), "list")) return null;

    const form_node = firstDirectChildOfType(node, "symbol") orelse return null;
    const form = nodeText(source, form_node) orelse return null;
    if (!isSchemeDefForm(form)) return null;

    const name_node = nextNamedDefinitionChild(node, form_node) orelse return null;
    const name = if (std.mem.eql(u8, std.mem.span(ts.ts_node_type(name_node)), "list"))
        if (firstDirectChildOfType(name_node, "symbol")) |child| nodeText(source, child) else null
    else
        nodeText(source, name_node);
    const resolved_name = name orelse return null;

    return @as(?model.Symbol, try makeNamedSymbol(
        allocator,
        file_path,
        source,
        lines,
        node,
        resolved_name,
        lang_name,
        doc_style,
        null,
        schemeFormKind(form),
    ));
}

fn isSchemeDefForm(form: []const u8) bool {
    const forms = [_][]const u8{
        "define",         "define-syntax", "define-values", "define-record-type",
        "define-library", "library",       "module",        "struct",
    };
    for (&forms) |candidate| {
        if (std.mem.eql(u8, form, candidate)) return true;
    }
    return false;
}

fn schemeFormKind(form: []const u8) []const u8 {
    if (std.mem.eql(u8, form, "define-library") or std.mem.eql(u8, form, "library") or std.mem.eql(u8, form, "module")) return "mod";
    if (std.mem.eql(u8, form, "define-record-type") or std.mem.eql(u8, form, "struct")) return "type";
    return "fn";
}

fn extractCommonLispSymbol(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    source: []const u8,
    lines: []const []const u8,
    node: ts.TSNode,
    comptime doc_style: util.DocStyle,
) !?model.Symbol {
    const node_type = std.mem.span(ts.ts_node_type(node));
    var name: ?[]const u8 = null;
    var symbol_kind: []const u8 = "fn";

    if (std.mem.eql(u8, node_type, "defun")) {
        const header = firstDirectChildOfType(node, "defun_header") orelse return null;
        name = fieldText(source, header, "function_name");
    } else if (std.mem.eql(u8, node_type, "list_lit")) {
        var definition_form: ?[]const u8 = null;
        var definition_name: ?[]const u8 = null;
        var seen: usize = 0;
        const count = ts.ts_node_child_count(node);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const child = ts.ts_node_child(node, i);
            const child_type = std.mem.span(ts.ts_node_type(child));
            if (!std.mem.eql(u8, child_type, "sym_lit") and !std.mem.eql(u8, child_type, "package_lit")) continue;
            if (seen == 0) definition_form = nodeText(source, child) else if (seen == 1) {
                definition_name = nodeText(source, child);
                break;
            }
            seen += 1;
        }
        if (!isCommonLispDefForm(definition_form orelse return null)) return null;
        symbol_kind = commonLispFormKind(definition_form.?);
        name = definition_name;
    } else return null;

    return @as(?model.Symbol, try makeNamedSymbol(
        allocator,
        file_path,
        source,
        lines,
        node,
        name orelse return null,
        "common-lisp",
        doc_style,
        null,
        symbol_kind,
    ));
}

fn isCommonLispDefForm(form: []const u8) bool {
    const forms = [_][]const u8{
        "defmacro", "defmethod", "defgeneric",   "defclass",    "defstruct",
        "deftype",  "defvar",    "defparameter", "defconstant", "defpackage",
    };
    for (&forms) |candidate| {
        if (std.ascii.eqlIgnoreCase(form, candidate)) return true;
    }
    return false;
}

fn commonLispFormKind(form: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(form, "defclass") or
        std.ascii.eqlIgnoreCase(form, "defstruct") or
        std.ascii.eqlIgnoreCase(form, "deftype")) return "type";
    if (std.ascii.eqlIgnoreCase(form, "defvar") or
        std.ascii.eqlIgnoreCase(form, "defparameter")) return "var";
    if (std.ascii.eqlIgnoreCase(form, "defconstant")) return "const";
    if (std.ascii.eqlIgnoreCase(form, "defpackage")) return "mod";
    return "fn";
}

fn extractWatSymbol(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    source: []const u8,
    lines: []const []const u8,
    node: ts.TSNode,
    mapping: ts_symbols.SymbolMapping,
    comptime doc_style: util.DocStyle,
) !?model.Symbol {
    const name = extractName(source, node, mapping.name_field) orelse return null;
    const doc_comment = try extractWatAdjacentComment(
        allocator,
        source,
        lines,
        @intCast(ts.ts_node_start_point(node).row),
        @intCast(ts.ts_node_start_byte(node)),
        doc_style,
    );
    return @as(?model.Symbol, try makeNamedSymbol(allocator, file_path, source, lines, node, name, "wat", doc_style, doc_comment, mapping.kind.label()));
}

/// Finds a WAT comment immediately before a definition. The backwards token
/// scan balances nested `(; ;)` pairs, which a line-oriented doc parser cannot.
fn extractWatAdjacentComment(
    allocator: std.mem.Allocator,
    source: []const u8,
    lines: []const []const u8,
    start_line: usize,
    start_byte: usize,
    comptime doc_style: util.DocStyle,
) !?[]const u8 {
    if (start_byte <= source.len) {
        const prefix = source[0..start_byte];
        const trimmed = std.mem.trimEnd(u8, prefix, " \t\r\n");
        if (std.mem.endsWith(u8, trimmed, ";)")) {
            const comment_end = trimmed.len;
            if (watCommentBlockStart(trimmed, comment_end)) |comment_start| {
                if (isAdjacentWatWhitespace(prefix[comment_end..])) {
                    const inner = std.mem.trim(u8, trimmed[comment_start + 2 .. comment_end - 2], " \t\r\n");
                    return try allocator.dupe(u8, inner);
                }
            }
        }
    }
    return util.extractDocComment(allocator, lines, start_line, doc_style);
}

fn watCommentBlockStart(source: []const u8, end: usize) ?usize {
    var cursor = end;
    var depth: usize = 0;
    while (cursor >= 2) {
        const token = source[cursor - 2 .. cursor];
        if (std.mem.eql(u8, token, ";)")) {
            depth += 1;
            cursor -= 2;
            continue;
        }
        if (std.mem.eql(u8, token, "(;")) {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return cursor - 2;
            cursor -= 2;
            continue;
        }
        cursor -= 1;
    }
    return null;
}

fn isAdjacentWatWhitespace(text: []const u8) bool {
    var newline_count: usize = 0;
    for (text) |byte| switch (byte) {
        ' ', '\t', '\r' => {},
        '\n' => {
            newline_count += 1;
            if (newline_count > 1) return false;
        },
        else => return false,
    };
    return true;
}

/// Extracts named WAST assertions as behavioral test symbols. A balanced byte
/// scanner skips strings and nested WAT comments so multiline commands remain intact.
fn extractWastAssertions(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    source: []const u8,
) ![]model.Symbol {
    var lines = try util.splitLines(allocator, source);
    defer lines.deinit(allocator);
    var symbols: std.ArrayListUnmanaged(model.Symbol) = .empty;
    errdefer {
        for (symbols.items) |*symbol| symbol.deinit(allocator);
        symbols.deinit(allocator);
    }

    var index: usize = 0;
    var line_index: usize = 0;
    var form_start: usize = 0;
    var form_start_line: usize = 0;
    var form_depth: usize = 0;
    var comment_depth: usize = 0;
    var in_line_comment = false;
    var in_string = false;
    var escaped = false;

    while (index < source.len) : (index += 1) {
        const byte = source[index];
        if (byte == '\n') line_index += 1;

        if (in_line_comment) {
            if (byte == '\n') in_line_comment = false;
            continue;
        }
        if (comment_depth > 0) {
            if (index + 1 < source.len and source[index] == '(' and source[index + 1] == ';') {
                comment_depth += 1;
                index += 1;
            } else if (index + 1 < source.len and source[index] == ';' and source[index + 1] == ')') {
                comment_depth -= 1;
                index += 1;
            }
            continue;
        }
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }
        if (index + 1 < source.len and source[index] == ';' and source[index + 1] == ';') {
            in_line_comment = true;
            index += 1;
            continue;
        }
        if (index + 1 < source.len and source[index] == '(' and source[index + 1] == ';') {
            comment_depth = 1;
            index += 1;
            continue;
        }
        if (byte == '"') {
            in_string = true;
            continue;
        }
        if (byte == '(') {
            if (form_depth == 0) {
                form_start = index;
                form_start_line = line_index;
            }
            form_depth += 1;
            continue;
        }
        if (byte != ')' or form_depth == 0) continue;
        form_depth -= 1;
        if (form_depth != 0) continue;

        const form = source[form_start .. index + 1];
        if (!isWastActionForm(form)) continue;
        const name = wastInvokedExport(form) orelse continue;
        const doc_comment = try extractWatAdjacentComment(
            allocator,
            source,
            lines.items,
            form_start_line,
            form_start,
            .{ .line_prefixes = &[_][]const u8{";;"} },
        );
        const signature = try allocator.dupe(u8, form);
        errdefer allocator.free(signature);
        try symbols.append(allocator, .{
            .language = try allocator.dupe(u8, "wat"),
            .file_path = try allocator.dupe(u8, file_path),
            .name = try allocator.dupe(u8, name),
            .signature = signature,
            .doc_comment = doc_comment,
            .symbol_kind = try allocator.dupe(u8, "test"),
            .start_line = form_start_line + 1,
            .end_line = line_index + 1,
        });
    }
    return symbols.toOwnedSlice(allocator);
}

fn isWastActionForm(form: []const u8) bool {
    const keyword = wastFormKeyword(form) orelse return false;
    return std.mem.startsWith(u8, keyword, "assert_") or std.mem.eql(u8, keyword, "invoke");
}

fn wastFormKeyword(form: []const u8) ?[]const u8 {
    if (form.len == 0 or form[0] != '(') return null;
    const start = std.mem.indexOfNonePos(u8, form, 1, " \t\r\n") orelse return null;
    const end = std.mem.indexOfAnyPos(u8, form, start, " \t\r\n()") orelse form.len;
    if (end <= start) return null;
    return form[start..end];
}

fn wastInvokedExport(form: []const u8) ?[]const u8 {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, form, search_from, "(invoke")) |invoke_start| {
        const after_keyword = invoke_start + "(invoke".len;
        if (after_keyword < form.len and
            !std.ascii.isWhitespace(form[after_keyword]) and
            form[after_keyword] != ')')
        {
            search_from = after_keyword;
            continue;
        }
        var cursor = std.mem.indexOfNonePos(u8, form, after_keyword, " \t\r\n") orelse return null;
        if (form[cursor] == '$') {
            cursor = std.mem.indexOfAnyPos(u8, form, cursor, " \t\r\n)") orelse return null;
            cursor = std.mem.indexOfNonePos(u8, form, cursor, " \t\r\n") orelse return null;
        }
        if (form[cursor] != '"') return null;
        const name_start = cursor + 1;
        cursor = name_start;
        var escaped = false;
        while (cursor < form.len) : (cursor += 1) {
            if (escaped) {
                escaped = false;
            } else if (form[cursor] == '\\') {
                escaped = true;
            } else if (form[cursor] == '"') {
                return form[name_start..cursor];
            }
        }
        return null;
    }
    return null;
}

fn extractOilNativeDefinitions(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    source: []const u8,
) ![]model.Symbol {
    var lines = try util.splitLines(allocator, source);
    defer lines.deinit(allocator);
    var symbols: std.ArrayListUnmanaged(model.Symbol) = .empty;
    errdefer {
        for (symbols.items) |*symbol| symbol.deinit(allocator);
        symbols.deinit(allocator);
    }

    for (lines.items, 0..) |line, line_index| {
        const trimmed = std.mem.trimStart(u8, line, " \t\r");
        const keyword_len: usize = if (std.mem.startsWith(u8, trimmed, "proc ") or std.mem.startsWith(u8, trimmed, "proc\t"))
            4
        else if (std.mem.startsWith(u8, trimmed, "func ") or std.mem.startsWith(u8, trimmed, "func\t"))
            4
        else
            continue;
        const rest = std.mem.trimStart(u8, trimmed[keyword_len..], " \t");
        const name_end = std.mem.indexOfAny(u8, rest, " \t({") orelse rest.len;
        if (name_end == 0) continue;
        const name = rest[0..name_end];
        const doc_comment = try util.extractDocComment(
            allocator,
            lines.items,
            line_index,
            .{ .line_prefixes = &[_][]const u8{"#"} },
        );
        const signature = try allocator.dupe(u8, std.mem.trimEnd(u8, trimmed, " \t\r"));
        errdefer allocator.free(signature);
        try symbols.append(allocator, .{
            .language = try allocator.dupe(u8, "oil"),
            .file_path = try allocator.dupe(u8, file_path),
            .name = try allocator.dupe(u8, name),
            .signature = signature,
            .doc_comment = doc_comment,
            .symbol_kind = try allocator.dupe(u8, "fn"),
            .start_line = line_index + 1,
            .end_line = line_index + 1,
        });
    }
    return symbols.toOwnedSlice(allocator);
}

fn firstDirectChildOfType(node: ts.TSNode, wanted: []const u8) ?ts.TSNode {
    const count = ts.ts_node_child_count(node);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const child = ts.ts_node_child(node, i);
        if (std.mem.eql(u8, std.mem.span(ts.ts_node_type(child)), wanted)) return child;
    }
    return null;
}

fn nextNamedDefinitionChild(node: ts.TSNode, after: ts.TSNode) ?ts.TSNode {
    const after_end = ts.ts_node_end_byte(after);
    const count = ts.ts_node_child_count(node);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const child = ts.ts_node_child(node, i);
        if (ts.ts_node_start_byte(child) < after_end or !ts.ts_node_is_named(child)) continue;
        const child_type = std.mem.span(ts.ts_node_type(child));
        if (std.mem.eql(u8, child_type, "symbol") or std.mem.eql(u8, child_type, "list")) return child;
    }
    return null;
}

fn makeNamedSymbol(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    source: []const u8,
    lines: []const []const u8,
    node: ts.TSNode,
    name: []const u8,
    comptime lang_name: []const u8,
    comptime doc_style: util.DocStyle,
    provided_doc: ?[]const u8,
    symbol_kind: []const u8,
) !model.Symbol {
    const signature = try extractSignature(allocator, source, node);
    const doc_comment = if (provided_doc) |doc|
        doc
    else
        try util.extractDocComment(allocator, lines, @intCast(ts.ts_node_start_point(node).row), doc_style);
    const start_point = ts.ts_node_start_point(node);
    const end_point = ts.ts_node_end_point(node);
    return .{
        .language = try allocator.dupe(u8, lang_name),
        .file_path = try allocator.dupe(u8, file_path),
        .name = try allocator.dupe(u8, name),
        .signature = signature,
        .doc_comment = doc_comment,
        .symbol_kind = try allocator.dupe(u8, symbol_kind),
        .start_line = start_point.row + 1,
        .end_line = end_point.row + 1,
    };
}

// ─── Name Extraction ─────────────────────────────────────────────────

fn extractName(source: []const u8, node: ts.TSNode, strategy: ts_symbols.NameField) ?[]const u8 {
    return switch (strategy) {
        .name => fieldText(source, node, "name"),
        .declarator => extractDeclaratorName(source, node),
        .attrpath => fieldText(source, node, "attrpath"),
        .first_identifier => findFirstIdentifier(source, node),
        .word => fieldText(source, node, "name") orelse fieldText(source, node, "word"),
        .unquoted_or_quoted => fieldText(source, node, "unquoted_name") orelse fieldText(source, node, "quoted_name"),
        .identifier => fieldText(source, node, "identifier"),
        .function_name => fieldText(source, node, "function_name"),
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
        "identifier",      "qualified_identifier",  "double_quoted_name",
        "value_name",      "module_name",           "class_name",
        "atom",            "global_var",            "local_var",
        "ident",           "word",                  "cmd_identifier",
        "val_string",      "function_name",         "simple_name",
        "type_identifier", "lower_case_identifier", "upper_case_identifier",
        "long_identifier", "op_identifier",         "vid",
        "tycon",           "strid",                 "sigid",
    };
    for (&ident_types) |t| {
        if (std.mem.eql(u8, ty, t)) return true;
    }
    return false;
}

fn findFirstIdentifier(source: []const u8, root: ts.TSNode) ?[]const u8 {
    return findFirstIdentifierWithin(source, root, 12);
}

fn findFirstIdentifierWithin(source: []const u8, root: ts.TSNode, remaining_depth: usize) ?[]const u8 {
    if (remaining_depth == 0) return null;
    const count = ts.ts_node_child_count(root);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const child = ts.ts_node_child(root, i);
        if (isIdentifierLike(std.mem.span(ts.ts_node_type(child)))) return nodeText(source, child);
    }
    i = 0;
    while (i < count) : (i += 1) {
        if (findFirstIdentifierWithin(source, ts.ts_node_child(root, i), remaining_depth - 1)) |name| return name;
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

fn findTestSymbol(symbols: []const model.Symbol, name: []const u8) ?*const model.Symbol {
    for (symbols) |*symbol| {
        if (std.mem.eql(u8, symbol.name, name)) return symbol;
    }
    return null;
}

fn deinitTestSymbols(allocator: std.mem.Allocator, symbols: []model.Symbol) void {
    for (symbols) |*symbol| symbol.deinit(allocator);
    allocator.free(symbols);
}

test "new shell extractors preserve named definitions and adjacent comments" {
    const allocator = std.testing.allocator;
    const cases = .{
        .{ extractFish, "config.fish", "# Refreshes cached completions.\nfunction refresh_cache\nend\n", "fish", "refresh_cache", "Refreshes cached completions.", "fn" },
        .{ extractNushell, "pipeline.nu", "# Normalizes incoming records.\ndef normalize-records [] { [] }\n", "nushell", "normalize-records", "Normalizes incoming records.", "fn" },
        .{ extractPowerShell, "profile.ps1", "# Rotates expired credentials.\nfunction Invoke-CredentialRotation { }\n", "powershell", "Invoke-CredentialRotation", "Rotates expired credentials.", "fn" },
        .{ extractTcl, "tool.tcl", "# Rehydrates a saved session.\nproc rehydrate_session {} { return 1 }\n", "tcl", "rehydrate_session", "Rehydrates a saved session.", "fn" },
        .{ extractOil, "release.ysh", "# Publishes signed release artifacts.\nproc publish_release() { echo done }\n", "oil", "publish_release", "Publishes signed release artifacts.", "fn" },
    };

    inline for (cases) |case| {
        const symbols = try case[0](allocator, case[1], case[2]);
        defer deinitTestSymbols(allocator, symbols);
        const symbol = findTestSymbol(symbols, case[4]) orelse {
            std.debug.print("missing {s} symbol {s}\n", .{ case[3], case[4] });
            return error.TestExpectedEqual;
        };
        try std.testing.expectEqualStrings(case[3], symbol.language);
        try std.testing.expectEqualStrings(case[5], symbol.doc_comment.?);
        try std.testing.expectEqualStrings(case[6], symbol.symbol_kind.?);
    }
}

test "new functional language extractors preserve representative definitions" {
    const allocator = std.testing.allocator;
    const cases = .{
        .{ extractFsharp, "Library.fs", "/// Adds two account balances.\nlet addBalances left right = left + right\n", "fsharp", "addBalances", "Adds two account balances.", "fn" },
        .{ extractElm, "Main.elm", "-- Renders the account dashboard.\nrenderDashboard model = \"ready\"\n", "elm", "renderDashboard", "Renders the account dashboard.", "fn" },
        .{ extractGleam, "main.gleam", "/// Decodes a compact event stream.\npub fn decode_events(input) { input }\n", "gleam", "decode_events", "Decodes a compact event stream.", "fn" },
        .{ extractScheme, "core.scm", ";; Walks a rose tree depth first.\n(define (walk-tree node) node)\n", "scheme", "walk-tree", "Walks a rose tree depth first.", "fn" },
        .{ extractRacket, "main.rkt", ";; Expands a routing macro.\n(define-syntax route-table (syntax-rules ()))\n", "racket", "route-table", "Expands a routing macro.", "fn" },
        .{ extractCommonLisp, "system.lisp", ";;; Rotates a persistent cache.\n(defun rotate-cache (cache) cache)\n", "common-lisp", "rotate-cache", "Rotates a persistent cache.", "fn" },
        .{ extractSml, "main.sml", "(* Folds a rose tree without recursion leaks. *)\nfun foldTree tree = tree\n", "sml", "foldTree", "Folds a rose tree without recursion leaks.", "fn" },
    };

    inline for (cases) |case| {
        const symbols = try case[0](allocator, case[1], case[2]);
        defer deinitTestSymbols(allocator, symbols);
        const symbol = findTestSymbol(symbols, case[4]) orelse {
            std.debug.print("missing {s} symbol {s}\n", .{ case[3], case[4] });
            return error.TestExpectedEqual;
        };
        try std.testing.expectEqualStrings(case[3], symbol.language);
        try std.testing.expectEqualStrings(case[5], symbol.doc_comment.?);
        try std.testing.expectEqualStrings(case[6], symbol.symbol_kind.?);
    }
}

test "wat attaches line and nested block comments to terse definitions" {
    const allocator = std.testing.allocator;
    const source =
        ";; Decodes frobnicator packets.\n" ++
        "(func $decode_packet (param i32) (result i32)\n" ++
        "  local.get 0)\n" ++
        "(; Stores packets for later replay.\n" ++
        "   (; The nested note must remain part of the explanation. ;)\n" ++
        ";)\n" ++
        "(memory $packet_memory 1)\n";

    const symbols = try extractWat(allocator, "codec.wat", source);
    defer deinitTestSymbols(allocator, symbols);

    const decode = findTestSymbol(symbols, "$decode_packet") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("Decodes frobnicator packets.", decode.doc_comment.?);
    try std.testing.expectEqualStrings("fn", decode.symbol_kind.?);

    const memory = findTestSymbol(symbols, "$packet_memory") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("var", memory.symbol_kind.?);
    try std.testing.expect(std.mem.indexOf(u8, memory.doc_comment.?, "Stores packets for later replay.") != null);
    try std.testing.expect(std.mem.indexOf(u8, memory.doc_comment.?, "nested note") != null);
}

test "wast assertions preserve invoked behavior names and explanatory comments" {
    const allocator = std.testing.allocator;
    const source =
        ";; Help overlay stays within the vertical safe area.\n" ++
        "(assert_return\n" ++
        "  (invoke $vibesteroids_tests \"help_fits_height\" (f32.const 720))\n" ++
        "  (i32.const 1))\n";

    const symbols = try extractWat(allocator, "gameplay.wast", source);
    defer deinitTestSymbols(allocator, symbols);

    const assertion = findTestSymbol(symbols, "help_fits_height") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("test", assertion.symbol_kind.?);
    try std.testing.expectEqualStrings(
        "Help overlay stays within the vertical safe area.",
        assertion.doc_comment.?,
    );
    try std.testing.expectEqual(@as(usize, 4), assertion.end_line);
}
