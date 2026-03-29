const std = @import("std");
const storage = @import("storage.zig");
const search = @import("search.zig");
const embedding = @import("embedding.zig");
const model = @import("model.zig");

pub const DiagnosticCounts = struct {
    query_only: ?usize = null,
    kind_only: ?usize = null,
    lang_only: ?usize = null,
};

/// Count active filter dimensions (query, kind, lang, path).
fn countActiveDimensions(
    query: []const u8,
    options: search.Options,
) usize {
    var count: usize = 0;
    if (query.len > 0) count += 1;
    if (options.allowed_symbol_kinds.len > 0) count += 1;
    if (options.allowed_langs.len > 0) count += 1;
    if (options.allowed_paths.len > 0) count += 1;
    return count;
}

/// Count symbols matching a kind filter (SQL query).
fn countKind(db: storage.Db, kinds: []const []const u8) !usize {
    const c = storage.sqlite;
    var total: usize = 0;

    // Check for "*" sentinel: any non-null symbol_kind
    for (kinds) |k| {
        if (std.mem.eql(u8, k, "*")) {
            const sql: [:0]const u8 = "SELECT COUNT(*) FROM symbols WHERE symbol_kind IS NOT NULL;\x00";
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
                return error.SqlPrepareFailed;
            }
            defer _ = c.sqlite3_finalize(stmt.?);
            if (c.sqlite3_step(stmt.?) == c.SQLITE_ROW) {
                total += @intCast(c.sqlite3_column_int64(stmt.?, 0));
            }
            return total;
        }
    }

    // Sum across each kind value
    for (kinds) |k| {
        const sql: [:0]const u8 = "SELECT COUNT(*) FROM symbols WHERE symbol_kind = ?1;\x00";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlPrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt.?);
        _ = c.sqlite3_bind_text(stmt.?, 1, k.ptr, @intCast(k.len), null);
        if (c.sqlite3_step(stmt.?) == c.SQLITE_ROW) {
            total += @intCast(c.sqlite3_column_int64(stmt.?, 0));
        }
    }
    return total;
}

/// Count symbols matching a lang filter (SQL query).
fn countLang(db: storage.Db, langs: []const []const u8) !usize {
    const c = storage.sqlite;
    var total: usize = 0;
    for (langs) |lang| {
        const sql: [:0]const u8 = "SELECT COUNT(*) FROM symbols WHERE lang = ?1;\x00";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlPrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt.?);
        _ = c.sqlite3_bind_text(stmt.?, 1, lang.ptr, @intCast(lang.len), null);
        if (c.sqlite3_step(stmt.?) == c.SQLITE_ROW) {
            total += @intCast(c.sqlite3_column_int64(stmt.?, 0));
        }
    }
    return total;
}

/// Run diagnostic count queries to help identify which filter combination eliminated results.
/// Returns empty DiagnosticCounts if fewer than 2 filter dimensions are active.
pub fn countDiagnostics(
    allocator: std.mem.Allocator,
    db: storage.Db,
    embedder: embedding.Embedder,
    query: []const u8,
    options: search.Options,
) !DiagnosticCounts {
    if (countActiveDimensions(query, options) < 2) {
        return DiagnosticCounts{};
    }

    var diag = DiagnosticCounts{};

    // Count: query alone (no kind/lang/path filters)
    if (query.len > 0) {
        const query_only_opts = search.Options{
            .top_n = 1000,
            .mode = options.mode,
            .fusion = options.fusion,
            .rrf_k = options.rrf_k,
            .fts_mode = options.fts_mode,
            .weight_vector = options.weight_vector,
            .weight_lexical = options.weight_lexical,
            .weight_symbol_kind = options.weight_symbol_kind,
            .weight_symbol_visibility = options.weight_symbol_visibility,
            .weight_symbol_scope = options.weight_symbol_scope,
            .weight_symbol_arity = options.weight_symbol_arity,
            .min_score = options.min_score,
            // No kind/lang/path filters
            .allowed_langs = &[_][]const u8{},
            .allowed_exts = &[_][]const u8{},
            .allowed_symbol_kinds = &[_][]const u8{},
            .allowed_paths = &[_][]const u8{},
            .comments_only = options.comments_only,
        };
        const sr = search.search(allocator, db, embedder, query, query_only_opts) catch null;
        if (sr) |result| {
            defer search.freeResults(allocator, result.results);
            diag.query_only = result.total_relevant;
        }
    }

    // Count: kind filter alone (SQL count, no search needed)
    if (options.allowed_symbol_kinds.len > 0) {
        diag.kind_only = try countKind(db, options.allowed_symbol_kinds);
    }

    // Count: lang filter alone (SQL count, no search needed)
    if (options.allowed_langs.len > 0) {
        diag.lang_only = try countLang(db, options.allowed_langs);
    }

    return diag;
}

// ---- Tests ----

test "diagnostics: kind filter causes zero results, shows query_only > 0 and kind_only = 0" {
    const allocator = std.testing.allocator;
    const db = try storage.openMemoryWithVec(allocator);
    defer storage.close(db);

    _ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

    // Insert a function symbol (no symbol_kind = struct)
    var sym = model.Symbol{
        .language = try allocator.dupe(u8, "zig"),
        .file_path = try allocator.dupe(u8, "src/foo.zig"),
        .name = try allocator.dupe(u8, "fooFunc"),
        .signature = try allocator.dupe(u8, "fn fooFunc() void"),
        .doc_comment = null,
        .start_line = 1,
        .end_line = 1,
        .symbol_kind = try allocator.dupe(u8, "function"),
    };
    defer sym.deinit(allocator);

    const id = try storage.insertSymbol(db, sym);
    try storage.insertEmbedding(db, allocator, id, &[_]f32{ 0.0, 0.0 });

    // Search for "fooFunc" with kind=struct should return 0 results
    var fake = FakeEmbedder{ .vector = &[_]f32{ 0.0, 0.0 } };

    const opts = search.Options{
        .top_n = 10,
        .mode = .lexical,
        .allowed_symbol_kinds = &[_][]const u8{"struct"},
    };
    const sr = try search.search(allocator, db, fake.embedder(), "fooFunc", opts);
    defer search.freeResults(allocator, sr.results);
    try std.testing.expectEqual(@as(usize, 0), sr.results.len);

    // Run diagnostics
    const diag = try countDiagnostics(allocator, db, fake.embedder(), "fooFunc", opts);

    // query alone should find fooFunc
    try std.testing.expect(diag.query_only != null);
    try std.testing.expect(diag.query_only.? > 0);

    // kind filter alone: no structs in db
    try std.testing.expect(diag.kind_only != null);
    try std.testing.expectEqual(@as(usize, 0), diag.kind_only.?);
}

test "diagnostics: single filter dimension returns empty (all null)" {
    const allocator = std.testing.allocator;
    const db = try storage.openMemoryWithVec(allocator);
    defer storage.close(db);

    _ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

    var sym = model.Symbol{
        .language = try allocator.dupe(u8, "zig"),
        .file_path = try allocator.dupe(u8, "src/bar.zig"),
        .name = try allocator.dupe(u8, "barFn"),
        .signature = try allocator.dupe(u8, "fn barFn() void"),
        .doc_comment = null,
        .start_line = 1,
        .end_line = 1,
    };
    defer sym.deinit(allocator);
    _ = try storage.insertSymbol(db, sym);

    var fake = FakeEmbedder{ .vector = &[_]f32{ 0.0, 0.0 } };

    // Only one active dimension: the query itself
    const opts = search.Options{
        .top_n = 10,
        .mode = .lexical,
        // No kind/lang/path filters
    };

    const diag = try countDiagnostics(allocator, db, fake.embedder(), "barFn", opts);

    try std.testing.expect(diag.query_only == null);
    try std.testing.expect(diag.kind_only == null);
    try std.testing.expect(diag.lang_only == null);
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
