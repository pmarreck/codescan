const std = @import("std");
const plugin = @import("plugin.zig");
const kind = @import("kind.zig");
const scan = @import("scan.zig");
const storage = @import("storage.zig");
const model = @import("model.zig");
const embedding = @import("embedding.zig");
const config = @import("config.zig");

pub const Options = struct {
	embedding_dim: usize,
	batch_size: usize = 16,
	max_file_size: usize = 1024 * 1024,
	allowed_exts: []const []const u8 = &[_][]const u8{},
	allowed_kinds: []const kind.Kind = &[_]kind.Kind{},
	ignore: scan.IgnoreConfig = .{
		.global = &[_][]const u8{},
		.per_language = &[_]config.IgnoreOverride{},
	},
};

pub const Stats = struct {
	files: usize,
	symbols: usize,
};

pub fn indexAll(
	allocator: std.mem.Allocator,
	db: storage.Db,
	root_path: []const u8,
	registry: plugin.Registry,
	embedder: embedding.Embedder,
	options: Options,
) !Stats {
	if (options.batch_size == 0) return error.InvalidBatchSize;

	try storage.initSchema(allocator, db, .{ .embedding_dim = options.embedding_dim });
	try storage.resetIndex(db);

	const files = try scan.findFiles(allocator, root_path, registry, options.ignore);
	defer {
		for (files) |path| allocator.free(path);
		allocator.free(files);
	}

	var batch_texts: std.ArrayListUnmanaged([]const u8) = .{};
	var batch_rowids: std.ArrayListUnmanaged(i64) = .{};
	var comment_texts: std.ArrayListUnmanaged([]const u8) = .{};
	var comment_rowids: std.ArrayListUnmanaged(i64) = .{};
	defer {
		for (batch_texts.items) |text| allocator.free(text);
		batch_texts.deinit(allocator);
		batch_rowids.deinit(allocator);
		for (comment_texts.items) |text| allocator.free(text);
		comment_texts.deinit(allocator);
		comment_rowids.deinit(allocator);
	}

	var stderr_buf: [4096]u8 = undefined;
	var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
	const stderr = &stderr_writer.interface;

	var stats = Stats{ .files = 0, .symbols = 0 };
	for (files) |rel_path| {
		const extractor = registry.find(rel_path) orelse continue;
		if (!kindAllowed(extractor.kind, options.allowed_kinds)) continue;
		if (!extAllowed(rel_path, options.allowed_exts)) continue;
		const full_path = try std.fs.path.join(allocator, &.{ root_path, rel_path });
		defer allocator.free(full_path);

		const file = try std.fs.cwd().openFile(full_path, .{});
		defer file.close();

		const stat = try file.stat();
		const size = stat.size;
		if (options.max_file_size > 0) {
			const warn_threshold: u64 = @intCast(options.max_file_size / 4);
			if (warn_threshold > 0 and size > warn_threshold) {
				const skipping = size > options.max_file_size;
				warnLargeFile(stderr, rel_path, size, warn_threshold, options.max_file_size, skipping);
			}
			if (size > options.max_file_size) continue;
		}

		const source = file.readToEndAlloc(allocator, options.max_file_size) catch |err| {
			if (err == error.FileTooBig) continue;
			return err;
		};
		defer allocator.free(source);

		stats.files += 1;

		const symbols = try extractor.extract(allocator, rel_path, source);
		defer {
			for (symbols) |*sym| sym.deinit(allocator);
			allocator.free(symbols);
		}

		for (symbols) |sym| {
			const rowid = try storage.insertSymbol(db, sym);
			stats.symbols += 1;

			const text = try buildSymbolText(allocator, sym);
			try batch_texts.append(allocator, text);
			try batch_rowids.append(allocator, rowid);

			if (batch_texts.items.len >= options.batch_size) {
				try flushBatch(allocator, db, embedder, options, &batch_texts, &batch_rowids);
			}

			if (sym.doc_comment) |doc| {
				const comment_text = try buildCommentText(allocator, doc);
				try comment_texts.append(allocator, comment_text);
				try comment_rowids.append(allocator, rowid);

				if (comment_texts.items.len >= options.batch_size) {
					try flushCommentBatch(allocator, db, embedder, options, &comment_texts, &comment_rowids);
				}
			}
		}
	}

	if (batch_texts.items.len > 0) {
		try flushBatch(allocator, db, embedder, options, &batch_texts, &batch_rowids);
	}
	if (comment_texts.items.len > 0) {
		try flushCommentBatch(allocator, db, embedder, options, &comment_texts, &comment_rowids);
	}

	return stats;
}

fn kindAllowed(kind_value: kind.Kind, allowed: []const kind.Kind) bool {
	if (allowed.len == 0) return true;
	for (allowed) |value| {
		if (value == kind_value) return true;
	}
	return false;
}

fn extAllowed(path: []const u8, allowed: []const []const u8) bool {
	if (allowed.len == 0) return true;
	for (allowed) |ext| {
		if (hasExtensionIgnoreCase(path, ext)) return true;
	}
	return false;
}

fn hasExtensionIgnoreCase(path: []const u8, ext: []const u8) bool {
	if (ext.len == 0) return false;
	if (path.len < ext.len) return false;
	const tail = path[path.len - ext.len ..];
	return std.ascii.eqlIgnoreCase(tail, ext);
}

pub fn buildSymbolText(allocator: std.mem.Allocator, symbol: model.Symbol) ![]u8 {
	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	try out.writer.writeAll(symbol.name);
	try out.writer.writeAll("\n");
	try out.writer.writeAll(symbol.signature);
	if (symbol.doc_comment) |doc| {
		try out.writer.writeAll("\n");
		try out.writer.writeAll(doc);
	}

	return out.toOwnedSlice();
}

pub fn buildCommentText(allocator: std.mem.Allocator, doc: []const u8) ![]u8 {
	return allocator.dupe(u8, doc);
}

fn flushBatch(
	allocator: std.mem.Allocator,
	db: storage.Db,
	embedder: embedding.Embedder,
	options: Options,
	batch_texts: *std.ArrayListUnmanaged([]const u8),
	batch_rowids: *std.ArrayListUnmanaged(i64),
) !void {
	const embeddings = try embedder.embed(embedder.ctx, allocator, batch_texts.items);
	defer embedder.free(embedder.ctx, allocator, embeddings);

	if (embeddings.len != batch_texts.items.len) return error.EmbeddingCountMismatch;
	for (embeddings, 0..) |vector, idx| {
		if (vector.len != options.embedding_dim) return error.EmbeddingDimMismatch;
		try storage.insertEmbedding(db, allocator, batch_rowids.items[idx], vector);
	}

	for (batch_texts.items) |text| allocator.free(text);
	batch_texts.clearRetainingCapacity();
	batch_rowids.clearRetainingCapacity();
}

fn flushCommentBatch(
	allocator: std.mem.Allocator,
	db: storage.Db,
	embedder: embedding.Embedder,
	options: Options,
	batch_texts: *std.ArrayListUnmanaged([]const u8),
	batch_rowids: *std.ArrayListUnmanaged(i64),
) !void {
	const embeddings = try embedder.embed(embedder.ctx, allocator, batch_texts.items);
	defer embedder.free(embedder.ctx, allocator, embeddings);

	if (embeddings.len != batch_texts.items.len) return error.EmbeddingCountMismatch;
	for (embeddings, 0..) |vector, idx| {
		if (vector.len != options.embedding_dim) return error.EmbeddingDimMismatch;
		try storage.insertCommentEmbedding(db, allocator, batch_rowids.items[idx], vector);
	}

	for (batch_texts.items) |text| allocator.free(text);
	batch_texts.clearRetainingCapacity();
	batch_rowids.clearRetainingCapacity();
}

fn warnLargeFile(
	writer: *std.Io.Writer,
	file_path: []const u8,
	size: u64,
	threshold: u64,
	max_size: usize,
	skipping: bool,
) void {
	const action = if (skipping) "skipping" else "consider refactoring";
	_ = writer.print(
		"codescan: warning: {s} is {d} bytes (warn>{d}, max {d}); {s} or increase --max-file-size / .codescan/config\n",
		.{ file_path, size, threshold, max_size, action },
	) catch {};
	_ = writer.flush() catch {};
}

test "buildSymbolText includes name signature and doc" {
	const allocator = std.testing.allocator;
	var symbol = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/main.zig"),
		.name = try allocator.dupe(u8, "add"),
		.signature = try allocator.dupe(u8, "pub fn add(a: i32, b: i32) i32"),
		.doc_comment = try allocator.dupe(u8, "Adds two ints"),
		.start_line = 1,
		.end_line = 2,
	};
	defer symbol.deinit(allocator);

	const text = try buildSymbolText(allocator, symbol);
	defer allocator.free(text);
	try std.testing.expectEqualStrings(
		"add\npub fn add(a: i32, b: i32) i32\nAdds two ints",
		text,
	);
}

test "indexAll stores symbols and embeddings" {
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	try tmp.dir.makePath("src");
	const source =
		"/// Adds\n" ++
		"pub fn add(a: i32, b: i32) i32 { return a + b; }\n" ++
		"fn sub(a: i32, b: i32) i32 { return a - b; }\n";
	try tmp.dir.writeFile(.{ .sub_path = "src/math.zig", .data = source });

	const allocator = std.testing.allocator;
	const root = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(root);

	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	var fake = FakeEmbedder{};
	const stats = try indexAll(allocator, db, root, plugin.defaultRegistry(), fake.embedder(), .{
		.embedding_dim = 2,
		.batch_size = 2,
	});

	try std.testing.expectEqual(@as(usize, 1), stats.files);
	try std.testing.expectEqual(@as(usize, 2), stats.symbols);
	try std.testing.expectEqual(@as(i64, 2), try storage.countRows(db, allocator, "symbols"));
	try std.testing.expectEqual(@as(i64, 2), try storage.countRows(db, allocator, "embeddings"));
	try std.testing.expectEqual(@as(i64, 1), try storage.countRows(db, allocator, "embeddings_comment"));
}

test "indexAll skips files over max_file_size" {
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	try tmp.dir.makePath("src");
	const source =
		"/// Big\n" ++
		"pub fn big() void { return; }\n";
	try tmp.dir.writeFile(.{ .sub_path = "src/big.zig", .data = source });

	const allocator = std.testing.allocator;
	const root = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(root);

	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	var fake = FakeEmbedder{};
	const stats = try indexAll(allocator, db, root, plugin.defaultRegistry(), fake.embedder(), .{
		.embedding_dim = 2,
		.batch_size = 2,
		.max_file_size = 8,
	});

	try std.testing.expectEqual(@as(usize, 0), stats.files);
	try std.testing.expectEqual(@as(usize, 0), stats.symbols);
	try std.testing.expectEqual(@as(i64, 0), try storage.countRows(db, allocator, "symbols"));
}

test "indexAll filters by extension and kind" {
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	try tmp.dir.makePath("src");
	try tmp.dir.writeFile(.{ .sub_path = "src/main.zig", .data = "pub fn add() void {}" });
	try tmp.dir.writeFile(.{ .sub_path = "README.md", .data = "# Title\nbody\n" });

	const allocator = std.testing.allocator;
	const root = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(root);

	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	var fake = FakeEmbedder{};
	const stats = try indexAll(allocator, db, root, plugin.defaultRegistry(), fake.embedder(), .{
		.embedding_dim = 2,
		.allowed_exts = &[_][]const u8{ ".md" },
		.allowed_kinds = &[_]kind.Kind{ .doc },
	});

	try std.testing.expectEqual(@as(usize, 1), stats.files);
	try std.testing.expect(stats.symbols > 0);
	try std.testing.expectEqual(@as(i64, 1), try storage.countDistinctFiles(db, allocator));
}

test "warnLargeFile includes limits" {
	const allocator = std.testing.allocator;
	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	warnLargeFile(&out.writer, "src/big.zig", 600_000, 500_000, 2_000_000, false);
	const payload = try out.toOwnedSlice();
	defer allocator.free(payload);

	try std.testing.expect(std.mem.indexOf(u8, payload, "src/big.zig") != null);
	try std.testing.expect(std.mem.indexOf(u8, payload, "max 2000000") != null);
}

const FakeEmbedder = struct {
	pub fn embedder(self: *FakeEmbedder) embedding.Embedder {
		return .{ .ctx = self, .embed = embed, .free = free };
	}

	fn embed(ctx: *anyopaque, allocator: std.mem.Allocator, inputs: []const []const u8) ![][]f32 {
		_ = ctx;
		var rows = try allocator.alloc([]f32, inputs.len);
		errdefer {
			for (rows) |row| allocator.free(row);
			allocator.free(rows);
		}
		for (inputs, 0..) |input, idx| {
			var row = try allocator.alloc(f32, 2);
			const len: f32 = @floatFromInt(input.len);
			row[0] = len;
			row[1] = len + 0.5;
			rows[idx] = row;
		}
		return rows;
	}

	fn free(ctx: *anyopaque, allocator: std.mem.Allocator, embeddings: [][]f32) void {
		_ = ctx;
		for (embeddings) |row| allocator.free(row);
		allocator.free(embeddings);
	}
};
