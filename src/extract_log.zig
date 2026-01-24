const std = @import("std");
const model = @import("model.zig");
const util = @import("extract_util.zig");

pub fn extract(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	source: []const u8,
) ![]model.Symbol {
	var lines = try util.splitLines(allocator, source);
	defer lines.deinit(allocator);

	var symbols = std.ArrayListUnmanaged(model.Symbol){};
	errdefer {
		for (symbols.items) |*sym| sym.deinit(allocator);
		symbols.deinit(allocator);
	}

	for (lines.items, 0..) |line, idx| {
		const trimmed = std.mem.trim(u8, line, " \t\r");
		if (trimmed.len == 0) continue;
		var name_buf: [64]u8 = undefined;
		const name = try std.fmt.bufPrint(&name_buf, "line {d}", .{idx + 1});
		const symbol = model.Symbol{
			.language = try allocator.dupe(u8, "log"),
			.file_path = try allocator.dupe(u8, file_path),
			.name = try allocator.dupe(u8, name),
			.signature = try allocator.dupe(u8, trimmed),
			.doc_comment = null,
			.start_line = idx + 1,
			.end_line = idx + 1,
		};
		try symbols.append(allocator, symbol);
	}

	return symbols.toOwnedSlice(allocator);
}

test "extract log emits line symbols" {
	const allocator = std.testing.allocator;
	const source =
		"INFO started\n" ++
		"\n" ++
		"ERROR failed\n";

	const symbols = try extract(allocator, "app.log", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expectEqual(@as(usize, 2), symbols.len);
	try std.testing.expectEqualStrings("line 1", symbols[0].name);
	try std.testing.expectEqualStrings("INFO started", symbols[0].signature);
	try std.testing.expectEqualStrings("line 3", symbols[1].name);
	try std.testing.expectEqualStrings("ERROR failed", symbols[1].signature);
}
