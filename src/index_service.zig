const std = @import("std");
const config = @import("config.zig");
const embedding = @import("embedding.zig");
const filters = @import("filters.zig");
const indexer = @import("indexer.zig");
const io_singleton = @import("io_singleton.zig");
const kind = @import("kind.zig");
const plugin = @import("plugin.zig");
const scan = @import("scan.zig");
const storage = @import("storage.zig");

pub const Mode = enum {
	full,
	incremental,
};

pub const Request = struct {
	mode: Mode = .full,
	root_path: []const u8,
	embedding_dim: usize,
	embedding_model: []const u8,
	batch_size: usize,
	max_file_size: usize,
	index_ext: ?[]const u8 = null,
	index_type: ?[]const u8 = null,
	ignore_global: []const []const u8 = &.{},
	ignore_per_language: []const config.IgnoreOverride = &.{},
	include_node_modules: bool = false,
	always_include: []const []const u8 = &.{},
	require_embeddings: bool = true,
	show_progress: bool = false,
	discovery_progress: ?scan.FileProgress = null,
};

pub const Result = union(Mode) {
	full: indexer.Stats,
	incremental: indexer.IncrementalStats,
};

/// Converts adapter-neutral indexing policy into the common options consumed
/// by both full and incremental domain indexing operations.
fn resolveOptions(
	request: Request,
	allowed_exts: []const []const u8,
	allowed_kinds: []const kind.Kind,
) indexer.Options {
	return .{
		.embedding_dim = request.embedding_dim,
		.embedding_model = request.embedding_model,
		.batch_size = request.batch_size,
		.max_file_size = request.max_file_size,
		.allowed_exts = allowed_exts,
		.allowed_kinds = allowed_kinds,
		.ignore = .{
			.global = request.ignore_global,
			.per_language = request.ignore_per_language,
			.include_node_modules = request.include_node_modules,
			.always_include = request.always_include,
		},
		.require_embeddings = request.require_embeddings,
		.show_progress = request.show_progress,
		.discovery_progress = request.discovery_progress,
	};
}

/// Executes a full or incremental index through one application boundary so
/// adapters cannot drift in filter, ignore, batching, or progress semantics.
pub fn execute(
	allocator: std.mem.Allocator,
	db: storage.Db,
	registry: plugin.Registry,
	embedder: embedding.Embedder,
	request: Request,
) !Result {
	var filter_lists = try filters.buildIndexFilters(allocator, request.index_ext, request.index_type);
	defer filter_lists.deinit(allocator);
	const options = resolveOptions(request, filter_lists.exts.items, filter_lists.kinds.items);

	return switch (request.mode) {
		.full => .{ .full = try indexer.indexAll(
			allocator,
			db,
			request.root_path,
			registry,
			embedder,
			options,
		) },
		.incremental => .{ .incremental = try indexer.indexIncremental(
			allocator,
			db,
			request.root_path,
			registry,
			embedder,
			options,
		) },
	};
}

/// Reports the semantic-index work an incremental pass would perform without
/// mutating the index. Adapters use this only while a watcher owns updates.
pub fn pendingPathCounts(
	allocator: std.mem.Allocator,
	db: storage.Db,
	registry: plugin.Registry,
	request: Request,
) !indexer.PendingPathCounts {
	var filter_lists = try filters.buildIndexFilters(allocator, request.index_ext, request.index_type);
	defer filter_lists.deinit(allocator);
	const options = resolveOptions(request, filter_lists.exts.items, filter_lists.kinds.items);
	return indexer.pendingPathCounts(allocator, db, request.root_path, registry, options);
}

test "resolveOptions maps application indexing policy and resolved filters" {
	const request = Request{
		.root_path = "src",
		.embedding_dim = 1536,
		.embedding_model = "jina-code-embeddings:1.5b",
		.batch_size = 3,
		.max_file_size = 4096,
		.require_embeddings = false,
		.show_progress = true,
	};
	const allowed_exts = [_][]const u8{".zig"};
	const allowed_kinds = [_]kind.Kind{.code};

	const options = resolveOptions(request, &allowed_exts, &allowed_kinds);

	try std.testing.expectEqual(@as(usize, 1536), options.embedding_dim);
	try std.testing.expectEqualStrings("jina-code-embeddings:1.5b", options.embedding_model);
	try std.testing.expectEqual(@as(usize, 3), options.batch_size);
	try std.testing.expectEqual(@as(usize, 4096), options.max_file_size);
	try std.testing.expectEqualSlices([]const u8, &allowed_exts, options.allowed_exts);
	try std.testing.expectEqualSlices(kind.Kind, &allowed_kinds, options.allowed_kinds);
	try std.testing.expect(!options.require_embeddings);
	try std.testing.expect(options.show_progress);
}

test "execute owns full and incremental index dispatch" {
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	try tmp.dir.writeFile(io_singleton.getOrInit(), .{
		.sub_path = "first.zig",
		.data = "pub fn first() void {}\n",
	});

	const allocator = std.testing.allocator;
	const root = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
	defer allocator.free(root);
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);
	const base_request = Request{
		.root_path = root,
		.embedding_dim = 2,
		.embedding_model = "test-model",
		.batch_size = 2,
		.max_file_size = 4096,
		.index_ext = "zig",
		.require_embeddings = false,
	};

	const full = try execute(
		allocator,
		db,
		plugin.defaultRegistry(),
		embedding.NullEmbedder.embedder(),
		base_request,
	);
	try std.testing.expectEqual(@as(usize, 1), full.full.files);
	try std.testing.expectEqual(@as(usize, 1), full.full.symbols);

	try tmp.dir.writeFile(io_singleton.getOrInit(), .{
		.sub_path = "second.zig",
		.data = "pub fn second() void {}\n",
	});
	var incremental_request = base_request;
	incremental_request.mode = .incremental;
	const incremental = try execute(
		allocator,
		db,
		plugin.defaultRegistry(),
		embedding.NullEmbedder.embedder(),
		incremental_request,
	);
	try std.testing.expectEqual(@as(usize, 1), incremental.incremental.new_files);
	try std.testing.expectEqual(@as(usize, 1), incremental.incremental.unchanged_files);
}

test "full indexing rebuilds vector schemas when the detected model width changes" {
	const http = @import("embedding_http.zig");
	const update = @import("update_service.zig");
	const Reply = struct {
		calls: usize = 0,
		fn send(ctx: *anyopaque, allocator: std.mem.Allocator, _: http.HttpRequest) !http.HttpResponse {
			const self: *@This() = @ptrCast(@alignCast(ctx));
			self.calls += 1;
			return .{ .status = 200, .body = try allocator.dupe(u8, "{\"embeddings\":[[1,0,0]]}") };
		}
	};
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	try tmp.dir.writeFile(io_singleton.getOrInit(), .{
		.sub_path = "current.zig", .data = "/// A current operation.\npub fn current() void {}\n",
	});
	const root = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
	defer allocator.free(root);
	var failures: usize = 0;
	for ([_]bool{ false, true }) |populated| {
		const db = try storage.openMemoryWithVec(allocator);
		defer storage.close(db);
		var old_schema = try storage.initSchema(allocator, db, .{ .embedding_dim = 2, .embedding_model = "original-model" });
		defer old_schema.deinit(allocator);
		if (populated) {
			const id = try storage.insertSymbol(db, .{
				.language = "zig", .file_path = "old.zig", .name = "old", .signature = "fn old() void",
				.doc_comment = "An original operation.", .start_line = 1, .end_line = 1,
			});
			try storage.insertEmbedding(db, allocator, id, &.{ 1, 0 });
			try storage.insertCommentEmbedding(db, allocator, id, &.{ 0, 1 });
		}
		var reply = Reply{};
		var adapter = embedding.HttpEmbedder{
			.transport = .{ .ctx = &reply, .send = Reply.send }, .base_url = "http://provider.invalid", .model = "replacement-model",
		};
		const dimension = update.probeEmbeddingDim(allocator, adapter.embedder()).?;
		try std.testing.expectEqual(@as(usize, 3), dimension);
		const result = execute(allocator, db, plugin.defaultRegistry(), adapter.embedder(), .{
			.root_path = root, .embedding_dim = dimension, .embedding_model = "replacement-model",
			.batch_size = 1, .max_file_size = 4096, .index_ext = "zig",
		}) catch |err| {
			std.debug.print("full-index width change (populated={}) returned {s}\n", .{ populated, @errorName(err) });
			failures += 1;
			continue;
		};
		try std.testing.expectEqual(@as(usize, 1), result.full.files);
		try std.testing.expectEqual(@as(usize, 1), result.full.symbols);
		try std.testing.expectEqual(@as(i64, 1), try storage.countRows(db, allocator, "symbols"));
		try std.testing.expectEqual(@as(i64, 1), try storage.countRows(db, allocator, "embeddings"));
		try std.testing.expectEqual(@as(i64, 1), try storage.countRows(db, allocator, "embeddings_comment"));
		try std.testing.expectEqual(@as(usize, 3), reply.calls);
		try std.testing.expectEqual(dimension, try storage.embeddingDimension(db, allocator));
		var checked = try storage.initSchema(allocator, db, .{ .embedding_dim = dimension, .embedding_model = "replacement-model" });
		defer checked.deinit(allocator);
		try std.testing.expect(!checked.embedding_model_mismatch and !checked.embedding_dim_mismatch);
	}
	try std.testing.expectEqual(@as(usize, 0), failures);
}

test "full index preparation preserves the old index after failure and permits retry" {
	const http = @import("embedding_http.zig");
	const semantic = @import("search.zig");
	const sql = storage.sqlite;
	const DenyReset = struct {
		denials: usize = 0,
		fn authorize(context: ?*anyopaque, action: c_int, table: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8) callconv(.c) c_int {
			if (action != sql.SQLITE_DELETE or table == null or !std.mem.eql(u8, std.mem.span(table), "embeddings_comment")) return sql.SQLITE_OK;
			const self: *@This() = @ptrCast(@alignCast(context.?));
			self.denials += 1;
			return sql.SQLITE_DENY;
		}
	};
	const Reply = struct {
		calls: usize = 0,
		fn send(ctx: *anyopaque, allocator: std.mem.Allocator, _: http.HttpRequest) !http.HttpResponse {
			const self: *@This() = @ptrCast(@alignCast(ctx));
			self.calls += 1;
			return .{ .status = 200, .body = try allocator.dupe(u8, "{\"embeddings\":[[1,0]]}") };
		}
	};
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	try tmp.dir.writeFile(io_singleton.getOrInit(), .{
		.sub_path = "current.zig", .data = "/// A current operation.\npub fn current() void {}\n",
	});
	const root = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
	defer allocator.free(root);
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);
	var schema = try storage.initSchema(allocator, db, .{ .embedding_dim = 2, .embedding_model = "original-model" });
	defer schema.deinit(allocator);
	const id = try storage.insertSymbol(db, .{
		.language = "zig", .file_path = "old.zig", .name = "old", .signature = "fn old() void",
		.doc_comment = "An original operation.", .start_line = 1, .end_line = 1,
	});
	try storage.insertEmbedding(db, allocator, id, &.{ 1, 0 });
	try storage.insertCommentEmbedding(db, allocator, id, &.{ 0, 1 });
	var reply = Reply{};
	var adapter = embedding.HttpEmbedder{
		.transport = .{ .ctx = &reply, .send = Reply.send }, .base_url = "http://provider.invalid", .model = "original-model",
	};
	const request = Request{
		.root_path = root, .embedding_dim = 2, .embedding_model = "original-model",
		.batch_size = 1, .max_file_size = 4096, .index_ext = "zig",
	};
	var fault = DenyReset{};
	try std.testing.expectEqual(sql.SQLITE_OK, sql.sqlite3_set_authorizer(db, DenyReset.authorize, &fault));
	defer _ = sql.sqlite3_set_authorizer(db, null, null);
	try std.testing.expectError(error.SqlError, execute(allocator, db, plugin.defaultRegistry(), adapter.embedder(), request));
	try std.testing.expect(fault.denials > 0);
	try std.testing.expectEqual(@as(usize, 0), reply.calls);
	try std.testing.expectEqual(@as(i64, 1), try storage.countRows(db, allocator, "symbols"));
	try std.testing.expectEqual(@as(i64, 1), try storage.countRows(db, allocator, "embeddings"));
	try std.testing.expectEqual(@as(i64, 1), try storage.countRows(db, allocator, "embeddings_comment"));
	try std.testing.expectEqual(@as(usize, 2), try storage.embeddingDimension(db, allocator));
	const retained = try semantic.search(allocator, db, adapter.embedder(), "old", .{ .mode = .vector, .top_n = 1 });
	defer semantic.freeResults(allocator, retained.results);
	try std.testing.expectEqual(@as(usize, 1), retained.results.len);
	try std.testing.expectEqualStrings("old", retained.results[0].symbol.name);
	try std.testing.expectEqual(sql.SQLITE_OK, sql.sqlite3_set_authorizer(db, null, null));
	const retried = try execute(allocator, db, plugin.defaultRegistry(), adapter.embedder(), request);
	try std.testing.expectEqual(@as(usize, 1), retried.full.symbols);
	try std.testing.expectEqual(@as(i64, 1), try storage.countRows(db, allocator, "symbols"));
	try std.testing.expectEqual(@as(i64, 1), try storage.countRows(db, allocator, "embeddings"));
	try std.testing.expectEqual(@as(i64, 1), try storage.countRows(db, allocator, "embeddings_comment"));
}

test "pendingPathCounts owns index filter resolution" {
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	try tmp.dir.writeFile(io_singleton.getOrInit(), .{
		.sub_path = "first.zig",
		.data = "pub fn first() void {}\n",
	});

	const allocator = std.testing.allocator;
	const root = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
	defer allocator.free(root);
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);
	const request = Request{
		.root_path = root,
		.embedding_dim = 2,
		.embedding_model = "test-model",
		.batch_size = 2,
		.max_file_size = 4096,
		.index_ext = "zig",
		.require_embeddings = false,
	};
	_ = try execute(allocator, db, plugin.defaultRegistry(), embedding.NullEmbedder.embedder(), request);

	try tmp.dir.writeFile(io_singleton.getOrInit(), .{
		.sub_path = "second.zig",
		.data = "pub fn second() void {}\n",
	});
	try tmp.dir.writeFile(io_singleton.getOrInit(), .{
		.sub_path = "notes.md",
		.data = "not in this semantic index\n",
	});

	const pending = try pendingPathCounts(allocator, db, plugin.defaultRegistry(), request);
	try std.testing.expectEqual(@as(usize, 1), pending.new_files);
	try std.testing.expectEqual(@as(usize, 1), pending.total());
}
