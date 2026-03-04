const std = @import("std");
const storage = @import("storage.zig");
const model = @import("model.zig");

pub fn main() !void {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = gpa.deinit();
	const allocator = gpa.allocator();

	const args = try std.process.argsAlloc(allocator);
	defer std.process.argsFree(allocator, args);

	var db_path: ?[]const u8 = null;
	var embedding_dim: usize = 1024;

	var i: usize = 1;
	while (i < args.len) {
		const arg = args[i];
		if (std.mem.eql(u8, arg, "--db")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			db_path = args[i];
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--embedding-dim")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			embedding_dim = try std.fmt.parseInt(usize, args[i], 10);
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
			try printUsage();
			return;
		}
		return error.UnexpectedArg;
	}

	const path = db_path orelse {
		try printUsage();
		return error.MissingDbPath;
	};

	const db = try storage.openFileWithVec(allocator, path);
	defer storage.close(db);

	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = embedding_dim });
	try storage.resetIndex(db);

	var sym_code = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/checksum.zig"),
		.name = try allocator.dupe(u8, "checksum_fn"),
		.signature = try allocator.dupe(u8, "fn checksum_fn(input: []const u8) u32"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym_code.deinit(allocator);

	var sym_comment = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/hash.zig"),
		.name = try allocator.dupe(u8, "hash_bytes"),
		.signature = try allocator.dupe(u8, "fn hash_bytes(input: []const u8) u32"),
		.doc_comment = try allocator.dupe(u8, "Compute checksum for bytes."),
		.start_line = 1,
		.end_line = 1,
	};
	defer sym_comment.deinit(allocator);

	var sym_doc = model.Symbol{
		.language = try allocator.dupe(u8, "markdown"),
		.file_path = try allocator.dupe(u8, "README"),
		.name = try allocator.dupe(u8, "Checksum Docs"),
		.signature = try allocator.dupe(u8, "Checksum guide"),
		.doc_comment = try allocator.dupe(u8, "Checksum guide for docs."),
		.start_line = 1,
		.end_line = 1,
	};
	defer sym_doc.deinit(allocator);

	// Symbol with a unique string only in its body (for body search test)
	var sym_body = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/body_test.zig"),
		.name = try allocator.dupe(u8, "processItems"),
		.signature = try allocator.dupe(u8, "fn processItems() void"),
		.doc_comment = null,
		.body = try allocator.dupe(u8, "const xylophone_unique_test_string = 42;"),
		.start_line = 1,
		.end_line = 5,
	};
	defer sym_body.deinit(allocator);

	const id_code = try storage.insertSymbol(db, sym_code);
	const id_comment = try storage.insertSymbol(db, sym_comment);
	const id_doc = try storage.insertSymbol(db, sym_doc);
	const id_body = try storage.insertSymbol(db, sym_body);

	const vector = try allocator.alloc(f32, embedding_dim);
	defer allocator.free(vector);
	for (vector) |*v| v.* = 0.0;

	try storage.insertEmbedding(db, allocator, id_code, vector);
	try storage.insertEmbedding(db, allocator, id_comment, vector);
	try storage.insertEmbedding(db, allocator, id_doc, vector);
	try storage.insertEmbedding(db, allocator, id_body, vector);
	try storage.insertCommentEmbedding(db, allocator, id_comment, vector);
	try storage.insertCommentEmbedding(db, allocator, id_doc, vector);
}

fn printUsage() !void {
	std.debug.print("usage: mk_test_db --db <path> [--embedding-dim <n>]\n", .{});
}
