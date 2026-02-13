const std = @import("std");
const hashline = @import("hashline.zig");
const LineIndex = @import("line_index.zig").LineIndex;

// ─── Types ───────────────────────────────────────────────────────────

/// Symbol kinds for classification in the symbol tree.
pub const SymbolKind = enum {
	function,
	struct_decl,
	enum_decl,
	union_decl,
	class,
	interface,
	trait_decl,
	impl_block,
	constant,
	variable,
	field,
	test_decl,
	module,
	type_alias,

	pub fn label(self: SymbolKind) []const u8 {
		return switch (self) {
			.function => "fn",
			.struct_decl => "struct",
			.enum_decl => "enum",
			.union_decl => "union",
			.class => "class",
			.interface => "interface",
			.trait_decl => "trait",
			.impl_block => "impl",
			.constant => "const",
			.variable => "var",
			.field => "field",
			.test_decl => "test",
			.module => "mod",
			.type_alias => "type",
		};
	}
};

/// A node in the symbol tree. Supports hierarchy (e.g. struct with methods).
pub const SymbolNode = struct {
	name: []const u8,
	kind: SymbolKind,
	start_line: usize, // 1-indexed
	end_line: usize, // 1-indexed
	start_byte: usize,
	end_byte: usize,
	children: []SymbolNode,

	pub fn deinit(self: *SymbolNode, allocator: std.mem.Allocator) void {
		for (self.children) |*child| child.deinit(allocator);
		allocator.free(self.children);
		allocator.free(self.name);
	}

	/// Build the full name path from root (e.g. "MyStruct/init").
	pub fn namePath(self: SymbolNode, allocator: std.mem.Allocator, parent_path: ?[]const u8) ![]const u8 {
		if (parent_path) |pp| {
			return std.fmt.allocPrint(allocator, "{s}/{s}", .{ pp, self.name });
		}
		return allocator.dupe(u8, self.name);
	}
};

/// Root container for symbol tree extracted from a single file.
pub const SymbolTree = struct {
	symbols: []SymbolNode,

	pub fn deinit(self: *SymbolTree, allocator: std.mem.Allocator) void {
		for (self.symbols) |*sym| sym.deinit(allocator);
		allocator.free(self.symbols);
	}
};

// ─── Zig Extraction ──────────────────────────────────────────────────

const Ast = std.zig.Ast;

/// Extract a hierarchical symbol tree from Zig source using the native AST.
pub fn extractZig(allocator: std.mem.Allocator, source: []const u8) !SymbolTree {
	const source_z = try allocator.dupeZ(u8, source);
	defer allocator.free(source_z);

	var tree = try Ast.parse(allocator, source_z, .zig);
	defer tree.deinit(allocator);

	// Build line-offset table once — O(n) — then O(log n) per lookup
	var line_idx = try LineIndex.build(allocator, source);
	defer line_idx.deinit(allocator);

	const root_decls = tree.rootDecls();
	var symbols = std.ArrayListUnmanaged(SymbolNode){};
	errdefer {
		for (symbols.items) |*sym| sym.deinit(allocator);
		symbols.deinit(allocator);
	}

	for (root_decls) |decl_idx| {
		if (try extractZigNode(allocator, &tree, decl_idx, line_idx)) |sym| {
			try symbols.append(allocator, sym);
		}
	}

	return .{ .symbols = try symbols.toOwnedSlice(allocator) };
}

const ZigExtractError = std.mem.Allocator.Error;

fn extractZigNode(allocator: std.mem.Allocator, tree: *const Ast, node: Ast.Node.Index, line_idx: LineIndex) ZigExtractError!?SymbolNode {
	return switch (tree.nodeTag(node)) {
		.fn_decl => try extractZigFn(allocator, tree, node, line_idx),
		.simple_var_decl => try extractZigVarDecl(allocator, tree, node, .simple, line_idx),
		.global_var_decl => try extractZigVarDecl(allocator, tree, node, .global, line_idx),
		.aligned_var_decl => try extractZigVarDecl(allocator, tree, node, .aligned, line_idx),
		.test_decl => try extractZigTest(allocator, tree, node, line_idx),
		else => null,
	};
}

const VarDeclKind = enum { simple, global, aligned };

fn extractZigVarDecl(
	allocator: std.mem.Allocator,
	tree: *const Ast,
	node: Ast.Node.Index,
	var_kind: VarDeclKind,
	line_idx: LineIndex,
) ZigExtractError!?SymbolNode {
	const var_decl = switch (var_kind) {
		.simple => tree.simpleVarDecl(node),
		.global => tree.globalVarDecl(node),
		.aligned => tree.alignedVarDecl(node),
	};
	const name_token_idx = var_decl.ast.mut_token + 1;

	if (tree.tokenTag(name_token_idx) != .identifier) return null;

	const name = try allocator.dupe(u8, tree.tokenSlice(name_token_idx));
	errdefer allocator.free(name);

	const start_tok = tree.firstToken(node);
	const end_tok = tree.lastToken(node);
	const start_line = line_idx.lineForOffset(tree.tokenStart(start_tok));
	const end_line = line_idx.lineForOffset(tree.tokenStart(end_tok));
	const start_byte: usize = tree.tokenStart(start_tok);
	const end_byte: usize = tree.tokenStart(end_tok) + tree.tokenSlice(end_tok).len;

	// Check if init is a container type (struct/enum/union)
	if (var_decl.ast.init_node.unwrap()) |init_idx| {
		var buf2: [2]Ast.Node.Index = undefined;
		if (tree.fullContainerDecl(&buf2, init_idx)) |container| {
			const kind = zigContainerKind(tree, container);
			const children = try extractZigContainerMembers(allocator, tree, container, line_idx);
			errdefer {
				for (children) |*c| @constCast(c).deinit(allocator);
				allocator.free(children);
			}
			return .{
				.name = name,
				.kind = kind,
				.start_line = start_line + 1,
				.end_line = end_line + 1,
				.start_byte = start_byte,
				.end_byte = end_byte,
				.children = children,
			};
		}
	}

	const is_const = tree.tokenTag(var_decl.ast.mut_token) == .keyword_const;
	return .{
		.name = name,
		.kind = if (is_const) .constant else .variable,
		.start_line = start_line + 1,
		.end_line = end_line + 1,
		.start_byte = start_byte,
		.end_byte = end_byte,
		.children = try allocator.alloc(SymbolNode, 0),
	};
}

fn extractZigFn(allocator: std.mem.Allocator, tree: *const Ast, node: Ast.Node.Index, line_idx: LineIndex) ZigExtractError!?SymbolNode {
	var buffer: [1]Ast.Node.Index = undefined;
	const fn_proto = tree.fullFnProto(&buffer, node) orelse return null;
	const name_token = fn_proto.name_token orelse return null;

	const name = try allocator.dupe(u8, tree.tokenSlice(name_token));
	errdefer allocator.free(name);

	const start_tok = tree.firstToken(node);
	const end_tok = tree.lastToken(node);
	const start_line = line_idx.lineForOffset(tree.tokenStart(start_tok));
	const end_line = line_idx.lineForOffset(tree.tokenStart(end_tok));
	const start_byte: usize = tree.tokenStart(start_tok);
	const end_byte: usize = tree.tokenStart(end_tok) + tree.tokenSlice(end_tok).len;

	return .{
		.name = name,
		.kind = .function,
		.start_line = start_line + 1,
		.end_line = end_line + 1,
		.start_byte = start_byte,
		.end_byte = end_byte,
		.children = try allocator.alloc(SymbolNode, 0),
	};
}

fn extractZigTest(allocator: std.mem.Allocator, tree: *const Ast, node: Ast.Node.Index, line_idx: LineIndex) ZigExtractError!?SymbolNode {
	const data = tree.nodeData(node).opt_token_and_node;

	var name: []const u8 = "(anonymous)";
	if (data[0].unwrap()) |name_token| {
		const raw = tree.tokenSlice(name_token);
		// Strip quotes from string literal
		if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') {
			name = raw[1 .. raw.len - 1];
		} else {
			name = raw;
		}
	}

	const owned_name = try allocator.dupe(u8, name);
	errdefer allocator.free(owned_name);

	const start_tok = tree.firstToken(node);
	const end_tok = tree.lastToken(node);
	const start_line = line_idx.lineForOffset(tree.tokenStart(start_tok));
	const end_line = line_idx.lineForOffset(tree.tokenStart(end_tok));
	const start_byte: usize = tree.tokenStart(start_tok);
	const end_byte: usize = tree.tokenStart(end_tok) + tree.tokenSlice(end_tok).len;

	return .{
		.name = owned_name,
		.kind = .test_decl,
		.start_line = start_line + 1,
		.end_line = end_line + 1,
		.start_byte = start_byte,
		.end_byte = end_byte,
		.children = try allocator.alloc(SymbolNode, 0),
	};
}

fn zigContainerKind(tree: *const Ast, container: Ast.full.ContainerDecl) SymbolKind {
	return switch (tree.tokenTag(container.ast.main_token)) {
		.keyword_struct => .struct_decl,
		.keyword_enum => .enum_decl,
		.keyword_union => .union_decl,
		else => .constant,
	};
}

fn extractZigContainerMembers(allocator: std.mem.Allocator, tree: *const Ast, container: Ast.full.ContainerDecl, line_idx: LineIndex) ZigExtractError![]SymbolNode {
	var children = std.ArrayListUnmanaged(SymbolNode){};
	errdefer {
		for (children.items) |*child| child.deinit(allocator);
		children.deinit(allocator);
	}

	for (container.ast.members) |member_idx| {
		if (try extractZigNode(allocator, tree, member_idx, line_idx)) |child| {
			try children.append(allocator, child);
		}
	}

	return children.toOwnedSlice(allocator);
}

// ─── Formatting ──────────────────────────────────────────────────────

/// Format a symbol tree as human-readable hierarchical output.
pub fn formatTree(symbols: []const SymbolNode, writer: anytype) !void {
	for (symbols) |sym| {
		try formatSymbolNode(&sym, writer, 0);
	}
}

fn formatSymbolNode(sym: *const SymbolNode, writer: anytype, depth: usize) !void {
	// Indent
	for (0..depth) |_| try writer.writeAll("  ");

	if (sym.start_line == sym.end_line) {
		try writer.print("{s} {s} ({d})\n", .{ sym.kind.label(), sym.name, sym.start_line });
	} else {
		try writer.print("{s} {s} ({d}-{d})\n", .{ sym.kind.label(), sym.name, sym.start_line, sym.end_line });
	}

	for (sym.children) |*child| {
		try formatSymbolNode(child, writer, depth + 1);
	}
}

// ─── Tests ───────────────────────────────────────────────────────────

test "zig: extracts top-level functions" {
	const allocator = std.testing.allocator;
	const source =
		\\pub fn add(a: i32, b: i32) i32 {
		\\    return a + b;
		\\}
		\\
		\\fn hidden() void {}
	;
	var tree = try extractZig(allocator, source);
	defer tree.deinit(allocator);

	try std.testing.expectEqual(@as(usize, 2), tree.symbols.len);
	try std.testing.expectEqualStrings("add", tree.symbols[0].name);
	try std.testing.expectEqual(SymbolKind.function, tree.symbols[0].kind);
	try std.testing.expectEqual(@as(usize, 1), tree.symbols[0].start_line);
	try std.testing.expectEqual(@as(usize, 3), tree.symbols[0].end_line);
	try std.testing.expectEqualStrings("hidden", tree.symbols[1].name);
}

test "zig: extracts struct with methods" {
	const allocator = std.testing.allocator;
	const source =
		\\pub const MyStruct = struct {
		\\    count: usize,
		\\
		\\    pub fn init() MyStruct {
		\\        return .{ .count = 0 };
		\\    }
		\\
		\\    pub fn increment(self: *MyStruct) void {
		\\        self.count += 1;
		\\    }
		\\};
	;
	var tree = try extractZig(allocator, source);
	defer tree.deinit(allocator);

	try std.testing.expectEqual(@as(usize, 1), tree.symbols.len);
	try std.testing.expectEqualStrings("MyStruct", tree.symbols[0].name);
	try std.testing.expectEqual(SymbolKind.struct_decl, tree.symbols[0].kind);
	try std.testing.expectEqual(@as(usize, 1), tree.symbols[0].start_line);
	try std.testing.expectEqual(@as(usize, 11), tree.symbols[0].end_line);

	// Should have 2 method children
	try std.testing.expectEqual(@as(usize, 2), tree.symbols[0].children.len);
	try std.testing.expectEqualStrings("init", tree.symbols[0].children[0].name);
	try std.testing.expectEqualStrings("increment", tree.symbols[0].children[1].name);
}

test "zig: extracts enum" {
	const allocator = std.testing.allocator;
	const source =
		\\pub const Color = enum {
		\\    red,
		\\    green,
		\\    blue,
		\\};
	;
	var tree = try extractZig(allocator, source);
	defer tree.deinit(allocator);

	try std.testing.expectEqual(@as(usize, 1), tree.symbols.len);
	try std.testing.expectEqualStrings("Color", tree.symbols[0].name);
	try std.testing.expectEqual(SymbolKind.enum_decl, tree.symbols[0].kind);
}

test "zig: extracts test declarations" {
	const allocator = std.testing.allocator;
	const source =
		\\test "basic addition" {
		\\    try std.testing.expectEqual(2 + 2, 4);
		\\}
	;
	var tree = try extractZig(allocator, source);
	defer tree.deinit(allocator);

	try std.testing.expectEqual(@as(usize, 1), tree.symbols.len);
	try std.testing.expectEqualStrings("basic addition", tree.symbols[0].name);
	try std.testing.expectEqual(SymbolKind.test_decl, tree.symbols[0].kind);
}

test "zig: extracts standalone constants (non-container)" {
	const allocator = std.testing.allocator;
	const source =
		\\pub const MAX_SIZE = 1024;
		\\const default_name = "hello";
	;
	var tree = try extractZig(allocator, source);
	defer tree.deinit(allocator);

	try std.testing.expectEqual(@as(usize, 2), tree.symbols.len);
	try std.testing.expectEqualStrings("MAX_SIZE", tree.symbols[0].name);
	try std.testing.expectEqual(SymbolKind.constant, tree.symbols[0].kind);
	try std.testing.expectEqualStrings("default_name", tree.symbols[1].name);
}

test "zig: empty source returns empty tree" {
	const allocator = std.testing.allocator;
	var tree = try extractZig(allocator, "");
	defer tree.deinit(allocator);

	try std.testing.expectEqual(@as(usize, 0), tree.symbols.len);
}

test "zig: mixed declarations" {
	const allocator = std.testing.allocator;
	const source =
		\\const std = @import("std");
		\\
		\\pub const Config = struct {
		\\    name: []const u8,
		\\
		\\    pub fn init() Config {
		\\        return .{ .name = "" };
		\\    }
		\\};
		\\
		\\pub fn run() void {}
		\\
		\\test "config works" {
		\\    _ = Config.init();
		\\}
	;
	var tree = try extractZig(allocator, source);
	defer tree.deinit(allocator);

	// std import + Config struct + run function + test
	try std.testing.expectEqual(@as(usize, 4), tree.symbols.len);
	try std.testing.expectEqualStrings("std", tree.symbols[0].name);
	try std.testing.expectEqual(SymbolKind.constant, tree.symbols[0].kind);
	try std.testing.expectEqualStrings("Config", tree.symbols[1].name);
	try std.testing.expectEqual(SymbolKind.struct_decl, tree.symbols[1].kind);
	try std.testing.expectEqual(@as(usize, 1), tree.symbols[1].children.len);
	try std.testing.expectEqualStrings("run", tree.symbols[2].name);
	try std.testing.expectEqual(SymbolKind.function, tree.symbols[2].kind);
	try std.testing.expectEqualStrings("config works", tree.symbols[3].name);
	try std.testing.expectEqual(SymbolKind.test_decl, tree.symbols[3].kind);
}

test "zig: byte ranges are populated" {
	const allocator = std.testing.allocator;
	const source =
		\\fn foo() void {}
	;
	var tree = try extractZig(allocator, source);
	defer tree.deinit(allocator);

	try std.testing.expectEqual(@as(usize, 1), tree.symbols.len);
	try std.testing.expectEqual(@as(usize, 0), tree.symbols[0].start_byte);
	try std.testing.expect(tree.symbols[0].end_byte > 0);
}

test "zig: name path generation" {
	const allocator = std.testing.allocator;
	const node = SymbolNode{
		.name = try allocator.dupe(u8, "init"),
		.kind = .function,
		.start_line = 1,
		.end_line = 3,
		.start_byte = 0,
		.end_byte = 30,
		.children = &.{},
	};
	defer allocator.free(node.name);

	const path1 = try node.namePath(allocator, null);
	defer allocator.free(path1);
	try std.testing.expectEqualStrings("init", path1);

	const path2 = try node.namePath(allocator, "MyStruct");
	defer allocator.free(path2);
	try std.testing.expectEqualStrings("MyStruct/init", path2);
}

test "formatTree produces hierarchical output" {
	const allocator = std.testing.allocator;
	const source =
		\\pub const Foo = struct {
		\\    pub fn bar() void {}
		\\};
		\\
		\\pub fn baz() void {}
	;
	var tree = try extractZig(allocator, source);
	defer tree.deinit(allocator);

	var buf: [1024]u8 = undefined;
	var fbs = std.io.fixedBufferStream(&buf);
	try formatTree(tree.symbols, fbs.writer());
	const result = fbs.getWritten();

	// Should contain the struct and its method indented
	try std.testing.expect(std.mem.indexOf(u8, result, "struct Foo") != null);
	try std.testing.expect(std.mem.indexOf(u8, result, "  fn bar") != null);
	try std.testing.expect(std.mem.indexOf(u8, result, "fn baz") != null);
}
