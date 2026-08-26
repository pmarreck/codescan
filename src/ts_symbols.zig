const std = @import("std");
const symbol_tree = @import("symbol_tree.zig");
const SymbolNode = symbol_tree.SymbolNode;
const SymbolKind = symbol_tree.SymbolKind;
const SymbolTree = symbol_tree.SymbolTree;

const ts = @cImport({
    @cInclude("tree_sitter/api.h");
});

// ─── Language Functions ──────────────────────────────────────────────

extern fn tree_sitter_c() *ts.TSLanguage;
extern fn tree_sitter_typescript() *ts.TSLanguage;
extern fn tree_sitter_tsx() *ts.TSLanguage;
extern fn tree_sitter_rust() *ts.TSLanguage;
extern fn tree_sitter_bash() *ts.TSLanguage;
extern fn tree_sitter_lua() *ts.TSLanguage;
extern fn tree_sitter_nix() *ts.TSLanguage;
extern fn tree_sitter_nim() *ts.TSLanguage;
extern fn tree_sitter_lean() *ts.TSLanguage;
extern fn tree_sitter_idris2() *ts.TSLanguage;
extern fn tree_sitter_haskell() *ts.TSLanguage;
extern fn tree_sitter_go() *ts.TSLanguage;
extern fn tree_sitter_ruby() *ts.TSLanguage;
extern fn tree_sitter_erlang() *ts.TSLanguage;
extern fn tree_sitter_ocaml() *ts.TSLanguage;
extern fn tree_sitter_swift() *ts.TSLanguage;
extern fn tree_sitter_llvm() *ts.TSLanguage;
extern fn tree_sitter_clojure() *ts.TSLanguage;
extern fn tree_sitter_asm() *ts.TSLanguage;
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

// ─── Language Configurations ─────────────────────────────────────────

pub const Language = enum {
    c,
    typescript,
    tsx,
    rust,
    bash,
    lua,
    nix,
    nim,
    lean,
    idris,
    haskell,
    go,
    ruby,
    erlang,
    ocaml,
    swift,
    llvm,
    clojure,
    assembly,
    fish,
    nushell,
    powershell,
    tcl,
    oil,
    fsharp,
    elm,
    gleam,
    scheme,
    racket,
    common_lisp,
    sml,
    wat,

    pub fn tsLanguage(self: Language) *ts.TSLanguage {
        return switch (self) {
            .c => tree_sitter_c(),
            .typescript => tree_sitter_typescript(),
            .tsx => tree_sitter_tsx(),
            .rust => tree_sitter_rust(),
            .bash => tree_sitter_bash(),
            .lua => tree_sitter_lua(),
            .nix => tree_sitter_nix(),
            .nim => tree_sitter_nim(),
            .lean => tree_sitter_lean(),
            .idris => tree_sitter_idris2(),
            .haskell => tree_sitter_haskell(),
            .go => tree_sitter_go(),
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
        };
    }

    pub fn mappings(self: Language) []const SymbolMapping {
        return switch (self) {
            .c => &c_mappings,
            .typescript, .tsx => &typescript_mappings,
            .rust => &rust_mappings,
            .bash => &bash_mappings,
            .lua => &lua_mappings,
            .nix => &nix_mappings,
            .nim => &nim_mappings,
            .lean => &lean_mappings,
            .idris => &idris_mappings,
            .haskell => &haskell_mappings,
            .go => &go_mappings,
            .ruby => &ruby_mappings,
            .erlang => &erlang_mappings,
            .ocaml => &ocaml_mappings,
            .swift => &swift_mappings,
            .llvm => &llvm_mappings,
            .clojure => &[_]SymbolMapping{}, // Uses custom extractClojureForm
            .assembly => &asm_mappings,
            .fish => &fish_mappings,
            .nushell => &nushell_mappings,
            .powershell => &powershell_mappings,
            .tcl => &tcl_mappings,
            .oil => &bash_mappings,
            .fsharp => &fsharp_mappings,
            .elm => &elm_mappings,
            .gleam => &gleam_mappings,
            .scheme, .racket => &[_]SymbolMapping{},
            .common_lisp => &[_]SymbolMapping{},
            .sml => &sml_mappings,
            .wat => &wat_mappings,
        };
    }

    /// Detect language from shebang line in source content.
    pub fn fromShebang(source: []const u8) ?Language {
        if (source.len < 2 or source[0] != '#' or source[1] != '!') return null;

        const line_end = std.mem.indexOfScalar(u8, source, '\n') orelse source.len;
        var rest = std.mem.trimStart(u8, source[2..line_end], " \t");

        // Skip /usr/bin/env (or similar) to get the actual interpreter
        const token = nextShebangToken(rest);
        const name = shebangBasename(token);
        const interpreter = if (std.mem.eql(u8, name, "env")) blk: {
            rest = rest[token.len..];
            rest = std.mem.trimStart(u8, rest, " \t");
            // Skip env flags like -S
            while (rest.len > 0 and rest[0] == '-') {
                const flag = nextShebangToken(rest);
                rest = rest[flag.len..];
                rest = std.mem.trimStart(u8, rest, " \t");
            }
            break :blk shebangBasename(nextShebangToken(rest));
        } else name;

        const map = .{
            .{ "bash", .bash },
            .{ "sh", .bash },
            .{ "zsh", .bash },
            .{ "dash", .bash },
            .{ "ash", .bash },
            .{ "ksh", .bash },
            .{ "lua", .lua },
            .{ "luajit", .lua },
            .{ "node", .typescript },
            .{ "nodejs", .typescript },
            .{ "deno", .typescript },
            .{ "bun", .typescript },
            .{ "ruby", .ruby },
            .{ "irb", .ruby },
            .{ "fish", .fish },
            .{ "nu", .nushell },
            .{ "nushell", .nushell },
            .{ "pwsh", .powershell },
            .{ "powershell", .powershell },
            .{ "tclsh", .tcl },
            .{ "wish", .tcl },
            .{ "osh", .oil },
            .{ "ysh", .oil },
            .{ "dotnet-fsi", .fsharp },
            .{ "fsi", .fsharp },
            .{ "gleam", .gleam },
            .{ "racket", .racket },
            .{ "raco", .racket },
            .{ "guile", .scheme },
            .{ "scheme", .scheme },
            .{ "csi", .scheme },
            .{ "sbcl", .common_lisp },
            .{ "clisp", .common_lisp },
            .{ "sml", .sml },
            .{ "poly", .sml },
            .{ "polyml", .sml },
            .{ "bb", .clojure },
            .{ "babashka", .clojure },
            .{ "clojure", .clojure },
            .{ "clj", .clojure },
            .{ "runghc", .haskell },
            .{ "runhaskell", .haskell },
            .{ "swift", .swift },
            .{ "nim", .nim },
            .{ "escript", .erlang },
            .{ "ocaml", .ocaml },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, interpreter, entry[0])) return entry[1];
        }
        return null;
    }

    fn nextShebangToken(text: []const u8) []const u8 {
        const trimmed = std.mem.trimStart(u8, text, " \t");
        const end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
        return trimmed[0..end];
    }

    fn shebangBasename(path: []const u8) []const u8 {
        const pos = std.mem.lastIndexOfScalar(u8, path, '/');
        return if (pos) |p| path[p + 1 ..] else path;
    }

    /// Detect language from file extension.
    pub fn fromExtension(ext: []const u8) ?Language {
        const map = .{
            .{ ".c", .c },
            .{ ".h", .c },
            .{ ".ts", .typescript },
            .{ ".tsx", .tsx },
            .{ ".js", .typescript },
            .{ ".jsx", .tsx },
            .{ ".rs", .rust },
            .{ ".sh", .bash },
            .{ ".bash", .bash },
            .{ ".lua", .lua },
            .{ ".nix", .nix },
            .{ ".nim", .nim },
            .{ ".lean", .lean },
            .{ ".idr", .idris },
            .{ ".hs", .haskell },
            .{ ".go", .go },
            .{ ".rb", .ruby },
            .{ ".erl", .erlang },
            .{ ".hrl", .erlang },
            .{ ".ml", .ocaml },
            .{ ".swift", .swift },
            .{ ".ll", .llvm },
            .{ ".clj", .clojure },
            .{ ".cljs", .clojure },
            .{ ".cljc", .clojure },
            .{ ".edn", .clojure },
            .{ ".s", .assembly },
            .{ ".S", .assembly },
            .{ ".asm", .assembly },
            .{ ".fish", .fish },
            .{ ".nu", .nushell },
            .{ ".ps1", .powershell },
            .{ ".psm1", .powershell },
            .{ ".psd1", .powershell },
            .{ ".tcl", .tcl },
            .{ ".tm", .tcl },
            .{ ".osh", .oil },
            .{ ".oil", .oil },
            .{ ".ysh", .oil },
            .{ ".fs", .fsharp },
            .{ ".fsi", .fsharp },
            .{ ".fsx", .fsharp },
            .{ ".elm", .elm },
            .{ ".gleam", .gleam },
            .{ ".scm", .scheme },
            .{ ".ss", .scheme },
            .{ ".rkt", .racket },
            .{ ".rktd", .racket },
            .{ ".scrbl", .racket },
            .{ ".lisp", .common_lisp },
            .{ ".lsp", .common_lisp },
            .{ ".cl", .common_lisp },
            .{ ".asd", .common_lisp },
            .{ ".sml", .sml },
            .{ ".sig", .sml },
            .{ ".fun", .sml },
            .{ ".wat", .wat },
            .{ ".wast", .wat },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, ext, entry[0])) return entry[1];
        }
        return null;
    }
};

pub const NameField = enum {
    name, // ts_node_child_by_field_name(node, "name")
    declarator, // C: ts_node_child_by_field_name(node, "declarator") -> find identifier
    attrpath, // Nix: ts_node_child_by_field_name(node, "attrpath")
    first_identifier, // Walk children for first identifier node
    word, // Bash: ts_node_child_by_field_name(node, "word") — fallback to "name"
    unquoted_or_quoted, // Nushell declaration names use one of two fields.
    identifier, // WAT declarations expose an optional identifier field.
    function_name, // Common Lisp defun headers expose this field.
};

pub const SymbolMapping = struct {
    node_type: [:0]const u8,
    kind: SymbolKind,
    name_field: NameField,
};

// ── C ──
const c_mappings = [_]SymbolMapping{
    .{ .node_type = "function_definition", .kind = .function, .name_field = .declarator },
    .{ .node_type = "struct_specifier", .kind = .struct_decl, .name_field = .name },
    .{ .node_type = "enum_specifier", .kind = .enum_decl, .name_field = .name },
    .{ .node_type = "union_specifier", .kind = .union_decl, .name_field = .name },
    .{ .node_type = "type_definition", .kind = .type_alias, .name_field = .declarator },
};

// ── TypeScript / TSX / JS ──
const typescript_mappings = [_]SymbolMapping{
    .{ .node_type = "function_declaration", .kind = .function, .name_field = .name },
    .{ .node_type = "generator_function_declaration", .kind = .function, .name_field = .name },
    .{ .node_type = "class_declaration", .kind = .class, .name_field = .name },
    .{ .node_type = "abstract_class_declaration", .kind = .class, .name_field = .name },
    .{ .node_type = "method_definition", .kind = .function, .name_field = .name },
    .{ .node_type = "interface_declaration", .kind = .interface, .name_field = .name },
    .{ .node_type = "enum_declaration", .kind = .enum_decl, .name_field = .name },
    .{ .node_type = "type_alias_declaration", .kind = .type_alias, .name_field = .name },
};

// ── Rust ──
const rust_mappings = [_]SymbolMapping{
    .{ .node_type = "function_item", .kind = .function, .name_field = .name },
    .{ .node_type = "struct_item", .kind = .struct_decl, .name_field = .name },
    .{ .node_type = "enum_item", .kind = .enum_decl, .name_field = .name },
    .{ .node_type = "trait_item", .kind = .trait_decl, .name_field = .name },
    .{ .node_type = "impl_item", .kind = .impl_block, .name_field = .name },
    .{ .node_type = "mod_item", .kind = .module, .name_field = .name },
    .{ .node_type = "type_item", .kind = .type_alias, .name_field = .name },
    .{ .node_type = "const_item", .kind = .constant, .name_field = .name },
};

// ── Bash ──
const bash_mappings = [_]SymbolMapping{
    .{ .node_type = "function_definition", .kind = .function, .name_field = .name },
};

// ── Lua ──
const lua_mappings = [_]SymbolMapping{
    .{ .node_type = "function_declaration", .kind = .function, .name_field = .name },
};

// ── Nix ──
const nix_mappings = [_]SymbolMapping{
    .{ .node_type = "binding", .kind = .function, .name_field = .attrpath },
};

// ── Nim ──
const nim_mappings = [_]SymbolMapping{
    .{ .node_type = "proc_declaration", .kind = .function, .name_field = .name },
    .{ .node_type = "func_declaration", .kind = .function, .name_field = .name },
    .{ .node_type = "method_declaration", .kind = .function, .name_field = .name },
    .{ .node_type = "iterator_declaration", .kind = .function, .name_field = .name },
    .{ .node_type = "macro_declaration", .kind = .function, .name_field = .name },
    .{ .node_type = "template_declaration", .kind = .function, .name_field = .name },
    .{ .node_type = "converter_declaration", .kind = .function, .name_field = .name },
    .{ .node_type = "type_section", .kind = .type_alias, .name_field = .first_identifier },
};

// ── Lean ──
const lean_mappings = [_]SymbolMapping{
	.{ .node_type = "namespace", .kind = .module, .name_field = .name },
    .{ .node_type = "def", .kind = .function, .name_field = .first_identifier },
    .{ .node_type = "theorem", .kind = .function, .name_field = .first_identifier },
    .{ .node_type = "structure", .kind = .struct_decl, .name_field = .first_identifier },
    .{ .node_type = "abbrev", .kind = .type_alias, .name_field = .first_identifier },
    .{ .node_type = "instance", .kind = .impl_block, .name_field = .first_identifier },
    .{ .node_type = "class", .kind = .class, .name_field = .first_identifier },
    .{ .node_type = "inductive", .kind = .enum_decl, .name_field = .first_identifier },
};

// ── Idris ──
const idris_mappings = [_]SymbolMapping{
    .{ .node_type = "function_definition", .kind = .function, .name_field = .first_identifier },
    .{ .node_type = "data_declaration", .kind = .enum_decl, .name_field = .first_identifier },
};

// ── Haskell ──
const haskell_mappings = [_]SymbolMapping{
    .{ .node_type = "function", .kind = .function, .name_field = .first_identifier },
    .{ .node_type = "data_type", .kind = .enum_decl, .name_field = .name },
    .{ .node_type = "newtype", .kind = .type_alias, .name_field = .name },
    .{ .node_type = "type_synomym", .kind = .type_alias, .name_field = .name },
    .{ .node_type = "class", .kind = .class, .name_field = .name },
    .{ .node_type = "instance", .kind = .impl_block, .name_field = .name },
};

// ── Go ──
const go_mappings = [_]SymbolMapping{
    .{ .node_type = "function_declaration", .kind = .function, .name_field = .name },
    .{ .node_type = "method_declaration", .kind = .function, .name_field = .name },
    .{ .node_type = "type_spec", .kind = .type_alias, .name_field = .name },
};

// ── Ruby ──
const ruby_mappings = [_]SymbolMapping{
    .{ .node_type = "method", .kind = .function, .name_field = .name },
    .{ .node_type = "singleton_method", .kind = .function, .name_field = .name },
    .{ .node_type = "class", .kind = .class, .name_field = .name },
    .{ .node_type = "module", .kind = .module, .name_field = .name },
};

// ── Erlang ──
const erlang_mappings = [_]SymbolMapping{
    .{ .node_type = "function_clause", .kind = .function, .name_field = .name },
    .{ .node_type = "type_alias", .kind = .type_alias, .name_field = .name },
    .{ .node_type = "record_decl", .kind = .struct_decl, .name_field = .name },
};

// ── OCaml ──
const ocaml_mappings = [_]SymbolMapping{
    .{ .node_type = "let_binding", .kind = .function, .name_field = .first_identifier },
    .{ .node_type = "type_binding", .kind = .type_alias, .name_field = .name },
    .{ .node_type = "module_binding", .kind = .module, .name_field = .first_identifier },
    .{ .node_type = "class_binding", .kind = .class, .name_field = .first_identifier },
    .{ .node_type = "external", .kind = .function, .name_field = .first_identifier },
};

// ── Swift ──
const swift_mappings = [_]SymbolMapping{
    .{ .node_type = "function_declaration", .kind = .function, .name_field = .name },
    .{ .node_type = "class_declaration", .kind = .class, .name_field = .name },
    .{ .node_type = "protocol_declaration", .kind = .interface, .name_field = .name },
    .{ .node_type = "typealias_declaration", .kind = .type_alias, .name_field = .name },
};

// ── LLVM IR ──
const llvm_mappings = [_]SymbolMapping{
    .{ .node_type = "fn_define", .kind = .function, .name_field = .first_identifier },
    .{ .node_type = "declare", .kind = .function, .name_field = .first_identifier },
    .{ .node_type = "global_global", .kind = .variable, .name_field = .first_identifier },
    .{ .node_type = "global_type", .kind = .type_alias, .name_field = .first_identifier },
    .{ .node_type = "alias", .kind = .variable, .name_field = .first_identifier },
};

// ── Assembly ──
const asm_mappings = [_]SymbolMapping{
    .{ .node_type = "label", .kind = .function, .name_field = .first_identifier },
    .{ .node_type = "const", .kind = .variable, .name_field = .name },
};

// ── Additional pinned Nix grammars ──
const fish_mappings = [_]SymbolMapping{
    .{ .node_type = "function_definition", .kind = .function, .name_field = .name },
};

const nushell_mappings = [_]SymbolMapping{
    .{ .node_type = "decl_def", .kind = .function, .name_field = .unquoted_or_quoted },
    .{ .node_type = "decl_extern", .kind = .function, .name_field = .unquoted_or_quoted },
    .{ .node_type = "decl_module", .kind = .module, .name_field = .unquoted_or_quoted },
    .{ .node_type = "decl_alias", .kind = .variable, .name_field = .unquoted_or_quoted },
};

const powershell_mappings = [_]SymbolMapping{
    .{ .node_type = "function_statement", .kind = .function, .name_field = .first_identifier },
    .{ .node_type = "filter_statement", .kind = .function, .name_field = .first_identifier },
    .{ .node_type = "class_statement", .kind = .class, .name_field = .first_identifier },
    .{ .node_type = "enum_statement", .kind = .enum_decl, .name_field = .first_identifier },
    .{ .node_type = "class_method_definition", .kind = .function, .name_field = .first_identifier },
};

const tcl_mappings = [_]SymbolMapping{
    .{ .node_type = "procedure", .kind = .function, .name_field = .name },
};

const fsharp_mappings = [_]SymbolMapping{
    .{ .node_type = "function_or_value_defn", .kind = .function, .name_field = .first_identifier },
    .{ .node_type = "named_module", .kind = .module, .name_field = .name },
    .{ .node_type = "module_defn", .kind = .module, .name_field = .first_identifier },
    .{ .node_type = "namespace", .kind = .module, .name_field = .name },
    .{ .node_type = "type_definition", .kind = .type_alias, .name_field = .first_identifier },
    .{ .node_type = "member_defn", .kind = .function, .name_field = .first_identifier },
};

const elm_mappings = [_]SymbolMapping{
    .{ .node_type = "value_declaration", .kind = .function, .name_field = .first_identifier },
    .{ .node_type = "type_declaration", .kind = .type_alias, .name_field = .name },
    .{ .node_type = "type_alias_declaration", .kind = .type_alias, .name_field = .name },
    .{ .node_type = "module_declaration", .kind = .module, .name_field = .name },
};

const gleam_mappings = [_]SymbolMapping{
    .{ .node_type = "function", .kind = .function, .name_field = .name },
    .{ .node_type = "external_function", .kind = .function, .name_field = .name },
    .{ .node_type = "type_definition", .kind = .type_alias, .name_field = .first_identifier },
    .{ .node_type = "external_type", .kind = .type_alias, .name_field = .first_identifier },
};

const sml_mappings = [_]SymbolMapping{
    .{ .node_type = "fun_dec", .kind = .function, .name_field = .first_identifier },
    .{ .node_type = "valbind", .kind = .variable, .name_field = .first_identifier },
    .{ .node_type = "datatype_dec", .kind = .enum_decl, .name_field = .first_identifier },
    .{ .node_type = "type_dec", .kind = .type_alias, .name_field = .first_identifier },
    .{ .node_type = "structure_strdec", .kind = .module, .name_field = .first_identifier },
    .{ .node_type = "signature_sigdec", .kind = .interface, .name_field = .first_identifier },
    .{ .node_type = "functor_fctdec", .kind = .module, .name_field = .first_identifier },
};

const wat_mappings = [_]SymbolMapping{
    .{ .node_type = "module", .kind = .module, .name_field = .first_identifier },
    .{ .node_type = "module_field_func", .kind = .function, .name_field = .first_identifier },
    .{ .node_type = "module_field_global", .kind = .variable, .name_field = .first_identifier },
    .{ .node_type = "module_field_memory", .kind = .variable, .name_field = .first_identifier },
    .{ .node_type = "module_field_table", .kind = .variable, .name_field = .first_identifier },
    .{ .node_type = "type_def", .kind = .type_alias, .name_field = .first_identifier },
};

// ─── Extraction ──────────────────────────────────────────────────────

/// Extract a hierarchical symbol tree from source using tree-sitter.
pub fn extract(allocator: std.mem.Allocator, source: []const u8, lang: Language) !SymbolTree {
    const parser = ts.ts_parser_new() orelse return error.ParseFailed;
    defer ts.ts_parser_delete(parser);

    if (!ts.ts_parser_set_language(parser, lang.tsLanguage())) {
        return error.ParseFailed;
    }

    const tree = ts.ts_parser_parse_string(
        parser,
        null,
        source.ptr,
        @intCast(source.len),
    ) orelse return error.ParseFailed;
    defer ts.ts_tree_delete(tree);

    const lang_mappings = lang.mappings();

    // Pass 1: Flat extraction — walk the full tree and collect all matching nodes
    var flat = @as(std.ArrayListUnmanaged(FlatSymbol), .empty);
    defer flat.deinit(allocator);

    var cursor = ts.ts_tree_cursor_new(ts.ts_tree_root_node(tree));
    defer ts.ts_tree_cursor_delete(&cursor);

    var done = false;
    while (!done) {
        const node = ts.ts_tree_cursor_current_node(&cursor);
        const node_type = std.mem.span(ts.ts_node_type(node));

        // Clojure: match list_lit forms like (defn ...), (def ...), (ns ...)
        if (lang == .clojure) {
            if (extractClojureForm(source, node)) |sym| {
                try flat.append(allocator, sym);
            }
        } else if (lang == .scheme or lang == .racket) {
            if (extractSchemeForm(source, node)) |sym| try flat.append(allocator, sym);
        } else if (lang == .common_lisp) {
            if (extractCommonLispForm(source, node)) |sym| try flat.append(allocator, sym);
        } else if (findMapping(lang_mappings, node_type)) |mapping| {
            if (extractName(source, node, mapping.name_field)) |name| {
                const start_point = ts.ts_node_start_point(node);
                const end_point = ts.ts_node_end_point(node);
                try flat.append(allocator, .{
                    .name = name,
                    .kind = mapping.kind,
                    .start_line = start_point.row + 1,
                    .end_line = end_point.row + 1,
                    .start_byte = ts.ts_node_start_byte(node),
                    .end_byte = ts.ts_node_end_byte(node),
                });
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

    if (lang == .oil) try appendOilNativeForms(allocator, &flat, source);

    // Pass 2: Build hierarchy from byte-range containment
    return buildHierarchy(allocator, flat.items, source);
}

fn findMapping(lang_mappings: []const SymbolMapping, node_type: []const u8) ?SymbolMapping {
    for (lang_mappings) |m| {
        if (std.mem.eql(u8, m.node_type, node_type)) return m;
    }
    return null;
}

fn extractName(source: []const u8, node: ts.TSNode, strategy: NameField) ?[]const u8 {
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

    // Walk down through nested declarators to find the identifier
    var limit: usize = 10;
    while (limit > 0) : (limit -= 1) {
        const ty = std.mem.span(ts.ts_node_type(decl));
        if (std.mem.eql(u8, ty, "identifier")) {
            return nodeText(source, decl);
        }
        // Try nested declarator
        const inner = ts.ts_node_child_by_field_name(decl, "declarator", "declarator".len);
        if (ts.ts_node_is_null(inner)) {
            // No nested declarator, try to find identifier child
            const count = ts.ts_node_child_count(decl);
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const child = ts.ts_node_child(decl, i);
                const child_ty = std.mem.span(ts.ts_node_type(child));
                if (std.mem.eql(u8, child_ty, "identifier")) {
                    return nodeText(source, child);
                }
            }
            return nodeText(source, decl);
        }
        decl = inner;
    }
    return null;
}

fn isIdentifierLike(ty: []const u8) bool {
    const ident_types = [_][]const u8{
        "identifier",
        "qualified_identifier",
        "double_quoted_name",
        // OCaml
        "value_name",
        "module_name",
        "class_name",
        // Erlang
        "atom",
        // LLVM IR
        "global_var",
        "local_var",
        // Assembly
        "ident",
        // Additional pinned grammars
        "word",
        "cmd_identifier",
        "val_string",
        "function_name",
        "simple_name",
        "type_identifier",
        "lower_case_identifier",
        "upper_case_identifier",
        "long_identifier",
        "op_identifier",
        "vid",
        "tycon",
        "strid",
        "sigid",
    };
    for (ident_types) |t| {
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

fn nodeText(source: []const u8, node: ts.TSNode) ?[]const u8 {
    const start = ts.ts_node_start_byte(node);
    const end = ts.ts_node_end_byte(node);
    if (start >= source.len or end > source.len or start >= end) return null;
    return source[start..end];
}

// ─── Clojure Extraction ─────────────────────────────────────────────

/// Match (defn name ...), (def name ...), (ns name ...) etc. in Clojure.
/// The tree-sitter-clojure grammar is syntax-only — all forms are list_lit
/// with sym_lit children, so we pattern-match the first symbol to determine kind.
fn extractClojureForm(source: []const u8, node: ts.TSNode) ?FlatSymbol {
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
    const kind = clojureFormKind(form) orelse return null;

    const start_point = ts.ts_node_start_point(node);
    const end_point = ts.ts_node_end_point(node);
    return FlatSymbol{
        .name = name,
        .kind = kind,
        .start_line = start_point.row + 1,
        .end_line = end_point.row + 1,
        .start_byte = ts.ts_node_start_byte(node),
        .end_byte = ts.ts_node_end_byte(node),
    };
}

fn clojureFormKind(form: []const u8) ?SymbolKind {
    const forms = .{
        .{ "defn", SymbolKind.function },
        .{ "defn-", SymbolKind.function },
        .{ "defmacro", SymbolKind.function },
        .{ "defmulti", SymbolKind.function },
        .{ "defmethod", SymbolKind.function },
        .{ "def", SymbolKind.variable },
        .{ "defonce", SymbolKind.variable },
        .{ "ns", SymbolKind.module },
        .{ "defprotocol", SymbolKind.interface },
        .{ "defrecord", SymbolKind.struct_decl },
        .{ "deftype", SymbolKind.type_alias },
    };
    inline for (forms) |entry| {
        if (std.mem.eql(u8, form, entry[0])) return entry[1];
    }
    return null;
}

/// Recognizes Scheme/Racket definition forms whose grammar exposes only lists.
fn extractSchemeForm(source: []const u8, node: ts.TSNode) ?FlatSymbol {
    if (!std.mem.eql(u8, std.mem.span(ts.ts_node_type(node)), "list")) return null;
    const form_node = firstDirectChildOfType(node, "symbol") orelse return null;
    const form = nodeText(source, form_node) orelse return null;
    const kind = schemeFormKind(form) orelse return null;
    const name_node = nextDefinitionChild(node, form_node, &.{ "symbol", "list" }) orelse return null;
    const name = if (std.mem.eql(u8, std.mem.span(ts.ts_node_type(name_node)), "list"))
        if (firstDirectChildOfType(name_node, "symbol")) |child| nodeText(source, child) else null
    else
        nodeText(source, name_node);
    return flatSymbolFromNode(node, name orelse return null, kind);
}

fn schemeFormKind(form: []const u8) ?SymbolKind {
    const forms = .{
        .{ "define", SymbolKind.function },
        .{ "define-syntax", SymbolKind.function },
        .{ "define-values", SymbolKind.variable },
        .{ "define-record-type", SymbolKind.type_alias },
        .{ "struct", SymbolKind.struct_decl },
        .{ "define-library", SymbolKind.module },
        .{ "library", SymbolKind.module },
        .{ "module", SymbolKind.module },
    };
    inline for (forms) |entry| {
        if (std.mem.eql(u8, form, entry[0])) return entry[1];
    }
    return null;
}

/// Promotes the whole Common Lisp defining form, not merely its header, so
/// semantic edits and bodies retain the complete definition span.
fn extractCommonLispForm(source: []const u8, node: ts.TSNode) ?FlatSymbol {
    const node_type = std.mem.span(ts.ts_node_type(node));
    if (std.mem.eql(u8, node_type, "defun")) {
        const header = firstDirectChildOfType(node, "defun_header") orelse return null;
        const name = fieldText(source, header, "function_name") orelse return null;
        return flatSymbolFromNode(node, name, .function);
    }
    if (!std.mem.eql(u8, node_type, "list_lit")) return null;

    var form_node: ?ts.TSNode = null;
    var name_node: ?ts.TSNode = null;
    const count = ts.ts_node_child_count(node);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const child = ts.ts_node_child(node, i);
        const child_type = std.mem.span(ts.ts_node_type(child));
        if (!std.mem.eql(u8, child_type, "sym_lit") and !std.mem.eql(u8, child_type, "package_lit")) continue;
        if (form_node == null) form_node = child else {
            name_node = child;
            break;
        }
    }
    const form = nodeText(source, form_node orelse return null) orelse return null;
    const kind = commonLispFormKind(form) orelse return null;
    const name = nodeText(source, name_node orelse return null) orelse return null;
    return flatSymbolFromNode(node, name, kind);
}

fn commonLispFormKind(form: []const u8) ?SymbolKind {
    const forms = .{
        .{ "defmacro", SymbolKind.function },
        .{ "defmethod", SymbolKind.function },
        .{ "defgeneric", SymbolKind.function },
        .{ "defclass", SymbolKind.class },
        .{ "defstruct", SymbolKind.struct_decl },
        .{ "deftype", SymbolKind.type_alias },
        .{ "defvar", SymbolKind.variable },
        .{ "defparameter", SymbolKind.variable },
        .{ "defconstant", SymbolKind.constant },
        .{ "defpackage", SymbolKind.module },
    };
    inline for (forms) |entry| {
        if (std.ascii.eqlIgnoreCase(form, entry[0])) return entry[1];
    }
    return null;
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

fn nextDefinitionChild(node: ts.TSNode, after: ts.TSNode, wanted: []const []const u8) ?ts.TSNode {
    const after_end = ts.ts_node_end_byte(after);
    const count = ts.ts_node_child_count(node);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const child = ts.ts_node_child(node, i);
        if (ts.ts_node_start_byte(child) < after_end or !ts.ts_node_is_named(child)) continue;
        const child_type = std.mem.span(ts.ts_node_type(child));
        for (wanted) |candidate| {
            if (std.mem.eql(u8, child_type, candidate)) return child;
        }
    }
    return null;
}

fn flatSymbolFromNode(node: ts.TSNode, name: []const u8, kind: SymbolKind) FlatSymbol {
    const start = ts.ts_node_start_point(node);
    const end = ts.ts_node_end_point(node);
    return .{
        .name = name,
        .kind = kind,
        .start_line = start.row + 1,
        .end_line = end.row + 1,
        .start_byte = ts.ts_node_start_byte(node),
        .end_byte = ts.ts_node_end_byte(node),
    };
}

/// Adds YSH-native `proc`/`func` spans alongside the Bash-compatible OSH tree.
fn appendOilNativeForms(
    allocator: std.mem.Allocator,
    flat: *std.ArrayListUnmanaged(FlatSymbol),
    source: []const u8,
) !void {
    var line_start: usize = 0;
    var line_number: usize = 1;
    while (line_start < source.len) {
        const relative_end = std.mem.indexOfScalar(u8, source[line_start..], '\n') orelse source.len - line_start;
        const line_end = line_start + relative_end;
        const line = source[line_start..line_end];
        const trimmed = std.mem.trimStart(u8, line, " \t\r");
        const keyword_len: usize = if (std.mem.startsWith(u8, trimmed, "proc ") or std.mem.startsWith(u8, trimmed, "proc\t"))
            4
        else if (std.mem.startsWith(u8, trimmed, "func ") or std.mem.startsWith(u8, trimmed, "func\t"))
            4
        else {
            line_start = @min(line_end + 1, source.len);
            line_number += 1;
            continue;
        };
        const rest = std.mem.trimStart(u8, trimmed[keyword_len..], " \t");
        const name_end = std.mem.indexOfAny(u8, rest, " \t({") orelse rest.len;
        if (name_end > 0) {
            const definition_start = line_start + (line.len - trimmed.len);
            const definition_end = oilDefinitionEnd(source, definition_start);
            try flat.append(allocator, .{
                .name = rest[0..name_end],
                .kind = .function,
                .start_line = line_number,
                .end_line = line_number + countNewlines(source[definition_start..definition_end]),
                .start_byte = definition_start,
                .end_byte = definition_end,
            });
        }
        line_start = @min(line_end + 1, source.len);
        line_number += 1;
    }
}

fn oilDefinitionEnd(source: []const u8, start: usize) usize {
    const open = std.mem.indexOfScalarPos(u8, source, start, '{') orelse
        (std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len);
    var depth: usize = 0;
    var cursor = open;
    while (cursor < source.len) : (cursor += 1) {
        switch (source[cursor]) {
            '{' => depth += 1,
            '}' => {
                if (depth == 0) return cursor + 1;
                depth -= 1;
                if (depth == 0) return cursor + 1;
            },
            else => {},
        }
    }
    return source.len;
}

fn countNewlines(text: []const u8) usize {
    var count: usize = 0;
    for (text) |byte| if (byte == '\n') {
        count += 1;
    };
    return count;
}

// ─── Hierarchy Builder ───────────────────────────────────────────────

const FlatSymbol = struct {
    name: []const u8, // slice into source, NOT owned
    kind: SymbolKind,
    start_line: usize,
    end_line: usize,
    start_byte: usize,
    end_byte: usize,
};

/// Build a hierarchical SymbolTree from flat symbols using byte-range nesting.
/// Names are duped into owned allocations. Caller owns the returned tree.
pub fn buildHierarchy(allocator: std.mem.Allocator, flat: []const FlatSymbol, source: []const u8) !SymbolTree {
    _ = source;
    if (flat.len == 0) return .{ .symbols = try allocator.alloc(SymbolNode, 0) };

    // Step 1: Find parent for each symbol (smallest container containing it)
    const parent_of = try allocator.alloc(?usize, flat.len);
    defer allocator.free(parent_of);

    for (flat, 0..) |sym, i| {
        parent_of[i] = null;
        var best_span: usize = std.math.maxInt(usize);

        for (flat, 0..) |other, j| {
            if (i == j) continue;
            if (other.start_byte <= sym.start_byte and other.end_byte >= sym.end_byte and
                !(other.start_byte == sym.start_byte and other.end_byte == sym.end_byte))
            {
                const span = other.end_byte - other.start_byte;
                if (span < best_span) {
                    best_span = span;
                    parent_of[i] = j;
                }
            }
        }
    }

    // Step 2: Count children per parent + roots
    const child_count = try allocator.alloc(usize, flat.len);
    defer allocator.free(child_count);
    @memset(child_count, 0);

    var root_count: usize = 0;
    for (parent_of) |p| {
        if (p) |pi| child_count[pi] += 1 else root_count += 1;
    }

    // Step 3: Allocate all nodes
    const nodes = try allocator.alloc(SymbolNode, flat.len);
    // On error, clean up allocated names and children
    var init_count: usize = 0;
    errdefer {
        for (nodes[0..init_count]) |*n| {
            allocator.free(n.name);
            if (n.children.len > 0) allocator.free(n.children);
        }
        allocator.free(nodes);
    }

    for (flat, 0..) |f, i| {
        nodes[i] = .{
            .name = try allocator.dupe(u8, f.name),
            .kind = f.kind,
            .start_line = f.start_line,
            .end_line = f.end_line,
            .start_byte = f.start_byte,
            .end_byte = f.end_byte,
            .children = if (child_count[i] > 0) try allocator.alloc(SymbolNode, child_count[i]) else try allocator.alloc(SymbolNode, 0),
        };
        init_count += 1;
    }

    // Step 4: Fill children arrays
    const child_offset = try allocator.alloc(usize, flat.len);
    defer allocator.free(child_offset);
    @memset(child_offset, 0);

    for (0..flat.len) |i| {
        if (parent_of[i]) |p| {
            nodes[p].children[child_offset[p]] = nodes[i];
            child_offset[p] += 1;
        }
    }

    // Step 5: Collect root symbols
    const roots = try allocator.alloc(SymbolNode, root_count);
    var ri: usize = 0;
    for (0..flat.len) |i| {
        if (parent_of[i] == null) {
            roots[ri] = nodes[i];
            ri += 1;
        }
    }

    // Free the scaffolding array (all data was copied into roots/children)
    allocator.free(nodes);

    return .{ .symbols = roots };
}

// ─── Tests ───────────────────────────────────────────────────────────

test "c: extracts functions" {
    const allocator = std.testing.allocator;
    const source =
        \\int add(int a, int b) {
        \\    return a + b;
        \\}
        \\
        \\void greet() {}
    ;
    var tree = try extract(allocator, source, .c);
    defer tree.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), tree.symbols.len);
    try std.testing.expectEqualStrings("add", tree.symbols[0].name);
    try std.testing.expectEqual(SymbolKind.function, tree.symbols[0].kind);
    try std.testing.expectEqualStrings("greet", tree.symbols[1].name);
}

test "typescript: extracts class with methods" {
    const allocator = std.testing.allocator;
    const source =
        \\class Greeter {
        \\    greet() {
        \\        return "hello";
        \\    }
        \\    farewell() {
        \\        return "bye";
        \\    }
        \\}
        \\
        \\function standalone() {}
    ;
    var tree = try extract(allocator, source, .typescript);
    defer tree.deinit(allocator);

    // Greeter class + standalone function at root
    try std.testing.expectEqual(@as(usize, 2), tree.symbols.len);
    try std.testing.expectEqualStrings("Greeter", tree.symbols[0].name);
    try std.testing.expectEqual(SymbolKind.class, tree.symbols[0].kind);
    // Methods should be children of the class
    try std.testing.expectEqual(@as(usize, 2), tree.symbols[0].children.len);
    try std.testing.expectEqualStrings("greet", tree.symbols[0].children[0].name);
    try std.testing.expectEqualStrings("farewell", tree.symbols[0].children[1].name);
    try std.testing.expectEqualStrings("standalone", tree.symbols[1].name);
}

test "rust: extracts function" {
    const allocator = std.testing.allocator;
    const source =
        \\fn main() {
        \\    println!("hello");
        \\}
    ;
    var tree = try extract(allocator, source, .rust);
    defer tree.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), tree.symbols.len);
    try std.testing.expectEqualStrings("main", tree.symbols[0].name);
    try std.testing.expectEqual(SymbolKind.function, tree.symbols[0].kind);
}

test "bash: extracts function" {
    const allocator = std.testing.allocator;
    const source =
        \\greet() {
        \\    echo "hello"
        \\}
    ;
    var tree = try extract(allocator, source, .bash);
    defer tree.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), tree.symbols.len);
    try std.testing.expectEqualStrings("greet", tree.symbols[0].name);
}

test "lua: extracts function" {
    const allocator = std.testing.allocator;
    const source =
        \\function greet()
        \\    print("hello")
        \\end
    ;
    var tree = try extract(allocator, source, .lua);
    defer tree.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), tree.symbols.len);
    try std.testing.expectEqualStrings("greet", tree.symbols[0].name);
}

test "empty source returns empty tree" {
    const allocator = std.testing.allocator;
    var tree = try extract(allocator, "", .c);
    defer tree.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), tree.symbols.len);
}

test "hierarchy: nested symbols get correct parent" {
    const allocator = std.testing.allocator;
    const source =
        \\class Foo {
        \\    bar() { return 1; }
        \\    baz() { return 2; }
        \\}
    ;
    var tree = try extract(allocator, source, .typescript);
    defer tree.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), tree.symbols.len);
    try std.testing.expectEqual(@as(usize, 2), tree.symbols[0].children.len);
}

test "language detection from extension" {
    try std.testing.expectEqual(Language.c, Language.fromExtension(".c").?);
    try std.testing.expectEqual(Language.typescript, Language.fromExtension(".ts").?);
    try std.testing.expectEqual(Language.tsx, Language.fromExtension(".tsx").?);
    try std.testing.expectEqual(Language.rust, Language.fromExtension(".rs").?);
    try std.testing.expectEqual(Language.bash, Language.fromExtension(".sh").?);
    try std.testing.expectEqual(Language.lua, Language.fromExtension(".lua").?);
    try std.testing.expectEqual(Language.haskell, Language.fromExtension(".hs").?);
    try std.testing.expectEqual(Language.go, Language.fromExtension(".go").?);
    try std.testing.expectEqual(Language.ruby, Language.fromExtension(".rb").?);
    try std.testing.expectEqual(Language.erlang, Language.fromExtension(".erl").?);
    try std.testing.expectEqual(Language.erlang, Language.fromExtension(".hrl").?);
    try std.testing.expectEqual(Language.ocaml, Language.fromExtension(".ml").?);
    try std.testing.expectEqual(Language.swift, Language.fromExtension(".swift").?);
    try std.testing.expectEqual(Language.llvm, Language.fromExtension(".ll").?);
    try std.testing.expectEqual(Language.clojure, Language.fromExtension(".clj").?);
    try std.testing.expectEqual(Language.clojure, Language.fromExtension(".cljs").?);
    try std.testing.expectEqual(Language.clojure, Language.fromExtension(".cljc").?);
    try std.testing.expectEqual(Language.clojure, Language.fromExtension(".edn").?);
    try std.testing.expectEqual(Language.assembly, Language.fromExtension(".s").?);
    try std.testing.expectEqual(Language.assembly, Language.fromExtension(".S").?);
    try std.testing.expectEqual(Language.assembly, Language.fromExtension(".asm").?);
    try std.testing.expectEqual(Language.wat, Language.fromExtension(".wat").?);
    try std.testing.expectEqual(Language.wat, Language.fromExtension(".wast").?);
    try std.testing.expect(Language.fromExtension(".zig") == null); // Zig uses native AST
    try std.testing.expect(Language.fromExtension(".xyz") == null);
}

test "language detection from shebang" {
    // bash variants
    try std.testing.expectEqual(Language.bash, Language.fromShebang("#!/bin/bash\nexit 0\n").?);
    try std.testing.expectEqual(Language.bash, Language.fromShebang("#!/usr/bin/env bash\nexit 0\n").?);
    try std.testing.expectEqual(Language.bash, Language.fromShebang("#!/bin/sh\nexit 0\n").?);
    try std.testing.expectEqual(Language.bash, Language.fromShebang("#!/usr/bin/env zsh\nexit 0\n").?);

    // lua
    try std.testing.expectEqual(Language.lua, Language.fromShebang("#!/usr/bin/env lua\nprint('hi')\n").?);
    try std.testing.expectEqual(Language.lua, Language.fromShebang("#!/usr/bin/env luajit\nprint('hi')\n").?);

    // node/JS → typescript parser
    try std.testing.expectEqual(Language.typescript, Language.fromShebang("#!/usr/bin/env node\nconsole.log('hi')\n").?);
    try std.testing.expectEqual(Language.typescript, Language.fromShebang("#!/usr/bin/env deno\n").?);
    try std.testing.expectEqual(Language.typescript, Language.fromShebang("#!/usr/bin/env bun\n").?);

    // ruby
    try std.testing.expectEqual(Language.ruby, Language.fromShebang("#!/usr/bin/env ruby\nputs 'hi'\n").?);
    try std.testing.expectEqual(Language.ruby, Language.fromShebang("#!/usr/bin/ruby\n").?);

    // no shebang
    try std.testing.expect(Language.fromShebang("no shebang here\n") == null);
    try std.testing.expect(Language.fromShebang("") == null);

    // unknown interpreter
    try std.testing.expect(Language.fromShebang("#!/usr/bin/env python3\nimport sys\n") == null);
}

test "semantic symbol trees cover Lisp forms, native Oil, and WAT" {
    const allocator = std.testing.allocator;
    const cases = .{
        .{ Language.scheme, "(define (walk-tree node)\n  node)\n", "walk-tree", @as(usize, 2) },
        .{ Language.racket, "(define-syntax route-table\n  (syntax-rules ()))\n", "route-table", @as(usize, 2) },
        .{ Language.common_lisp, "(defun rotate-cache (cache)\n  cache)\n", "rotate-cache", @as(usize, 2) },
        .{ Language.oil, "proc publish_release() {\n  echo done\n}\n", "publish_release", @as(usize, 3) },
        .{ Language.wat, "(func $decode_packet (param i32)\n  local.get 0)\n", "$decode_packet", @as(usize, 2) },
    };

    inline for (cases) |case| {
        var tree = try extract(allocator, case[1], case[0]);
        defer tree.deinit(allocator);
        try std.testing.expect(tree.symbols.len >= 1);
        try std.testing.expectEqualStrings(case[2], tree.symbols[0].name);
        try std.testing.expectEqual(case[3], tree.symbols[0].end_line);
    }
}

test "go: extracts function and type" {
    const allocator = std.testing.allocator;
    const source =
        \\package main
        \\
        \\func Add(a, b int) int {
        \\    return a + b
        \\}
        \\
        \\type Point struct {
        \\    X int
        \\    Y int
        \\}
    ;
    var tree = try extract(allocator, source, .go);
    defer tree.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), tree.symbols.len);
    try std.testing.expectEqualStrings("Add", tree.symbols[0].name);
    try std.testing.expectEqual(SymbolKind.function, tree.symbols[0].kind);
    try std.testing.expectEqualStrings("Point", tree.symbols[1].name);
    try std.testing.expectEqual(SymbolKind.type_alias, tree.symbols[1].kind);
}

test "ruby: extracts class with methods" {
    const allocator = std.testing.allocator;
    const source =
        \\class Greeter
        \\  def greet
        \\    puts "hello"
        \\  end
        \\
        \\  def self.create
        \\    new
        \\  end
        \\end
    ;
    var tree = try extract(allocator, source, .ruby);
    defer tree.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), tree.symbols.len);
    try std.testing.expectEqualStrings("Greeter", tree.symbols[0].name);
    try std.testing.expectEqual(SymbolKind.class, tree.symbols[0].kind);
    try std.testing.expectEqual(@as(usize, 2), tree.symbols[0].children.len);
    try std.testing.expectEqualStrings("greet", tree.symbols[0].children[0].name);
    try std.testing.expectEqualStrings("create", tree.symbols[0].children[1].name);
}

test "erlang: extracts function" {
    const allocator = std.testing.allocator;
    const source =
        \\-module(hello).
        \\
        \\greet() ->
        \\    io:format("hello~n").
        \\
        \\add(A, B) ->
        \\    A + B.
    ;
    var tree = try extract(allocator, source, .erlang);
    defer tree.deinit(allocator);

    try std.testing.expect(tree.symbols.len >= 2);
    try std.testing.expectEqualStrings("greet", tree.symbols[0].name);
    try std.testing.expectEqual(SymbolKind.function, tree.symbols[0].kind);
    try std.testing.expectEqualStrings("add", tree.symbols[1].name);
}

test "ocaml: extracts let binding and type" {
    const allocator = std.testing.allocator;
    const source =
        \\let greet name =
        \\  print_endline ("Hello " ^ name)
        \\
        \\type point = { x: int; y: int }
    ;
    var tree = try extract(allocator, source, .ocaml);
    defer tree.deinit(allocator);

    try std.testing.expect(tree.symbols.len >= 2);
    try std.testing.expectEqualStrings("greet", tree.symbols[0].name);
    try std.testing.expectEqual(SymbolKind.function, tree.symbols[0].kind);
    try std.testing.expectEqualStrings("point", tree.symbols[1].name);
    try std.testing.expectEqual(SymbolKind.type_alias, tree.symbols[1].kind);
}

test "swift: extracts function and class" {
    const allocator = std.testing.allocator;
    const source =
        \\func greet(name: String) -> String {
        \\    return "Hello, " + name
        \\}
        \\
        \\class Greeter {
        \\    func sayHi() {}
        \\}
    ;
    var tree = try extract(allocator, source, .swift);
    defer tree.deinit(allocator);

    try std.testing.expect(tree.symbols.len >= 2);
    try std.testing.expectEqualStrings("greet", tree.symbols[0].name);
    try std.testing.expectEqual(SymbolKind.function, tree.symbols[0].kind);
    try std.testing.expectEqualStrings("Greeter", tree.symbols[1].name);
    try std.testing.expectEqual(SymbolKind.class, tree.symbols[1].kind);
}

test "llvm: extracts function and global" {
    const allocator = std.testing.allocator;
    const source =
        \\@msg = constant [6 x i8] c"hello\00"
        \\
        \\%Point = type { i32, i32 }
        \\
        \\define i32 @add(i32 %a, i32 %b) {
        \\entry:
        \\  %sum = add i32 %a, %b
        \\  ret i32 %sum
        \\}
        \\
        \\declare void @printf(ptr, ...)
    ;
    var tree = try extract(allocator, source, .llvm);
    defer tree.deinit(allocator);

    try std.testing.expect(tree.symbols.len >= 3);
    try std.testing.expectEqualStrings("@msg", tree.symbols[0].name);
    try std.testing.expectEqual(SymbolKind.variable, tree.symbols[0].kind);
    try std.testing.expectEqualStrings("%Point", tree.symbols[1].name);
    try std.testing.expectEqual(SymbolKind.type_alias, tree.symbols[1].kind);
    try std.testing.expectEqualStrings("@add", tree.symbols[2].name);
    try std.testing.expectEqual(SymbolKind.function, tree.symbols[2].kind);
}

test "llvm: define function captures full body range" {
    const allocator = std.testing.allocator;
    const source =
        \\define i32 @add(i32 %a, i32 %b) {
        \\entry:
        \\  %sum = add i32 %a, %b
        \\  ret i32 %sum
        \\}
    ;
    var tree = try extract(allocator, source, .llvm);
    defer tree.deinit(allocator);

    try std.testing.expect(tree.symbols.len >= 1);
    try std.testing.expectEqualStrings("@add", tree.symbols[0].name);
    try std.testing.expectEqual(SymbolKind.function, tree.symbols[0].kind);
    // Lines are 1-indexed: define on line 1, closing } on line 5
    // Before the fix (function_header), both would be 1 (single-line)
    try std.testing.expectEqual(@as(u32, 1), tree.symbols[0].start_line);
    try std.testing.expect(tree.symbols[0].end_line > tree.symbols[0].start_line);
    try std.testing.expectEqual(@as(u32, 5), tree.symbols[0].end_line);
}

test "llvm: declare functions are extracted" {
    const allocator = std.testing.allocator;
    const source =
        \\declare void @printf(ptr, ...)
        \\declare i32 @puts(ptr)
    ;
    var tree = try extract(allocator, source, .llvm);
    defer tree.deinit(allocator);

    try std.testing.expect(tree.symbols.len >= 2);
    try std.testing.expectEqualStrings("@printf", tree.symbols[0].name);
    try std.testing.expectEqual(SymbolKind.function, tree.symbols[0].kind);
    try std.testing.expectEqualStrings("@puts", tree.symbols[1].name);
    try std.testing.expectEqual(SymbolKind.function, tree.symbols[1].kind);
}

test "clojure: extracts defn, def, defmacro, ns" {
    const allocator = std.testing.allocator;
    const source =
        \\(ns myapp.core)
        \\
        \\(def max-retries 3)
        \\
        \\(defn greet [name]
        \\  (str "Hello, " name))
        \\
        \\(defmacro when-let [bindings & body]
        \\  `(let [~(first bindings) ~(second bindings)]
        \\     (when ~(first bindings)
        \\       ~@body)))
    ;
    var tree = try extract(allocator, source, .clojure);
    defer tree.deinit(allocator);

    try std.testing.expect(tree.symbols.len >= 4);

    // ns
    try std.testing.expectEqualStrings("myapp.core", tree.symbols[0].name);
    try std.testing.expectEqual(SymbolKind.module, tree.symbols[0].kind);

    // def
    try std.testing.expectEqualStrings("max-retries", tree.symbols[1].name);
    try std.testing.expectEqual(SymbolKind.variable, tree.symbols[1].kind);

    // defn — should span multiple lines
    try std.testing.expectEqualStrings("greet", tree.symbols[2].name);
    try std.testing.expectEqual(SymbolKind.function, tree.symbols[2].kind);
    try std.testing.expect(tree.symbols[2].end_line > tree.symbols[2].start_line);

    // defmacro
    try std.testing.expectEqualStrings("when-let", tree.symbols[3].name);
    try std.testing.expectEqual(SymbolKind.function, tree.symbols[3].kind);
}

test "clojure: extracts defprotocol, defrecord, defmulti" {
    const allocator = std.testing.allocator;
    const source =
        \\(defprotocol Greetable
        \\  (greet [this]))
        \\
        \\(defrecord Person [name age])
        \\
        \\(defmulti area :shape)
    ;
    var tree = try extract(allocator, source, .clojure);
    defer tree.deinit(allocator);

    try std.testing.expect(tree.symbols.len >= 3);

    try std.testing.expectEqualStrings("Greetable", tree.symbols[0].name);
    try std.testing.expectEqual(SymbolKind.interface, tree.symbols[0].kind);

    try std.testing.expectEqualStrings("Person", tree.symbols[1].name);
    try std.testing.expectEqual(SymbolKind.struct_decl, tree.symbols[1].kind);

    try std.testing.expectEqualStrings("area", tree.symbols[2].name);
    try std.testing.expectEqual(SymbolKind.function, tree.symbols[2].kind);
}

test "assembly: extracts labels and constants" {
    const allocator = std.testing.allocator;
    const source =
        \\.global _start
        \\
        \\const MAX_SIZE 1024
        \\
        \\_start:
        \\  mov rax, 60
        \\  xor rdi, rdi
        \\  syscall
        \\
        \\helper:
        \\  ret
    ;
    var tree = try extract(allocator, source, .assembly);
    defer tree.deinit(allocator);

    // Should extract labels and constants
    try std.testing.expect(tree.symbols.len >= 3);

    try std.testing.expectEqualStrings("MAX_SIZE", tree.symbols[0].name);
    try std.testing.expectEqual(SymbolKind.variable, tree.symbols[0].kind);

    try std.testing.expectEqualStrings("_start", tree.symbols[1].name);
    try std.testing.expectEqual(SymbolKind.function, tree.symbols[1].kind);

    try std.testing.expectEqualStrings("helper", tree.symbols[2].name);
    try std.testing.expectEqual(SymbolKind.function, tree.symbols[2].kind);
}
