const std = @import("std");
const embedding = @import("embedding.zig");
const filters = @import("filters.zig");
const model = @import("model.zig");
const plugin = @import("plugin.zig");
const search = @import("search.zig");
const storage = @import("storage.zig");
const weights = @import("weights.zig");

pub const Request = struct {
	query: []const u8,
	top_n: usize,
	mode: search.SearchMode,
	fusion: search.FusionMode,
	rrf_k: f32,
	fts_mode: search.FtsMode,
	weight_vector: f32,
	weight_lexical: f32,
	explicit_weight_override: bool = false,
	min_score: f32,
	search_ext: ?[]const u8 = null,
	search_type: ?[]const u8 = null,
	search_lang: ?[]const u8 = null,
	search_symbol_kind: ?[]const u8 = null,
	primary_lang: ?[]const u8 = null,
	include_docs: bool = false,
	docs_only: bool = false,
	comments_only: bool = false,
	allowed_paths: []const []const u8 = &.{},
	search_weights: ?*const weights.Table = null,
};

pub const Execution = struct {
	allocator: std.mem.Allocator,
	filter_lists: filters.FilterLists,
	options: search.Options,
	result: search.SearchResult,

	pub fn deinit(self: *Execution) void {
		search.freeResults(self.allocator, self.result.results);
		self.filter_lists.deinit(self.allocator);
		self.* = undefined;
	}
};

/// Converts adapter-neutral search policy into the domain search options used
/// by every transport, keeping weight and filter semantics in one place.
fn resolveOptions(
	request: Request,
	allowed_langs: []const []const u8,
	allowed_exts: []const []const u8,
	allowed_symbol_kinds: []const []const u8,
	resolved_weights: weights.WeightPair,
) search.Options {
	return .{
		.top_n = request.top_n,
		.mode = request.mode,
		.fusion = request.fusion,
		.rrf_k = request.rrf_k,
		.fts_mode = request.fts_mode,
		.weight_vector = resolved_weights.weight_vector,
		.weight_lexical = resolved_weights.weight_lexical,
		.weight_symbol_kind = resolved_weights.weight_symbol_kind,
		.weight_symbol_visibility = resolved_weights.weight_symbol_visibility,
		.weight_symbol_scope = resolved_weights.weight_symbol_scope,
		.weight_symbol_arity = resolved_weights.weight_symbol_arity,
		.min_score = request.min_score,
		.allowed_langs = allowed_langs,
		.allowed_exts = allowed_exts,
		.allowed_symbol_kinds = allowed_symbol_kinds,
		.allowed_paths = request.allowed_paths,
		.comments_only = request.comments_only,
	};
}

/// Executes one transport-neutral search command while retaining its resolved
/// filters and options for adapter-specific diagnostics.
pub fn execute(
	allocator: std.mem.Allocator,
	db: storage.Db,
	registry: plugin.Registry,
	embedder: embedding.Embedder,
	request: Request,
) !Execution {
	var filter_lists = try filters.buildSearchFilters(allocator, registry, db, .{
		.search_ext = request.search_ext,
		.search_type = request.search_type,
		.search_lang = request.search_lang,
		.search_symbol_kind = request.search_symbol_kind,
		.primary_lang = request.primary_lang,
		.include_docs = request.include_docs,
		.docs_only = request.docs_only,
	});
	errdefer filter_lists.deinit(allocator);

	const resolved_weights = weights.resolveSearchWeights(
		request.search_weights,
		filter_lists.langs.items,
		request.weight_vector,
		request.weight_lexical,
		request.explicit_weight_override,
	);
	const options = resolveOptions(
		request,
		filter_lists.langs.items,
		filter_lists.exts.items,
		filter_lists.symbol_kinds.items,
		resolved_weights,
	);
	const result = try search.search(allocator, db, embedder, request.query, options);

	return .{
		.allocator = allocator,
		.filter_lists = filter_lists,
		.options = options,
		.result = result,
	};
}

test "resolveOptions maps application policy and resolved filters" {
	const request = Request{
		.query = "transaction rollback",
		.top_n = 17,
		.mode = .vector,
		.fusion = .rrf,
		.rrf_k = 42,
		.fts_mode = .strict,
		.weight_vector = 0.8,
		.weight_lexical = 0.2,
		.min_score = 0.125,
		.comments_only = true,
		.allowed_paths = &.{"src/storage.zig"},
	};
	const allowed_langs = [_][]const u8{"zig"};
	const allowed_exts = [_][]const u8{".zig"};
	const allowed_symbol_kinds = [_][]const u8{"fn"};
	const resolved_weights = weights.WeightPair{
		.weight_vector = 0.55,
		.weight_lexical = 0.45,
		.weight_symbol_kind = 0.15,
		.weight_symbol_visibility = 0.1,
		.weight_symbol_scope = 0.05,
		.weight_symbol_arity = 0.025,
	};

	const options = resolveOptions(
		request,
		&allowed_langs,
		&allowed_exts,
		&allowed_symbol_kinds,
		resolved_weights,
	);

	try std.testing.expectEqual(@as(usize, 17), options.top_n);
	try std.testing.expectEqual(search.SearchMode.vector, options.mode);
	try std.testing.expectEqual(search.FusionMode.rrf, options.fusion);
	try std.testing.expectEqual(@as(f32, 42), options.rrf_k);
	try std.testing.expectEqual(search.FtsMode.strict, options.fts_mode);
	try std.testing.expectEqual(@as(f32, 0.55), options.weight_vector);
	try std.testing.expectEqual(@as(f32, 0.45), options.weight_lexical);
	try std.testing.expectEqual(@as(f32, 0.15), options.weight_symbol_kind);
	try std.testing.expectEqual(@as(f32, 0.1), options.weight_symbol_visibility);
	try std.testing.expectEqual(@as(f32, 0.05), options.weight_symbol_scope);
	try std.testing.expectEqual(@as(f32, 0.025), options.weight_symbol_arity);
	try std.testing.expectEqual(@as(f32, 0.125), options.min_score);
	try std.testing.expectEqualSlices([]const u8, &allowed_langs, options.allowed_langs);
	try std.testing.expectEqualSlices([]const u8, &allowed_exts, options.allowed_exts);
	try std.testing.expectEqualSlices([]const u8, &allowed_symbol_kinds, options.allowed_symbol_kinds);
	try std.testing.expectEqualSlices([]const u8, request.allowed_paths, options.allowed_paths);
	try std.testing.expect(options.comments_only);
}

test "execute owns filter resolution and returns searchable results" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);
	var schema = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });
	defer schema.deinit(allocator);

	var symbol = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/storage.zig"),
		.name = try allocator.dupe(u8, "rollbackDelete"),
		.signature = try allocator.dupe(u8, "fn rollbackDelete() void"),
		.doc_comment = try allocator.dupe(u8, "Rolls back an interrupted transaction."),
		.start_line = 1,
		.end_line = 1,
	};
	defer symbol.deinit(allocator);
	_ = try storage.insertSymbol(db, symbol);

	var execution = try execute(
		allocator,
		db,
		plugin.defaultRegistry(),
		embedding.NullEmbedder.embedder(),
		.{
			.query = "rollback transaction",
			.top_n = 5,
			.mode = .lexical,
			.fusion = .weighted_sum,
			.rrf_k = 60,
			.fts_mode = .broad,
			.weight_vector = 0,
			.weight_lexical = 1,
			.min_score = 0,
			.search_lang = "zig",
		},
	);
	defer execution.deinit();

	try std.testing.expectEqual(@as(usize, 1), execution.result.results.len);
	try std.testing.expectEqualStrings("rollbackDelete", execution.result.results[0].symbol.name);
	try std.testing.expectEqual(@as(usize, 1), execution.options.allowed_langs.len);
	try std.testing.expectEqualStrings("zig", execution.options.allowed_langs[0]);
}
