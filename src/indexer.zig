const std = @import("std");
const plugin = @import("plugin.zig");
const scan = @import("scan.zig");
const storage = @import("storage.zig");
const model = @import("model.zig");
const embedding = @import("embedding.zig");
const config = @import("config.zig");

pub const Options = struct {
	embedding_dim: usize,
	batch_size: usize = 16,
	max_file_size: usize = 1024 * 1024,
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
	defer {
		for (batch_texts.items) |text| allocator.free(text);
		batch_texts.deinit(allocator);
		batch_rowids.deinit(allocator);
	}

	var stats = Stats{ .files = files.len, .symbols = 0 };
	for (files) |rel_path| {
		const extractor = registry.find(rel_path) orelse continue;
		const full_path = try std.fs.path.join(allocator, &.{ root_path, rel_path });
		defer allocator.free(full_path);

		const file = try std.fs.cwd().openFile(full_path, .{});
		defer file.close();

		const source = file.readToEndAlloc(allocator, options.max_file_size) catch |err| {
			if (err == error.FileTooBig) continue;
			return err;
		};
		defer allocator.free(source);

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
		}
	}

	if (batch_texts.items.len > 0) {
		try flushBatch(allocator, db, embedder, options, &batch_texts, &batch_rowids);
	}

	return stats;
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

	try std.testing.expectEqual(@as(usize, 1), stats.files);
	try std.testing.expectEqual(@as(usize, 0), stats.symbols);
	try std.testing.expectEqual(@as(i64, 0), try storage.countRows(db, allocator, "symbols"));
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
