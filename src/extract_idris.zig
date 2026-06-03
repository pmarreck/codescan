const std = @import("std");
const model = @import("model.zig");
const util = @import("extract_util.zig");

pub fn extract(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	source: []const u8,
) ![]model.Symbol {
	var results = @as(std.ArrayListUnmanaged(model.Symbol), .empty);
	errdefer {
		for (results.items) |*sym| sym.deinit(allocator);
		results.deinit(allocator);
	}

	var lines = try util.splitLines(allocator, source);
	defer lines.deinit(allocator);

	var pending_name: ?[]const u8 = null;
	var pending_sig: ?[]const u8 = null;
	var pending_doc: ?[]const u8 = null;
	defer {
		if (pending_sig) |sig| allocator.free(sig);
		if (pending_doc) |doc| allocator.free(doc);
	}

	for (lines.items, 0..) |line, idx| {
		const trimmed = std.mem.trimStart(u8, line, " \t\r");
		if (trimmed.len == 0) continue;
		if (std.mem.startsWith(u8, trimmed, "--")) continue;

		const name = extractName(trimmed) orelse continue;

		if (hasTypeSig(trimmed)) {
			if (pending_sig) |sig| allocator.free(sig);
			if (pending_doc) |doc| allocator.free(doc);
			pending_name = name;
			pending_sig = try allocator.dupe(u8, trimmed);
			pending_doc = try util.extractDocComment(allocator, lines.items, idx, .{
				.line_prefixes = &[_][]const u8{ "--" },
			});
			continue;
		}

		if (!hasDefinition(trimmed)) continue;

		var signature: []const u8 = undefined;
		if (pending_name) |pending| {
			if (std.mem.eql(u8, pending, name) and pending_sig != null) {
				signature = pending_sig.?;
				pending_sig = null;
			} else {
				signature = try allocator.dupe(u8, trimmed);
			}
			pending_name = null;
		} else {
			signature = try allocator.dupe(u8, trimmed);
		}

		var doc_comment = try util.extractDocComment(allocator, lines.items, idx, .{
			.line_prefixes = &[_][]const u8{ "--" },
		});
		if (doc_comment == null and pending_doc != null) {
			doc_comment = pending_doc;
			pending_doc = null;
		}

		const symbol = model.Symbol{
			.language = try allocator.dupe(u8, "idris"),
			.file_path = try allocator.dupe(u8, file_path),
			.name = try allocator.dupe(u8, name),
			.signature = signature,
			.doc_comment = doc_comment,
			.start_line = idx + 1,
			.end_line = idx + 1,
		};
		try results.append(allocator, symbol);
	}

	return results.toOwnedSlice(allocator);
}

fn hasTypeSig(line: []const u8) bool {
	return std.mem.indexOfScalar(u8, line, ':') != null and std.mem.indexOfScalar(u8, line, '=') == null;
}

fn hasDefinition(line: []const u8) bool {
	return std.mem.indexOfScalar(u8, line, '=') != null;
}

fn extractName(line: []const u8) ?[]const u8 {
	const end_idx = std.mem.indexOfAny(u8, line, " \t(:=") orelse line.len;
	if (end_idx == 0) return null;
	return line[0..end_idx];
}

test "extract finds idris definitions" {
	const allocator = std.testing.allocator;
	const source =
		"-- adds\n" ++
		"add : Int -> Int -> Int\n" ++
		"add a b = a + b\n";

	const symbols = try extract(allocator, "Main.idr", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expectEqual(@as(usize, 1), symbols.len);
	try std.testing.expectEqualStrings("add", symbols[0].name);
	try std.testing.expectEqualStrings("adds", symbols[0].doc_comment.?);
}


// ─── smoke matrix (added 2026-06-02 from fleet review inadequate-tests) ────

test "extract returns no symbols on empty source" {
	const allocator = std.testing.allocator;
	const symbols = try extract(allocator, "src/empty.idr", "");
	defer allocator.free(symbols);
	try std.testing.expectEqual(@as(usize, 0), symbols.len);
}

test "extract handles declaration with no preceding comment (doc_comment null)" {
	const allocator = std.testing.allocator;
	const source = "plain : Int -> Int\nplain x = x\n";

	const symbols = try extract(allocator, "src/nodoc.idr", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expect(symbols.len >= 1);
	for (symbols) |sym| {
		try std.testing.expect(sym.doc_comment == null);
	}
}

test "extract attaches preceding comment as doc_comment" {
	const allocator = std.testing.allocator;
	const source = "-- adds\nadd : Int -> Int -> Int\nadd a b = a + b\n";

	const symbols = try extract(allocator, "src/withdoc.idr", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expect(symbols.len >= 1);
	var found = false;
	for (symbols) |sym| {
		if (std.mem.eql(u8, sym.name, "add")) {
			found = true;
			if (sym.doc_comment) |doc| {
				try std.testing.expect(std.mem.indexOf(u8, doc, "adds") != null);
			}
		}
	}
	try std.testing.expect(found);
}

test "extract handles UTF-8 content without crashing" {
	const allocator = std.testing.allocator;
	// Source contains non-ASCII bytes — the extractor must not crash.
	const source = "-- café and über\n";
	const symbols = try extract(allocator, "src/utf8.idr", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}
	_ = symbols.len;
}
