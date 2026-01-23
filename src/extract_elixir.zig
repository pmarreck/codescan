const std = @import("std");
const model = @import("model.zig");

pub fn extract(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	source: []const u8,
) ![]model.Symbol {
	_ = allocator;
	_ = file_path;
	_ = source;
	return error.NotImplemented;
}
