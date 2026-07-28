const std = @import("std");
const embedding = @import("embedding.zig");
const storage = @import("storage.zig");
const model = @import("model.zig");
const io_singleton = @import("io_singleton.zig");

/// How an update database open is allowed to react to an unusable index.
/// `inspect_only` reports the problem without touching data; `immediate_recreate`
/// is permitted to destroy and rebuild it.
pub const OpenMode = enum {
	inspect_only,
	immediate_recreate,
};

/// Observations about an existing index gathered while opening it: whether the
/// schema could be initialized at all, and whether the stored embedding
/// model/dimension still match the configured ones.
pub const SchemaProbe = struct {
	init_failed: bool = false,
	model_mismatch: bool = false,
	dim_mismatch: bool = false,
};

/// The lifecycle verdict for an update database: reuse it, refuse it, or
/// recreate it — and, when refusing or recreating, why.
pub const DbAction = enum {
	use_existing,
	fail_incompatible,
	fail_embedding_mismatch,
	recreate_incompatible,
	recreate_embedding_mismatch,
};

/// Decides the update database lifecycle action from a schema probe and the
/// caller's destruction budget. Pure and total over the finite probe × mode
/// domain so the policy can be exhausted in tests rather than sampled.
pub fn decideDbAction(probe: SchemaProbe, mode: OpenMode) DbAction {
	// A schema that would not initialize tells us nothing about its embedding
	// metadata, so this case dominates the mismatch flags rather than combining
	// with them.
	if (probe.init_failed) return switch (mode) {
		.inspect_only => .fail_incompatible,
		.immediate_recreate => .recreate_incompatible,
	};

	if (!probe.model_mismatch and !probe.dim_mismatch) return .use_existing;

	return switch (mode) {
		.inspect_only => .fail_embedding_mismatch,
		.immediate_recreate => .recreate_embedding_mismatch,
	};
}

/// Why an update database was rebuilt rather than reused.
pub const RebuildReason = enum {
	none,
	incompatible,
	embedding_mismatch,
};

/// What an adapter permits when the existing index cannot be reused. The
/// distinction matters because destroying an index is only safe once the
/// replacement embedder has been shown to produce the same vector width.
pub const RebuildPolicy = enum {
	/// Report the problem and change nothing. Used by pre-search reconciliation
	/// with a null embedder, which could not regenerate what it deleted.
	refuse,
	/// Rebuild without probing: the caller has no live embedder to ask, and has
	/// accepted that the index will be repopulated without vectors.
	recreate_unverified,
	/// Ask the live embedder for its real width first, and refuse to touch the
	/// index if it disagrees with the configured dimension.
	verify_then_recreate,
};

/// An opened update database plus the story of how it got that way.
pub const Prepared = struct {
	db: storage.Db,
	schema_result: storage.InitSchemaResult,
	rebuild_reason: RebuildReason = .none,
	previous_embedding_model: ?[]u8 = null,
	previous_embedding_dim: ?usize = null,
	effective_dim: usize = 0,

	pub fn deinit(self: *Prepared, allocator: std.mem.Allocator) void {
		if (self.previous_embedding_model) |value| allocator.free(value);
		self.schema_result.deinit(allocator);
		storage.close(self.db);
		self.* = undefined;
	}
};

pub const PrepareRequest = struct {
	db_path: []const u8,
	embedding_dim: usize,
	embedding_model: []const u8,
	policy: RebuildPolicy = .verify_then_recreate,
	/// Called once immediately before the live embedder is probed, so an
	/// interactive adapter can explain a pause it would otherwise not account
	/// for. Never called on the paths that do not probe.
	on_verify_start: ?*const fn () void = null,
};

/// Asks an embedder for the width of the vectors it actually produces, by
/// embedding one throwaway input. Returns null when the provider is unreachable
/// or answers with nothing usable.
pub fn probeEmbeddingDim(allocator: std.mem.Allocator, embedder: embedding.Embedder) ?usize {
	const inputs = [_][]const u8{"dimension probe"};
	const embeddings = embedder.embed(embedder.ctx, allocator, &inputs) catch return null;
	defer embedder.free(embedder.ctx, allocator, embeddings);
	if (embeddings.len == 0) return null;
	if (embeddings[0].len == 0) return null;
	return embeddings[0].len;
}

/// Opens an update database, choosing a fresh index whenever the stored
/// embedding model or dimension cannot represent the configured vectors.
pub fn openDb(
	allocator: std.mem.Allocator,
	db_path: []const u8,
	schema: storage.Schema,
	mode: OpenMode,
) !Prepared {
	var db = try storage.openFileWithVec(allocator, db_path);
	var init_failed = false;
	var schema_result: storage.InitSchemaResult = storage.initSchema(allocator, db, schema) catch probe: {
		init_failed = true;
		break :probe .{};
	};

	const action = decideDbAction(.{
		.init_failed = init_failed,
		.model_mismatch = schema_result.embedding_model_mismatch,
		.dim_mismatch = schema_result.embedding_dim_mismatch,
	}, mode);

	if (action == .use_existing) return .{ .db = db, .schema_result = schema_result };

	// Every remaining action abandons the database that is currently open, so
	// rescue the stored embedding identity before the schema result is freed —
	// callers render it when explaining a rebuild.
	const previous_model = schema_result.stored_embedding_model;
	schema_result.stored_embedding_model = null;
	const previous_dim = schema_result.stored_embedding_dim;
	schema_result.deinit(allocator);
	storage.close(db);

	switch (action) {
		.use_existing => unreachable,
		.fail_incompatible, .fail_embedding_mismatch => {
			if (previous_model) |value| allocator.free(value);
			return switch (action) {
				.fail_incompatible => error.IncompatibleDatabase,
				else => error.EmbeddingMismatch,
			};
		},
		.recreate_incompatible, .recreate_embedding_mismatch => {},
	}

	db = storage.openFileWithVecRecreate(allocator, db_path) catch |err| {
		if (previous_model) |value| allocator.free(value);
		return err;
	};
	errdefer {
		if (previous_model) |value| allocator.free(value);
		storage.close(db);
	}
	schema_result = try storage.initSchema(allocator, db, schema);
	return .{
		.db = db,
		.schema_result = schema_result,
		.rebuild_reason = switch (action) {
			.recreate_incompatible => .incompatible,
			else => .embedding_mismatch,
		},
		// A failed schema init never observed an embedding identity, so these
		// are null on the `.incompatible` path by construction.
		.previous_embedding_model = previous_model,
		.previous_embedding_dim = previous_dim,
	};
}

/// Opens the update database for indexing, never destroying an existing index
/// until the replacement embedder has been proven to produce the configured
/// vector width. Inspects first; only on an unusable index does it consult the
/// policy, and only `verify_then_recreate` reaches the embedder.
pub fn prepare(
	allocator: std.mem.Allocator,
	embedder: embedding.Embedder,
	request: PrepareRequest,
) !Prepared {
	var effective_dim = request.embedding_dim;

	// Inspect first. Nothing is destroyed on this pass, so an index that turns
	// out to be unusable is still intact while the policy is consulted.
	var prepared = openDb(allocator, request.db_path, .{
		.embedding_dim = request.embedding_dim,
		.embedding_model = request.embedding_model,
	}, .inspect_only) catch |err| retry: {
		switch (err) {
			error.EmbeddingMismatch, error.IncompatibleDatabase => {},
			else => return err,
		}

		switch (request.policy) {
			.refuse => return err,
			.recreate_unverified => {},
			.verify_then_recreate => {
				if (request.on_verify_start) |notify| notify();
				// Ask the provider what it actually emits. Trusting the
				// configured value here is what would let a rebuild wipe an
				// index and then fail to repopulate it at the expected width.
				const detected = probeEmbeddingDim(allocator, embedder) orelse
					return error.EmbeddingUnavailable;
				if (detected != request.embedding_dim) return error.EmbeddingDimensionMismatch;
				effective_dim = detected;
			},
		}

		break :retry try openDb(allocator, request.db_path, .{
			.embedding_dim = effective_dim,
			.embedding_model = request.embedding_model,
		}, .immediate_recreate);
	};

	prepared.effective_dim = effective_dim;
	return prepared;
}


const DecisionCase = struct {
	probe: SchemaProbe,
	mode: OpenMode,
	expected: DbAction,
};

/// Every point of the `SchemaProbe` × `OpenMode` domain (2 modes × 2^3 probe
/// states = 16), with the action transcribed from the behavior of `openUpdateDb`
/// in `main.zig`: a failed schema init dominates the embedding flags, a clean
/// probe reuses the index, and either embedding mismatch is one verdict.
const decision_table = [_]DecisionCase{
	// Clean probe: reuse regardless of what destruction is permitted.
	.{ .probe = .{}, .mode = .inspect_only, .expected = .use_existing },
	.{ .probe = .{}, .mode = .immediate_recreate, .expected = .use_existing },

	// Embedding model mismatch alone.
	.{ .probe = .{ .model_mismatch = true }, .mode = .inspect_only, .expected = .fail_embedding_mismatch },
	.{ .probe = .{ .model_mismatch = true }, .mode = .immediate_recreate, .expected = .recreate_embedding_mismatch },

	// Embedding dimension mismatch alone.
	.{ .probe = .{ .dim_mismatch = true }, .mode = .inspect_only, .expected = .fail_embedding_mismatch },
	.{ .probe = .{ .dim_mismatch = true }, .mode = .immediate_recreate, .expected = .recreate_embedding_mismatch },

	// Both embedding flags: still one verdict, not a distinct one.
	.{ .probe = .{ .model_mismatch = true, .dim_mismatch = true }, .mode = .inspect_only, .expected = .fail_embedding_mismatch },
	.{ .probe = .{ .model_mismatch = true, .dim_mismatch = true }, .mode = .immediate_recreate, .expected = .recreate_embedding_mismatch },

	// A failed schema init dominates: the embedding flags were never observed,
	// so they must not change the verdict in any of their four combinations.
	.{ .probe = .{ .init_failed = true }, .mode = .inspect_only, .expected = .fail_incompatible },
	.{ .probe = .{ .init_failed = true }, .mode = .immediate_recreate, .expected = .recreate_incompatible },
	.{ .probe = .{ .init_failed = true, .model_mismatch = true }, .mode = .inspect_only, .expected = .fail_incompatible },
	.{ .probe = .{ .init_failed = true, .model_mismatch = true }, .mode = .immediate_recreate, .expected = .recreate_incompatible },
	.{ .probe = .{ .init_failed = true, .dim_mismatch = true }, .mode = .inspect_only, .expected = .fail_incompatible },
	.{ .probe = .{ .init_failed = true, .dim_mismatch = true }, .mode = .immediate_recreate, .expected = .recreate_incompatible },
	.{ .probe = .{ .init_failed = true, .model_mismatch = true, .dim_mismatch = true }, .mode = .inspect_only, .expected = .fail_incompatible },
	.{ .probe = .{ .init_failed = true, .model_mismatch = true, .dim_mismatch = true }, .mode = .immediate_recreate, .expected = .recreate_incompatible },
};

test "decision table covers every probe/mode domain point exactly once" {
	// Sweep the domain mechanically rather than trusting the table's length, so
	// a duplicated row cannot mask a missing one.
	for ([_]OpenMode{ .inspect_only, .immediate_recreate }) |mode| {
		for (0..8) |bits| {
			const probe = SchemaProbe{
				.init_failed = bits & 0b001 != 0,
				.model_mismatch = bits & 0b010 != 0,
				.dim_mismatch = bits & 0b100 != 0,
			};
			var matches: usize = 0;
			for (decision_table) |case| {
				if (case.mode == mode and std.meta.eql(case.probe, probe)) matches += 1;
			}
			if (matches != 1) {
				std.debug.print(
					"domain point mode={s} init_failed={} model_mismatch={} dim_mismatch={} matched {d} table rows\n",
					.{ @tagName(mode), probe.init_failed, probe.model_mismatch, probe.dim_mismatch, matches },
				);
				return error.DomainPointNotCoveredExactlyOnce;
			}
		}
	}
}

test "decideDbAction matches the openUpdateDb decision table across the whole domain" {
	for (decision_table) |case| {
		const actual = decideDbAction(case.probe, case.mode);
		if (actual != case.expected) {
			std.debug.print(
				"mode={s} init_failed={} model_mismatch={} dim_mismatch={}: expected {s}, got {s}\n",
				.{
					@tagName(case.mode),
					case.probe.init_failed,
					case.probe.model_mismatch,
					case.probe.dim_mismatch,
					@tagName(case.expected),
					@tagName(actual),
				},
			);
			return error.DecisionMismatch;
		}
	}
}

/// An embedder that reports a fixed vector width and counts how many times it
/// was consulted, so tests can assert that non-verifying policies never reach
/// the provider at all.
const FakeEmbedder = struct {
	dim: usize,
	calls: usize = 0,

	fn embedder(self: *FakeEmbedder) embedding.Embedder {
		return .{ .ctx = self, .embed = embedFn, .free = freeFn };
	}

	fn embedFn(ctx: *anyopaque, allocator: std.mem.Allocator, inputs: []const []const u8) anyerror![][]f32 {
		const self: *FakeEmbedder = @ptrCast(@alignCast(ctx));
		self.calls += 1;
		const out = try allocator.alloc([]f32, inputs.len);
		errdefer allocator.free(out);
		for (out) |*slot| {
			slot.* = try allocator.alloc(f32, self.dim);
			@memset(slot.*, 0.5);
		}
		return out;
	}

	fn freeFn(_: *anyopaque, allocator: std.mem.Allocator, embeddings: [][]f32) void {
		for (embeddings) |vector| allocator.free(vector);
		allocator.free(embeddings);
	}
};

/// Builds an index carrying a stored embedding identity that will not match the
/// one the caller later configures, and puts one symbol plus one vector in it so
/// destruction is observable.
fn seedMismatchedIndex(allocator: std.mem.Allocator, db_path: []const u8) !void {
	const db = try storage.openFileWithVec(allocator, db_path);
	defer storage.close(db);
	var schema_result = try storage.initSchema(allocator, db, .{
		.embedding_dim = 2,
		.embedding_model = "bge-large",
	});
	defer schema_result.deinit(allocator);

	var symbol = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/main.zig"),
		.name = try allocator.dupe(u8, "main"),
		.signature = try allocator.dupe(u8, "pub fn main() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer symbol.deinit(allocator);
	const rowid = try storage.insertSymbol(db, symbol);
	try storage.insertEmbedding(db, allocator, rowid, &.{ 0.1, 0.2 });
}

fn countSymbols(allocator: std.mem.Allocator, db_path: []const u8) !i64 {
	const db = try storage.openFileWithVec(allocator, db_path);
	defer storage.close(db);
	return storage.countRows(db, allocator, "symbols");
}

test "prepare refuses to destroy an index when the live embedder's width disagrees" {
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const root = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
	defer allocator.free(root);
	const db_path = try std.fs.path.join(allocator, &.{ root, "index.sqlite3" });
	defer allocator.free(db_path);

	try seedMismatchedIndex(allocator, db_path);

	// The caller wants 4-wide vectors, but the provider actually emits 8. The
	// index must survive: regenerating it would produce vectors the schema
	// cannot store, and the old data would already be gone.
	var fake = FakeEmbedder{ .dim = 8 };
	try std.testing.expectError(error.EmbeddingDimensionMismatch, prepare(allocator, fake.embedder(), .{
		.db_path = db_path,
		.embedding_dim = 4,
		.embedding_model = "jina-code-embeddings:1.5b",
		.policy = .verify_then_recreate,
	}));

	try std.testing.expectEqual(@as(usize, 1), fake.calls);
	try std.testing.expectEqual(@as(i64, 1), try countSymbols(allocator, db_path));
}

test "prepare rebuilds once the live embedder's width is confirmed" {
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const root = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
	defer allocator.free(root);
	const db_path = try std.fs.path.join(allocator, &.{ root, "index.sqlite3" });
	defer allocator.free(db_path);

	try seedMismatchedIndex(allocator, db_path);

	var fake = FakeEmbedder{ .dim = 4 };
	var prepared = try prepare(allocator, fake.embedder(), .{
		.db_path = db_path,
		.embedding_dim = 4,
		.embedding_model = "jina-code-embeddings:1.5b",
		.policy = .verify_then_recreate,
	});
	defer prepared.deinit(allocator);

	try std.testing.expectEqual(@as(usize, 1), fake.calls);
	try std.testing.expectEqual(RebuildReason.embedding_mismatch, prepared.rebuild_reason);
	try std.testing.expectEqualStrings("bge-large", prepared.previous_embedding_model.?);
	try std.testing.expectEqual(@as(?usize, 2), prepared.previous_embedding_dim);
	try std.testing.expectEqual(@as(usize, 4), prepared.effective_dim);
	try std.testing.expectEqual(@as(i64, 0), try storage.countRows(prepared.db, allocator, "symbols"));
}

test "prepare with the refuse policy neither rebuilds nor contacts the embedder" {
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const root = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
	defer allocator.free(root);
	const db_path = try std.fs.path.join(allocator, &.{ root, "index.sqlite3" });
	defer allocator.free(db_path);

	try seedMismatchedIndex(allocator, db_path);

	// Pre-search reconciliation with a null embedder takes this path: it could
	// not regenerate what it deleted, so it must report instead.
	var fake = FakeEmbedder{ .dim = 4 };
	try std.testing.expectError(error.EmbeddingMismatch, prepare(allocator, fake.embedder(), .{
		.db_path = db_path,
		.embedding_dim = 4,
		.embedding_model = "jina-code-embeddings:1.5b",
		.policy = .refuse,
	}));

	try std.testing.expectEqual(@as(usize, 0), fake.calls);
	try std.testing.expectEqual(@as(i64, 1), try countSymbols(allocator, db_path));
}

test "prepare with the unverified policy rebuilds without contacting the embedder" {
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const root = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
	defer allocator.free(root);
	const db_path = try std.fs.path.join(allocator, &.{ root, "index.sqlite3" });
	defer allocator.free(db_path);

	try seedMismatchedIndex(allocator, db_path);

	// An explicit update with --lexical-only has no provider to ask; rebuilding
	// is the caller's stated intent, so no probe may be attempted.
	var fake = FakeEmbedder{ .dim = 99 };
	var prepared = try prepare(allocator, fake.embedder(), .{
		.db_path = db_path,
		.embedding_dim = 4,
		.embedding_model = "jina-code-embeddings:1.5b",
		.policy = .recreate_unverified,
	});
	defer prepared.deinit(allocator);

	try std.testing.expectEqual(@as(usize, 0), fake.calls);
	try std.testing.expectEqual(RebuildReason.embedding_mismatch, prepared.rebuild_reason);
	try std.testing.expectEqual(@as(usize, 4), prepared.effective_dim);
}

test "prepare reuses a matching index without consulting the embedder" {
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const root = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
	defer allocator.free(root);
	const db_path = try std.fs.path.join(allocator, &.{ root, "index.sqlite3" });
	defer allocator.free(db_path);

	{
		const db = try storage.openFileWithVec(allocator, db_path);
		defer storage.close(db);
		var schema_result = try storage.initSchema(allocator, db, .{
			.embedding_dim = 4,
			.embedding_model = "jina-code-embeddings:1.5b",
		});
		defer schema_result.deinit(allocator);
	}

	var fake = FakeEmbedder{ .dim = 4 };
	var prepared = try prepare(allocator, fake.embedder(), .{
		.db_path = db_path,
		.embedding_dim = 4,
		.embedding_model = "jina-code-embeddings:1.5b",
		.policy = .verify_then_recreate,
	});
	defer prepared.deinit(allocator);

	try std.testing.expectEqual(@as(usize, 0), fake.calls);
	try std.testing.expectEqual(RebuildReason.none, prepared.rebuild_reason);
}

test "openDb recreates populated indexes when embedding model or dimension changes" {
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const root = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
	defer allocator.free(root);
	const db_path = try std.fs.path.join(allocator, &.{ root, "index.sqlite3" });
	defer allocator.free(db_path);

	{
		const old_db = try storage.openFileWithVec(allocator, db_path);
		defer storage.close(old_db);
		var old_schema = try storage.initSchema(allocator, old_db, .{
			.embedding_dim = 2,
			.embedding_model = "bge-large",
		});
		defer old_schema.deinit(allocator);

		var symbol = model.Symbol{
			.language = try allocator.dupe(u8, "zig"),
			.file_path = try allocator.dupe(u8, "src/main.zig"),
			.name = try allocator.dupe(u8, "main"),
			.signature = try allocator.dupe(u8, "pub fn main() void"),
			.doc_comment = null,
			.start_line = 1,
			.end_line = 1,
		};
		defer symbol.deinit(allocator);
		const rowid = try storage.insertSymbol(old_db, symbol);
		try storage.insertEmbedding(old_db, allocator, rowid, &.{ 0.1, 0.2 });
		try storage.upsertIndexedFile(old_db, "src/main.zig", 1, 20);
	}

	try std.testing.expectError(error.EmbeddingMismatch, openDb(allocator, db_path, .{
		.embedding_dim = 4,
		.embedding_model = "jina-code-embeddings:1.5b",
	}, .inspect_only));
	{
		const preserved_db = try storage.openFileWithVec(allocator, db_path);
		defer storage.close(preserved_db);
		try std.testing.expectEqual(@as(i64, 1), try storage.countRows(preserved_db, allocator, "symbols"));
		try std.testing.expectEqual(@as(i64, 1), try storage.countRows(preserved_db, allocator, "embeddings"));
	}

	var prepared = try openDb(allocator, db_path, .{
		.embedding_dim = 4,
		.embedding_model = "jina-code-embeddings:1.5b",
	}, .immediate_recreate);
	defer prepared.deinit(allocator);

	try std.testing.expectEqual(RebuildReason.embedding_mismatch, prepared.rebuild_reason);
	try std.testing.expectEqualStrings("bge-large", prepared.previous_embedding_model.?);
	try std.testing.expectEqual(@as(?usize, 2), prepared.previous_embedding_dim);
	try std.testing.expectEqual(@as(i64, 0), try storage.countRows(prepared.db, allocator, "symbols"));
	try std.testing.expectEqual(@as(i64, 0), try storage.countRows(prepared.db, allocator, "embeddings"));
	try std.testing.expectEqual(@as(?i64, null), try storage.getIndexedFileMtime(prepared.db, "src/main.zig"));

	// Prove sqlite-vec was recreated at the requested width, not merely emptied.
	var fresh_symbol = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/fresh.zig"),
		.name = try allocator.dupe(u8, "fresh"),
		.signature = try allocator.dupe(u8, "fn fresh() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer fresh_symbol.deinit(allocator);
	const fresh_rowid = try storage.insertSymbol(prepared.db, fresh_symbol);
	try storage.insertEmbedding(prepared.db, allocator, fresh_rowid, &.{ 0.1, 0.2, 0.3, 0.4 });
}

/// Whether an index exists on disk and holds anything worth searching.
/// Freshness policy uses this to decide whether a failed reconciliation may
/// fall back to a stale index rather than failing the search outright, so
/// "missing" and "present but empty" must both answer false.
pub fn indexUsable(allocator: std.mem.Allocator, db_path: []const u8) bool {
	std.Io.Dir.accessAbsolute(io_singleton.getOrInit(), db_path, .{}) catch return false;
	const db = storage.openFileWithVec(allocator, db_path) catch return false;
	defer storage.close(db);
	return storage.isIndexPopulated(db);
}

test "indexUsable classifies missing, empty, and populated indexes" {
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const root = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
	defer allocator.free(root);

	// Missing: no file at all.
	const missing = try std.fs.path.join(allocator, &.{ root, "absent.sqlite3" });
	defer allocator.free(missing);
	try std.testing.expect(!indexUsable(allocator, missing));

	// Present but empty — the case that must not be mistaken for usable, since
	// falling back to it would silently return no results.
	const empty = try std.fs.path.join(allocator, &.{ root, "empty.sqlite3" });
	defer allocator.free(empty);
	{
		const db = try storage.openFileWithVec(allocator, empty);
		defer storage.close(db);
		var schema_result = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });
		defer schema_result.deinit(allocator);
	}
	try std.testing.expect(!indexUsable(allocator, empty));

	// Populated.
	const populated = try std.fs.path.join(allocator, &.{ root, "populated.sqlite3" });
	defer allocator.free(populated);
	{
		const db = try storage.openFileWithVec(allocator, populated);
		defer storage.close(db);
		var schema_result = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });
		defer schema_result.deinit(allocator);
		var symbol = model.Symbol{
			.language = try allocator.dupe(u8, "zig"),
			.file_path = try allocator.dupe(u8, "src/main.zig"),
			.name = try allocator.dupe(u8, "main"),
			.signature = try allocator.dupe(u8, "pub fn main() void"),
			.doc_comment = null,
			.start_line = 1,
			.end_line = 1,
		};
		defer symbol.deinit(allocator);
		_ = try storage.insertSymbol(db, symbol);
	}
	try std.testing.expect(indexUsable(allocator, populated));
}
