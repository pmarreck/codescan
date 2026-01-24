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

	const debug = try debugEnabled(allocator);

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
	if (debug) {
		debugLog(stderr, "codescan: debug: indexing {d} files\n", .{files.len});
	}
	for (files) |rel_path| {
		if (debug) {
			debugLog(stderr, "codescan: debug: scanning {s}\n", .{rel_path});
		}
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

			const text = try buildSymbolText(allocator, sym, extractor.kind);
			try batch_texts.append(allocator, text);
			try batch_rowids.append(allocator, rowid);

			if (batch_texts.items.len >= options.batch_size) {
				if (debug) {
					debugLog(stderr, "codescan: debug: embedding {d} symbols\n", .{batch_texts.items.len});
				}
				try flushBatch(allocator, db, embedder, options, &batch_texts, &batch_rowids);
			}

			if (sym.doc_comment) |doc| {
				const comment_text = try buildCommentText(allocator, doc, .doc);
				try comment_texts.append(allocator, comment_text);
				try comment_rowids.append(allocator, rowid);

				if (comment_texts.items.len >= options.batch_size) {
					if (debug) {
						debugLog(stderr, "codescan: debug: embedding {d} comments\n", .{comment_texts.items.len});
					}
					try flushCommentBatch(allocator, db, embedder, options, &comment_texts, &comment_rowids);
				}
			}
		}
	}

	if (batch_texts.items.len > 0) {
		if (debug) {
			debugLog(stderr, "codescan: debug: embedding {d} symbols\n", .{batch_texts.items.len});
		}
		try flushBatch(allocator, db, embedder, options, &batch_texts, &batch_rowids);
	}
	if (comment_texts.items.len > 0) {
		if (debug) {
			debugLog(stderr, "codescan: debug: embedding {d} comments\n", .{comment_texts.items.len});
		}
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

pub fn buildSymbolText(
	allocator: std.mem.Allocator,
	symbol: model.Symbol,
	symbol_kind: kind.Kind,
) ![]u8 {
	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	try out.writer.writeAll(symbol.name);
	try out.writer.writeAll("\n");
	try out.writer.writeAll(symbol.signature);
	if (symbol.doc_comment) |doc| {
		try out.writer.writeAll("\n");
		try out.writer.writeAll(doc);
	}

	const text = try out.toOwnedSlice();
	return truncateOwnedText(allocator, symbol_kind, text);
}

pub fn buildCommentText(
	allocator: std.mem.Allocator,
	doc: []const u8,
	comment_kind: kind.Kind,
) ![]u8 {
	return truncateForKind(allocator, comment_kind, doc);
}

const max_embed_bytes: usize = 1600;

fn truncateOwnedText(allocator: std.mem.Allocator, item_kind: kind.Kind, text: []u8) ![]u8 {
	if (text.len <= max_embed_bytes) return text;
	const trimmed = try truncateForKind(allocator, item_kind, text);
	allocator.free(text);
	return trimmed;
}

fn truncateForKind(
	allocator: std.mem.Allocator,
	item_kind: kind.Kind,
	text: []const u8,
) ![]u8 {
	if (text.len <= max_embed_bytes) return allocator.dupe(u8, text);

	return switch (item_kind) {
		.code, .log => truncateCode(allocator, text),
		.doc, .text => truncateText(allocator, text),
	};
}

fn truncateText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
	const limit = max_embed_bytes;
	const min_reasonable = limit / 2;
	const bounded = text[0..limit];

	if (findSentenceCut(bounded, min_reasonable)) |cut| {
		return allocator.dupe(u8, trimRight(text[0..cut]));
	}
	if (findWhitespaceCut(bounded, min_reasonable)) |cut| {
		return allocator.dupe(u8, trimRight(text[0..cut]));
	}
	return allocator.dupe(u8, text[0..limit]);
}

fn truncateCode(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
	const limit = max_embed_bytes;
	const min_reasonable = limit / 2;
	const bounded = text[0..limit];

	if (findNewlineCut(bounded, min_reasonable)) |cut| {
		return allocator.dupe(u8, trimRight(text[0..cut]));
	}
	if (findWhitespaceCut(bounded, min_reasonable)) |cut| {
		return allocator.dupe(u8, trimRight(text[0..cut]));
	}
	return allocator.dupe(u8, text[0..limit]);
}

fn findSentenceCut(text: []const u8, min_reasonable: usize) ?usize {
	if (text.len == 0) return null;
	var idx: usize = text.len;
	while (idx > min_reasonable) : (idx -= 1) {
		const ch = text[idx - 1];
		if (ch == '.' or ch == '!' or ch == '?') {
			if (idx < text.len and !isWhitespace(text[idx])) continue;
			return idx;
		}
	}
	return null;
}

fn findNewlineCut(text: []const u8, min_reasonable: usize) ?usize {
	const idx = std.mem.lastIndexOfScalar(u8, text, '\n') orelse return null;
	if (idx + 1 < min_reasonable) return null;
	return idx + 1;
}

fn findWhitespaceCut(text: []const u8, min_reasonable: usize) ?usize {
	if (text.len == 0) return null;
	var idx: usize = text.len;
	while (idx > min_reasonable) : (idx -= 1) {
		if (isWhitespace(text[idx - 1])) return idx - 1;
	}
	return null;
}

fn isWhitespace(ch: u8) bool {
	return ch == ' ' or ch == '\n' or ch == '\r' or ch == '\t';
}

fn trimRight(text: []const u8) []const u8 {
	return std.mem.trimRight(u8, text, " \t\r\n");
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

fn debugEnabled(allocator: std.mem.Allocator) !bool {
	const value = std.process.getEnvVarOwned(allocator, "DEBUG") catch |err| switch (err) {
		error.EnvironmentVariableNotFound => return false,
		else => return err,
	};
	defer allocator.free(value);
	return debugEnabledFromValue(value);
}

fn debugEnabledFromValue(value: []const u8) bool {
	const trimmed = std.mem.trim(u8, value, " \t\r\n");
	if (trimmed.len == 0) return false;
	if (std.ascii.eqlIgnoreCase(trimmed, "0")) return false;
	if (std.ascii.eqlIgnoreCase(trimmed, "false")) return false;
	if (std.ascii.eqlIgnoreCase(trimmed, "no")) return false;
	return true;
}

fn debugLog(writer: *std.Io.Writer, comptime fmt: []const u8, args: anytype) void {
	_ = writer.print(fmt, args) catch {};
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

	const text = try buildSymbolText(allocator, symbol, .code);
	defer allocator.free(text);
	try std.testing.expectEqualStrings(
		"add\npub fn add(a: i32, b: i32) i32\nAdds two ints",
		text,
	);
}

test "truncateForKind prefers sentence boundary for docs" {
	const allocator = std.testing.allocator;
	const sentence = "This is a sentence. ";
	var out = std.ArrayListUnmanaged(u8){};
	defer out.deinit(allocator);

	while (out.items.len <= max_embed_bytes + 20) {
		try out.appendSlice(allocator, sentence);
	}
	const text = out.items;

	const truncated = try truncateForKind(allocator, .doc, text);
	defer allocator.free(truncated);
	try std.testing.expect(truncated.len <= max_embed_bytes);
	try std.testing.expect(truncated.len >= max_embed_bytes / 2);
	const last = truncated[truncated.len - 1];
	try std.testing.expect(last == '.' or last == '!' or last == '?');
}

test "truncateForKind prefers newline boundary for code" {
	const allocator = std.testing.allocator;
	var out = std.ArrayListUnmanaged(u8){};
	defer out.deinit(allocator);

	while (out.items.len <= max_embed_bytes + 40) {
		try out.appendSlice(allocator, "const value = 12345;\n");
	}
	const text = out.items;

	const truncated = try truncateForKind(allocator, .code, text);
	defer allocator.free(truncated);
	try std.testing.expect(truncated.len <= max_embed_bytes);
	try std.testing.expect(truncated.len >= max_embed_bytes / 2);

	const slice = text[0..max_embed_bytes];
	const last_newline = std.mem.lastIndexOfScalar(u8, slice, '\n') orelse 0;
	const expected = std.mem.trimRight(u8, text[0..last_newline + 1], " \t\r\n");
	try std.testing.expectEqualStrings(expected, truncated);
}

test "buildSymbolText truncates long inputs" {
	const allocator = std.testing.allocator;
	const long_doc = try allocator.alloc(u8, max_embed_bytes + 10);
	defer allocator.free(long_doc);
	@memset(long_doc, 'a');

	var symbol = model.Symbol{
		.language = try allocator.dupe(u8, "markdown"),
		.file_path = try allocator.dupe(u8, "README.md"),
		.name = try allocator.dupe(u8, "Title"),
		.signature = try allocator.dupe(u8, "Intro"),
		.doc_comment = try allocator.dupe(u8, long_doc),
		.start_line = 1,
		.end_line = 2,
	};
	defer symbol.deinit(allocator);

	const text = try buildSymbolText(allocator, symbol, .doc);
	defer allocator.free(text);
	try std.testing.expect(text.len <= max_embed_bytes);
}

test "debugEnabledFromValue recognizes truthy values" {
	try std.testing.expect(!debugEnabledFromValue(""));
	try std.testing.expect(!debugEnabledFromValue("0"));
	try std.testing.expect(!debugEnabledFromValue("false"));
	try std.testing.expect(!debugEnabledFromValue("no"));
	try std.testing.expect(debugEnabledFromValue("1"));
	try std.testing.expect(debugEnabledFromValue("true"));
	try std.testing.expect(debugEnabledFromValue("yes"));
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
