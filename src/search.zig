const std = @import("std");
const storage = @import("storage.zig");
const embedding = @import("embedding.zig");
const model = @import("model.zig");
const hashline = @import("hashline.zig");

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
	score_dropoff: f32 = 0.65,
	allowed_langs: []const []const u8 = &[_][]const u8{},
	allowed_exts: []const []const u8 = &[_][]const u8{},
	comments_only: bool = false,
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

pub const SearchResult = struct {
	results: []Result,
	total_relevant: usize,
};

pub fn search(
	allocator: std.mem.Allocator,
	db: storage.Db,
	embedder: embedding.Embedder,
	query: []const u8,
	options: Options,
) !SearchResult {
	if (query.len == 0) return error.EmptyQuery;
	if (options.top_n == 0) return .{ .results = try allocator.alloc(Result, 0), .total_relevant = 0 };

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
		const lexical = try lexicalCandidates(
			allocator,
			db,
			query,
			options.top_n * options.candidate_multiplier,
			options.comments_only,
		);
		for (lexical) |res| try results.append(allocator, res);
		allocator.free(lexical);
	} else {
		const inputs = [_][]const u8{ query };
		const embeddings = try embedder.embed(embedder.ctx, allocator, &inputs);
		defer embedder.free(embedder.ctx, allocator, embeddings);
		if (embeddings.len != 1) return error.InvalidEmbeddingCount;

		const limit = options.top_n * options.candidate_multiplier;
		const vector_results = try vectorCandidates(allocator, db, embeddings[0], limit, options.comments_only);
		for (vector_results) |res| try results.append(allocator, res);
		allocator.free(vector_results);

		if (options.mode == .hybrid) {
			const lexical = try lexicalCandidates(allocator, db, query, limit, options.comments_only);
			defer allocator.free(lexical);
			for (lexical) |res| {
				try appendUnique(allocator, &results, res);
			}
		}
	}

	if (options.comments_only) {
		var filtered = std.ArrayListUnmanaged(Result){};
		errdefer {
			for (filtered.items) |*res| res.deinit(allocator);
			filtered.deinit(allocator);
		}
		for (results.items) |res| {
			if (res.symbol.doc_comment != null) {
				try filtered.append(allocator, res);
			} else {
				var tmp = res;
				tmp.deinit(allocator);
			}
		}
		results.deinit(allocator);
		results = filtered;
	}

	if (options.allowed_langs.len > 0 or options.allowed_exts.len > 0) {
		var filtered = std.ArrayListUnmanaged(Result){};
		errdefer {
			for (filtered.items) |*res| res.deinit(allocator);
			filtered.deinit(allocator);
		}
		for (results.items) |res| {
			if (matchesFilters(res.symbol, options)) {
				try filtered.append(allocator, res);
			} else {
				var tmp = res;
				tmp.deinit(allocator);
			}
		}
		results.deinit(allocator);
		results = filtered;
	}

	const query_trimmed = std.mem.trim(u8, query, " \t\r\n");
	for (results.items) |*res| {
		const lexical = try lexicalScore(allocator, query, res.symbol, options.comments_only);
		res.lexical = lexical;
		const vector_score = if (std.math.isInf(res.distance)) 0 else (1.0 / (1.0 + res.distance));
		if (options.mode == .vector) {
			res.score = vector_score;
		} else if (options.mode == .lexical) {
			res.score = lexical;
		} else {
			res.score = vector_score * weight_vector + lexical * weight_lexical;
		}

		// Post-combination name-relevance adjustment: the vector model doesn't
		// distinguish definitions from call sites, so boost/penalize based on
		// whether the query matches the symbol name vs. just appearing in the signature.
		if (!options.comments_only and query_trimmed.len > 0 and options.mode != .lexical) {
			const name_rel = nameRelevance(allocator, query_trimmed, res.symbol.name) catch .none;
			switch (name_rel) {
				.exact => res.score = @min(1.0, res.score * 1.25),
				.substring => res.score = @min(1.0, res.score * 1.1),
				.none => if (lexical > 0) {
					res.score = res.score * 0.7;
				},
			}
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

	// Apply score dropoff: drop results below top_score * score_dropoff
	var relevant: usize = filtered.items.len;
	if (filtered.items.len > 0 and options.score_dropoff > 0) {
		const floor = filtered.items[0].score * options.score_dropoff;
		relevant = 0;
		for (filtered.items) |res| {
			if (res.score >= floor) {
				relevant += 1;
			} else break; // sorted desc, so once below floor, all remaining are too
		}
	}

	const take = @min(relevant, options.top_n);
	const out = try allocator.alloc(Result, take);
	@memcpy(out, filtered.items[0..take]);
	for (filtered.items[take..]) |*res| res.deinit(allocator);
	filtered.deinit(allocator);
	return .{ .results = out, .total_relevant = relevant };
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

fn matchesFilters(symbol: model.Symbol, options: Options) bool {
	if (options.allowed_langs.len > 0) {
		var ok = false;
		for (options.allowed_langs) |lang| {
			if (std.mem.eql(u8, symbol.language, lang)) {
				ok = true;
				break;
			}
		}
		if (!ok) return false;
	}
	if (options.allowed_exts.len > 0) {
		var ok = false;
		for (options.allowed_exts) |ext| {
			if (hasExtensionIgnoreCase(symbol.file_path, ext)) {
				ok = true;
				break;
			}
		}
		if (!ok) return false;
	}
	return true;
}

fn hasExtensionIgnoreCase(path: []const u8, ext: []const u8) bool {
	if (ext.len == 0) return false;
	if (path.len < ext.len) return false;
	const tail = path[path.len - ext.len ..];
	return std.ascii.eqlIgnoreCase(tail, ext);
}

fn vectorCandidates(
	allocator: std.mem.Allocator,
	db: storage.Db,
	vector: []const f32,
	limit: usize,
	comments_only: bool,
) ![]Result {
	if (limit == 0) return allocator.alloc(Result, 0);

	const json = try vectorToJson(allocator, vector);
	defer allocator.free(json);

	const table = if (comments_only) "embeddings_comment" else "embeddings";
	// Use vec0 KNN MATCH syntax for indexed search instead of brute-force ORDER BY distance.
	const sql = try allocPrintZ(
		allocator,
		"SELECT symbols.id, lang, file_path, start_line, start_hash, end_line, end_hash, symbol_name, signature, doc_comment, "
		++ "knn.distance "
		++ "FROM {s} AS knn JOIN symbols ON knn.rowid = symbols.id "
		++ "WHERE knn.embedding MATCH vec_f32(?1) AND k = ?2 "
		++ "ORDER BY knn.distance;",
		.{table},
	);
	defer allocator.free(sql);

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
	comments_only: bool,
) ![]Result {
	if (comments_only) {
		return commentCandidates(allocator, db, query, limit);
	}
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
		"SELECT id, lang, file_path, start_line, start_hash, end_line, end_hash, symbol_name, signature, doc_comment, "
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

fn commentCandidates(
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
		"SELECT id, lang, file_path, start_line, start_hash, end_line, end_hash, symbol_name, signature, doc_comment, "
		++ "0.0 AS distance "
		++ "FROM symbols "
		++ "WHERE doc_comment IS NOT NULL "
		++ "AND doc_comment LIKE ?1 COLLATE NOCASE "
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
		"SELECT symbols.id, symbols.lang, symbols.file_path, symbols.start_line, symbols.start_hash, "
		++ "symbols.end_line, symbols.end_hash, symbols.symbol_name, symbols.signature, symbols.doc_comment, "
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
		"SELECT symbols.id, symbols.lang, symbols.file_path, symbols.start_line, symbols.start_hash, "
		++ "symbols.end_line, symbols.end_hash, symbols.symbol_name, symbols.signature, symbols.doc_comment, "
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
	const start_hash = readHashColumn(stmt, 4);
	const end_line = @as(usize, @intCast(sqlite.sqlite3_column_int64(stmt, 5)));
	const end_hash = readHashColumn(stmt, 6);
	const name = try dupColumnText(allocator, stmt, 7);
	const signature = try dupColumnText(allocator, stmt, 8);
	const doc_comment = try dupColumnTextOptional(allocator, stmt, 9);
	const distance = @as(f32, @floatCast(sqlite.sqlite3_column_double(stmt, 10)));

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
			.start_hash = start_hash,
			.end_hash = end_hash,
		},
		.score = 0,
		.distance = distance,
		.lexical = 0,
	};
}

fn readHashColumn(stmt: *sqlite.sqlite3_stmt, col: c_int) ?hashline.Hash {
	const ptr = sqlite.sqlite3_column_text(stmt, col) orelse return null;
	const slice = std.mem.span(ptr);
	if (slice.len < hashline.HASH_LEN) return null;
	return slice[0..hashline.HASH_LEN].*;
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

const NameRelevance = enum { exact, substring, none };

/// Determine how the query relates to the symbol name.
/// Handles multi-word queries by checking camelCase/snake_case joins
/// and whether all individual tokens appear in the name.
fn nameRelevance(allocator: std.mem.Allocator, query: []const u8, name: []const u8) !NameRelevance {
	// Single-token fast path: direct comparison
	if (std.mem.indexOfScalar(u8, query, ' ') == null) {
		if (std.ascii.eqlIgnoreCase(query, name)) return .exact;
		if (std.ascii.indexOfIgnoreCase(name, query) != null) return .substring;
		// Try cross-case match for single tokens (e.g. "nameRelevance" vs "name_relevance")
		const cross = try crossCaseQueryMatch(allocator, query, name);
		if (cross != .none) return cross;
		return .none;
	}

	// Multi-word: try camelCase and snake_case joins for exact match
	const camel = try joinCamelCase(allocator, query);
	defer allocator.free(camel);
	if (std.ascii.eqlIgnoreCase(camel, name)) return .exact;

	const snake = try joinSnakeCase(allocator, query);
	defer allocator.free(snake);
	if (std.ascii.eqlIgnoreCase(snake, name)) return .exact;

	// Check if camelCase/snake_case join is a substring of the name
	if (std.ascii.indexOfIgnoreCase(name, camel) != null) return .substring;
	if (std.ascii.indexOfIgnoreCase(name, snake) != null) return .substring;

	// Check if ALL query tokens appear individually in the name
	var tokens = std.mem.tokenizeAny(u8, query, " \t\r\n");
	var all_in_name = true;
	var token_count: usize = 0;
	while (tokens.next()) |tok| {
		token_count += 1;
		if (std.ascii.indexOfIgnoreCase(name, tok) == null) {
			all_in_name = false;
			break;
		}
	}
	if (all_in_name and token_count > 0) return .substring;

	return .none;
}

/// Join query words as camelCase: "draw rectangle" → "drawRectangle"
fn joinCamelCase(allocator: std.mem.Allocator, query: []const u8) ![]u8 {
	var tokens = std.mem.tokenizeAny(u8, query, " \t\r\n");
	var parts = std.ArrayListUnmanaged(u8){};
	defer parts.deinit(allocator);
	var first = true;
	while (tokens.next()) |tok| {
		if (tok.len == 0) continue;
		if (first) {
			try parts.appendSlice(allocator, tok);
			first = false;
		} else {
			// Capitalize first letter
			var upper: [1]u8 = .{std.ascii.toUpper(tok[0])};
			try parts.appendSlice(allocator, &upper);
			if (tok.len > 1) try parts.appendSlice(allocator, tok[1..]);
		}
	}
	return parts.toOwnedSlice(allocator);
}

/// Join query words as snake_case: "draw rectangle" → "draw_rectangle"
fn joinSnakeCase(allocator: std.mem.Allocator, query: []const u8) ![]u8 {
	var tokens = std.mem.tokenizeAny(u8, query, " \t\r\n");
	var parts = std.ArrayListUnmanaged(u8){};
	defer parts.deinit(allocator);
	var first = true;
	while (tokens.next()) |tok| {
		if (tok.len == 0) continue;
		if (!first) try parts.append(allocator, '_');
		try parts.appendSlice(allocator, tok);
		first = false;
	}
	return parts.toOwnedSlice(allocator);
}

/// Split a camelCase or snake_case token into its component words (all lowercased).
/// - "nameRelevance"  → ["name", "relevance"]
/// - "name_relevance" → ["name", "relevance"]
/// - "HTTPServer"     → ["http", "server"]
/// - "parseJSON"      → ["parse", "json"]
/// - "simple"         → ["simple"]
fn splitCamelSnake(allocator: std.mem.Allocator, token: []const u8) ![][]u8 {
	var parts = std.ArrayListUnmanaged([]u8){};
	errdefer {
		for (parts.items) |p| allocator.free(p);
		parts.deinit(allocator);
	}

	var start: usize = 0;
	var i: usize = 0;
	while (i < token.len) : (i += 1) {
		if (token[i] == '_') {
			if (i > start) {
				try parts.append(allocator, try toLowerDupe(allocator, token[start..i]));
			}
			start = i + 1;
			continue;
		}
		if (i > start and std.ascii.isUpper(token[i])) {
			// Check if this is start of a new word or an uppercase run
			if (!std.ascii.isUpper(token[i - 1])) {
				// camelCase boundary: "nameR" → split before 'R'
				try parts.append(allocator, try toLowerDupe(allocator, token[start..i]));
				start = i;
			} else if (i + 1 < token.len and !std.ascii.isUpper(token[i + 1]) and token[i + 1] != '_') {
				// End of uppercase run: "HTTPServer" → split before 'S' to get "HTTP" + "Server"
				try parts.append(allocator, try toLowerDupe(allocator, token[start..i]));
				start = i;
			}
		}
	}
	if (start < token.len) {
		try parts.append(allocator, try toLowerDupe(allocator, token[start..]));
	}

	return parts.toOwnedSlice(allocator);
}

fn toLowerDupe(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
	const result = try allocator.alloc(u8, s.len);
	for (s, 0..) |c, j| result[j] = std.ascii.toLower(c);
	return result;
}

fn lexicalScore(allocator: std.mem.Allocator, query: []const u8, symbol: model.Symbol, comments_only: bool) !f32 {
	var tokens = std.mem.tokenizeAny(u8, query, " \t\r\n");
	var token_count: usize = 0;
	var weighted_score: f32 = 0;

	// Weight matches by where the query term appears:
	//   name match    → 1.0  (this symbol IS the thing)
	//   doc comment   → 0.5  (described in docs)
	//   signature only → 0.3 (just referenced/called in body)
	while (tokens.next()) |tok| {
		token_count += 1;

		const in_doc = if (symbol.doc_comment) |doc| std.ascii.indexOfIgnoreCase(doc, tok) != null else false;
		if (comments_only) {
			if (in_doc) weighted_score += 1.0;
		} else {
			const in_name = std.ascii.indexOfIgnoreCase(symbol.name, tok) != null;
			const in_sig = std.ascii.indexOfIgnoreCase(symbol.signature, tok) != null;
			if (in_name) {
				weighted_score += 1.0;
			} else if (in_doc) {
				weighted_score += 0.5;
			} else if (in_sig) {
				weighted_score += 0.3;
			} else {
				// Try cross-case matching: split camelCase/snake_case token into parts
				// and check if the joined variants match the symbol name
				const cross_score = try crossCaseMatch(allocator, tok, symbol.name, symbol.signature);
				if (cross_score > 0) weighted_score += cross_score;
			}
		}
	}

	if (token_count == 0) return 0;
	var base_score = weighted_score / @as(f32, @floatFromInt(token_count));

	// Exact-match and substring bonuses (only for non-comment-only mode)
	if (!comments_only) {
		const query_trimmed = std.mem.trim(u8, query, " \t\r\n");
		if (query_trimmed.len > 0) {
			if (std.ascii.eqlIgnoreCase(query_trimmed, symbol.name)) {
				// Exact name match → strong boost
				base_score = @min(1.0, base_score + 0.5);
			} else if (query_trimmed.len >= 3 and std.ascii.indexOfIgnoreCase(symbol.name, query_trimmed) != null) {
				// Full query is a substring of the name → moderate boost
				base_score = @min(1.0, base_score + 0.2);
			} else {
				// Try cross-case exact/substring match for the full query
				const cross = try crossCaseQueryMatch(allocator, query_trimmed, symbol.name);
				if (cross == .exact) {
					base_score = @min(1.0, base_score + 0.5);
				} else if (cross == .substring) {
					base_score = @min(1.0, base_score + 0.2);
				}
			}
		}
	}

	return base_score;
}

/// Check if a single token (possibly camelCase or snake_case) matches a field
/// via its alternate-case form. Returns the match weight (1.0 for name, 0.3 for sig, 0 for none).
fn crossCaseMatch(allocator: std.mem.Allocator, tok: []const u8, name: []const u8, signature: []const u8) !f32 {
	const parts = try splitCamelSnake(allocator, tok);
	defer {
		for (parts) |p| allocator.free(p);
		allocator.free(parts);
	}
	if (parts.len <= 1) return 0; // single word, no cross-case to try

	// Try camelCase join
	const camel = try joinPartsAsCamel(allocator, parts);
	defer allocator.free(camel);
	if (std.ascii.indexOfIgnoreCase(name, camel) != null) return 1.0;

	// Try snake_case join
	const snake = try joinPartsAsSnake(allocator, parts);
	defer allocator.free(snake);
	if (std.ascii.indexOfIgnoreCase(name, snake) != null) return 1.0;

	// Check signature
	if (std.ascii.indexOfIgnoreCase(signature, camel) != null) return 0.3;
	if (std.ascii.indexOfIgnoreCase(signature, snake) != null) return 0.3;

	// Check if all sub-parts appear individually in the name
	var all_in_name = true;
	for (parts) |p| {
		if (std.ascii.indexOfIgnoreCase(name, p) == null) {
			all_in_name = false;
			break;
		}
	}
	if (all_in_name) return 0.8;

	return 0;
}

/// Check if a full query (single token, possibly camelCase/snake_case) matches a symbol
/// name in its alternate case form.
fn crossCaseQueryMatch(allocator: std.mem.Allocator, query: []const u8, name: []const u8) !NameRelevance {
	const parts = try splitCamelSnake(allocator, query);
	defer {
		for (parts) |p| allocator.free(p);
		allocator.free(parts);
	}
	if (parts.len <= 1) return .none;

	const camel = try joinPartsAsCamel(allocator, parts);
	defer allocator.free(camel);
	if (std.ascii.eqlIgnoreCase(camel, name)) return .exact;

	const snake = try joinPartsAsSnake(allocator, parts);
	defer allocator.free(snake);
	if (std.ascii.eqlIgnoreCase(snake, name)) return .exact;

	if (std.ascii.indexOfIgnoreCase(name, camel) != null) return .substring;
	if (std.ascii.indexOfIgnoreCase(name, snake) != null) return .substring;

	return .none;
}

/// Join pre-split parts as camelCase: ["name", "relevance"] → "nameRelevance"
fn joinPartsAsCamel(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
	var buf = std.ArrayListUnmanaged(u8){};
	defer buf.deinit(allocator);
	for (parts, 0..) |part, idx| {
		if (part.len == 0) continue;
		if (idx == 0) {
			try buf.appendSlice(allocator, part); // already lowercased
		} else {
			var upper: [1]u8 = .{std.ascii.toUpper(part[0])};
			try buf.appendSlice(allocator, &upper);
			if (part.len > 1) try buf.appendSlice(allocator, part[1..]);
		}
	}
	return buf.toOwnedSlice(allocator);
}

/// Join pre-split parts as snake_case: ["name", "relevance"] → "name_relevance"
fn joinPartsAsSnake(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
	var buf = std.ArrayListUnmanaged(u8){};
	defer buf.deinit(allocator);
	for (parts, 0..) |part, idx| {
		if (part.len == 0) continue;
		if (idx > 0) try buf.append(allocator, '_');
		try buf.appendSlice(allocator, part);
	}
	return buf.toOwnedSlice(allocator);
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

	// Both tokens match only in doc_comment (0.5 weight each) → 0.5
	const score = try lexicalScore(allocator, "hash functions", symbol, false);
	try std.testing.expectApproxEqAbs(@as(f32, 0.5), score, 0.0001);
}

test "lexicalScore comments_only ignores name and signature" {
	const allocator = std.testing.allocator;
	var symbol = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/hash.zig"),
		.name = try allocator.dupe(u8, "checksum"),
		.signature = try allocator.dupe(u8, "fn checksum() void"),
		.doc_comment = try allocator.dupe(u8, "Compute hash"),
		.start_line = 1,
		.end_line = 1,
	};
	defer symbol.deinit(allocator);

	const score = try lexicalScore(allocator, "checksum", symbol, true);
	try std.testing.expectApproxEqAbs(@as(f32, 0.0), score, 0.0001);
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
	const results = (try search(allocator, db, fake.embedder(), "query", .{
		.top_n = 1,
		.mode = .vector,
	})).results;
	defer freeResults(allocator, results);

	try std.testing.expectEqual(@as(usize, 1), results.len);
	try std.testing.expectEqualStrings("near", results[0].symbol.name);
}

test "search comments_only uses comment embeddings" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

	var sym_comment = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/a.zig"),
		.name = try allocator.dupe(u8, "commented"),
		.signature = try allocator.dupe(u8, "fn commented() void"),
		.doc_comment = try allocator.dupe(u8, "Useful comment"),
		.start_line = 1,
		.end_line = 1,
	};
	defer sym_comment.deinit(allocator);

	var sym_plain = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/b.zig"),
		.name = try allocator.dupe(u8, "plain"),
		.signature = try allocator.dupe(u8, "fn plain() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym_plain.deinit(allocator);

	const id_comment = try storage.insertSymbol(db, sym_comment);
	const id_plain = try storage.insertSymbol(db, sym_plain);
	try storage.insertCommentEmbedding(db, allocator, id_comment, &[_]f32{ 0.0, 0.0 });
	try storage.insertEmbedding(db, allocator, id_plain, &[_]f32{ 10.0, 0.0 });

	var fake = FakeEmbedder{ .vector = &[_]f32{ 0.0, 0.0 } };
	const results = (try search(allocator, db, fake.embedder(), "query", .{
		.top_n = 1,
		.mode = .vector,
		.comments_only = true,
	})).results;
	defer freeResults(allocator, results);

	try std.testing.expectEqual(@as(usize, 1), results.len);
	try std.testing.expectEqualStrings("commented", results[0].symbol.name);
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
	const results = (try search(allocator, db, fake.embedder(), "query", .{
		.top_n = 5,
		.mode = .vector,
		.min_score = 0.5,
	})).results;
	defer freeResults(allocator, results);

try std.testing.expectEqual(@as(usize, 1), results.len);
try std.testing.expectEqualStrings("near", results[0].symbol.name);
}

test "search filters by language and extension" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

	var sym_code = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/main.zig"),
		.name = try allocator.dupe(u8, "add"),
		.signature = try allocator.dupe(u8, "fn add() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym_code.deinit(allocator);

	var sym_doc = model.Symbol{
		.language = try allocator.dupe(u8, "markdown"),
		.file_path = try allocator.dupe(u8, "README.md"),
		.name = try allocator.dupe(u8, "Title"),
		.signature = try allocator.dupe(u8, "Intro"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym_doc.deinit(allocator);

	_ = try storage.insertSymbol(db, sym_code);
	_ = try storage.insertSymbol(db, sym_doc);

	var fake = FakeEmbedder{ .vector = &[_]f32{ 0.0, 0.0 } };
	const results_lang = (try search(allocator, db, fake.embedder(), "Intro", .{
		.top_n = 5,
		.mode = .lexical,
		.allowed_langs = &[_][]const u8{ "markdown" },
	})).results;
	defer freeResults(allocator, results_lang);

	try std.testing.expectEqual(@as(usize, 1), results_lang.len);
	try std.testing.expectEqualStrings("README.md", results_lang[0].symbol.file_path);

	const results_ext = (try search(allocator, db, fake.embedder(), "add", .{
		.top_n = 5,
		.mode = .lexical,
		.allowed_exts = &[_][]const u8{ ".zig" },
	})).results;
	defer freeResults(allocator, results_ext);

	try std.testing.expectEqual(@as(usize, 1), results_ext.len);
	try std.testing.expectEqualStrings("src/main.zig", results_ext[0].symbol.file_path);
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

	const prefer_vector = (try search(allocator, db, fake.embedder(), "alpha beta", .{
		.top_n = 1,
		.mode = .hybrid,
		.weight_vector = 0.9,
		.weight_lexical = 0.1,
	})).results;
	defer freeResults(allocator, prefer_vector);
	try std.testing.expectEqualStrings("near_nomatch", prefer_vector[0].symbol.name);

	const prefer_lexical = (try search(allocator, db, fake.embedder(), "alpha beta", .{
		.top_n = 1,
		.mode = .hybrid,
		.weight_vector = 0.1,
		.weight_lexical = 0.9,
	})).results;
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
	const results = (try search(allocator, db, fake.embedder(), "missing", .{
		.top_n = 1,
		.mode = .hybrid,
		.weight_vector = 2.0,
		.weight_lexical = 1.0,
	})).results;
	defer freeResults(allocator, results);

	try std.testing.expectEqual(@as(usize, 1), results.len);
	// "missing" has lex=0 so no name-relevance penalty applies: (2/3) ≈ 0.6667
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
	const results = (try search(allocator, db, fake.embedder(), "functions hash", .{
		.top_n = 3,
		.mode = .lexical,
	})).results;
	defer freeResults(allocator, results);

	if (has_fts) {
		try std.testing.expectEqual(@as(usize, 1), results.len);
		try std.testing.expectEqualStrings("crc32", results[0].symbol.name);
	} else {
		try std.testing.expectEqual(@as(usize, 0), results.len);
	}
}

test "search hybrid returns no duplicate symbol IDs" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

	// Insert a symbol that will match BOTH vector (nearby) and lexical (name match)
	var sym = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/hash.zig"),
		.name = try allocator.dupe(u8, "computeHash"),
		.signature = try allocator.dupe(u8, "pub fn computeHash(data: []const u8) u32"),
		.doc_comment = try allocator.dupe(u8, "Compute a hash digest"),
		.start_line = 1,
		.end_line = 10,
	};
	defer sym.deinit(allocator);

	const id = try storage.insertSymbol(db, sym);
	try storage.insertEmbedding(db, allocator, id, &[_]f32{ 0.0, 0.0 });

	// Hybrid search: vector will find it (close embedding), lexical will also find it (name match)
	var fake = FakeEmbedder{ .vector = &[_]f32{ 0.0, 0.0 } };
	const results = (try search(allocator, db, fake.embedder(), "computeHash", .{
		.top_n = 10,
		.mode = .hybrid,
	})).results;
	defer freeResults(allocator, results);

	// Must appear exactly once despite matching both vector and lexical
	try std.testing.expectEqual(@as(usize, 1), results.len);
	try std.testing.expectEqualStrings("computeHash", results[0].symbol.name);

	// Verify no duplicate IDs
	for (results, 0..) |res, i| {
		for (results[i + 1 ..]) |other| {
			try std.testing.expect(res.id != other.id);
		}
	}
}

test "UNIQUE constraint prevents duplicate symbols in DB" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

	var sym1 = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/a.zig"),
		.name = try allocator.dupe(u8, "foo"),
		.signature = try allocator.dupe(u8, "fn foo() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 5,
	};
	defer sym1.deinit(allocator);

	_ = try storage.insertSymbol(db, sym1);

	// Insert the same symbol again (same file, lines, name) — should replace, not duplicate
	var sym2 = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/a.zig"),
		.name = try allocator.dupe(u8, "foo"),
		.signature = try allocator.dupe(u8, "fn foo() void // updated"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 5,
	};
	defer sym2.deinit(allocator);

	_ = try storage.insertSymbol(db, sym2);

	// Should have exactly 1 row, not 2
	const count = try storage.countRows(db, allocator, "symbols");
	try std.testing.expectEqual(@as(i64, 1), count);
}

test "search omits low-relevance results below score dropoff" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

	// sym1: very close to query vector
	var sym1 = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/a.zig"),
		.name = try allocator.dupe(u8, "close"),
		.signature = try allocator.dupe(u8, "fn close() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym1.deinit(allocator);

	// sym2: moderately close
	var sym2 = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/b.zig"),
		.name = try allocator.dupe(u8, "medium"),
		.signature = try allocator.dupe(u8, "fn medium() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym2.deinit(allocator);

	// sym3: very far from query vector — should be dropped by dropoff
	var sym3 = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/c.zig"),
		.name = try allocator.dupe(u8, "distant"),
		.signature = try allocator.dupe(u8, "fn distant() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym3.deinit(allocator);

	const id1 = try storage.insertSymbol(db, sym1);
	const id2 = try storage.insertSymbol(db, sym2);
	const id3 = try storage.insertSymbol(db, sym3);
	// distance 0 → score 1.0, distance 0.5 → score ~0.667, distance 100 → score ~0.0099
	try storage.insertEmbedding(db, allocator, id1, &[_]f32{ 0.0, 0.0 });
	try storage.insertEmbedding(db, allocator, id2, &[_]f32{ 0.5, 0.0 });
	try storage.insertEmbedding(db, allocator, id3, &[_]f32{ 100.0, 0.0 });

	var fake = FakeEmbedder{ .vector = &[_]f32{ 0.0, 0.0 } };
	const results = (try search(allocator, db, fake.embedder(), "query", .{
		.top_n = 10,
		.mode = .vector,
		.score_dropoff = 0.65,
	})).results;
	defer freeResults(allocator, results);

	// sym3 scores ~0.01, top score is 1.0, floor is 0.65 — sym3 should be dropped
	try std.testing.expect(results.len < 3);
	try std.testing.expect(results.len >= 1);
	// First result should be the closest
	try std.testing.expectEqualStrings("close", results[0].symbol.name);
}

test "exact symbol name match scores higher than partial match" {
	const allocator = std.testing.allocator;
	var sym_exact = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/a.zig"),
		.name = try allocator.dupe(u8, "insertSymbol"),
		.signature = try allocator.dupe(u8, "fn insertSymbol() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym_exact.deinit(allocator);

	var sym_partial = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/b.zig"),
		.name = try allocator.dupe(u8, "deleteSymbol"),
		.signature = try allocator.dupe(u8, "fn deleteSymbol() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym_partial.deinit(allocator);

	const score_exact = try lexicalScore(allocator, "insertSymbol", sym_exact, false);
	const score_partial = try lexicalScore(allocator, "insertSymbol", sym_partial, false);

	// Exact name match should score higher than partial (both have "Symbol" in name)
	try std.testing.expect(score_exact > score_partial);
	// Exact match should get the bonus
	try std.testing.expect(score_exact >= 1.0);
}

test "lexicalScore name substring bonus for contained query" {
	const allocator = std.testing.allocator;
	var sym_contains = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/a.zig"),
		.name = try allocator.dupe(u8, "myInsertHelper"),
		.signature = try allocator.dupe(u8, "fn myInsertHelper() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym_contains.deinit(allocator);

	var sym_no_match = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/b.zig"),
		.name = try allocator.dupe(u8, "deleteAll"),
		.signature = try allocator.dupe(u8, "fn deleteAll() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym_no_match.deinit(allocator);

	const score_contains = try lexicalScore(allocator, "Insert", sym_contains, false);
	const score_none = try lexicalScore(allocator, "Insert", sym_no_match, false);

	// Name containing the full query should get substring bonus
	try std.testing.expect(score_contains > score_none);
}

test "nameRelevance matches camelCase from multi-word query" {
	const allocator = std.testing.allocator;
	// "draw rectangle" → camelCase "drawRectangle" matches exactly
	try std.testing.expectEqual(NameRelevance.exact, try nameRelevance(allocator, "draw rectangle", "drawRectangle"));
	// snake_case match
	try std.testing.expectEqual(NameRelevance.exact, try nameRelevance(allocator, "draw rectangle", "draw_rectangle"));
	// All tokens in name (different joining)
	try std.testing.expectEqual(NameRelevance.substring, try nameRelevance(allocator, "draw rectangle", "drawBigRectangle"));
	// camelCase join is substring of a longer name
	try std.testing.expectEqual(NameRelevance.substring, try nameRelevance(allocator, "draw rect", "myDrawRectHelper"));
	// Single word exact
	try std.testing.expectEqual(NameRelevance.exact, try nameRelevance(allocator, "init", "init"));
	// Single word substring
	try std.testing.expectEqual(NameRelevance.substring, try nameRelevance(allocator, "init", "initEvents"));
	// No match at all
	try std.testing.expectEqual(NameRelevance.none, try nameRelevance(allocator, "draw rectangle", "colorPicker"));
	// Case-insensitive exact
	try std.testing.expectEqual(NameRelevance.exact, try nameRelevance(allocator, "Draw Rectangle", "drawRectangle"));
}

test "splitCamelSnake splits camelCase" {
	const allocator = std.testing.allocator;
	const parts = try splitCamelSnake(allocator, "nameRelevance");
	defer {
		for (parts) |p| allocator.free(p);
		allocator.free(parts);
	}
	try std.testing.expectEqual(@as(usize, 2), parts.len);
	try std.testing.expectEqualStrings("name", parts[0]);
	try std.testing.expectEqualStrings("relevance", parts[1]);
}

test "splitCamelSnake splits snake_case" {
	const allocator = std.testing.allocator;
	const parts = try splitCamelSnake(allocator, "name_relevance");
	defer {
		for (parts) |p| allocator.free(p);
		allocator.free(parts);
	}
	try std.testing.expectEqual(@as(usize, 2), parts.len);
	try std.testing.expectEqualStrings("name", parts[0]);
	try std.testing.expectEqualStrings("relevance", parts[1]);
}

test "splitCamelSnake handles acronyms" {
	const allocator = std.testing.allocator;
	const parts = try splitCamelSnake(allocator, "HTTPServer");
	defer {
		for (parts) |p| allocator.free(p);
		allocator.free(parts);
	}
	try std.testing.expectEqual(@as(usize, 2), parts.len);
	try std.testing.expectEqualStrings("http", parts[0]);
	try std.testing.expectEqualStrings("server", parts[1]);
}

test "splitCamelSnake handles single word" {
	const allocator = std.testing.allocator;
	const parts = try splitCamelSnake(allocator, "simple");
	defer {
		for (parts) |p| allocator.free(p);
		allocator.free(parts);
	}
	try std.testing.expectEqual(@as(usize, 1), parts.len);
	try std.testing.expectEqualStrings("simple", parts[0]);
}

test "splitCamelSnake handles trailing acronym" {
	const allocator = std.testing.allocator;
	const parts = try splitCamelSnake(allocator, "parseJSON");
	defer {
		for (parts) |p| allocator.free(p);
		allocator.free(parts);
	}
	try std.testing.expectEqual(@as(usize, 2), parts.len);
	try std.testing.expectEqualStrings("parse", parts[0]);
	try std.testing.expectEqualStrings("json", parts[1]);
}

test "lexicalScore cross-case matching camelCase query vs snake_case name" {
	const allocator = std.testing.allocator;
	var symbol = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/search.zig"),
		.name = try allocator.dupe(u8, "name_relevance"),
		.signature = try allocator.dupe(u8, "fn name_relevance() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer symbol.deinit(allocator);

	const score = try lexicalScore(allocator, "nameRelevance", symbol, false);
	// Should get a positive score via cross-case matching
	try std.testing.expect(score > 0.0);
}

test "lexicalScore cross-case matching snake_case query vs camelCase name" {
	const allocator = std.testing.allocator;
	var symbol = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/search.zig"),
		.name = try allocator.dupe(u8, "nameRelevance"),
		.signature = try allocator.dupe(u8, "fn nameRelevance() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer symbol.deinit(allocator);

	const score = try lexicalScore(allocator, "name_relevance", symbol, false);
	// Should get a positive score via cross-case matching
	try std.testing.expect(score > 0.0);
}

test "nameRelevance single-token cross-case matching" {
	const allocator = std.testing.allocator;
	// camelCase query vs snake_case name
	try std.testing.expectEqual(NameRelevance.exact, try nameRelevance(allocator, "nameRelevance", "name_relevance"));
	// snake_case query vs camelCase name
	try std.testing.expectEqual(NameRelevance.exact, try nameRelevance(allocator, "name_relevance", "nameRelevance"));
	// camelCase query vs camelCase name (substring)
	try std.testing.expectEqual(NameRelevance.substring, try nameRelevance(allocator, "nameRelevance", "myNameRelevanceHelper"));
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
