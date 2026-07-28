const std = @import("std");
const storage = @import("storage.zig");
const embedding_http = @import("embedding_http.zig");

pub const PreflightFailure = union(enum) {
	server_unreachable: struct {
		url: []const u8,
		dialect: []const u8,
	},
	db_open_failed: struct {
		path: []const u8,
		err_name: []const u8,
	},
	model_unavailable: struct {
		model: []const u8,
		url: []const u8,
	},
	schema_mismatch: struct {
		model_mismatch: bool,
		dim_mismatch: bool,
		stored_model: ?[]u8,
		current_model: []const u8,
		stored_dim: ?usize,
		current_dim: usize,
	},

	pub fn deinit(self: *PreflightFailure, allocator: std.mem.Allocator) void {
		switch (self.*) {
			.schema_mismatch => |*m| {
				if (m.stored_model) |s| allocator.free(s);
				m.stored_model = null;
			},
			else => {},
		}
	}
};

/// Reports a missing embedding model before the watcher daemon is spawned.
///
/// The daemon runs with stdin/stdout/stderr closed, so any startup failure there
/// is invisible: the parent printed "Started background watcher (PID N)" and
/// `watcher status` then reported nothing running. A missing model is the most
/// common such death and is unrecoverable without user action, so it belongs in
/// preflight rather than being discovered by silence.
///
/// `error.ModelLoading` means the model exists but is cold. The daemon loads it
/// on first embed, so that is deliberately not treated as a failure — blocking
/// there would trade a silent failure for a false alarm.
pub fn checkModelAvailable(
	allocator: std.mem.Allocator,
	transport: embedding_http.Transport,
	base_url: []const u8,
	model_name: []const u8,
	dialect: embedding_http.ApiDialect,
) ?PreflightFailure {
	embedding_http.ensureModelAvailable(allocator, transport, base_url, model_name, dialect) catch |err| switch (err) {
		error.ModelNotFound => return PreflightFailure{ .model_unavailable = .{
			.model = model_name,
			.url = base_url,
		} },
		// Anything else — cold model, transport hiccup, unparseable inventory —
		// is ambiguous. Reachability is already proven by this point, so let the
		// daemon try instead of refusing to start on a guess.
		else => return null,
	};
	return null;
}

pub fn checkIndexConsistency(
	allocator: std.mem.Allocator,
	db_path: []const u8,
	embedding_model: []const u8,
	embedding_dim: usize,
) !?PreflightFailure {
	const db = storage.openFileWithVec(allocator, db_path) catch |err| {
		return PreflightFailure{ .db_open_failed = .{
			.path = db_path,
			.err_name = @errorName(err),
		} };
	};
	defer storage.close(db);

	var schema_result = storage.initSchema(allocator, db, .{
		.embedding_dim = embedding_dim,
		.embedding_model = embedding_model,
	}) catch |err| {
		return PreflightFailure{ .db_open_failed = .{
			.path = db_path,
			.err_name = @errorName(err),
		} };
	};

	if (!schema_result.embedding_model_mismatch and !schema_result.embedding_dim_mismatch) {
		schema_result.deinit(allocator);
		return null;
	}

	const stored_model = schema_result.stored_embedding_model;
	schema_result.stored_embedding_model = null;

	return PreflightFailure{ .schema_mismatch = .{
		.model_mismatch = schema_result.embedding_model_mismatch,
		.dim_mismatch = schema_result.embedding_dim_mismatch,
		.stored_model = stored_model,
		.current_model = embedding_model,
		.stored_dim = schema_result.stored_embedding_dim,
		.current_dim = embedding_dim,
	} };
}

pub fn formatActionable(failure: PreflightFailure, writer: *std.Io.Writer) !void {
	switch (failure) {
		.server_unreachable => |s| {
			try writer.print("error: cannot reach embedding server at {s}\n", .{s.url});
			try writer.print("  configured dialect: {s}\n", .{s.dialect});
			try writer.writeAll("  fix one of:\n");
			try writer.writeAll("    - start the embedding server\n");
			try writer.writeAll("    - update embedding_url / embedding_api in .codescan/config\n");
			try writer.writeAll("    - run 'codescan setup-model' for setup instructions\n");
			try writer.writeAll("  watcher NOT started.\n");
		},
		.db_open_failed => |s| {
			try writer.print("error: cannot open index database at {s} ({s})\n", .{ s.path, s.err_name });
			try writer.writeAll("  fix: run 'codescan index' to (re)create the database.\n");
			try writer.writeAll("  watcher NOT started.\n");
		},
		.model_unavailable => |s| {
			try writer.print("error: embedding model '{s}' is not installed on {s}\n", .{ s.model, s.url });
			try writer.writeAll("  fix one of:\n");
			try writer.print("    - ollama pull {s}\n", .{s.model});
			try writer.writeAll("    - run 'codescan setup-model' to pick an installed model\n");
			try writer.writeAll("  watcher NOT started.\n");
		},
		.schema_mismatch => |m| {
			if (m.model_mismatch) {
				try writer.print(
					"error: Embedding model mismatch. Index was built with '{s}', but current model is '{s}'.\n",
					.{ m.stored_model orelse "unknown", m.current_model },
				);
			}
			if (m.dim_mismatch) {
				try writer.print(
					"error: Embedding dimension mismatch. Index was built with {d}, but current setting is {d}.\n",
					.{ m.stored_dim orelse 0, m.current_dim },
				);
			}
			try writer.writeAll("  fix: run 'codescan index' to rebuild the index with the current model.\n");
			try writer.writeAll("  watcher NOT started.\n");
		},
	}
}

// ============================================================================
// Tests
// ============================================================================

const model = @import("model.zig");
const io_singleton = @import("io_singleton.zig");

fn writeTempDbWithSchema(
	allocator: std.mem.Allocator,
	dir: std.Io.Dir,
	path: []const u8,
	embedding_model: []const u8,
	embedding_dim: usize,
) ![]u8 {
	const abs_path = try dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
	defer allocator.free(abs_path);
	const full_path = try std.fs.path.join(allocator, &.{ abs_path, path });

	const db = try storage.openFileWithVec(allocator, full_path);
	defer storage.close(db);

	var schema_result = try storage.initSchema(allocator, db, .{
		.embedding_dim = embedding_dim,
		.embedding_model = embedding_model,
	});
	defer schema_result.deinit(allocator);

	// Insert a symbol to mark index as populated — required for mismatch detection
	var sym = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/a.zig"),
		.name = try allocator.dupe(u8, "a"),
		.signature = try allocator.dupe(u8, "fn a() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym.deinit(allocator);
	_ = try storage.insertSymbol(db, sym);

	return full_path;
}

test "checkIndexConsistency returns null when model and dim match" {
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	const path = try writeTempDbWithSchema(allocator, tmp.dir, "ok.sqlite3", "bge-large", 1024);
	defer allocator.free(path);

	const failure = try checkIndexConsistency(allocator, path, "bge-large", 1024);
	try std.testing.expect(failure == null);
}

test "checkIndexConsistency detects model mismatch on populated index" {
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	const path = try writeTempDbWithSchema(allocator, tmp.dir, "mm.sqlite3", "bge-large", 1024);
	defer allocator.free(path);

	var failure = (try checkIndexConsistency(allocator, path, "jina-code-embeddings-1.5b-mlx", 1024)) orelse {
		try std.testing.expect(false);
		return;
	};
	defer failure.deinit(allocator);

	try std.testing.expect(failure == .schema_mismatch);
	try std.testing.expect(failure.schema_mismatch.model_mismatch);
	try std.testing.expect(!failure.schema_mismatch.dim_mismatch);
	try std.testing.expect(failure.schema_mismatch.stored_model != null);
	try std.testing.expectEqualStrings("bge-large", failure.schema_mismatch.stored_model.?);
	try std.testing.expectEqualStrings("jina-code-embeddings-1.5b-mlx", failure.schema_mismatch.current_model);
}

test "checkIndexConsistency detects both model and dim mismatch (dirtree scenario)" {
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	const path = try writeTempDbWithSchema(allocator, tmp.dir, "dual.sqlite3", "bge-large", 1024);
	defer allocator.free(path);

	var failure = (try checkIndexConsistency(allocator, path, "jina-code-embeddings-1.5b-mlx", 1536)) orelse {
		try std.testing.expect(false);
		return;
	};
	defer failure.deinit(allocator);

	try std.testing.expect(failure == .schema_mismatch);
	try std.testing.expect(failure.schema_mismatch.model_mismatch);
	try std.testing.expect(failure.schema_mismatch.dim_mismatch);
	try std.testing.expectEqual(@as(?usize, 1024), failure.schema_mismatch.stored_dim);
	try std.testing.expectEqual(@as(usize, 1536), failure.schema_mismatch.current_dim);
}

const tags_with_jina =
	\\{"models":[{"name":"jina-code-embeddings:1.5b"},{"name":"mistral:latest"}]}
;
const tags_without_jina =
	\\{"models":[{"name":"mistral:latest"},{"name":"zephyr:latest"}]}
;
const ps_with_jina =
	\\{"models":[{"name":"jina-code-embeddings:1.5b"}]}
;
const ps_empty =
	\\{"models":[]}
;

test "checkModelAvailable classifies the set of server model states" {
	// Regression: `watcher start` printed "Started background watcher (PID N)"
	// and the daemon died immediately with "model not found". Its stdio is
	// closed, so the real reason was invisible and `watcher status` just said
	// "No watcher running". Preflight already existed to catch exactly this
	// class but never checked the most likely cause.
	const allocator = std.testing.allocator;

	// Model present and already loaded — nothing to report.
	{
		var ctx = embedding_http.MockTransportCtx{ .tags_body = tags_with_jina, .ps_body = ps_with_jina };
		const failure = checkModelAvailable(allocator, ctx.transport(), "http://localhost:11434", "jina-code-embeddings:1.5b", .ollama);
		try std.testing.expect(failure == null);
	}

	// Model present but cold. The daemon loads it on first embed, so blocking
	// startup here would be a false alarm — this is NOT a failure.
	{
		var ctx = embedding_http.MockTransportCtx{ .tags_body = tags_with_jina, .ps_body = ps_empty };
		const failure = checkModelAvailable(allocator, ctx.transport(), "http://localhost:11434", "jina-code-embeddings:1.5b", .ollama);
		try std.testing.expect(failure == null);
	}

	// Model genuinely absent — the daemon cannot recover, so refuse to claim success.
	{
		var ctx = embedding_http.MockTransportCtx{ .tags_body = tags_without_jina, .ps_body = ps_empty };
		const failure = checkModelAvailable(allocator, ctx.transport(), "http://localhost:11434", "jina-code-embeddings:1.5b", .ollama);
		try std.testing.expect(failure != null);
		try std.testing.expectEqualStrings("jina-code-embeddings:1.5b", failure.?.model_unavailable.model);
	}

	// OpenAI-compatible servers expose no model inventory; absence of proof is
	// not proof of absence, so never block startup on that dialect.
	{
		var ctx = embedding_http.MockTransportCtx{ .tags_body = tags_without_jina, .ps_body = ps_empty };
		const failure = checkModelAvailable(allocator, ctx.transport(), "http://localhost:8080", "anything", .openai);
		try std.testing.expect(failure == null);
	}
}

test "formatActionable for model_unavailable names the model and the pull command" {
	const allocator = std.testing.allocator;
	var aw: std.Io.Writer.Allocating = .init(allocator);
	defer aw.deinit();

	const failure = PreflightFailure{ .model_unavailable = .{
		.model = "jina-code-embeddings:1.5b",
		.url = "http://localhost:11434",
	} };
	try formatActionable(failure, &aw.writer);

	const out = aw.written();
	try std.testing.expect(std.mem.indexOf(u8, out, "jina-code-embeddings:1.5b") != null);
	try std.testing.expect(std.mem.indexOf(u8, out, "ollama pull") != null);
	// The whole point is to stop claiming success when nothing will run.
	try std.testing.expect(std.mem.indexOf(u8, out, "watcher NOT started.") != null);
}

test "formatActionable for schema_mismatch includes both errors and fix" {
	const allocator = std.testing.allocator;
	var aw: std.Io.Writer.Allocating = .init(allocator);
	defer aw.deinit();

	const failure = PreflightFailure{ .schema_mismatch = .{
		.model_mismatch = true,
		.dim_mismatch = true,
		.stored_model = null,
		.current_model = "jina-code-embeddings-1.5b-mlx",
		.stored_dim = 1024,
		.current_dim = 1536,
	} };
	try formatActionable(failure, &aw.writer);

	const out = aw.written();
	try std.testing.expect(std.mem.indexOf(u8, out, "Embedding model mismatch") != null);
	try std.testing.expect(std.mem.indexOf(u8, out, "Embedding dimension mismatch") != null);
	try std.testing.expect(std.mem.indexOf(u8, out, "codescan index") != null);
	try std.testing.expect(std.mem.indexOf(u8, out, "watcher NOT started") != null);
}
