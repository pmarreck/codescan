const std = @import("std");
const storage = @import("storage.zig");
const embedding = @import("embedding.zig");
const model = @import("model.zig");

const sqlite = storage.sqlite;

pub const SearchMode = enum {
	vector,
	lexical,
	hybrid,
};

pub const Options = struct {
	top_n: usize = 10,
	candidate_multiplier: usize = 5,
	mode: SearchMode = .hybrid,
	weight_vector: f32 = 0.7,
	weight_lexical: f32 = 0.3,
	min_score: f32 = 0.0,
};

pub const Result = struct {
	id: i64,
	symbol: model.Symbol,
	score: f32,
	distance: f32,
	lexical: f32,

	pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
		self.symbol.deinit(allocator);
		self.* = undefined;
	}
};

pub fn search(
	allocator: std.mem.Allocator,
	db: storage.Db,
	embedder: embedding.Embedder,
	query: []const u8,
	options: Options,
) ![]Result {
	if (query.len == 0) return error.EmptyQuery;
	if (options.top_n == 0) return allocator.alloc(Result, 0);

	var weight_vector = options.weight_vector;
	var weight_lexical = options.weight_lexical;
	if (options.mode == .hybrid) {
		if (weight_vector < 0 or weight_lexical < 0) return error.InvalidWeights;
		const sum = weight_vector + weight_lexical;
		if (sum <= 0) return error.InvalidWeights;
		weight_vector /= sum;
		weight_lexical /= sum;
	}

	var results = std.ArrayListUnmanaged(Result){};
	errdefer {
		for (results.items) |*res| res.deinit(allocator);
		results.deinit(allocator);
	}

	if (options.mode == .lexical) {
		const lexical = try lexicalCandidates(allocator, db, query, options.top_n * options.candidate_multiplier);
		for (lexical) |res| try results.append(allocator, res);
		allocator.free(lexical);
	} else {
		const inputs = [_][]const u8{ query };
		const embeddings = try embedder.embed(embedder.ctx, allocator, &inputs);
		defer embedder.free(embedder.ctx, allocator, embeddings);
		if (embeddings.len != 1) return error.InvalidEmbeddingCount;

		const limit = options.top_n * options.candidate_multiplier;
		const vector_results = try vectorCandidates(allocator, db, embeddings[0], limit);
		for (vector_results) |res| try results.append(allocator, res);
		allocator.free(vector_results);

		if (options.mode == .hybrid) {
			const lexical = try lexicalCandidates(allocator, db, query, limit);
			defer allocator.free(lexical);
			for (lexical) |res| {
				try appendUnique(allocator, &results, res);
			}
		}
	}

	for (results.items) |*res| {
		const lexical = try lexicalScore(allocator, query, res.symbol);
		res.lexical = lexical;
		const vector_score = if (std.math.isInf(res.distance)) 0 else (1.0 / (1.0 + res.distance));
		if (options.mode == .vector) {
			res.score = vector_score;
		} else if (options.mode == .lexical) {
			res.score = lexical;
		} else {
			res.score = vector_score * weight_vector + lexical * weight_lexical;
		}
	}

	var filtered = std.ArrayListUnmanaged(Result){};
	errdefer {
		for (filtered.items) |*res| res.deinit(allocator);
		filtered.deinit(allocator);
	}

	for (results.items) |res| {
		if (res.score >= options.min_score) {
			try filtered.append(allocator, res);
		} else {
			var tmp = res;
			tmp.deinit(allocator);
		}
	}
	results.deinit(allocator);

	std.sort.heap(Result, filtered.items, {}, sortByScoreDesc);

	const take = @min(filtered.items.len, options.top_n);
	const out = try allocator.alloc(Result, take);
	@memcpy(out, filtered.items[0..take]);
	for (filtered.items[take..]) |*res| res.deinit(allocator);
	filtered.deinit(allocator);
	return out;
}

pub fn freeResults(allocator: std.mem.Allocator, results: []Result) void {
	for (results) |*res| res.deinit(allocator);
	allocator.free(results);
}

fn sortByScoreDesc(_: void, a: Result, b: Result) bool {
	return a.score > b.score;
}

fn appendUnique(
	allocator: std.mem.Allocator,
	results: *std.ArrayListUnmanaged(Result),
	res: Result,
) !void {
	for (results.items) |*existing| {
		if (existing.id == res.id) {
			var tmp = res;
			tmp.deinit(allocator);
			return;
		}
	}
	try results.append(allocator, res);
}

fn vectorCandidates(
	allocator: std.mem.Allocator,
	db: storage.Db,
	vector: []const f32,
	limit: usize,
) ![]Result {
	if (limit == 0) return allocator.alloc(Result, 0);

	const json = try vectorToJson(allocator, vector);
	defer allocator.free(json);

	const sql: [:0]const u8 =
		"SELECT symbols.id, lang, file_path, start_line, end_line, symbol_name, signature, doc_comment, "
		++ "vec_distance_l2(embedding, vec_f32(?1)) AS distance "
		++ "FROM embeddings JOIN symbols ON embeddings.rowid = symbols.id "
		++ "ORDER BY distance LIMIT ?2;\x00";

	var stmt: ?*sqlite.sqlite3_stmt = null;
	if (sqlite.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != sqlite.SQLITE_OK) {
		return error.SqlPrepareFailed;
	}
	defer _ = sqlite.sqlite3_finalize(stmt.?);

	try bindText(stmt.?, 1, json);
	_ = sqlite.sqlite3_bind_int64(stmt.?, 2, @intCast(limit));

	var results = std.ArrayListUnmanaged(Result){};
	errdefer {
		for (results.items) |*res| res.deinit(allocator);
		results.deinit(allocator);
	}

	while (true) {
		const rc = sqlite.sqlite3_step(stmt.?);
		if (rc == sqlite.SQLITE_ROW) {
			const res = try readResultRow(allocator, stmt.?);
			try results.append(allocator, res);
		} else if (rc == sqlite.SQLITE_DONE) {
			break;
		} else {
			return error.SqlStepFailed;
		}
	}

	return results.toOwnedSlice(allocator);
}

fn lexicalCandidates(
	allocator: std.mem.Allocator,
	db: storage.Db,
	query: []const u8,
	limit: usize,
) ![]Result {
	if (ftsAvailable(db) catch false) {
		const fts = ftsCandidates(allocator, db, query, limit) catch null;
		if (fts) |rows| return rows;
	}
	return likeCandidates(allocator, db, query, limit);
}

fn likeCandidates(
	allocator: std.mem.Allocator,
	db: storage.Db,
	query: []const u8,
	limit: usize,
) ![]Result {
	if (limit == 0) return allocator.alloc(Result, 0);

	const pattern = try std.fmt.allocPrint(allocator, "%{s}%", .{query});
	defer allocator.free(pattern);
	const pattern_z = try allocator.dupeZ(u8, pattern);
	defer allocator.free(pattern_z);

	const sql: [:0]const u8 =
		"SELECT id, lang, file_path, start_line, end_line, symbol_name, signature, doc_comment, "
		++ "0.0 AS distance "
		++ "FROM symbols "
		++ "WHERE symbol_name LIKE ?1 COLLATE NOCASE "
		++ "OR signature LIKE ?1 COLLATE NOCASE "
		++ "OR doc_comment LIKE ?1 COLLATE NOCASE "
		++ "LIMIT ?2;\x00";

	var stmt: ?*sqlite.sqlite3_stmt = null;
	if (sqlite.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != sqlite.SQLITE_OK) {
		return error.SqlPrepareFailed;
	}
	defer _ = sqlite.sqlite3_finalize(stmt.?);

	_ = sqlite.sqlite3_bind_text(stmt.?, 1, pattern_z.ptr, @intCast(pattern.len), null);
	_ = sqlite.sqlite3_bind_int64(stmt.?, 2, @intCast(limit));

	var results = std.ArrayListUnmanaged(Result){};
	errdefer {
		for (results.items) |*res| res.deinit(allocator);
		results.deinit(allocator);
	}

	while (true) {
		const rc = sqlite.sqlite3_step(stmt.?);
		if (rc == sqlite.SQLITE_ROW) {
			const res = try readResultRow(allocator, stmt.?);
			try results.append(allocator, res);
		} else if (rc == sqlite.SQLITE_DONE) {
			break;
		} else {
			return error.SqlStepFailed;
		}
	}

	return results.toOwnedSlice(allocator);
}

fn ftsCandidates(
	allocator: std.mem.Allocator,
	db: storage.Db,
	query: []const u8,
	limit: usize,
) ![]Result {
	if (limit == 0) return allocator.alloc(Result, 0);

	const fts_query = try buildFtsQuery(allocator, query);
	defer allocator.free(fts_query);
	const escaped = try escapeSqlLiteral(allocator, fts_query);
	defer allocator.free(escaped);

	const sql_ranked = try allocPrintZ(
		allocator,
		"SELECT symbols.id, symbols.lang, symbols.file_path, symbols.start_line, symbols.end_line, "
		++ "symbols.symbol_name, symbols.signature, symbols.doc_comment, "
		++ "0.0 AS distance "
		++ "FROM symbols_fts JOIN symbols ON symbols_fts.rowid = symbols.id "
		++ "WHERE symbols_fts MATCH '{s}' "
		++ "ORDER BY bm25(symbols_fts) "
		++ "LIMIT {d};",
		.{ escaped, limit },
	);
	defer allocator.free(sql_ranked);
	const sql_plain = try allocPrintZ(
		allocator,
		"SELECT symbols.id, symbols.lang, symbols.file_path, symbols.start_line, symbols.end_line, "
		++ "symbols.symbol_name, symbols.signature, symbols.doc_comment, "
		++ "0.0 AS distance "
		++ "FROM symbols_fts JOIN symbols ON symbols_fts.rowid = symbols.id "
		++ "WHERE symbols_fts MATCH '{s}' "
		++ "LIMIT {d};",
		.{ escaped, limit },
	);
	defer allocator.free(sql_plain);

	var stmt: ?*sqlite.sqlite3_stmt = null;
	if (sqlite.sqlite3_prepare_v2(db, sql_ranked, -1, &stmt, null) != sqlite.SQLITE_OK) {
		if (sqlite.sqlite3_prepare_v2(db, sql_plain, -1, &stmt, null) != sqlite.SQLITE_OK) {
			return error.SqlPrepareFailed;
		}
	}
	defer _ = sqlite.sqlite3_finalize(stmt.?);

	var results = std.ArrayListUnmanaged(Result){};
	errdefer {
		for (results.items) |*res| res.deinit(allocator);
		results.deinit(allocator);
	}

	while (true) {
		const rc = sqlite.sqlite3_step(stmt.?);
		if (rc == sqlite.SQLITE_ROW) {
			const res = try readResultRow(allocator, stmt.?);
			try results.append(allocator, res);
		} else if (rc == sqlite.SQLITE_DONE) {
			break;
		} else {
			return error.SqlStepFailed;
		}
	}

	return results.toOwnedSlice(allocator);
}

fn readResultRow(allocator: std.mem.Allocator, stmt: *sqlite.sqlite3_stmt) !Result {
	const id = sqlite.sqlite3_column_int64(stmt, 0);
	const lang = try dupColumnText(allocator, stmt, 1);
	const file_path = try dupColumnText(allocator, stmt, 2);
	const start_line = @as(usize, @intCast(sqlite.sqlite3_column_int64(stmt, 3)));
	const end_line = @as(usize, @intCast(sqlite.sqlite3_column_int64(stmt, 4)));
	const name = try dupColumnText(allocator, stmt, 5);
	const signature = try dupColumnText(allocator, stmt, 6);
	const doc_comment = try dupColumnTextOptional(allocator, stmt, 7);
	const distance = @as(f32, @floatCast(sqlite.sqlite3_column_double(stmt, 8)));

	return .{
		.id = id,
		.symbol = .{
			.language = lang,
			.file_path = file_path,
			.name = name,
			.signature = signature,
			.doc_comment = doc_comment,
			.start_line = start_line,
			.end_line = end_line,
		},
		.score = 0,
		.distance = distance,
		.lexical = 0,
	};
}

fn bindText(stmt: *sqlite.sqlite3_stmt, index: c_int, text: []const u8) !void {
	if (sqlite.sqlite3_bind_text(stmt, index, text.ptr, @intCast(text.len), null) != sqlite.SQLITE_OK) {
		return error.SqlBindFailed;
	}
}

fn dupColumnText(allocator: std.mem.Allocator, stmt: *sqlite.sqlite3_stmt, index: c_int) ![]const u8 {
	const ptr = sqlite.sqlite3_column_text(stmt, index) orelse return error.SqlNull;
	const slice = std.mem.span(ptr);
	return allocator.dupe(u8, slice);
}

fn dupColumnTextOptional(
	allocator: std.mem.Allocator,
	stmt: *sqlite.sqlite3_stmt,
	index: c_int,
) !?[]const u8 {
	const ptr = sqlite.sqlite3_column_text(stmt, index) orelse return null;
	const slice = std.mem.span(ptr);
	return @as(?[]const u8, try allocator.dupe(u8, slice));
}

fn vectorToJson(allocator: std.mem.Allocator, vector: []const f32) ![]u8 {
	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	try out.writer.writeAll("[");
	for (vector, 0..) |value, idx| {
		if (idx != 0) try out.writer.writeAll(",");
		try out.writer.print("{d}", .{value});
	}
	try out.writer.writeAll("]");
	return out.toOwnedSlice();
}

fn lexicalScore(allocator: std.mem.Allocator, query: []const u8, symbol: model.Symbol) !f32 {
	_ = allocator;
	var tokens = std.mem.tokenizeAny(u8, query, " \t\r\n");
	var token_count: usize = 0;
	var match_count: usize = 0;

	while (tokens.next()) |tok| {
		token_count += 1;

		const in_name = std.ascii.indexOfIgnoreCase(symbol.name, tok) != null;
		const in_sig = std.ascii.indexOfIgnoreCase(symbol.signature, tok) != null;
		const in_doc = if (symbol.doc_comment) |doc| std.ascii.indexOfIgnoreCase(doc, tok) != null else false;
		if (in_name or in_sig or in_doc) match_count += 1;
	}

	if (token_count == 0) return 0;
	return @as(f32, @floatFromInt(match_count)) / @as(f32, @floatFromInt(token_count));
}

fn buildFtsQuery(allocator: std.mem.Allocator, query: []const u8) ![]u8 {
	var out = std.ArrayListUnmanaged(u8){};
	errdefer out.deinit(allocator);

	var tokens = std.mem.tokenizeAny(u8, query, " \t\r\n");
	var token_count: usize = 0;
	while (tokens.next()) |tok| {
		if (tok.len == 0) continue;
		if (token_count > 0) {
			try out.appendSlice(allocator, " AND ");
		}
		try out.append(allocator, '"');
		try out.appendSlice(allocator, tok);
		try out.append(allocator, '"');
		token_count += 1;
	}

	if (token_count == 0) {
		try out.appendSlice(allocator, query);
	}

	return out.toOwnedSlice(allocator);
}

fn escapeSqlLiteral(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
	var out = std.ArrayListUnmanaged(u8){};
	errdefer out.deinit(allocator);

	for (input) |ch| {
		if (ch == '\'') {
			try out.appendSlice(allocator, "''");
		} else {
			try out.append(allocator, ch);
		}
	}

	return out.toOwnedSlice(allocator);
}

fn allocPrintZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]u8 {
	const tmp = try std.fmt.allocPrint(allocator, fmt, args);
	defer allocator.free(tmp);
	return allocator.dupeZ(u8, tmp);
}

fn ftsAvailable(db: storage.Db) !bool {
	const sql: [:0]const u8 =
		"SELECT name FROM sqlite_master WHERE type='table' AND name='symbols_fts' LIMIT 1;\x00";
	var stmt: ?*sqlite.sqlite3_stmt = null;
	if (sqlite.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != sqlite.SQLITE_OK) {
		return error.SqlPrepareFailed;
	}
	defer _ = sqlite.sqlite3_finalize(stmt.?);

	const step_rc = sqlite.sqlite3_step(stmt.?);
	if (step_rc == sqlite.SQLITE_ROW) return true;
	if (step_rc == sqlite.SQLITE_DONE) return false;
	return error.SqlStepFailed;
}

test "lexicalScore matches query tokens" {
	const allocator = std.testing.allocator;
	var symbol = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/hash.zig"),
		.name = try allocator.dupe(u8, "crc32"),
		.signature = try allocator.dupe(u8, "pub fn crc32(data: []const u8) u32"),
		.doc_comment = try allocator.dupe(u8, "Hash functions for checksums"),
		.start_line = 1,
		.end_line = 2,
	};
	defer symbol.deinit(allocator);

	const score = try lexicalScore(allocator, "hash functions", symbol);
	try std.testing.expectApproxEqAbs(@as(f32, 1.0), score, 0.0001);
}

test "search vector mode returns nearest symbol" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

	var sym1 = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/a.zig"),
		.name = try allocator.dupe(u8, "near"),
		.signature = try allocator.dupe(u8, "fn near() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym1.deinit(allocator);

	var sym2 = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/b.zig"),
		.name = try allocator.dupe(u8, "far"),
		.signature = try allocator.dupe(u8, "fn far() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym2.deinit(allocator);

	const id1 = try storage.insertSymbol(db, sym1);
	const id2 = try storage.insertSymbol(db, sym2);
	try storage.insertEmbedding(db, allocator, id1, &[_]f32{ 0.0, 0.0 });
	try storage.insertEmbedding(db, allocator, id2, &[_]f32{ 10.0, 0.0 });

	var fake = FakeEmbedder{ .vector = &[_]f32{ 0.0, 0.0 } };
	const results = try search(allocator, db, fake.embedder(), "query", .{
		.top_n = 1,
		.mode = .vector,
	});
	defer freeResults(allocator, results);

	try std.testing.expectEqual(@as(usize, 1), results.len);
	try std.testing.expectEqualStrings("near", results[0].symbol.name);
}

test "search filters by min_score" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

	var sym1 = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/a.zig"),
		.name = try allocator.dupe(u8, "near"),
		.signature = try allocator.dupe(u8, "fn near() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym1.deinit(allocator);

	var sym2 = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/b.zig"),
		.name = try allocator.dupe(u8, "far"),
		.signature = try allocator.dupe(u8, "fn far() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym2.deinit(allocator);

	const id1 = try storage.insertSymbol(db, sym1);
	const id2 = try storage.insertSymbol(db, sym2);
	try storage.insertEmbedding(db, allocator, id1, &[_]f32{ 0.0, 0.0 });
	try storage.insertEmbedding(db, allocator, id2, &[_]f32{ 10.0, 0.0 });

	var fake = FakeEmbedder{ .vector = &[_]f32{ 0.0, 0.0 } };
	const results = try search(allocator, db, fake.embedder(), "query", .{
		.top_n = 5,
		.mode = .vector,
		.min_score = 0.5,
	});
	defer freeResults(allocator, results);

	try std.testing.expectEqual(@as(usize, 1), results.len);
	try std.testing.expectEqualStrings("near", results[0].symbol.name);
}

test "search hybrid weights influence ranking" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

	var sym1 = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/far.zig"),
		.name = try allocator.dupe(u8, "far_match"),
		.signature = try allocator.dupe(u8, "fn far_match() void"),
		.doc_comment = try allocator.dupe(u8, "alpha beta"),
		.start_line = 1,
		.end_line = 1,
	};
	defer sym1.deinit(allocator);

	var sym2 = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/near.zig"),
		.name = try allocator.dupe(u8, "near_nomatch"),
		.signature = try allocator.dupe(u8, "fn near_nomatch() void"),
		.doc_comment = try allocator.dupe(u8, "gamma"),
		.start_line = 1,
		.end_line = 1,
	};
	defer sym2.deinit(allocator);

	const id1 = try storage.insertSymbol(db, sym1);
	const id2 = try storage.insertSymbol(db, sym2);
	try storage.insertEmbedding(db, allocator, id1, &[_]f32{ 10.0, 0.0 });
	try storage.insertEmbedding(db, allocator, id2, &[_]f32{ 0.0, 0.0 });

	var fake = FakeEmbedder{ .vector = &[_]f32{ 0.0, 0.0 } };

	const prefer_vector = try search(allocator, db, fake.embedder(), "alpha beta", .{
		.top_n = 1,
		.mode = .hybrid,
		.weight_vector = 0.9,
		.weight_lexical = 0.1,
	});
	defer freeResults(allocator, prefer_vector);
	try std.testing.expectEqualStrings("near_nomatch", prefer_vector[0].symbol.name);

	const prefer_lexical = try search(allocator, db, fake.embedder(), "alpha beta", .{
		.top_n = 1,
		.mode = .hybrid,
		.weight_vector = 0.1,
		.weight_lexical = 0.9,
	});
	defer freeResults(allocator, prefer_lexical);
	try std.testing.expectEqualStrings("far_match", prefer_lexical[0].symbol.name);
}

test "search hybrid normalizes weights" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

	var sym = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/only.zig"),
		.name = try allocator.dupe(u8, "only"),
		.signature = try allocator.dupe(u8, "fn only() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym.deinit(allocator);

	const id = try storage.insertSymbol(db, sym);
	try storage.insertEmbedding(db, allocator, id, &[_]f32{ 0.0, 0.0 });

	var fake = FakeEmbedder{ .vector = &[_]f32{ 0.0, 0.0 } };
	const results = try search(allocator, db, fake.embedder(), "missing", .{
		.top_n = 1,
		.mode = .hybrid,
		.weight_vector = 2.0,
		.weight_lexical = 1.0,
	});
	defer freeResults(allocator, results);

	try std.testing.expectEqual(@as(usize, 1), results.len);
	try std.testing.expectApproxEqAbs(@as(f32, 0.6666667), results[0].score, 0.0001);
}

test "search lexical uses fts when available" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

	var sym = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/hash.zig"),
		.name = try allocator.dupe(u8, "crc32"),
		.signature = try allocator.dupe(u8, "pub fn crc32(data: []const u8) u32"),
		.doc_comment = try allocator.dupe(u8, "Hash functions for checksums"),
		.start_line = 1,
		.end_line = 1,
	};
	defer sym.deinit(allocator);

	const id = try storage.insertSymbol(db, sym);
	try storage.insertEmbedding(db, allocator, id, &[_]f32{ 0.0, 0.0 });

	const has_fts = try ftsAvailable(db);
	var fake = FakeEmbedder{ .vector = &[_]f32{ 0.0, 0.0 } };
	if (has_fts) {
		const count = try storage.countRows(db, allocator, "symbols_fts");
		try std.testing.expectEqual(@as(i64, 1), count);
		const fts_results = try ftsCandidates(allocator, db, "functions hash", 3);
		defer freeResults(allocator, fts_results);
		try std.testing.expectEqual(@as(usize, 1), fts_results.len);
	}
	const results = try search(allocator, db, fake.embedder(), "functions hash", .{
		.top_n = 3,
		.mode = .lexical,
	});
	defer freeResults(allocator, results);

	if (has_fts) {
		try std.testing.expectEqual(@as(usize, 1), results.len);
		try std.testing.expectEqualStrings("crc32", results[0].symbol.name);
	} else {
		try std.testing.expectEqual(@as(usize, 0), results.len);
	}
}

const FakeEmbedder = struct {
	vector: []const f32,

	pub fn embedder(self: *FakeEmbedder) embedding.Embedder {
		return .{ .ctx = self, .embed = embed, .free = free };
	}

	fn embed(ctx: *anyopaque, allocator: std.mem.Allocator, inputs: []const []const u8) ![][]f32 {
		const self: *FakeEmbedder = @ptrCast(@alignCast(ctx));
		_ = inputs;
		var rows = try allocator.alloc([]f32, 1);
		const row = try allocator.alloc(f32, self.vector.len);
		@memcpy(row, self.vector);
		rows[0] = row;
		return rows;
	}

	fn free(ctx: *anyopaque, allocator: std.mem.Allocator, embeddings: [][]f32) void {
		_ = ctx;
		for (embeddings) |row| allocator.free(row);
		allocator.free(embeddings);
	}
};
