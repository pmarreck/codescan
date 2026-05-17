const std = @import("std");
const model = @import("model.zig");
const LineIndex = @import("line_index.zig").LineIndex;

pub fn extract(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	source: []const u8,
) ![]model.Symbol {
	const source_z = try allocator.dupeZ(u8, source);
	defer allocator.free(source_z);

	var tree = try std.zig.Ast.parse(allocator, source_z, .zig);
	defer tree.deinit(allocator);

	// Build line-offset table once — O(n) — then O(log n) per lookup
	var line_idx = try LineIndex.build(allocator, source);
	defer line_idx.deinit(allocator);

	var results = @as(std.ArrayListUnmanaged(model.Symbol), .empty);
	errdefer {
		for (results.items) |*sym| sym.deinit(allocator);
		results.deinit(allocator);
	}

	const tags = tree.nodes.items(.tag);
	var fn_buffer: [1]std.zig.Ast.Node.Index = undefined;
	for (tags, 0..) |tag, idx| {
		const node: std.zig.Ast.Node.Index = @enumFromInt(@as(u32, @intCast(idx)));

		if (tag == .fn_decl) {
			const fn_proto = tree.fullFnProto(&fn_buffer, node) orelse continue;
			const name_token = fn_proto.name_token orelse continue;

			const name = tree.tokenSlice(name_token);
			const signature = try extractFnSignature(allocator, tree, node);
			const doc_comment = try extractDocComment(allocator, tree, fn_proto.firstToken());

			const start_tok = tree.firstToken(node);
			const end_tok = tree.lastToken(node);
			const start_line = line_idx.lineForOffset(tree.tokenStart(start_tok));
			const end_line = line_idx.lineForOffset(tree.tokenStart(end_tok));

			const symbol = model.Symbol{
				.language = try allocator.dupe(u8, "zig"),
				.file_path = try allocator.dupe(u8, file_path),
				.name = try allocator.dupe(u8, name),
				.signature = signature,
				.doc_comment = doc_comment,
				.start_line = start_line + 1,
				.end_line = end_line + 1,
			};
			try results.append(allocator, symbol);
		} else if (tag == .simple_var_decl or tag == .global_var_decl or tag == .aligned_var_decl) {
			if (try extractVarDecl(allocator, file_path, tree, node, tag, line_idx)) |symbol| {
				try results.append(allocator, symbol);
			}
		}
	}

	return results.toOwnedSlice(allocator);
}

fn extractFnSignature(
	allocator: std.mem.Allocator,
	tree: std.zig.Ast,
	node: std.zig.Ast.Node.Index,
) ![]const u8 {
	const start_tok = tree.firstToken(node);
	const body_node = tree.nodeData(node).node_and_node[1];
	const body_tok = tree.firstToken(body_node);
	const start_byte = tree.tokenStart(start_tok);
	const end_byte = tree.tokenStart(body_tok);
	const slice = std.mem.trimEnd(u8, tree.source[start_byte..end_byte], " \t\r\n");
	return allocator.dupe(u8, slice);
}

fn extractVarDecl(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	tree: std.zig.Ast,
	node: std.zig.Ast.Node.Index,
	tag: std.zig.Ast.Node.Tag,
	line_idx: LineIndex,
) !?model.Symbol {
	const var_decl = switch (tag) {
		.simple_var_decl => tree.simpleVarDecl(node),
		.global_var_decl => tree.globalVarDecl(node),
		.aligned_var_decl => tree.alignedVarDecl(node),
		else => return null,
	};
	const name_token_idx = var_decl.ast.mut_token + 1;
	if (tree.tokenTag(name_token_idx) != .identifier) return null;

	const name = tree.tokenSlice(name_token_idx);

	// Build signature from the first line of the declaration
	const start_tok = tree.firstToken(node);
	const end_tok = tree.lastToken(node);
	const start_line = line_idx.lineForOffset(tree.tokenStart(start_tok));
	const end_line = line_idx.lineForOffset(tree.tokenStart(end_tok));
	const start_byte = tree.tokenStart(start_tok);

	// Get the first line of the decl for the signature
	const remaining = tree.source[start_byte..];
	const newline_pos = std.mem.indexOfScalar(u8, remaining, '\n') orelse remaining.len;
	const first_line = std.mem.trimEnd(u8, remaining[0..newline_pos], " \t\r{");
	const signature = try allocator.dupe(u8, first_line);

	const doc_comment = try extractDocComment(allocator, tree, start_tok);

	return model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, file_path),
		.name = try allocator.dupe(u8, name),
		.signature = signature,
		.doc_comment = doc_comment,
		.start_line = start_line + 1,
		.end_line = end_line + 1,
	};
}

fn extractDocComment(
	allocator: std.mem.Allocator,
	tree: std.zig.Ast,
	start_token: std.zig.Ast.TokenIndex,
) !?[]const u8 {
	if (start_token == 0) return null;
	var tok: std.zig.Ast.TokenIndex = start_token - 1;
	var lines = @as(std.ArrayListUnmanaged([]const u8), .empty);
	defer lines.deinit(allocator);

	while (true) : (tok -= 1) {
		if (tree.tokenTag(tok) != .doc_comment) break;
		try lines.append(allocator, cleanDocLine(tree.tokenSlice(tok)));
		if (tok == 0) break;
	}

	if (lines.items.len == 0) return null;

	var out: std.Io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	var i: usize = lines.items.len;
	while (i > 0) : (i -= 1) {
		if (i != lines.items.len) {
			try out.writer.writeAll("\n");
		}
		try out.writer.writeAll(lines.items[i - 1]);
	}

	const owned = try out.toOwnedSlice();
	return @as(?[]const u8, owned);
}

fn cleanDocLine(raw: []const u8) []const u8 {
	var line = raw;
	if (std.mem.startsWith(u8, line, "///")) {
		line = line[3..];
	} else if (std.mem.startsWith(u8, line, "//!")) {
		line = line[3..];
	}
	return std.mem.trimStart(u8, line, " \t");
}

test "extract finds zig enums" {
	const allocator = std.testing.allocator;
	const source =
		"/// Output format\n" ++
		"pub const OutputFormat = enum {\n" ++
		"    human,\n" ++
		"    json,\n" ++
		"};\n";

	const symbols = try extract(allocator, "src/cli.zig", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expectEqual(@as(usize, 1), symbols.len);
	try std.testing.expectEqualStrings("OutputFormat", symbols[0].name);
	try std.testing.expectEqualStrings("Output format", symbols[0].doc_comment.?);
}

test "extract finds zig structs" {
	const allocator = std.testing.allocator;
	const source =
		"pub const Options = struct {\n" ++
		"    top_n: usize = 10,\n" ++
		"    mode: SearchMode = .hybrid,\n" ++
		"};\n";

	const symbols = try extract(allocator, "src/search.zig", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expectEqual(@as(usize, 1), symbols.len);
	try std.testing.expectEqualStrings("Options", symbols[0].name);
}

test "extract finds zig constants" {
	const allocator = std.testing.allocator;
	const source =
		"pub const MAX_SIZE: usize = 1024;\n" ++
		"const DEFAULT_NAME = \"hello\";\n";

	const symbols = try extract(allocator, "src/config.zig", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expectEqual(@as(usize, 2), symbols.len);
	try std.testing.expectEqualStrings("MAX_SIZE", symbols[0].name);
	try std.testing.expectEqualStrings("DEFAULT_NAME", symbols[1].name);
}

test "extract finds zig functions" {
	const allocator = std.testing.allocator;
	const source =
		"/// Adds two ints\n" ++
		"pub fn add(a: i32, b: i32) i32 {\n" ++
		"    return a + b;\n" ++
		"}\n" ++
		"\n" ++
		"fn hidden() void {}\n";

	const symbols = try extract(allocator, "src/math.zig", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expectEqual(@as(usize, 2), symbols.len);
	try std.testing.expectEqualStrings("add", symbols[0].name);
	try std.testing.expectEqualStrings("Adds two ints", symbols[0].doc_comment.?);
	try std.testing.expectEqual(@as(usize, 2), symbols[0].start_line);
	try std.testing.expectEqual(@as(usize, 4), symbols[0].end_line);
}
