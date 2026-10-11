const std = @import("std");
const model = @import("model.zig");
const util = @import("extract_util.zig");
const symbols = @import("symbol_tree.zig");
const ts_symbols = @import("ts_symbols.zig");

pub fn extract(allocator: std.mem.Allocator, file_path: []const u8, source: []const u8) ![]model.Symbol {
	var tree = try ts_symbols.extract(allocator, source, .roc);
	defer tree.deinit(allocator);
	var lines = try util.splitLines(allocator, source);
	defer lines.deinit(allocator);
	var out: std.ArrayListUnmanaged(model.Symbol) = .empty;
	errdefer {
		for (out.items) |*sym| sym.deinit(allocator);
		out.deinit(allocator);
	}
	try appendSymbols(allocator, &out, tree.symbols, null, file_path, source, lines.items);
	return out.toOwnedSlice(allocator);
}

fn appendSymbols(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(model.Symbol), nodes: []const symbols.SymbolNode, parent: ?[]const u8, file_path: []const u8, source: []const u8, lines: []const []const u8) anyerror!void {
	for (nodes) |node| {
		const name = try node.namePath(allocator, parent);
		defer allocator.free(name);
		var item = try makeSymbol(allocator, node, name, file_path, source, lines);
		out.append(allocator, item) catch |err| {
			item.deinit(allocator);
			return err;
		};
		try appendSymbols(allocator, out, node.children, name, file_path, source, lines);
	}
}

fn makeSymbol(allocator: std.mem.Allocator, node: symbols.SymbolNode, name: []const u8, file_path: []const u8, source: []const u8, lines: []const []const u8) !model.Symbol {
	const language = try allocator.dupe(u8, "roc");
	errdefer allocator.free(language);
	const path = try allocator.dupe(u8, file_path);
	errdefer allocator.free(path);
	const owned_name = try allocator.dupe(u8, name);
	errdefer allocator.free(owned_name);
	const text = source[node.start_byte..node.end_byte];
	const line_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
	var signature_end = line_end;
	const first_line = text[0..line_end];
	const after_name = if (std.mem.startsWith(u8, first_line, node.name)) std.mem.trimStart(u8, first_line[node.name.len..], " \t") else "";
	if (std.mem.startsWith(u8, after_name, ":") and !std.mem.startsWith(u8, after_name, "::") and !std.mem.startsWith(u8, after_name, ":=")) {
		var offset: usize = 0;
		var declaration_lines = std.mem.splitScalar(u8, text, '\n');
		while (declaration_lines.next()) |line| {
			const trimmed = std.mem.trim(u8, line, " \t\r");
			if (std.mem.startsWith(u8, trimmed, node.name)) {
				const rest = std.mem.trimStart(u8, trimmed[node.name.len..], " \t");
				if (std.mem.startsWith(u8, rest, "=") and !std.mem.startsWith(u8, rest, "=>")) {
					signature_end = offset;
					break;
				}
			}
			offset += line.len + 1;
		}
	}
	const signature = try allocator.dupe(u8, std.mem.trimEnd(u8, text[0..signature_end], "\n\r\t "));
	errdefer allocator.free(signature);
	const doc = try util.extractDocComment(allocator, lines, node.start_line - 1, .{ .line_prefixes = &.{ "##", "#" } });
	errdefer if (doc) |value| allocator.free(value);
	const kind = try allocator.dupe(u8, node.kind.label());
	errdefer allocator.free(kind);
	return .{
		.language = language,
		.file_path = path,
		.name = owned_name,
		.signature = signature,
		.doc_comment = doc,
		.symbol_kind = kind,
		.start_line = node.start_line,
		.end_line = node.end_line,
	};
}

test "Roc symbols cover associated methods, types, expectations, and UTF-8" {
	const source = "## A label\nLabel :: { text : Str }.{\n\t## Creates café labels\n\tnew : Str -> Label\n\tnew = |text| { text: text }\n\tNested := [Ready, Failed(Str)]\n}\n\nanswer = 42\nexpect answer == 42\n";
	const allocator = std.testing.allocator;
	const found = try extract(allocator, "Label.roc", source);
	defer {
		for (found) |*sym| sym.deinit(allocator);
		allocator.free(found);
	}
	try std.testing.expectEqual(@as(usize, 5), found.len);
	const names = [_][]const u8{ "Label", "Label/new", "Label/Nested", "answer", "expect answer == 42" };
	for (found, names) |sym, name| try std.testing.expectEqualStrings(name, sym.name);
	try std.testing.expectEqualStrings("Creates café labels", found[1].doc_comment.?);
	try std.testing.expectEqualStrings("new : Str -> Label", found[1].signature);
	try std.testing.expectEqual(@as(usize, 4), found[1].start_line);
	try std.testing.expectEqual(@as(usize, 5), found[1].end_line);
}

test "Roc ignores declarations inside comments and strings" {
	const source = "# fake = |x| x\ntext = \"fake = |x| x\"\nmultiline =\n\t\\\\wrong = |x| x\n";
	const allocator = std.testing.allocator;
	const found = try extract(allocator, "main.roc", source);
	defer {
		for (found) |*sym| sym.deinit(allocator);
		allocator.free(found);
	}
	try std.testing.expectEqual(@as(usize, 2), found.len);
	try std.testing.expectEqualStrings("text", found[0].name);
	try std.testing.expectEqualStrings("multiline", found[1].name);
}

test "Roc empty source has no symbols" {
	const allocator = std.testing.allocator;
	const found = try extract(allocator, "empty.roc", "");
	defer allocator.free(found);
	try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "Roc retains multiline annotations for signature queries" {
	const allocator = std.testing.allocator;
	const found = try extract(allocator, "Dec.roc", "ceil :\n\tDec\n\t-> Dec\nceil = |value| value\n");
	defer {
		for (found) |*sym| sym.deinit(allocator);
		allocator.free(found);
	}
	try std.testing.expectEqual(@as(usize, 1), found.len);
	try std.testing.expectEqualStrings("ceil :\n\tDec\n\t-> Dec", found[0].signature);
}

test "Roc unannotated record and string values retain their signatures" {
	const allocator = std.testing.allocator;
	const found = try extract(allocator, "values.roc", "record = { tag: \"foo\" }\nurl = \"https://example.invalid\"\n");
	defer {
		for (found) |*sym| sym.deinit(allocator);
		allocator.free(found);
	}
	try std.testing.expectEqual(@as(usize, 2), found.len);
	try std.testing.expectEqualStrings("record = { tag: \"foo\" }", found[0].signature);
	try std.testing.expectEqualStrings("url = \"https://example.invalid\"", found[1].signature);
}
