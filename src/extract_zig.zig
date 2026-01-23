const std = @import("std");
const model = @import("model.zig");

pub fn extract(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	source: []const u8,
) ![]model.Symbol {
	const source_z = try allocator.dupeZ(u8, source);
	defer allocator.free(source_z);

	var tree = try std.zig.Ast.parse(allocator, source_z, .zig);
	defer tree.deinit(allocator);

	var results = std.ArrayListUnmanaged(model.Symbol){};
	errdefer {
		for (results.items) |*sym| sym.deinit(allocator);
		results.deinit(allocator);
	}

	const tags = tree.nodes.items(.tag);
	var buffer: [1]std.zig.Ast.Node.Index = undefined;
	for (tags, 0..) |tag, idx| {
		if (tag != .fn_decl) continue;
		const node: std.zig.Ast.Node.Index = @enumFromInt(@as(u32, @intCast(idx)));
		const fn_proto = tree.fullFnProto(&buffer, node) orelse continue;
		const name_token = fn_proto.name_token orelse continue;

		const name = tree.tokenSlice(name_token);
		const signature = try extractSignature(allocator, tree, node);
		const doc_comment = try extractDocComment(allocator, tree, fn_proto.firstToken());

		const start_tok = tree.firstToken(node);
		const end_tok = tree.lastToken(node);
		const start_loc = tree.tokenLocation(0, start_tok);
		const end_loc = tree.tokenLocation(0, end_tok);

		const symbol = model.Symbol{
			.language = try allocator.dupe(u8, "zig"),
			.file_path = try allocator.dupe(u8, file_path),
			.name = try allocator.dupe(u8, name),
			.signature = signature,
			.doc_comment = doc_comment,
			.start_line = start_loc.line + 1,
			.end_line = end_loc.line + 1,
		};
		try results.append(allocator, symbol);
	}

	return results.toOwnedSlice(allocator);
}

fn extractSignature(
	allocator: std.mem.Allocator,
	tree: std.zig.Ast,
	node: std.zig.Ast.Node.Index,
) ![]const u8 {
	const start_tok = tree.firstToken(node);
	const body_node = tree.nodeData(node).node_and_node[1];
	const body_tok = tree.firstToken(body_node);
	const start_byte = tree.tokenStart(start_tok);
	const end_byte = tree.tokenStart(body_tok);
	const slice = std.mem.trimRight(u8, tree.source[start_byte..end_byte], " \t\r\n");
	return allocator.dupe(u8, slice);
}

fn extractDocComment(
	allocator: std.mem.Allocator,
	tree: std.zig.Ast,
	start_token: std.zig.Ast.TokenIndex,
) !?[]const u8 {
	if (start_token == 0) return null;
	var tok: std.zig.Ast.TokenIndex = start_token - 1;
	var lines = std.ArrayListUnmanaged([]const u8){};
	defer lines.deinit(allocator);

	while (true) : (tok -= 1) {
		if (tree.tokenTag(tok) != .doc_comment) break;
		try lines.append(allocator, cleanDocLine(tree.tokenSlice(tok)));
		if (tok == 0) break;
	}

	if (lines.items.len == 0) return null;

	var out: std.io.Writer.Allocating = .init(allocator);
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
	return std.mem.trimLeft(u8, line, " \t");
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
