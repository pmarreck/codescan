const std = @import("std");
const cli = @import("cli.zig");
const extract_util = @import("extract_util.zig");
const hashline = @import("hashline.zig");

pub fn run(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	from_line: ?usize,
	to_line: ?usize,
	format: cli.OutputFormat,
	writer: *std.Io.Writer,
	read_contents: anytype,
	write_json: anytype,
) !void {
	const source = try read_contents(allocator, file_path);
	defer allocator.free(source);

	// Split into lines and compute chain hashes
	var lines_list = try extract_util.splitLines(allocator, source);
	defer lines_list.deinit(allocator);
	const lines = lines_list.items;
	const total_lines = lines.len;

	const hashes = try hashline.computeChainHashes(allocator, lines);
	defer allocator.free(hashes);

	// Version is the hash of the last line of the entire file
	const version: hashline.Hash = if (hashes.len > 0) hashes[hashes.len - 1] else .{ '0', '0', '0' };

	// Determine range (1-indexed, inclusive)
	const from: usize = if (from_line) |f| if (f >= 1 and f <= total_lines) f else 1 else 1;
	const to: usize = if (to_line) |t| if (t >= 1 and t <= total_lines) t else total_lines else total_lines;

	if (from > to) {
		try writer.print("error: --from ({d}) must be <= --to ({d})\n", .{ from, to });
		return;
	}

	switch (format) {
		.json => {
			// Build the hashlined content as a string
			var content_buf = @as(std.ArrayListUnmanaged(u8), .empty);
			defer content_buf.deinit(allocator);
			for (from - 1..to) |idx| {
				if (content_buf.items.len > 0) {
					try content_buf.append(allocator, '\n');
				}
				// Format: line_num:hash|content
				var line_header: [32]u8 = undefined;
				const header_len = (std.fmt.bufPrint(&line_header, "{d}:{s}|", .{ idx + 1, @as([]const u8, &hashes[idx]) }) catch unreachable).len;
				try content_buf.appendSlice(allocator, line_header[0..header_len]);
				try content_buf.appendSlice(allocator, lines[idx]);
			}

			// Write JSON object
			try writer.writeAll("{\"file\":");
			try write_json(file_path, writer);
			try writer.print(",\"version\":\"{s}\",\"total_lines\":{d},\"from\":{d},\"to\":{d},\"content\":", .{
				@as([]const u8, &version), total_lines, from, to,
			});
			try write_json(content_buf.items, writer);
			try writer.writeAll("}\n");
		},
		.human => {
			try writer.print("# {s}  (version: {s}, lines: {d})\n", .{
				file_path, @as([]const u8, &version), total_lines,
			});
			for (from - 1..to) |idx| {
				try writer.print("{d}:{s}|{s}\n", .{ idx + 1, @as([]const u8, &hashes[idx]), lines[idx] });
			}
		},
	}
}
