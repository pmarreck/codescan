const std = @import("std");
const storage = @import("storage.zig");
const embedding = @import("embedding.zig");
const model = @import("model.zig");
const hashline = @import("hashline.zig");
const simd = @import("simd.zig");

const sqlite = storage.sqlite;

pub const SearchMode = enum {
	vector,
	lexical,
	hybrid,

	pub fn parse(value: []const u8) !SearchMode {
		if (std.mem.eql(u8, value, "vector")) return .vector;
		if (std.mem.eql(u8, value, "lexical")) return .lexical;
		if (std.mem.eql(u8, value, "hybrid")) return .hybrid;
		return error.InvalidMode;
	}
};

pub const FusionMode = enum {
	weighted_sum,
	rrf,

	pub fn parse(value: []const u8) !FusionMode {
		if (std.mem.eql(u8, value, "weighted_sum") or std.mem.eql(u8, value, "weighted-sum")) return .weighted_sum;
		if (std.mem.eql(u8, value, "rrf")) return .rrf;
		return error.InvalidFusionMode;
	}
};

pub const FtsMode = enum {
	broad, // OR for all tokens (maximum recall)
	balanced, // AND for significant tokens, drops short/stop words
	strict, // AND for all tokens (maximum precision)

	pub fn parse(value: []const u8) !FtsMode {
		if (std.mem.eql(u8, value, "broad")) return .broad;
		if (std.mem.eql(u8, value, "balanced")) return .balanced;
		if (std.mem.eql(u8, value, "strict")) return .strict;
		return error.InvalidFtsMode;
	}
};

const QueryIntent = enum {
	lookup,
	navigation,
	conceptual,
};

pub const Options = struct {
	top_n: usize = 10,
	candidate_multiplier: usize = 5,
	mode: SearchMode = .hybrid,
	fusion: FusionMode = .weighted_sum,
	rrf_k: f32 = 60,
	fts_mode: FtsMode = .broad,
	weight_vector: f32 = 0.7,
	weight_lexical: f32 = 0.3,
	weight_symbol_kind: f32 = 0.0,
	weight_symbol_visibility: f32 = 0.0,
	weight_symbol_scope: f32 = 0.0,
	weight_symbol_arity: f32 = 0.0,
	min_score: f32 = 0.0,
	score_dropoff: f32 = 0.3,
	allowed_langs: []const []const u8 = &[_][]const u8{},
	allowed_exts: []const []const u8 = &[_][]const u8{},
	allowed_symbol_kinds: []const []const u8 = &[_][]const u8{},
	allowed_paths: []const []const u8 = &[_][]const u8{},
	comments_only: bool = false,
};

pub const Result = struct {
	id: i64,
	symbol: model.Symbol,
	score: f32,
	distance: f32,
	lexical: f32,
	bm25: f32, // raw FTS5 bm25 score (negative; 0 = no FTS data)

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
	if (query.len == 0) {
		if (options.allowed_symbol_kinds.len == 0 and
			options.allowed_langs.len == 0 and
			options.allowed_exts.len == 0 and
			options.allowed_paths.len == 0)
		{
			return error.EmptyQuery;
		}
		return browseSymbols(allocator, db, options);
	}
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

	// Rank maps for RRF hybrid fusion (id → 1-based rank in source list).
	var vector_ranks = std.AutoHashMap(i64, usize).init(allocator);
	defer vector_ranks.deinit();
	var lexical_ranks = std.AutoHashMap(i64, usize).init(allocator);
	defer lexical_ranks.deinit();

	if (options.mode == .lexical) {
		const lexical = try lexicalCandidates(
			allocator,
			db,
			query,
			options.top_n * options.candidate_multiplier,
			options.comments_only,
			options.fts_mode,
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

		// Build vector rank map (candidates are ordered by distance, best first).
		for (vector_results, 0..) |res, i| {
			try vector_ranks.put(res.id, i + 1); // 1-based rank
		}

		for (vector_results) |res| try results.append(allocator, res);
		allocator.free(vector_results);

		if (options.mode == .hybrid) {
			// Build seen-set from vector results for O(1) dedup lookups.
			var seen = std.AutoHashMap(i64, void).init(allocator);
			defer seen.deinit();
			for (results.items) |res| {
				try seen.put(res.id, {});
			}

			const lexical = try lexicalCandidates(allocator, db, query, limit, options.comments_only, options.fts_mode);
			defer allocator.free(lexical);

			// Build lexical rank map (candidates are ordered by relevance, best first).
			for (lexical, 0..) |res, i| {
				try lexical_ranks.put(res.id, i + 1); // 1-based rank
			}

			for (lexical) |res| {
				if (seen.contains(res.id)) {
					var tmp = res;
					tmp.deinit(allocator);
				} else {
					try seen.put(res.id, {});
					try results.append(allocator, res);
				}
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

	if (options.allowed_langs.len > 0 or options.allowed_exts.len > 0 or options.allowed_symbol_kinds.len > 0) {
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

	// Pre-tokenize the query once rather than re-tokenizing per result.
	var token_buf: [64][]const u8 = undefined;
	var query_token_count: usize = 0;
	{
		var tokenizer = std.mem.tokenizeAny(u8, query, " \t\r\n");
		while (tokenizer.next()) |tok| {
			if (query_token_count < token_buf.len) {
				token_buf[query_token_count] = tok;
				query_token_count += 1;
			}
		}
	}
	const query_tokens = token_buf[0..query_token_count];
	const query_intent = inferQueryIntent(query_trimmed, query_tokens);
	const metadata_query = inferMetadataQuery(query_tokens);

	// Normalize BM25 scores to [0, 1] for FTS candidates.
	// FTS5 bm25() returns negative values (more negative = better match).
	var best_bm25: f32 = 0; // most negative
	var worst_bm25: f32 = -std.math.inf(f32); // least negative
	for (results.items) |res| {
		if (res.bm25 != 0) {
			if (res.bm25 < best_bm25) best_bm25 = res.bm25;
			if (res.bm25 > worst_bm25) worst_bm25 = res.bm25;
		}
	}
	const bm25_range = worst_bm25 - best_bm25; // positive number

	for (results.items) |*res| {
		const lexical = if (res.bm25 != 0) blk: {
			// Use normalized BM25 as the lexical score for FTS candidates.
			const bm25_norm = if (bm25_range > 0)
				(worst_bm25 - res.bm25) / bm25_range // best → 1.0, worst → 0.0
			else
				@as(f32, 1.0); // single result or all same score

			// Apply token coverage gating: if the query has multiple tokens,
			// penalize FTS results that only match a fraction of them.
			// Floor at 0.1 because FTS already confirmed the match (may be in body column
			// which isn't loaded into the result struct).
			const coverage = @max(tokenCoverage(query_tokens, res.symbol), 0.1);
			break :blk bm25_norm * coverage;
		} else try lexicalScore(allocator, query_tokens, query_trimmed, res.symbol, options.comments_only);
		res.lexical = lexical;
		const vector_score = if (std.math.isInf(res.distance)) 0 else (1.0 / (1.0 + res.distance));
		if (options.mode == .vector) {
			res.score = vector_score;
		} else if (options.mode == .lexical) {
			res.score = lexical;
		} else if (options.fusion == .rrf) {
			// Reciprocal Rank Fusion: score based on position in source lists.
			const k = options.rrf_k;
			const v_rank = vector_ranks.get(res.id);
			const l_rank = lexical_ranks.get(res.id);
			const v_contrib = if (v_rank) |r| weight_vector / (k + @as(f32, @floatFromInt(r))) else 0;
			const l_contrib = if (l_rank) |r| weight_lexical / (k + @as(f32, @floatFromInt(r))) else 0;
			res.score = v_contrib + l_contrib;
		} else {
			res.score = vector_score * weight_vector + lexical * weight_lexical;
		}

			// Post-combination name-relevance adjustment tuned by inferred query intent.
			if (!options.comments_only and query_trimmed.len > 0 and options.mode != .lexical) {
				const name_rel = nameRelevance(allocator, query_trimmed, res.symbol.name) catch .none;
				switch (name_rel) {
					.exact => {
						const boost: f32 = switch (query_intent) {
							.lookup => 1.35,
							.navigation => 1.2,
							.conceptual => 1.08,
						};
						res.score = @min(@as(f32, 1.0), res.score * boost);
					},
					.substring => {
						const boost: f32 = switch (query_intent) {
							.lookup => 1.15,
							.navigation => 1.1,
							.conceptual => 1.04,
						};
						res.score = @min(@as(f32, 1.0), res.score * boost);
					},
					.none => if (lexical > 0) {
						const penalty: f32 = switch (query_intent) {
							.lookup => 0.8,
							.navigation => 0.88,
							.conceptual => 0.7,
						};
						res.score *= penalty;
					},
				}
			}

			if (!options.comments_only and options.mode != .lexical and query_intent == .navigation) {
				const coverage = pathTokenCoverage(query_tokens, res.symbol.file_path);
				if (coverage > 0) {
					res.score *= (1.0 + (0.2 * coverage));
				}
			}

			// For non-lookup queries, strongly vector-matched local bindings
			// (for example: `var reader = ...`) and generic helper names (`ok`, `file`)
			// are often noise.
			if (!options.comments_only and options.mode != .lexical and query_token_count >= 3 and query_intent != .lookup) {
				if (isLikelyLocalBindingSignature(res.symbol.signature)) {
					const factor: f32 = switch (query_intent) {
						.navigation => if (lexical == 0) 0.72 else 0.86,
						.conceptual => if (lexical == 0) 0.55 else 0.75,
						.lookup => 1.0,
					};
					res.score *= factor;
				}
				if (isGenericSymbolName(res.symbol.name)) {
					const factor: f32 = switch (query_intent) {
						.navigation => if (lexical == 0) 0.82 else 0.92,
						.conceptual => if (lexical == 0) 0.65 else 0.85,
						.lookup => 1.0,
					};
					res.score *= factor;
				}
			}

			res.score = applyMetadataBoost(res.score, res.symbol, metadata_query, options);
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

	// Natural-language queries are prone to duplicate call-site style hits.
	// Down-weight repeated name/signature pairs so distinct symbols surface.
	if (query_token_count >= 3 and query_intent != .lookup) {
		try applyDuplicatePenalty(allocator, filtered.items);
	}

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

fn browseSymbols(allocator: std.mem.Allocator, db: storage.Db, options: Options) !SearchResult {
	if (options.top_n == 0) return .{ .results = try allocator.alloc(Result, 0), .total_relevant = 0 };

	// Build WHERE clauses
	var where_parts = std.ArrayListUnmanaged([]const u8){};
	defer {
		for (where_parts.items) |part| allocator.free(part);
		where_parts.deinit(allocator);
	}

	// Handle symbol kind filter
	if (options.allowed_symbol_kinds.len > 0) {
		// Check for "*" sentinel (any non-null kind)
		var has_wildcard = false;
		for (options.allowed_symbol_kinds) |k| {
			if (std.mem.eql(u8, k, "*")) {
				has_wildcard = true;
				break;
			}
		}
		if (has_wildcard) {
			try where_parts.append(allocator, try allocator.dupe(u8, "symbol_kind IS NOT NULL"));
		} else {
			// Build IN clause
			var in_buf = std.ArrayListUnmanaged(u8){};
			defer in_buf.deinit(allocator);
			try in_buf.appendSlice(allocator, "symbol_kind IN (");
			for (options.allowed_symbol_kinds, 0..) |k, idx| {
				if (idx > 0) try in_buf.appendSlice(allocator, ", ");
				try in_buf.append(allocator, '\'');
				try in_buf.appendSlice(allocator, k);
				try in_buf.append(allocator, '\'');
			}
			try in_buf.appendSlice(allocator, ")");
			try where_parts.append(allocator, try allocator.dupe(u8, in_buf.items));
		}
	}

	// Handle language filter
	if (options.allowed_langs.len > 0) {
		var in_buf = std.ArrayListUnmanaged(u8){};
		defer in_buf.deinit(allocator);
		try in_buf.appendSlice(allocator, "lang IN (");
		for (options.allowed_langs, 0..) |lang, idx| {
			if (idx > 0) try in_buf.appendSlice(allocator, ", ");
			try in_buf.append(allocator, '\'');
			try in_buf.appendSlice(allocator, lang);
			try in_buf.append(allocator, '\'');
		}
		try in_buf.appendSlice(allocator, ")");
		try where_parts.append(allocator, try allocator.dupe(u8, in_buf.items));
	}

	// Handle extension filter (applied post-query via matchesFilters, not in SQL)
	// Extensions are checked on file_path which is harder in SQL, so we over-fetch and filter.

	// Build final SQL
	var sql_buf = std.ArrayListUnmanaged(u8){};
	defer sql_buf.deinit(allocator);
	try sql_buf.appendSlice(allocator,
		"SELECT id, lang, file_path, start_line, start_hash, end_line, end_hash, symbol_name, signature, doc_comment, " ++
		"symbol_kind, symbol_visibility, symbol_scope, symbol_arity, " ++
		"0.0 AS distance " ++
		"FROM symbols"
	);
	if (where_parts.items.len > 0) {
		try sql_buf.appendSlice(allocator, " WHERE ");
		for (where_parts.items, 0..) |part, idx| {
			if (idx > 0) try sql_buf.appendSlice(allocator, " AND ");
			try sql_buf.appendSlice(allocator, part);
		}
	}
	try sql_buf.appendSlice(allocator, " ORDER BY file_path, start_line");

	// If we have post-query filters, over-fetch since we filter in-code
	const fetch_limit = if (options.allowed_exts.len > 0 or options.allowed_paths.len > 0)
		options.top_n * 5
	else
		options.top_n;

	const limit_str = try std.fmt.allocPrint(allocator, " LIMIT {d}", .{fetch_limit});
	defer allocator.free(limit_str);
	try sql_buf.appendSlice(allocator, limit_str);

	try sql_buf.append(allocator, 0); // null terminate
	const sql_z: [:0]const u8 = sql_buf.items[0..sql_buf.items.len - 1 :0];

	var stmt: ?*sqlite.sqlite3_stmt = null;
	if (sqlite.sqlite3_prepare_v2(db, sql_z.ptr, -1, &stmt, null) != sqlite.SQLITE_OK) {
		return error.SqlPrepareFailed;
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
			var res = try readResultRow(allocator, stmt.?);
			// Apply post-query filters (extensions, paths)
			if ((options.allowed_exts.len > 0 or options.allowed_paths.len > 0) and !matchesFilters(res.symbol, options)) {
				res.deinit(allocator);
				continue;
			}
			res.score = 1.0;
			res.distance = 0.0;
			res.lexical = 0.0;
			res.bm25 = 0.0;
			try results.append(allocator, res);
			if (results.items.len >= options.top_n) break;
		} else if (rc == sqlite.SQLITE_DONE) {
			break;
		} else {
			return error.SqlStepFailed;
		}
	}

	const total = results.items.len;
	return .{ .results = try results.toOwnedSlice(allocator), .total_relevant = total };
}

pub fn freeResults(allocator: std.mem.Allocator, results: []Result) void {
	for (results) |*res| res.deinit(allocator);
	allocator.free(results);
}

fn sortByScoreDesc(_: void, a: Result, b: Result) bool {
	return a.score > b.score;
}

fn applyDuplicatePenalty(allocator: std.mem.Allocator, items: []Result) !void {
	var seen = std.AutoHashMap(u64, usize).init(allocator);
	defer seen.deinit();

	for (items) |*res| {
		const key = duplicateSymbolKey(res.symbol.name, res.symbol.signature);
		const dup_count = seen.get(key) orelse 0;
		if (dup_count > 0) {
			const factor = duplicateDecayFactor(dup_count);
			res.score *= factor;
		}
		try seen.put(key, dup_count + 1);
	}
}

fn duplicateSymbolKey(name: []const u8, signature: []const u8) u64 {
	var hasher = std.hash.Wyhash.init(0);
	hasher.update(name);
	hasher.update(&[_]u8{0});
	hasher.update(signature);
	return hasher.final();
}

fn duplicateDecayFactor(dup_count: usize) f32 {
	var factor: f32 = 1.0;
	var i: usize = 0;
	while (i < dup_count) : (i += 1) {
		factor *= 0.85;
	}
	return factor;
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
	if (options.allowed_symbol_kinds.len > 0) {
		const sk = symbol.symbol_kind orelse return false;
		var ok = false;
		for (options.allowed_symbol_kinds) |k| {
			if (std.mem.eql(u8, k, "*")) {
				// "*" sentinel means "any non-null symbol_kind" — already passed the null check above
				ok = true;
				break;
			}
			if (std.mem.eql(u8, sk, k)) {
				ok = true;
				break;
			}
		}
		if (!ok) return false;
	}
	if (options.allowed_paths.len > 0) {
		var ok = false;
		for (options.allowed_paths) |pattern| {
			if (pathMatchesGlob(symbol.file_path, pattern)) {
				ok = true;
				break;
			}
		}
		if (!ok) return false;
	}
	return true;
}

/// Simple glob match for path filtering. Supports * and ? wildcards.
pub fn pathMatchesGlob(path: []const u8, pattern: []const u8) bool {
	var pi: usize = 0;
	var gi: usize = 0;
	var star_pi: ?usize = null;
	var star_gi: ?usize = null;

	while (pi < path.len) {
		if (gi < pattern.len and (pattern[gi] == '?' or pattern[gi] == path[pi])) {
			pi += 1;
			gi += 1;
		} else if (gi < pattern.len and pattern[gi] == '*') {
			star_pi = pi;
			star_gi = gi;
			gi += 1;
		} else if (star_gi) |sg| {
			gi = sg + 1;
			star_pi = star_pi.? + 1;
			pi = star_pi.?;
		} else {
			return false;
		}
	}
	while (gi < pattern.len and pattern[gi] == '*') gi += 1;
	return gi == pattern.len;
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
		++ "symbol_kind, symbol_visibility, symbol_scope, symbol_arity, "
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
	fts_mode: FtsMode,
) ![]Result {
	if (comments_only) {
		return commentCandidates(allocator, db, query, limit);
	}
	if (ftsAvailable(db) catch false) {
		const fts = ftsCandidates(allocator, db, query, limit, fts_mode) catch null;
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

	const query_z = try allocator.dupeZ(u8, query);
	defer allocator.free(query_z);
	const prefix = try std.fmt.allocPrint(allocator, "{s}%", .{query});
	defer allocator.free(prefix);
	const prefix_z = try allocator.dupeZ(u8, prefix);
	defer allocator.free(prefix_z);

	// ?1 = %query% (LIKE pattern), ?2 = query (exact), ?3 = query% (prefix), ?4 = limit
	const sql: [:0]const u8 =
		"SELECT id, lang, file_path, start_line, start_hash, end_line, end_hash, symbol_name, signature, doc_comment, "
		++ "symbol_kind, symbol_visibility, symbol_scope, symbol_arity, "
		++ "1e999 AS distance "
		++ "FROM symbols "
		++ "WHERE symbol_name LIKE ?1 COLLATE NOCASE "
		++ "OR signature LIKE ?1 COLLATE NOCASE "
		++ "OR doc_comment LIKE ?1 COLLATE NOCASE "
		++ "OR body LIKE ?1 COLLATE NOCASE "
		++ "ORDER BY "
		++ "CASE WHEN symbol_name LIKE ?2 COLLATE NOCASE THEN 0 "
		++ "WHEN symbol_name LIKE ?3 COLLATE NOCASE THEN 1 "
		++ "WHEN symbol_name LIKE ?1 COLLATE NOCASE THEN 2 "
		++ "WHEN signature LIKE ?1 COLLATE NOCASE THEN 3 "
		++ "ELSE 4 END "
		++ "LIMIT ?4;\x00";

	var stmt: ?*sqlite.sqlite3_stmt = null;
	if (sqlite.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != sqlite.SQLITE_OK) {
		return error.SqlPrepareFailed;
	}
	defer _ = sqlite.sqlite3_finalize(stmt.?);

	_ = sqlite.sqlite3_bind_text(stmt.?, 1, pattern_z.ptr, @intCast(pattern.len), null);
	_ = sqlite.sqlite3_bind_text(stmt.?, 2, query_z.ptr, @intCast(query.len), null);
	_ = sqlite.sqlite3_bind_text(stmt.?, 3, prefix_z.ptr, @intCast(prefix.len), null);
	_ = sqlite.sqlite3_bind_int64(stmt.?, 4, @intCast(limit));

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
		++ "symbol_kind, symbol_visibility, symbol_scope, symbol_arity, "
		++ "1e999 AS distance "
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
	fts_mode: FtsMode,
) ![]Result {
	if (limit == 0) return allocator.alloc(Result, 0);

	const fts_query = try buildFtsQueryMode(allocator, query, fts_mode);
	defer allocator.free(fts_query);
	const escaped = try escapeSqlLiteral(allocator, fts_query);
	defer allocator.free(escaped);

	const sql_ranked = try allocPrintZ(
		allocator,
		"SELECT symbols.id, symbols.lang, symbols.file_path, symbols.start_line, symbols.start_hash, "
		++ "symbols.end_line, symbols.end_hash, symbols.symbol_name, symbols.signature, symbols.doc_comment, "
		++ "symbols.symbol_kind, symbols.symbol_visibility, symbols.symbol_scope, symbols.symbol_arity, "
		++ "1e999 AS distance, "
		++ "bm25(symbols_fts, 10.0, 3.0, 5.0, 1.0, 0.5) AS bm25_score "
		++ "FROM symbols_fts JOIN symbols ON symbols_fts.rowid = symbols.id "
		++ "WHERE symbols_fts MATCH '{s}' "
		++ "ORDER BY bm25(symbols_fts, 10.0, 3.0, 5.0, 1.0, 0.5) "
		++ "LIMIT {d};",
		.{ escaped, limit },
	);
	defer allocator.free(sql_ranked);
	const sql_plain = try allocPrintZ(
		allocator,
		"SELECT symbols.id, symbols.lang, symbols.file_path, symbols.start_line, symbols.start_hash, "
		++ "symbols.end_line, symbols.end_hash, symbols.symbol_name, symbols.signature, symbols.doc_comment, "
		++ "symbols.symbol_kind, symbols.symbol_visibility, symbols.symbol_scope, symbols.symbol_arity, "
		++ "1e999 AS distance, "
		++ "bm25(symbols_fts, 10.0, 3.0, 5.0, 1.0, 0.5) AS bm25_score "
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
			var res = try readResultRow(allocator, stmt.?);
			res.bm25 = @as(f32, @floatCast(sqlite.sqlite3_column_double(stmt.?, 15)));
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
	const symbol_kind = try dupColumnTextOptional(allocator, stmt, 10);
	const symbol_visibility = try dupColumnTextOptional(allocator, stmt, 11);
	const symbol_scope = try dupColumnTextOptional(allocator, stmt, 12);
	const symbol_arity = readIntColumnOptional(stmt, 13);
	const distance = @as(f32, @floatCast(sqlite.sqlite3_column_double(stmt, 14)));

	return .{
		.id = id,
		.symbol = .{
			.language = lang,
			.file_path = file_path,
			.name = name,
			.signature = signature,
			.doc_comment = doc_comment,
			.symbol_kind = symbol_kind,
			.symbol_visibility = symbol_visibility,
			.symbol_scope = symbol_scope,
			.symbol_arity = symbol_arity,
			.start_line = start_line,
			.end_line = end_line,
			.start_hash = start_hash,
			.end_hash = end_hash,
		},
		.score = 0,
		.distance = distance,
		.lexical = 0,
		.bm25 = 0,
	};
}

fn readHashColumn(stmt: *sqlite.sqlite3_stmt, col: c_int) ?hashline.Hash {
	const ptr = sqlite.sqlite3_column_text(stmt, col) orelse return null;
	const slice = std.mem.span(ptr);
	if (slice.len < hashline.HASH_LEN) return null;
	return slice[0..hashline.HASH_LEN].*;
}

fn readIntColumnOptional(stmt: *sqlite.sqlite3_stmt, col: c_int) ?i32 {
	if (sqlite.sqlite3_column_type(stmt, col) == sqlite.SQLITE_NULL) return null;
	return @as(i32, @intCast(sqlite.sqlite3_column_int(stmt, col)));
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

/// Compute the fraction of significant query tokens that appear in a symbol's
/// name, signature, or doc comment. Used to gate FTS/BM25 scores so that
/// single-token matches don't inflate to 1.0 on multi-token queries.
fn tokenCoverage(query_tokens: []const []const u8, symbol: model.Symbol) f32 {
	if (query_tokens.len == 0) return 1.0;
	var matched: usize = 0;
	var significant: usize = 0;
	for (query_tokens) |tok| {
		// Skip very short tokens (likely noise: "a", "I", etc.)
		if (tok.len < 2) continue;
		significant += 1;
		const in_name = simd.indexOfIgnoreCase(symbol.name, tok) != null;
		const in_sig = simd.indexOfIgnoreCase(symbol.signature, tok) != null;
		const in_doc = if (symbol.doc_comment) |doc| simd.indexOfIgnoreCase(doc, tok) != null else false;
		if (in_name or in_sig or in_doc) matched += 1;
	}
	if (significant == 0) return 1.0;
	return @as(f32, @floatFromInt(matched)) / @as(f32, @floatFromInt(significant));
}

fn pathTokenCoverage(query_tokens: []const []const u8, file_path: []const u8) f32 {
	if (query_tokens.len == 0) return 0;
	var matched: usize = 0;
	var significant: usize = 0;
	for (query_tokens) |tok| {
		if (tok.len < 3) continue;
		if (isConceptualCue(tok)) continue;
		significant += 1;
		if (simd.indexOfIgnoreCase(file_path, tok) != null) matched += 1;
	}
	if (significant == 0) return 0;
	return @as(f32, @floatFromInt(matched)) / @as(f32, @floatFromInt(significant));
}

fn inferQueryIntent(query_trimmed: []const u8, query_tokens: []const []const u8) QueryIntent {
	if (query_tokens.len == 0) return .lookup;

	var has_navigation_cue = false;
	var has_conceptual_cue = false;
	var code_like_count: usize = 0;
	for (query_tokens) |tok| {
		if (isNavigationCue(tok)) has_navigation_cue = true;
		if (isConceptualCue(tok)) has_conceptual_cue = true;
		if (isCodeLikeToken(tok)) code_like_count += 1;
	}

	if (has_navigation_cue) return .navigation;
	if (query_tokens.len == 1 and isCodeLikeToken(query_tokens[0])) return .lookup;
	if (has_conceptual_cue) return .conceptual;
	if (code_like_count * 2 >= query_tokens.len) return .lookup;
	if (query_tokens.len >= 5 and !looksCodeLikeQuery(query_trimmed)) return .conceptual;
	return .lookup;
}

fn isNavigationCue(token: []const u8) bool {
	return std.ascii.eqlIgnoreCase(token, "where") or
		std.ascii.eqlIgnoreCase(token, "find") or
		std.ascii.eqlIgnoreCase(token, "locate") or
		std.ascii.eqlIgnoreCase(token, "path") or
		std.ascii.eqlIgnoreCase(token, "file") or
		std.ascii.eqlIgnoreCase(token, "defined") or
		std.ascii.eqlIgnoreCase(token, "definition") or
		std.ascii.eqlIgnoreCase(token, "implemented") or
		std.ascii.eqlIgnoreCase(token, "implementation") or
		std.ascii.eqlIgnoreCase(token, "handle") or
		std.ascii.eqlIgnoreCase(token, "handled") or
		std.ascii.eqlIgnoreCase(token, "handling");
}

fn isConceptualCue(token: []const u8) bool {
	return std.ascii.eqlIgnoreCase(token, "how") or
		std.ascii.eqlIgnoreCase(token, "why") or
		std.ascii.eqlIgnoreCase(token, "explain") or
		std.ascii.eqlIgnoreCase(token, "overview") or
		std.ascii.eqlIgnoreCase(token, "conceptual") or
		std.ascii.eqlIgnoreCase(token, "architecture") or
		std.ascii.eqlIgnoreCase(token, "algorithm") or
		std.ascii.eqlIgnoreCase(token, "flow") or
		std.ascii.eqlIgnoreCase(token, "work") or
		std.ascii.eqlIgnoreCase(token, "works") or
		std.ascii.eqlIgnoreCase(token, "behavior") or
		std.ascii.eqlIgnoreCase(token, "semantics");
}

fn looksCodeLikeQuery(query: []const u8) bool {
	return std.mem.indexOfAny(u8, query, "./\\:_()[]{}<>") != null;
}

fn isCodeLikeToken(token: []const u8) bool {
	if (token.len == 0) return false;
	if (std.mem.indexOfAny(u8, token, "./\\:_()[]{}<>") != null) return true;

	var has_lower = false;
	var has_upper = false;
	for (token) |c| {
		if (std.ascii.isLower(c)) has_lower = true;
		if (std.ascii.isUpper(c)) has_upper = true;
	}
	if (has_lower and has_upper) return true; // camelCase/PascalCase
	return false;
}

fn isLikelyLocalBindingSignature(signature: []const u8) bool {
	const trimmed = std.mem.trimLeft(u8, signature, " \t");
	return std.mem.startsWith(u8, trimmed, "var ") or
		std.mem.startsWith(u8, trimmed, "const ") or
		std.mem.startsWith(u8, trimmed, "let ") or
		std.mem.startsWith(u8, trimmed, "val ") or
		std.mem.startsWith(u8, trimmed, "mut ");
}

fn isGenericSymbolName(name: []const u8) bool {
	const generic_names = [_][]const u8{
		"ok",
		"fail",
		"reader",
		"writer",
		"file",
		"data",
		"tmp",
		"buf",
		"result",
		"results",
		"value",
		"item",
		"items",
		"count",
		"index",
		"id",
	};
	for (generic_names) |generic| {
		if (std.ascii.eqlIgnoreCase(name, generic)) return true;
	}
	return false;
}

const MetadataQuery = struct {
	kind: ?[]const u8 = null,
	visibility: ?[]const u8 = null,
	scope: ?[]const u8 = null,
	arity: ?i32 = null,
};

fn inferMetadataQuery(tokens: []const []const u8) MetadataQuery {
	var out: MetadataQuery = .{};
	var prev_was_arity_cue = false;

	for (tokens) |tok| {
		if (out.kind == null) out.kind = tokenToKind(tok);
		if (out.visibility == null) out.visibility = tokenToVisibility(tok);
		if (out.scope == null) out.scope = tokenToScope(tok);

		if (std.ascii.eqlIgnoreCase(tok, "arity") or
			std.ascii.eqlIgnoreCase(tok, "args") or
			std.ascii.eqlIgnoreCase(tok, "arg") or
			std.ascii.eqlIgnoreCase(tok, "params") or
			std.ascii.eqlIgnoreCase(tok, "parameters"))
		{
			prev_was_arity_cue = true;
			continue;
		}

		if (out.arity == null) {
			if (parseSlashArity(tok)) |arity| {
				out.arity = arity;
			} else if (prev_was_arity_cue) {
				if (parseIntToken(tok)) |arity| out.arity = arity;
			} else if (hasPrefixIgnoreCase(tok, "arity")) {
				if (parseIntToken(tok[5..])) |arity| out.arity = arity;
			}
		}

		prev_was_arity_cue = false;
	}

	return out;
}

fn applyMetadataBoost(base_score: f32, symbol: model.Symbol, query_meta: MetadataQuery, options: Options) f32 {
	var score = base_score;

	if (query_meta.kind) |expected| {
		score = applyMetadataFactor(score, symbol.symbol_kind, expected, options.weight_symbol_kind);
	}
	if (query_meta.visibility) |expected| {
		score = applyMetadataFactor(score, symbol.symbol_visibility, expected, options.weight_symbol_visibility);
	}
	if (query_meta.scope) |expected| {
		score = applyMetadataFactor(score, symbol.symbol_scope, expected, options.weight_symbol_scope);
	}
	if (query_meta.arity) |expected| {
		if (options.weight_symbol_arity > 0 and symbol.symbol_arity != null) {
			if (symbol.symbol_arity.? == expected) {
				score *= (1.0 + options.weight_symbol_arity);
			} else {
				const penalty = @max(@as(f32, 0.05), 1.0 - (options.weight_symbol_arity * 0.5));
				score *= penalty;
			}
		}
	}

	return score;
}

fn applyMetadataFactor(score: f32, actual: ?[]const u8, expected: []const u8, weight: f32) f32 {
	if (weight <= 0 or actual == null) return score;
	if (std.ascii.eqlIgnoreCase(actual.?, expected)) {
		return score * (1.0 + weight);
	}
	const penalty = @max(@as(f32, 0.05), 1.0 - (weight * 0.5));
	return score * penalty;
}

fn tokenToKind(token: []const u8) ?[]const u8 {
	if (std.ascii.eqlIgnoreCase(token, "function") or
		std.ascii.eqlIgnoreCase(token, "fn") or
		std.ascii.eqlIgnoreCase(token, "def") or
		std.ascii.eqlIgnoreCase(token, "method"))
		return "fn";
	if (std.ascii.eqlIgnoreCase(token, "class")) return "class";
	if (std.ascii.eqlIgnoreCase(token, "struct")) return "struct";
	if (std.ascii.eqlIgnoreCase(token, "enum")) return "enum";
	if (std.ascii.eqlIgnoreCase(token, "interface")) return "interface";
	if (std.ascii.eqlIgnoreCase(token, "trait")) return "trait";
	if (std.ascii.eqlIgnoreCase(token, "module") or
		std.ascii.eqlIgnoreCase(token, "namespace") or
		std.ascii.eqlIgnoreCase(token, "ns"))
		return "mod";
	if (std.ascii.eqlIgnoreCase(token, "variable") or
		std.ascii.eqlIgnoreCase(token, "var") or
		std.ascii.eqlIgnoreCase(token, "const") or
		std.ascii.eqlIgnoreCase(token, "let") or
		std.ascii.eqlIgnoreCase(token, "field"))
		return "var";
	if (std.ascii.eqlIgnoreCase(token, "type")) return "type";
	if (std.ascii.eqlIgnoreCase(token, "macro")) return "macro";
	return null;
}

fn tokenToVisibility(token: []const u8) ?[]const u8 {
	if (std.ascii.eqlIgnoreCase(token, "public") or
		std.ascii.eqlIgnoreCase(token, "pub") or
		std.ascii.eqlIgnoreCase(token, "export") or
		std.ascii.eqlIgnoreCase(token, "exported"))
		return "public";
	if (std.ascii.eqlIgnoreCase(token, "private") or
		std.ascii.eqlIgnoreCase(token, "priv"))
		return "private";
	if (std.ascii.eqlIgnoreCase(token, "protected")) return "protected";
	if (std.ascii.eqlIgnoreCase(token, "internal")) return "internal";
	return null;
}

fn tokenToScope(token: []const u8) ?[]const u8 {
	if (std.ascii.eqlIgnoreCase(token, "top_level") or
		std.ascii.eqlIgnoreCase(token, "top-level") or
		std.ascii.eqlIgnoreCase(token, "toplevel") or
		std.ascii.eqlIgnoreCase(token, "global"))
		return "top_level";
	if (std.ascii.eqlIgnoreCase(token, "local")) return "local";
	if (std.ascii.eqlIgnoreCase(token, "member")) return "member";
	if (std.ascii.eqlIgnoreCase(token, "method")) return "method";
	return null;
}

fn parseIntToken(token: []const u8) ?i32 {
	if (token.len == 0) return null;
	for (token) |ch| {
		if (!std.ascii.isDigit(ch)) return null;
	}
	return std.fmt.parseInt(i32, token, 10) catch null;
}

fn parseSlashArity(token: []const u8) ?i32 {
	if (token.len < 2) return null;
	if (token[0] == '/') {
		return parseIntToken(token[1..]);
	}
	const slash_idx = std.mem.lastIndexOfScalar(u8, token, '/') orelse return null;
	if (slash_idx + 1 >= token.len) return null;
	return parseIntToken(token[slash_idx + 1 ..]);
}

fn hasPrefixIgnoreCase(value: []const u8, prefix: []const u8) bool {
	if (value.len < prefix.len) return false;
	return std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

/// Determine how the query relates to the symbol name.
/// Handles multi-word queries by checking camelCase/snake_case joins
/// and whether all individual tokens appear in the name.
fn nameRelevance(allocator: std.mem.Allocator, query: []const u8, name: []const u8) !NameRelevance {
	// Single-token fast path: direct comparison
	if (std.mem.indexOfScalar(u8, query, ' ') == null) {
		if (std.ascii.eqlIgnoreCase(query, name)) return .exact;
		if (simd.indexOfIgnoreCase(name, query) != null) return .substring;
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
	if (simd.indexOfIgnoreCase(name, camel) != null) return .substring;
	if (simd.indexOfIgnoreCase(name, snake) != null) return .substring;

	// Check if ALL query tokens appear individually in the name
	var tokens = std.mem.tokenizeAny(u8, query, " \t\r\n");
	var all_in_name = true;
	var token_count: usize = 0;
	while (tokens.next()) |tok| {
		token_count += 1;
		if (simd.indexOfIgnoreCase(name, tok) == null) {
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

fn lexicalScore(allocator: std.mem.Allocator, query_tokens: []const []const u8, query_trimmed: []const u8, symbol: model.Symbol, comments_only: bool) !f32 {
	var weighted_score: f32 = 0;

	// Weight matches by where the query term appears:
	//   name match    → 1.0  (this symbol IS the thing)
	//   doc comment   → 0.5  (described in docs)
	//   signature only → 0.3 (just referenced/called in body)
	for (query_tokens) |tok| {
		const in_doc = if (symbol.doc_comment) |doc| simd.indexOfIgnoreCase(doc, tok) != null else false;
		if (comments_only) {
			if (in_doc) weighted_score += 1.0;
		} else {
			const in_name = simd.indexOfIgnoreCase(symbol.name, tok) != null;
			const in_sig = simd.indexOfIgnoreCase(symbol.signature, tok) != null;
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

	if (query_tokens.len == 0) return 0;
	var base_score = weighted_score / @as(f32, @floatFromInt(query_tokens.len));

	// Exact-match and substring bonuses (only for non-comment-only mode)
	if (!comments_only and query_trimmed.len > 0) {
		if (std.ascii.eqlIgnoreCase(query_trimmed, symbol.name)) {
			// Exact name match → strong boost
			base_score = @min(1.0, base_score + 0.5);
		} else if (query_trimmed.len >= 3 and simd.indexOfIgnoreCase(symbol.name, query_trimmed) != null) {
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
	if (simd.indexOfIgnoreCase(name, camel) != null) return 1.0;

	// Try snake_case join
	const snake = try joinPartsAsSnake(allocator, parts);
	defer allocator.free(snake);
	if (simd.indexOfIgnoreCase(name, snake) != null) return 1.0;

	// Check signature
	if (simd.indexOfIgnoreCase(signature, camel) != null) return 0.3;
	if (simd.indexOfIgnoreCase(signature, snake) != null) return 0.3;

	// Check if all sub-parts appear individually in the name
	var all_in_name = true;
	for (parts) |p| {
		if (simd.indexOfIgnoreCase(name, p) == null) {
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

	if (simd.indexOfIgnoreCase(name, camel) != null) return .substring;
	if (simd.indexOfIgnoreCase(name, snake) != null) return .substring;

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
	return buildFtsQueryMode(allocator, query, .broad);
}

fn buildFtsQueryMode(allocator: std.mem.Allocator, query: []const u8, fts_mode: FtsMode) ![]u8 {
	var out = std.ArrayListUnmanaged(u8){};
	errdefer out.deinit(allocator);

	const joiner: []const u8 = switch (fts_mode) {
		.broad => " OR ",
		.balanced, .strict => " AND ",
	};

	var tokens = std.mem.tokenizeAny(u8, query, " \t\r\n");
	var token_count: usize = 0;
	while (tokens.next()) |tok| {
		if (tok.len == 0) continue;
		// In balanced mode, skip short tokens (likely noise: "a", "I", "is", etc.)
		if (fts_mode == .balanced and tok.len < 3) continue;
		if (token_count > 0) {
			try out.appendSlice(allocator, joiner);
		}
		try out.append(allocator, '"');
		try out.appendSlice(allocator, tok);
		try out.append(allocator, '"');
		token_count += 1;
	}

	if (token_count == 0) {
		// Fallback: if balanced mode dropped all tokens, use broad OR with original query
		if (fts_mode == .balanced) {
			return buildFtsQueryMode(allocator, query, .broad);
		}
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

/// Test helper: tokenizes a query string and calls lexicalScore.
fn testLexicalScore(allocator: std.mem.Allocator, query: []const u8, symbol: model.Symbol, comments_only: bool) !f32 {
	const trimmed = std.mem.trim(u8, query, " \t\r\n");
	var buf: [64][]const u8 = undefined;
	var count: usize = 0;
	var tok = std.mem.tokenizeAny(u8, query, " \t\r\n");
	while (tok.next()) |t| {
		if (count < buf.len) {
			buf[count] = t;
			count += 1;
		}
	}
	return lexicalScore(allocator, buf[0..count], trimmed, symbol, comments_only);
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
	const score = try testLexicalScore(allocator, "hash functions", symbol, false);
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

	const score = try testLexicalScore(allocator, "checksum", symbol, true);
	try std.testing.expectApproxEqAbs(@as(f32, 0.0), score, 0.0001);
}

test "search vector mode returns nearest symbol" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

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

	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

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

	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

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

	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

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

	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

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

	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

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

	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

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
		const fts_results = try ftsCandidates(allocator, db, "functions hash", 3, .broad);
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

	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

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

	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

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

	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

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
		.score_dropoff = 0.3,
	})).results;
	defer freeResults(allocator, results);

	// sym3 scores ~0.01, top score is 1.0, floor is 0.3 — sym3 should be dropped
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

	const score_exact = try testLexicalScore(allocator, "insertSymbol", sym_exact, false);
	const score_partial = try testLexicalScore(allocator, "insertSymbol", sym_partial, false);

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

	const score_contains = try testLexicalScore(allocator, "Insert", sym_contains, false);
	const score_none = try testLexicalScore(allocator, "Insert", sym_no_match, false);

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

	const score = try testLexicalScore(allocator, "nameRelevance", symbol, false);
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

	const score = try testLexicalScore(allocator, "name_relevance", symbol, false);
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

test "hybrid scoring: lexical-only result gets no vector credit" {
	// A lexical-only candidate (not in vector results) must NOT receive
	// vector_score = 1.0 from its sentinel distance. Its score should
	// come purely from the lexical signal.
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

	// sym_vector: close to query vector but name doesn't match query text
	var sym_vector = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/a.zig"),
		.name = try allocator.dupe(u8, "unrelated_name"),
		.signature = try allocator.dupe(u8, "fn unrelated_name() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym_vector.deinit(allocator);

	// sym_lexical: far from query vector but name matches query text exactly
	var sym_lexical = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/b.zig"),
		.name = try allocator.dupe(u8, "greet"),
		.signature = try allocator.dupe(u8, "fn greet() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym_lexical.deinit(allocator);

	const id1 = try storage.insertSymbol(db, sym_vector);
	_ = try storage.insertSymbol(db, sym_lexical);
	// Only sym_vector gets an embedding — sym_lexical has no embedding,
	// so it can only appear via lexical retrieval.
	try storage.insertEmbedding(db, allocator, id1, &[_]f32{ 0.0, 0.0 });

	// Query embedding at origin — sym_vector is near, sym_lexical is far
	var fake = FakeEmbedder{ .vector = &[_]f32{ 0.0, 0.0 } };

	// With equal weights, a lexical-only candidate should NOT outscore
	// a true vector match just because it gets phantom vector credit.
	const results = (try search(allocator, db, fake.embedder(), "greet", .{
		.top_n = 10,
		.mode = .hybrid,
		.weight_vector = 0.7,
		.weight_lexical = 0.3,
		.score_dropoff = 0,
	})).results;
	defer freeResults(allocator, results);

	try std.testing.expect(results.len >= 2);

	// Find both results
	var lexical_only_score: f32 = 0;
	var vector_match_score: f32 = 0;
	for (results) |res| {
		if (std.mem.eql(u8, res.symbol.name, "greet")) {
			lexical_only_score = res.score;
		} else if (std.mem.eql(u8, res.symbol.name, "unrelated_name")) {
			vector_match_score = res.score;
		}
	}

	// The vector match (distance ~0) should score higher than the lexical-only
	// match when vector weight dominates. Before the fix, "greet" would get
	// vector_score=1.0 from distance=0.0, inflating its hybrid score.
	try std.testing.expect(vector_match_score > lexical_only_score);
}

test "hybrid natural-language query prefers meaningful symbols over local generic bindings" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

	// Local/generic binding: very close vector match, but low semantic value.
	var sym_local = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/a.zig"),
		.name = try allocator.dupe(u8, "reader"),
		.signature = try allocator.dupe(u8, "var reader = BitReader.init(&data);"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym_local.deinit(allocator);

	// Meaningful API symbol: slightly farther vector distance.
	var sym_api = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/b.zig"),
		.name = try allocator.dupe(u8, "decodeKernel"),
		.signature = try allocator.dupe(u8, "pub fn decodeKernel() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym_api.deinit(allocator);

	const id_local = try storage.insertSymbol(db, sym_local);
	const id_api = try storage.insertSymbol(db, sym_api);
	try storage.insertEmbedding(db, allocator, id_local, &[_]f32{ 0.0, 0.0 });
	try storage.insertEmbedding(db, allocator, id_api, &[_]f32{ 0.2, 0.0 });

	var fake = FakeEmbedder{ .vector = &[_]f32{ 0.0, 0.0 } };
	const results = (try search(allocator, db, fake.embedder(), "how does stream parsing work", .{
		.top_n = 2,
		.mode = .hybrid,
		.score_dropoff = 0,
	})).results;
	defer freeResults(allocator, results);

	try std.testing.expectEqual(@as(usize, 2), results.len);
	try std.testing.expectEqualStrings("decodeKernel", results[0].symbol.name);
}

test "hybrid natural-language query demotes local bindings even with partial lexical overlap" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

	var sym_local = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/a.zig"),
		.name = try allocator.dupe(u8, "reader"),
		.signature = try allocator.dupe(u8, "var reader = BitReader.init(&data);"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym_local.deinit(allocator);

	var sym_api = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/b.zig"),
		.name = try allocator.dupe(u8, "decodeKernel"),
		.signature = try allocator.dupe(u8, "pub fn decodeKernel() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym_api.deinit(allocator);

	const id_local = try storage.insertSymbol(db, sym_local);
	const id_api = try storage.insertSymbol(db, sym_api);
	try storage.insertEmbedding(db, allocator, id_local, &[_]f32{ 0.0, 0.0 });
	try storage.insertEmbedding(db, allocator, id_api, &[_]f32{ 0.2, 0.0 });

	var fake = FakeEmbedder{ .vector = &[_]f32{ 0.0, 0.0 } };
	const results = (try search(allocator, db, fake.embedder(), "how does bitstream reader work", .{
		.top_n = 2,
		.mode = .hybrid,
		.score_dropoff = 0,
	})).results;
	defer freeResults(allocator, results);

	try std.testing.expectEqual(@as(usize, 2), results.len);
	try std.testing.expectEqualStrings("decodeKernel", results[0].symbol.name);
	var local_score: f32 = 0;
	for (results) |res| {
		if (std.mem.eql(u8, res.symbol.name, "reader")) local_score = res.score;
	}
	try std.testing.expect(local_score < 0.45);
}

test "hybrid ranking applies diversity penalty to duplicate symbol signatures" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

	// Three near-identical local symbols that would otherwise crowd top results.
	var dup_a = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/a.zig"),
		.name = try allocator.dupe(u8, "reader"),
		.signature = try allocator.dupe(u8, "var reader = BitReader.init(&data);"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer dup_a.deinit(allocator);
	var dup_b = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/b.zig"),
		.name = try allocator.dupe(u8, "reader"),
		.signature = try allocator.dupe(u8, "var reader = BitReader.init(&data);"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer dup_b.deinit(allocator);
	var dup_c = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/c.zig"),
		.name = try allocator.dupe(u8, "reader"),
		.signature = try allocator.dupe(u8, "var reader = BitReader.init(&data);"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer dup_c.deinit(allocator);

	// Distinct symbol slightly farther in vector space.
	var unique = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/d.zig"),
		.name = try allocator.dupe(u8, "parseBitstream"),
		.signature = try allocator.dupe(u8, "pub fn parseBitstream() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer unique.deinit(allocator);

	const id_a = try storage.insertSymbol(db, dup_a);
	const id_b = try storage.insertSymbol(db, dup_b);
	const id_c = try storage.insertSymbol(db, dup_c);
	const id_u = try storage.insertSymbol(db, unique);

	try storage.insertEmbedding(db, allocator, id_a, &[_]f32{ 0.00, 0.0 });
	try storage.insertEmbedding(db, allocator, id_b, &[_]f32{ 0.01, 0.0 });
	try storage.insertEmbedding(db, allocator, id_c, &[_]f32{ 0.02, 0.0 });
	try storage.insertEmbedding(db, allocator, id_u, &[_]f32{ 0.05, 0.0 });

	var fake = FakeEmbedder{ .vector = &[_]f32{ 0.0, 0.0 } };
	const results = (try search(allocator, db, fake.embedder(), "conceptual ranking check", .{
		.top_n = 4,
		.mode = .hybrid,
		.score_dropoff = 0,
		.min_score = 0,
	})).results;
	defer freeResults(allocator, results);

	try std.testing.expectEqual(@as(usize, 4), results.len);
	// Without diversity pressure, top slots are all duplicate `reader` entries.
	// With the penalty, the unique symbol should surface into the top two.
	const in_top_two =
		std.mem.eql(u8, results[0].symbol.name, "parseBitstream") or
		std.mem.eql(u8, results[1].symbol.name, "parseBitstream");
	try std.testing.expect(in_top_two);
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

test "RRF hybrid fusion produces rank-based compromise ordering" {
	// Three symbols with disagreeing vector and lexical rankings:
	// - sym_a: vector rank 1 (closest), lexical rank 3 (worst name match)
	// - sym_b: vector rank 2, lexical rank 2 (compromise candidate)
	// - sym_c: vector rank 3 (farthest), lexical rank 1 (best name match)
	// With RRF (k=60), B should score highest as the best compromise.
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

	// sym_a: close to query vector, poor name match for "search"
	var sym_a = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/a.zig"),
		.name = try allocator.dupe(u8, "unrelated_func"),
		.signature = try allocator.dupe(u8, "fn unrelated_func() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym_a.deinit(allocator);

	// sym_b: medium distance, medium name match for "search"
	var sym_b = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/b.zig"),
		.name = try allocator.dupe(u8, "search_index"),
		.signature = try allocator.dupe(u8, "fn search_index() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym_b.deinit(allocator);

	// sym_c: far from query vector, exact name match for "search"
	var sym_c = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/c.zig"),
		.name = try allocator.dupe(u8, "search"),
		.signature = try allocator.dupe(u8, "fn search() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym_c.deinit(allocator);

	const id_a = try storage.insertSymbol(db, sym_a);
	const id_b = try storage.insertSymbol(db, sym_b);
	const id_c = try storage.insertSymbol(db, sym_c);

	// Embeddings: query is at [0,0]. sym_a closest, sym_b medium, sym_c farthest.
	try storage.insertEmbedding(db, allocator, id_a, &[_]f32{ 0.1, 0.0 });
	try storage.insertEmbedding(db, allocator, id_b, &[_]f32{ 0.5, 0.0 });
	try storage.insertEmbedding(db, allocator, id_c, &[_]f32{ 1.0, 1.0 });

	var fake = FakeEmbedder{ .vector = &[_]f32{ 0.0, 0.0 } };

	// RRF mode — rank-based fusion should favor the compromise candidate
	const sr = try search(allocator, db, fake.embedder(), "search", .{
		.top_n = 10,
		.mode = .hybrid,
		.fusion = .rrf,
		.rrf_k = 60,
		.weight_vector = 0.7,
		.weight_lexical = 0.3,
		.score_dropoff = 0,
		.min_score = 0,
	});
	defer freeResults(allocator, sr.results);

	try std.testing.expect(sr.results.len >= 3);

	// Find scores by name
	var score_a: f32 = 0;
	var score_b: f32 = 0;
	var score_c: f32 = 0;
	for (sr.results) |res| {
		if (std.mem.eql(u8, res.symbol.name, "unrelated_func")) score_a = res.score;
		if (std.mem.eql(u8, res.symbol.name, "search_index")) score_b = res.score;
		if (std.mem.eql(u8, res.symbol.name, "search")) score_c = res.score;
	}

	// With RRF, the compromise candidate (B, rank 2 in both) should
	// score highest or very close to A. The key property is that C
	// (worst vector rank but best lexical rank) should NOT dominate
	// like it would with raw-score weighted sum.
	// RRF scores:
	//   A: 0.7/61 + 0.3/63 ≈ 0.01624
	//   B: 0.7/62 + 0.3/62 ≈ 0.01613
	//   C: 0.7/63 + 0.3/61 ≈ 0.01603
	// A > B > C (all close together, ranks dominate over weight asymmetry)
	try std.testing.expect(score_a > 0);
	try std.testing.expect(score_b > 0);
	try std.testing.expect(score_c > 0);

	// RRF scores must be on the RRF scale (much smaller than [0,1]).
	// With k=60, max possible RRF score ≈ w/(k+1) ≈ 0.0164 (before name boost).
	// Weighted_sum would produce scores in [0.3, 0.9] — clearly different.
	try std.testing.expect(score_a < 0.05);
	try std.testing.expect(score_b < 0.05);
	try std.testing.expect(score_c < 0.05);
	// Key RRF property: a vector-only result (A, rank 1 vector but no lexical)
	// should score below a result that appears in both lists (B or C).
	try std.testing.expect(score_b > score_a);
	try std.testing.expect(score_c > score_a);
}

test "lexical coverage: single FTS result does not normalize to 1.0 for multi-token query" {
	// When there's only one FTS result for a multi-token query, bm25_range=0
	// causes normalization to 1.0. With coverage gating, the score should
	// be penalized based on how many query tokens actually matched.
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

	// Only symbol in DB: matches "parse" but not "json" or "config"
	var sym = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/a.zig"),
		.name = try allocator.dupe(u8, "parse_data"),
		.signature = try allocator.dupe(u8, "fn parse_data(data: []u8) void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym.deinit(allocator);
	_ = try storage.insertSymbol(db, sym);

	const sr = try search(allocator, db, undefined, "parse json config", .{
		.top_n = 10,
		.mode = .lexical,
		.score_dropoff = 0,
		.min_score = 0,
	});
	defer freeResults(allocator, sr.results);

	try std.testing.expect(sr.results.len >= 1);

	// With coverage gating, a symbol matching 1/3 tokens should NOT score 1.0.
	// Its BM25 would normalize to 1.0 (single result, bm25_range=0), but
	// coverage = 1/3 should pull it down.
	const score = sr.results[0].score;
	try std.testing.expect(score < 0.7); // Should be ~0.33 with coverage
}

test "buildFtsQuery uses OR for multi-word queries" {
	const allocator = std.testing.allocator;
	const result = try buildFtsQuery(allocator, "hash functions");
	defer allocator.free(result);
	try std.testing.expectEqualStrings("\"hash\" OR \"functions\"", result);
}

test "buildFtsQueryMode broad uses OR" {
	const allocator = std.testing.allocator;
	const result = try buildFtsQueryMode(allocator, "parse json config", .broad);
	defer allocator.free(result);
	try std.testing.expectEqualStrings("\"parse\" OR \"json\" OR \"config\"", result);
}

test "buildFtsQueryMode strict uses AND" {
	const allocator = std.testing.allocator;
	const result = try buildFtsQueryMode(allocator, "parse json config", .strict);
	defer allocator.free(result);
	try std.testing.expectEqualStrings("\"parse\" AND \"json\" AND \"config\"", result);
}

test "buildFtsQueryMode balanced uses AND and drops short tokens" {
	const allocator = std.testing.allocator;
	// "a" and "is" are < 3 chars, should be dropped in balanced mode
	const result = try buildFtsQueryMode(allocator, "a is parse json config", .balanced);
	defer allocator.free(result);
	try std.testing.expectEqualStrings("\"parse\" AND \"json\" AND \"config\"", result);
}

test "buildFtsQueryMode balanced falls back to broad when all tokens short" {
	const allocator = std.testing.allocator;
	// All tokens are < 3 chars, balanced should fall back to broad OR
	const result = try buildFtsQueryMode(allocator, "a is of", .balanced);
	defer allocator.free(result);
	try std.testing.expectEqualStrings("\"a\" OR \"is\" OR \"of\"", result);
}

test "inferQueryIntent classifies conceptual question deterministically" {
	const tokens = [_][]const u8{ "how", "does", "bitstream", "reader", "work" };
	const intent = inferQueryIntent("how does bitstream reader work", tokens[0..]);
	try std.testing.expectEqual(QueryIntent.conceptual, intent);
}

test "inferQueryIntent classifies navigation query deterministically" {
	const tokens = [_][]const u8{ "where", "is", "validateRarDeep", "defined" };
	const intent = inferQueryIntent("where is validateRarDeep defined", tokens[0..]);
	try std.testing.expectEqual(QueryIntent.navigation, intent);
}

test "inferQueryIntent classifies symbol lookup query deterministically" {
	const tokens = [_][]const u8{ "parseEncryptionParams" };
	const intent = inferQueryIntent("parseEncryptionParams", tokens[0..]);
	try std.testing.expectEqual(QueryIntent.lookup, intent);
}

test "inferMetadataQuery parses kind visibility scope and arity cues" {
	const tokens = [_][]const u8{ "find", "public", "function", "arity", "2", "top-level" };
	const meta = inferMetadataQuery(tokens[0..]);
	try std.testing.expect(meta.kind != null);
	try std.testing.expect(meta.visibility != null);
	try std.testing.expect(meta.scope != null);
	try std.testing.expect(meta.arity != null);
	try std.testing.expectEqualStrings("fn", meta.kind.?);
	try std.testing.expectEqualStrings("public", meta.visibility.?);
	try std.testing.expectEqualStrings("top_level", meta.scope.?);
	try std.testing.expectEqual(@as(i32, 2), meta.arity.?);
}

test "search result retrieval includes symbol metadata columns" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

	var sym = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/meta.zig"),
		.name = try allocator.dupe(u8, "add"),
		.signature = try allocator.dupe(u8, "pub fn add(a: i32, b: i32) i32"),
		.doc_comment = null,
		.symbol_kind = try allocator.dupe(u8, "fn"),
		.symbol_visibility = try allocator.dupe(u8, "public"),
		.symbol_scope = try allocator.dupe(u8, "top_level"),
		.symbol_arity = 2,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym.deinit(allocator);

	const id = try storage.insertSymbol(db, sym);
	try storage.insertEmbedding(db, allocator, id, &[_]f32{ 0.0, 0.0 });

	var fake = FakeEmbedder{ .vector = &[_]f32{ 0.0, 0.0 } };
	const results = (try search(allocator, db, fake.embedder(), "add", .{
		.top_n = 1,
		.mode = .vector,
	})).results;
	defer freeResults(allocator, results);

	try std.testing.expectEqual(@as(usize, 1), results.len);
	try std.testing.expect(results[0].symbol.symbol_kind != null);
	try std.testing.expect(results[0].symbol.symbol_visibility != null);
	try std.testing.expect(results[0].symbol.symbol_scope != null);
	try std.testing.expect(results[0].symbol.symbol_arity != null);
	try std.testing.expectEqualStrings("fn", results[0].symbol.symbol_kind.?);
	try std.testing.expectEqualStrings("public", results[0].symbol.symbol_visibility.?);
	try std.testing.expectEqualStrings("top_level", results[0].symbol.symbol_scope.?);
	try std.testing.expectEqual(@as(i32, 2), results[0].symbol.symbol_arity.?);
}

test "metadata weights prioritize matching symbol metadata for query cues" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

	var sym_good = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/public_fn.zig"),
		.name = try allocator.dupe(u8, "target"),
		.signature = try allocator.dupe(u8, "symbol target"),
		.doc_comment = null,
		.symbol_kind = try allocator.dupe(u8, "fn"),
		.symbol_visibility = try allocator.dupe(u8, "public"),
		.start_line = 1,
		.end_line = 1,
	};
	defer sym_good.deinit(allocator);

	var sym_bad = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/private_var.zig"),
		.name = try allocator.dupe(u8, "target"),
		.signature = try allocator.dupe(u8, "symbol target"),
		.doc_comment = null,
		.symbol_kind = try allocator.dupe(u8, "var"),
		.symbol_visibility = try allocator.dupe(u8, "private"),
		.start_line = 1,
		.end_line = 1,
	};
	defer sym_bad.deinit(allocator);

	const id_good = try storage.insertSymbol(db, sym_good);
	const id_bad = try storage.insertSymbol(db, sym_bad);
	try storage.insertEmbedding(db, allocator, id_good, &[_]f32{ 0.0, 0.0 });
	try storage.insertEmbedding(db, allocator, id_bad, &[_]f32{ 0.0, 0.0 });

	var fake = FakeEmbedder{ .vector = &[_]f32{ 0.0, 0.0 } };
	const results = (try search(allocator, db, fake.embedder(), "public function target", .{
		.top_n = 2,
		.mode = .vector,
		.weight_symbol_kind = 1.0,
		.weight_symbol_visibility = 1.0,
		.score_dropoff = 0,
	})).results;
	defer freeResults(allocator, results);

	try std.testing.expectEqual(@as(usize, 2), results.len);
	try std.testing.expectEqualStrings("src/public_fn.zig", results[0].symbol.file_path);
}

test "buildFtsQuery single word has no operator" {
	const allocator = std.testing.allocator;
	const result = try buildFtsQuery(allocator, "hash");
	defer allocator.free(result);
	try std.testing.expectEqualStrings("\"hash\"", result);
}

test "ftsCandidates captures bm25 scores" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

	var sym1 = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/hash.zig"),
		.name = try allocator.dupe(u8, "crc32"),
		.signature = try allocator.dupe(u8, "pub fn crc32(data: []const u8) u32"),
		.doc_comment = try allocator.dupe(u8, "Hash functions for checksums"),
		.start_line = 1,
		.end_line = 10,
	};
	defer sym1.deinit(allocator);

	const id1 = try storage.insertSymbol(db, sym1);
	try storage.insertEmbedding(db, allocator, id1, &[_]f32{ 0.0, 0.0 });

	if (!(ftsAvailable(db) catch false)) return; // skip if FTS not available

	const results = try ftsCandidates(allocator, db, "hash", 10, .broad);
	defer freeResults(allocator, results);

	try std.testing.expect(results.len > 0);
	// BM25 scores from FTS5 are negative (more negative = better match)
	try std.testing.expect(results[0].bm25 < 0);
}

test "bm25 normalization produces values in 0-1 range" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

	// Insert two symbols with different relevance to "hash"
	var sym1 = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/hash.zig"),
		.name = try allocator.dupe(u8, "hash"),
		.signature = try allocator.dupe(u8, "pub fn hash(data: []const u8) u32"),
		.doc_comment = try allocator.dupe(u8, "Primary hash function"),
		.start_line = 1,
		.end_line = 10,
	};
	defer sym1.deinit(allocator);

	var sym2 = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/utils.zig"),
		.name = try allocator.dupe(u8, "helper"),
		.signature = try allocator.dupe(u8, "pub fn helper() void"),
		.doc_comment = try allocator.dupe(u8, "General helper with hash support"),
		.start_line = 1,
		.end_line = 5,
	};
	defer sym2.deinit(allocator);

	const id1 = try storage.insertSymbol(db, sym1);
	try storage.insertEmbedding(db, allocator, id1, &[_]f32{ 0.0, 0.0 });
	const id2 = try storage.insertSymbol(db, sym2);
	try storage.insertEmbedding(db, allocator, id2, &[_]f32{ 0.0, 0.0 });

	if (!(ftsAvailable(db) catch false)) return;

	var fake = FakeEmbedder{ .vector = &[_]f32{ 0.0, 0.0 } };
	const sr = try search(allocator, db, fake.embedder(), "hash", .{
		.top_n = 10,
		.mode = .lexical,
		.min_score = 0.0,
		.score_dropoff = 0.0,
	});
	defer freeResults(allocator, sr.results);

	try std.testing.expect(sr.results.len >= 2);
	// Lexical scores should be in [0, 1] range
	for (sr.results) |res| {
		try std.testing.expect(res.lexical >= 0.0);
		try std.testing.expect(res.lexical <= 1.0);
	}
}

test "bm25 column weights rank name match above doc_comment match" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

	// sym_name: "hash" appears in the symbol name (weight 10)
	var sym_name = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/a.zig"),
		.name = try allocator.dupe(u8, "hash"),
		.signature = try allocator.dupe(u8, "pub fn hash() void"),
		.doc_comment = try allocator.dupe(u8, "does stuff"),
		.start_line = 1,
		.end_line = 5,
	};
	defer sym_name.deinit(allocator);

	// sym_doc: "hash" appears only in the doc_comment (weight 5)
	var sym_doc = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/b.zig"),
		.name = try allocator.dupe(u8, "compute"),
		.signature = try allocator.dupe(u8, "pub fn compute() void"),
		.doc_comment = try allocator.dupe(u8, "uses hash internally"),
		.start_line = 1,
		.end_line = 5,
	};
	defer sym_doc.deinit(allocator);

	const id1 = try storage.insertSymbol(db, sym_name);
	try storage.insertEmbedding(db, allocator, id1, &[_]f32{ 0.0, 0.0 });
	const id2 = try storage.insertSymbol(db, sym_doc);
	try storage.insertEmbedding(db, allocator, id2, &[_]f32{ 0.0, 0.0 });

	if (!(ftsAvailable(db) catch false)) return;

	var fake = FakeEmbedder{ .vector = &[_]f32{ 0.0, 0.0 } };
	const sr = try search(allocator, db, fake.embedder(), "hash", .{
		.top_n = 10,
		.mode = .lexical,
		.min_score = 0.0,
		.score_dropoff = 0.0,
	});
	defer freeResults(allocator, sr.results);

	try std.testing.expect(sr.results.len >= 2);
	// The symbol with "hash" in its name should rank first
	try std.testing.expectEqualStrings("hash", sr.results[0].symbol.name);
}

test "bm25 body matches rank below name and doc_comment matches" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

	// sym_name: "widget" in the symbol name (weight 10)
	var sym_name = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/a.zig"),
		.name = try allocator.dupe(u8, "widget"),
		.signature = try allocator.dupe(u8, "pub fn widget() void"),
		.doc_comment = try allocator.dupe(u8, "does stuff"),
		.start_line = 1,
		.end_line = 5,
	};
	defer sym_name.deinit(allocator);

	// sym_doc: "widget" in doc_comment only (weight 5)
	var sym_doc = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/b.zig"),
		.name = try allocator.dupe(u8, "render"),
		.signature = try allocator.dupe(u8, "pub fn render() void"),
		.doc_comment = try allocator.dupe(u8, "renders a widget"),
		.start_line = 1,
		.end_line = 5,
	};
	defer sym_doc.deinit(allocator);

	// sym_body: "widget" in body only (weight 0.5)
	var sym_body = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/c.zig"),
		.name = try allocator.dupe(u8, "process"),
		.signature = try allocator.dupe(u8, "pub fn process() void"),
		.doc_comment = try allocator.dupe(u8, "does processing"),
		.body = try allocator.dupe(u8, "const x = widget.create();"),
		.start_line = 1,
		.end_line = 5,
	};
	defer sym_body.deinit(allocator);

	const id1 = try storage.insertSymbol(db, sym_name);
	try storage.insertEmbedding(db, allocator, id1, &[_]f32{ 0.0, 0.0 });
	const id2 = try storage.insertSymbol(db, sym_doc);
	try storage.insertEmbedding(db, allocator, id2, &[_]f32{ 0.0, 0.0 });
	const id3 = try storage.insertSymbol(db, sym_body);
	try storage.insertEmbedding(db, allocator, id3, &[_]f32{ 0.0, 0.0 });

	if (!(ftsAvailable(db) catch false)) return;

	var fake = FakeEmbedder{ .vector = &[_]f32{ 0.0, 0.0 } };
	const sr = try search(allocator, db, fake.embedder(), "widget", .{
		.top_n = 10,
		.mode = .lexical,
		.min_score = 0.0,
		.score_dropoff = 0.0,
	});
	defer freeResults(allocator, sr.results);

	try std.testing.expect(sr.results.len >= 3);
	// Name match should rank first, body match should rank last
	try std.testing.expectEqualStrings("widget", sr.results[0].symbol.name);
	try std.testing.expectEqualStrings("process", sr.results[2].symbol.name);
}

test "search works against v2 schema DB after initSchema migration" {
	// Simulates opening an existing DB created before schema v3 (no symbol_kind etc.)
	// initSchema must add the missing columns so search SQL can prepare.
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	// Create v2-style schema WITHOUT symbol_kind/visibility/scope/arity columns
	const v2_meta: [:0]const u8 = "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);\x00";
	const v2_symbols: [:0]const u8 =
		"CREATE TABLE symbols (" ++
		"id INTEGER PRIMARY KEY, " ++
		"lang TEXT NOT NULL, " ++
		"file_path TEXT NOT NULL, " ++
		"start_line INTEGER NOT NULL, " ++
		"start_hash TEXT, " ++
		"end_line INTEGER NOT NULL, " ++
		"end_hash TEXT, " ++
		"symbol_name TEXT NOT NULL, " ++
		"signature TEXT, " ++
		"doc_comment TEXT" ++
		");\x00";
	const v2_unique: [:0]const u8 = "CREATE UNIQUE INDEX IF NOT EXISTS idx_symbols_unique ON symbols (file_path, start_line, end_line, symbol_name);\x00";
	const v2_vec: [:0]const u8 = "CREATE VIRTUAL TABLE embeddings USING vec0(embedding float[2]);\x00";

	_ = sqlite.sqlite3_exec(db, v2_meta, null, null, null);
	_ = sqlite.sqlite3_exec(db, v2_symbols, null, null, null);
	_ = sqlite.sqlite3_exec(db, v2_unique, null, null, null);
	_ = sqlite.sqlite3_exec(db, v2_vec, null, null, null);

	// Insert a symbol directly via SQL (v2 schema — no metadata columns)
	const insert_sym: [:0]const u8 =
		"INSERT INTO symbols (lang, file_path, start_line, end_line, symbol_name, signature) " ++
		"VALUES ('zig', 'src/test.zig', 1, 10, 'compress', 'pub fn compress(data: []const u8) []u8');\x00";
	_ = sqlite.sqlite3_exec(db, insert_sym, null, null, null);
	const insert_emb: [:0]const u8 = "INSERT INTO embeddings (rowid, embedding) VALUES (1, X'0000000000000000');\x00";
	_ = sqlite.sqlite3_exec(db, insert_emb, null, null, null);

	// Run initSchema to migrate v2 → v3 (adds metadata columns).
	// This is what main.zig now does unconditionally before search.
	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

	// Search should succeed after migration
	var fake = FakeEmbedder{ .vector = &[_]f32{ 0.0, 0.0 } };
	const sr = try search(allocator, db, fake.embedder(), "compress", .{
		.top_n = 5,
		.mode = .vector,
		.score_dropoff = 0,
		.min_score = 0,
	});
	defer freeResults(allocator, sr.results);

	try std.testing.expect(sr.results.len >= 1);
	try std.testing.expectEqualStrings("compress", sr.results[0].symbol.name);
}

test "likeCandidates orders exact name > prefix > substring > signature-only" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

	// sym_sig: "init" appears only in the signature (priority 3)
	var sym_sig = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/a.zig"),
		.name = try allocator.dupe(u8, "setup"),
		.signature = try allocator.dupe(u8, "pub fn setup(init: bool) void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 5,
	};
	defer sym_sig.deinit(allocator);

	// sym_sub: "init" is a substring of the name (priority 2)
	var sym_sub = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/b.zig"),
		.name = try allocator.dupe(u8, "reinitialize"),
		.signature = try allocator.dupe(u8, "pub fn reinitialize() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 5,
	};
	defer sym_sub.deinit(allocator);

	// sym_prefix: "init" is a prefix of the name (priority 1)
	var sym_prefix = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/c.zig"),
		.name = try allocator.dupe(u8, "initSystem"),
		.signature = try allocator.dupe(u8, "pub fn initSystem() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 5,
	};
	defer sym_prefix.deinit(allocator);

	// sym_exact: "init" is the exact name (priority 0)
	var sym_exact = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/d.zig"),
		.name = try allocator.dupe(u8, "init"),
		.signature = try allocator.dupe(u8, "pub fn init() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 5,
	};
	defer sym_exact.deinit(allocator);

	// Insert in reverse priority order to ensure ORDER BY matters
	const id1 = try storage.insertSymbol(db, sym_sig);
	try storage.insertEmbedding(db, allocator, id1, &[_]f32{ 0.0, 0.0 });
	const id2 = try storage.insertSymbol(db, sym_sub);
	try storage.insertEmbedding(db, allocator, id2, &[_]f32{ 0.0, 0.0 });
	const id3 = try storage.insertSymbol(db, sym_prefix);
	try storage.insertEmbedding(db, allocator, id3, &[_]f32{ 0.0, 0.0 });
	const id4 = try storage.insertSymbol(db, sym_exact);
	try storage.insertEmbedding(db, allocator, id4, &[_]f32{ 0.0, 0.0 });

	const results = try likeCandidates(allocator, db, "init", 10);
	defer {
		for (results) |*r| {
			var res = r.*;
			res.deinit(allocator);
		}
		allocator.free(results);
	}

	try std.testing.expectEqual(@as(usize, 4), results.len);
	// Exact name match first
	try std.testing.expectEqualStrings("init", results[0].symbol.name);
	// Prefix match second
	try std.testing.expectEqualStrings("initSystem", results[1].symbol.name);
	// Substring in name third
	try std.testing.expectEqualStrings("reinitialize", results[2].symbol.name);
	// Signature-only match last
	try std.testing.expectEqualStrings("setup", results[3].symbol.name);
}

test "browse mode: empty query with kind filter returns matching symbols" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

	var sym_fn = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/lib.zig"),
		.name = try allocator.dupe(u8, "doWork"),
		.signature = try allocator.dupe(u8, "pub fn doWork() void"),
		.doc_comment = null,
		.symbol_kind = try allocator.dupe(u8, "fn"),
		.start_line = 1,
		.end_line = 5,
	};
	defer sym_fn.deinit(allocator);

	var sym_struct = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/types.zig"),
		.name = try allocator.dupe(u8, "Config"),
		.signature = try allocator.dupe(u8, "pub const Config = struct"),
		.doc_comment = null,
		.symbol_kind = try allocator.dupe(u8, "struct"),
		.start_line = 1,
		.end_line = 10,
	};
	defer sym_struct.deinit(allocator);

	const id1 = try storage.insertSymbol(db, sym_fn);
	try storage.insertEmbedding(db, allocator, id1, &[_]f32{ 0.0, 0.0 });
	const id2 = try storage.insertSymbol(db, sym_struct);
	try storage.insertEmbedding(db, allocator, id2, &[_]f32{ 0.0, 0.0 });

	// Browse with kind filter "fn" — should return only the fn symbol
	var fake = FakeEmbedder{ .vector = &[_]f32{ 0.0, 0.0 } };
	const sr = try search(allocator, db, fake.embedder(), "", .{
		.top_n = 10,
		.allowed_symbol_kinds = &[_][]const u8{"fn"},
	});
	defer freeResults(allocator, sr.results);

	try std.testing.expectEqual(@as(usize, 1), sr.results.len);
	try std.testing.expectEqualStrings("doWork", sr.results[0].symbol.name);
	try std.testing.expectEqualStrings("fn", sr.results[0].symbol.symbol_kind.?);
	// Browse mode should set score=1.0, distance=0, lexical=0, bm25=0
	try std.testing.expectEqual(@as(f32, 1.0), sr.results[0].score);
	try std.testing.expectEqual(@as(f32, 0.0), sr.results[0].distance);
	try std.testing.expectEqual(@as(f32, 0.0), sr.results[0].lexical);
	try std.testing.expectEqual(@as(f32, 0.0), sr.results[0].bm25);
}

test "browse mode: empty query with no filters returns EmptyQuery" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

	var fake = FakeEmbedder{ .vector = &[_]f32{ 0.0, 0.0 } };
	const result = search(allocator, db, fake.embedder(), "", .{
		.top_n = 10,
	});
	try std.testing.expectError(error.EmptyQuery, result);
}

test "browse mode: wildcard kind filter returns all symbols with any kind" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

	var sym_fn = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/a.zig"),
		.name = try allocator.dupe(u8, "alpha"),
		.signature = try allocator.dupe(u8, "fn alpha() void"),
		.doc_comment = null,
		.symbol_kind = try allocator.dupe(u8, "fn"),
		.start_line = 1,
		.end_line = 1,
	};
	defer sym_fn.deinit(allocator);

	var sym_struct = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/b.zig"),
		.name = try allocator.dupe(u8, "Beta"),
		.signature = try allocator.dupe(u8, "const Beta = struct"),
		.doc_comment = null,
		.symbol_kind = try allocator.dupe(u8, "struct"),
		.start_line = 1,
		.end_line = 1,
	};
	defer sym_struct.deinit(allocator);

	var sym_none = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/c.zig"),
		.name = try allocator.dupe(u8, "gamma"),
		.signature = try allocator.dupe(u8, "gamma"),
		.doc_comment = null,
		.symbol_kind = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym_none.deinit(allocator);

	const id1 = try storage.insertSymbol(db, sym_fn);
	try storage.insertEmbedding(db, allocator, id1, &[_]f32{ 0.0, 0.0 });
	const id2 = try storage.insertSymbol(db, sym_struct);
	try storage.insertEmbedding(db, allocator, id2, &[_]f32{ 0.0, 0.0 });
	const id3 = try storage.insertSymbol(db, sym_none);
	try storage.insertEmbedding(db, allocator, id3, &[_]f32{ 0.0, 0.0 });

	// Wildcard "*" means any non-null kind — should return fn and struct, not gamma
	var fake = FakeEmbedder{ .vector = &[_]f32{ 0.0, 0.0 } };
	const sr = try search(allocator, db, fake.embedder(), "", .{
		.top_n = 10,
		.allowed_symbol_kinds = &[_][]const u8{"*"},
	});
	defer freeResults(allocator, sr.results);

	try std.testing.expectEqual(@as(usize, 2), sr.results.len);
}

test "pathMatchesGlob matches file paths" {
	try std.testing.expect(pathMatchesGlob("src/storage.zig", "src/storage*"));
	try std.testing.expect(pathMatchesGlob("src/storage.zig", "src/*.zig"));
	try std.testing.expect(pathMatchesGlob("src/storage.zig", "*/storage.zig"));
	try std.testing.expect(pathMatchesGlob("src/storage.zig", "src/storage.zig"));
	try std.testing.expect(!pathMatchesGlob("src/search.zig", "src/storage*"));
	try std.testing.expect(pathMatchesGlob("src/a.zig", "src/?.zig"));
	try std.testing.expect(!pathMatchesGlob("src/ab.zig", "src/?.zig"));
	// Edge cases
	try std.testing.expect(pathMatchesGlob("anything", "*"));
	try std.testing.expect(!pathMatchesGlob("src/foo.zig", "src/bar.zig"));
	try std.testing.expect(pathMatchesGlob("", ""));
	try std.testing.expect(!pathMatchesGlob("", "a"));
	try std.testing.expect(!pathMatchesGlob("a", ""));
}

test "browse mode: path filter restricts results by file path" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

	var sym1 = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/storage.zig"),
		.name = try allocator.dupe(u8, "initDb"),
		.signature = try allocator.dupe(u8, "pub fn initDb() void"),
		.doc_comment = null,
		.symbol_kind = try allocator.dupe(u8, "fn"),
		.start_line = 1,
		.end_line = 5,
	};
	defer sym1.deinit(allocator);

	var sym2 = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/search.zig"),
		.name = try allocator.dupe(u8, "runSearch"),
		.signature = try allocator.dupe(u8, "pub fn runSearch() void"),
		.doc_comment = null,
		.symbol_kind = try allocator.dupe(u8, "fn"),
		.start_line = 1,
		.end_line = 5,
	};
	defer sym2.deinit(allocator);

	const id1 = try storage.insertSymbol(db, sym1);
	try storage.insertEmbedding(db, allocator, id1, &[_]f32{ 0.0, 0.0 });
	const id2 = try storage.insertSymbol(db, sym2);
	try storage.insertEmbedding(db, allocator, id2, &[_]f32{ 0.0, 0.0 });

	// Browse with path filter — should return only storage.zig symbol
	var fake = FakeEmbedder{ .vector = &[_]f32{ 0.0, 0.0 } };
	const sr = try search(allocator, db, fake.embedder(), "", .{
		.top_n = 10,
		.allowed_symbol_kinds = &[_][]const u8{"*"},
		.allowed_paths = &[_][]const u8{"src/storage*"},
	});
	defer freeResults(allocator, sr.results);

	try std.testing.expectEqual(@as(usize, 1), sr.results.len);
	try std.testing.expectEqualStrings("initDb", sr.results[0].symbol.name);
}
