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
