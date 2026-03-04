const std = @import("std");
const hashline = @import("hashline.zig");

pub const Symbol = struct {
	language: []const u8,
	file_path: []const u8,
	name: []const u8,
	signature: []const u8,
	doc_comment: ?[]const u8,
	symbol_kind: ?[]const u8 = null,
	symbol_visibility: ?[]const u8 = null,
	symbol_scope: ?[]const u8 = null,
	symbol_arity: ?i32 = null,
	body: ?[]const u8 = null,
	start_line: usize,
	end_line: usize,
	start_hash: ?hashline.Hash = null,
	end_hash: ?hashline.Hash = null,

	pub fn deinit(self: *Symbol, allocator: std.mem.Allocator) void {
		allocator.free(self.language);
		allocator.free(self.file_path);
		allocator.free(self.name);
		allocator.free(self.signature);
		if (self.doc_comment) |value| allocator.free(value);
		if (self.symbol_kind) |value| allocator.free(value);
		if (self.symbol_visibility) |value| allocator.free(value);
		if (self.symbol_scope) |value| allocator.free(value);
		if (self.body) |value| allocator.free(value);
		self.* = undefined;
	}
};
