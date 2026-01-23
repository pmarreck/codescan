const std = @import("std");

pub const Symbol = struct {
	language: []const u8,
	file_path: []const u8,
	name: []const u8,
	signature: []const u8,
	doc_comment: ?[]const u8,
	start_line: usize,
	end_line: usize,

	pub fn deinit(self: *Symbol, allocator: std.mem.Allocator) void {
		allocator.free(self.language);
		allocator.free(self.file_path);
		allocator.free(self.name);
		allocator.free(self.signature);
		if (self.doc_comment) |value| allocator.free(value);
		self.* = undefined;
	}
};
