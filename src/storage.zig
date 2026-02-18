const std = @import("std");

const c = @cImport({
	@cDefine("SQLITE_VEC_STATIC", "1");
	@cInclude("sqlite3.h");
	@cInclude("sqlite-vec.h");
});
const model = @import("model.zig");
const hashline = @import("hashline.zig");

pub const sqlite = c;
pub const Db = *c.sqlite3;

pub const Schema = struct {
	embedding_dim: usize,
};

pub fn openMemoryWithVec(allocator: std.mem.Allocator) !Db {
	_ = allocator;
	var db: ?*c.sqlite3 = null;
	if (c.sqlite3_open(":memory:", &db) != c.SQLITE_OK) {
		return error.OpenFailed;
	}
	const handle = db orelse return error.OpenFailed;
	errdefer _ = c.sqlite3_close(handle);

	try initVecStatic(handle);

	return handle;
}

pub fn close(db: Db) void {
	_ = c.sqlite3_close(db);
}

pub fn openFileWithVec(allocator: std.mem.Allocator, path: []const u8) !Db {
	const path_z = try allocator.dupeZ(u8, path);
	defer allocator.free(path_z);

	var db: ?*c.sqlite3 = null;
	if (c.sqlite3_open(path_z, &db) != c.SQLITE_OK) {
		return error.OpenFailed;
	}
	const handle = db orelse return error.OpenFailed;
	errdefer _ = c.sqlite3_close(handle);

	try initVecStatic(handle);

	// Enable WAL mode for concurrent access (watcher + CLI commands)
	_ = execMaybe(handle, "PRAGMA journal_mode=WAL;\x00");
	// Wait up to 5s if another process holds the write lock
	_ = execMaybe(handle, "PRAGMA busy_timeout=5000;\x00");

	return handle;
}

pub fn openFileWithVecRecreate(allocator: std.mem.Allocator, path: []const u8) !Db {
	try deleteFileIfExists(path);
	return openFileWithVec(allocator, path);
}

fn deleteFileIfExists(path: []const u8) !void {
	if (std.fs.path.isAbsolute(path)) {
		std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
			error.FileNotFound => {},
			else => return err,
		};
		return;
	}

	std.fs.cwd().deleteFile(path) catch |err| switch (err) {
		error.FileNotFound => {},
		else => return err,
	};
}

pub fn initSchema(allocator: std.mem.Allocator, db: Db, schema: Schema) !void {
	const meta_sql: [:0]const u8 = "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);\x00";
	const symbols_sql: [:0]const u8 = "CREATE TABLE IF NOT EXISTS symbols (id INTEGER PRIMARY KEY, lang TEXT NOT NULL, file_path TEXT NOT NULL, start_line INTEGER NOT NULL, start_hash TEXT, end_line INTEGER NOT NULL, end_hash TEXT, symbol_name TEXT NOT NULL, signature TEXT, doc_comment TEXT);\x00";
	try exec(db, meta_sql);
	try exec(db, symbols_sql);

	// Unique constraint prevents duplicate symbols from being inserted (defense-in-depth)
	const unique_idx_sql: [:0]const u8 = "CREATE UNIQUE INDEX IF NOT EXISTS idx_symbols_unique ON symbols (file_path, start_line, end_line, symbol_name);\x00";
	try exec(db, unique_idx_sql);

	const vec_sql = try allocPrintZ(
		allocator,
		"CREATE VIRTUAL TABLE IF NOT EXISTS embeddings USING vec0(embedding float[{d}]);",
		.{schema.embedding_dim},
	);
	defer allocator.free(vec_sql);
	try exec(db, vec_sql);

	const vec_comment_sql = try allocPrintZ(
		allocator,
		"CREATE VIRTUAL TABLE IF NOT EXISTS embeddings_comment USING vec0(embedding float[{d}]);",
		.{schema.embedding_dim},
	);
	defer allocator.free(vec_comment_sql);
	try exec(db, vec_comment_sql);

	const version_sql: [:0]const u8 = "INSERT OR REPLACE INTO meta(key, value) VALUES ('schema_version', '2');\x00";
	try exec(db, version_sql);
	const dim_sql = try allocPrintZ(
		allocator,
		"INSERT OR REPLACE INTO meta(key, value) VALUES ('embedding_dim', '{d}');",
		.{schema.embedding_dim},
	);
	defer allocator.free(dim_sql);
	try exec(db, dim_sql);

	const files_sql: [:0]const u8 =
		"CREATE TABLE IF NOT EXISTS indexed_files (" ++
		"file_path TEXT PRIMARY KEY, " ++
		"mtime_ns INTEGER NOT NULL, " ++
		"size INTEGER NOT NULL, " ++
		"indexed_at INTEGER NOT NULL" ++
		");\x00";
	try exec(db, files_sql);

	const fts_enabled = tryInitFts(allocator, db);
	const fts_sql = if (fts_enabled)
		"INSERT OR REPLACE INTO meta(key, value) VALUES ('fts_enabled', '1');"
	else
		"INSERT OR REPLACE INTO meta(key, value) VALUES ('fts_enabled', '0');";
	const fts_meta = try allocator.dupeZ(u8, fts_sql);
	defer allocator.free(fts_meta);
	try exec(db, fts_meta);
}

pub fn resetIndex(db: Db) !void {
	const symbols_sql: [:0]const u8 = "DELETE FROM symbols;\x00";
	const embeddings_sql: [:0]const u8 = "DELETE FROM embeddings;\x00";
	const comment_sql: [:0]const u8 = "DELETE FROM embeddings_comment;\x00";
	const files_sql: [:0]const u8 = "DELETE FROM indexed_files;\x00";
	try exec(db, symbols_sql);
	try exec(db, embeddings_sql);
	try exec(db, comment_sql);
	_ = execMaybe(db, "DELETE FROM symbols_fts;\x00");
	_ = execMaybe(db, files_sql);
}

pub fn insertSymbol(db: Db, symbol: model.Symbol) !i64 {
	const sql: [:0]const u8 =
		"INSERT OR REPLACE INTO symbols (lang, file_path, start_line, start_hash, end_line, end_hash, symbol_name, signature, doc_comment) "
		++ "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9);\x00";
	var stmt: ?*c.sqlite3_stmt = null;
	if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
		logSqliteError(db, "insertSymbol: prepare");
		return error.SqlPrepareFailed;
	}
	defer _ = c.sqlite3_finalize(stmt.?);

	try bindText(stmt.?, 1, symbol.language);
	try bindText(stmt.?, 2, symbol.file_path);
	try bindInt(stmt.?, 3, symbol.start_line);
	if (symbol.start_hash) |hash| {
		_ = c.sqlite3_bind_text(stmt.?, 4, &hash, hashline.HASH_LEN, null);
	} else {
		_ = c.sqlite3_bind_null(stmt.?, 4);
	}
	try bindInt(stmt.?, 5, symbol.end_line);
	if (symbol.end_hash) |hash| {
		_ = c.sqlite3_bind_text(stmt.?, 6, &hash, hashline.HASH_LEN, null);
	} else {
		_ = c.sqlite3_bind_null(stmt.?, 6);
	}
	try bindText(stmt.?, 7, symbol.name);
	try bindText(stmt.?, 8, symbol.signature);
	if (symbol.doc_comment) |doc| {
		try bindText(stmt.?, 9, doc);
	} else {
		_ = c.sqlite3_bind_null(stmt.?, 9);
	}

	if (c.sqlite3_step(stmt.?) != c.SQLITE_DONE) {
		logSqliteError(db, "insertSymbol: step");
		return error.SqlStepFailed;
	}
	const rowid = c.sqlite3_last_insert_rowid(db);
	insertSymbolFts(db, symbol, rowid) catch |err| switch (err) {
		error.SqlPrepareFailed => {},
		else => {
			logSqliteError(db, "insertSymbolFts");
			return err;
		},
	};
	return rowid;
}

pub fn insertEmbedding(db: Db, allocator: std.mem.Allocator, rowid: i64, vector: []const f32) !void {
	const sql: [:0]const u8 = "INSERT INTO embeddings (rowid, embedding) VALUES (?1, vec_f32(?2));\x00";
	var stmt: ?*c.sqlite3_stmt = null;
	if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
		logSqliteError(db, "insertEmbedding: prepare");
		return error.SqlPrepareFailed;
	}
	defer _ = c.sqlite3_finalize(stmt.?);

	const json = try vectorToJson(allocator, vector);
	defer allocator.free(json);

	_ = c.sqlite3_bind_int64(stmt.?, 1, rowid);
	_ = c.sqlite3_bind_text(stmt.?, 2, json.ptr, @intCast(json.len), null);

	if (c.sqlite3_step(stmt.?) != c.SQLITE_DONE) {
		logSqliteError(db, "insertEmbedding: step");
		return error.SqlStepFailed;
	}
}

pub fn insertCommentEmbedding(db: Db, allocator: std.mem.Allocator, rowid: i64, vector: []const f32) !void {
	const sql: [:0]const u8 = "INSERT INTO embeddings_comment (rowid, embedding) VALUES (?1, vec_f32(?2));\x00";
	var stmt: ?*c.sqlite3_stmt = null;
	if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
		logSqliteError(db, "insertCommentEmbedding: prepare");
		return error.SqlPrepareFailed;
	}
	defer _ = c.sqlite3_finalize(stmt.?);

	const json = try vectorToJson(allocator, vector);
	defer allocator.free(json);

	_ = c.sqlite3_bind_int64(stmt.?, 1, rowid);
	_ = c.sqlite3_bind_text(stmt.?, 2, json.ptr, @intCast(json.len), null);

	if (c.sqlite3_step(stmt.?) != c.SQLITE_DONE) {
		logSqliteError(db, "insertCommentEmbedding: step");
		return error.SqlStepFailed;
	}
}

fn exec(db: Db, sql: [:0]const u8) !void {
	var err_msg: [*c]u8 = null;
	const rc = c.sqlite3_exec(db, sql, null, null, &err_msg);
	if (rc != c.SQLITE_OK) {
		if (err_msg != null) {
			c.sqlite3_free(err_msg);
		}
		return error.SqlError;
	}
}

fn execMaybe(db: Db, sql: [:0]const u8) bool {
	var err_msg: [*c]u8 = null;
	const rc = c.sqlite3_exec(db, sql, null, null, &err_msg);
	if (rc != c.SQLITE_OK) {
		if (err_msg != null) {
			c.sqlite3_free(err_msg);
		}
		return false;
	}
	return true;
}

fn tryInitFts(allocator: std.mem.Allocator, db: Db) bool {
	const fts_sql: [:0]const u8 =
		"CREATE VIRTUAL TABLE IF NOT EXISTS symbols_fts USING fts5(symbol_name, signature, doc_comment, file_path);\x00";
	if (!execMaybe(db, fts_sql)) return false;

	const fts_count = countRows(db, allocator, "symbols_fts") catch return true;
	if (fts_count == 0) {
		const rebuild_sql: [:0]const u8 =
			"INSERT OR REPLACE INTO symbols_fts(rowid, symbol_name, signature, doc_comment, file_path) "
			++ "SELECT id, symbol_name, signature, doc_comment, file_path FROM symbols;\x00";
		_ = execMaybe(db, rebuild_sql);
	}

	return true;
}

fn insertSymbolFts(db: Db, symbol: model.Symbol, rowid: i64) !void {
	const sql: [:0]const u8 =
		"INSERT INTO symbols_fts (rowid, symbol_name, signature, doc_comment, file_path) "
		++ "VALUES (?1, ?2, ?3, ?4, ?5);\x00";
	var stmt: ?*c.sqlite3_stmt = null;
	if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
		return error.SqlPrepareFailed;
	}
	defer _ = c.sqlite3_finalize(stmt.?);

	_ = c.sqlite3_bind_int64(stmt.?, 1, rowid);
	try bindText(stmt.?, 2, symbol.name);
	try bindText(stmt.?, 3, symbol.signature);
	if (symbol.doc_comment) |doc| {
		try bindText(stmt.?, 4, doc);
	} else {
		_ = c.sqlite3_bind_null(stmt.?, 4);
	}
	try bindText(stmt.?, 5, symbol.file_path);

	if (c.sqlite3_step(stmt.?) != c.SQLITE_DONE) {
		return error.SqlStepFailed;
	}
}

fn initVecStatic(db: Db) !void {
	var err_msg: [*c]u8 = null;
	const rc = c.sqlite3_vec_init(db, &err_msg, null);
	if (rc != c.SQLITE_OK) {
		if (err_msg != null) {
			c.sqlite3_free(err_msg);
		}
		return error.LoadExtensionFailed;
	}
}

fn tableExists(db: Db, allocator: std.mem.Allocator, name: []const u8) !bool {
	const sql = try allocPrintZ(
		allocator,
		"SELECT name FROM sqlite_master WHERE type='table' AND name='{s}' LIMIT 1;",
		.{name},
	);
	defer allocator.free(sql);

	var stmt: ?*c.sqlite3_stmt = null;
	if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
		return error.SqlPrepareFailed;
	}
	defer _ = c.sqlite3_finalize(stmt.?);

	const step_rc = c.sqlite3_step(stmt.?);
	if (step_rc == c.SQLITE_ROW) return true;
	if (step_rc == c.SQLITE_DONE) return false;
	return error.SqlStepFailed;
}

pub fn countRows(db: Db, allocator: std.mem.Allocator, table: []const u8) !i64 {
	const sql = try allocPrintZ(
		allocator,
		"SELECT COUNT(*) FROM {s};",
		.{table},
	);
	defer allocator.free(sql);

	var stmt: ?*c.sqlite3_stmt = null;
	if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
		return error.SqlPrepareFailed;
	}
	defer _ = c.sqlite3_finalize(stmt.?);

	if (c.sqlite3_step(stmt.?) != c.SQLITE_ROW) {
		return error.SqlStepFailed;
	}
	return c.sqlite3_column_int64(stmt.?, 0);
}

/// Returns true if the symbols table exists and contains at least one row.
pub fn isIndexPopulated(db: Db) bool {
	var stmt: ?*c.sqlite3_stmt = null;
	const sql = "SELECT 1 FROM symbols LIMIT 1;";
	if (c.sqlite3_prepare_v2(db, sql, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) {
		return false; // table doesn't exist
	}
	defer _ = c.sqlite3_finalize(stmt.?);
	return c.sqlite3_step(stmt.?) == c.SQLITE_ROW;
}

pub fn countDistinctFiles(db: Db, allocator: std.mem.Allocator) !i64 {
	_ = allocator;
	const sql: [:0]const u8 = "SELECT COUNT(DISTINCT file_path) FROM symbols;\x00";
	var stmt: ?*c.sqlite3_stmt = null;
	if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
		return error.SqlPrepareFailed;
	}
	defer _ = c.sqlite3_finalize(stmt.?);

	if (c.sqlite3_step(stmt.?) != c.SQLITE_ROW) {
		return error.SqlStepFailed;
	}
	return c.sqlite3_column_int64(stmt.?, 0);
}

pub fn primaryLanguage(
	db: Db,
	allocator: std.mem.Allocator,
	allowed_langs: []const []const u8,
) !?[]const u8 {
	if (allowed_langs.len == 0) return null;

	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	try out.writer.writeAll("SELECT lang, COUNT(DISTINCT file_path) AS files FROM symbols WHERE lang IN (");
	for (allowed_langs, 0..) |_, idx| {
		if (idx > 0) try out.writer.writeAll(",");
		try out.writer.print("?{d}", .{idx + 1});
	}
	try out.writer.writeAll(") GROUP BY lang ORDER BY files DESC LIMIT 1;");

	const sql = try out.toOwnedSlice();
	defer allocator.free(sql);

	const sql_z = try allocator.dupeZ(u8, sql);
	defer allocator.free(sql_z);

	var stmt: ?*c.sqlite3_stmt = null;
	if (c.sqlite3_prepare_v2(db, sql_z, -1, &stmt, null) != c.SQLITE_OK) {
		return error.SqlPrepareFailed;
	}
	defer _ = c.sqlite3_finalize(stmt.?);

	for (allowed_langs, 0..) |lang, idx| {
		try bindText(stmt.?, @intCast(idx + 1), lang);
	}

	const rc = c.sqlite3_step(stmt.?);
	if (rc == c.SQLITE_ROW) {
		const ptr = c.sqlite3_column_text(stmt.?, 0) orelse return null;
		const slice = std.mem.span(ptr);
		return @as(?[]const u8, try allocator.dupe(u8, slice));
	}
	if (rc == c.SQLITE_DONE) return null;
	return error.SqlStepFailed;
}

pub const LangStat = struct {
	language: []const u8,
	file_count: i64,
	symbol_count: i64,
};

/// Returns language stats ordered by file_count DESC.
/// Caller must free the returned slice and each language string with the given allocator.
pub fn languageStats(db: Db, allocator: std.mem.Allocator) ![]LangStat {
	const sql: [:0]const u8 = "SELECT lang, COUNT(DISTINCT file_path), COUNT(*) FROM symbols GROUP BY lang ORDER BY 2 DESC;\x00";
	var stmt: ?*c.sqlite3_stmt = null;
	if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
		return error.SqlPrepareFailed;
	}
	defer _ = c.sqlite3_finalize(stmt.?);

	var results: std.ArrayListUnmanaged(LangStat) = .{};
	errdefer {
		for (results.items) |item| allocator.free(item.language);
		results.deinit(allocator);
	}

	while (c.sqlite3_step(stmt.?) == c.SQLITE_ROW) {
		const lang_ptr = c.sqlite3_column_text(stmt.?, 0) orelse continue;
		const lang_slice = std.mem.span(lang_ptr);
		const lang = try allocator.dupe(u8, lang_slice);
		try results.append(allocator, .{
			.language = lang,
			.file_count = c.sqlite3_column_int64(stmt.?, 1),
			.symbol_count = c.sqlite3_column_int64(stmt.?, 2),
		});
	}

	return results.toOwnedSlice(allocator);
}

pub const LastIndexedResult = struct {
	file_path: []const u8,
	indexed_at: i64,
};

/// Returns the most recently indexed file and its indexed_at epoch (seconds).
/// Caller must free the returned file_path with the given allocator.
pub fn lastIndexedFile(db: Db, allocator: std.mem.Allocator) !?LastIndexedResult {
	const sql: [:0]const u8 = "SELECT file_path, indexed_at FROM indexed_files ORDER BY indexed_at DESC LIMIT 1;\x00";
	var stmt: ?*c.sqlite3_stmt = null;
	if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
		return error.SqlPrepareFailed;
	}
	defer _ = c.sqlite3_finalize(stmt.?);

	if (c.sqlite3_step(stmt.?) == c.SQLITE_ROW) {
		const path_ptr = c.sqlite3_column_text(stmt.?, 0) orelse return null;
		const path_slice = std.mem.span(path_ptr);
		return .{
			.file_path = try allocator.dupe(u8, path_slice),
			.indexed_at = c.sqlite3_column_int64(stmt.?, 1),
		};
	}
	return null;
}

fn logSqliteError(db: Db, context: []const u8) void {
	const msg = c.sqlite3_errmsg(db);
	if (msg != null) {
		const msg_slice = std.mem.span(msg);
		var stderr_buf: [4096]u8 = undefined;
		var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
		const stderr = &stderr_writer.interface;
		_ = stderr.print("sqlite error ({s}): {s}\n", .{ context, msg_slice }) catch {};
		_ = stderr.flush() catch {};
	}
}

fn bindText(stmt: *c.sqlite3_stmt, index: c_int, text: []const u8) !void {
	if (c.sqlite3_bind_text(stmt, index, text.ptr, @intCast(text.len), null) != c.SQLITE_OK) {
		return error.SqlBindFailed;
	}
}

fn bindInt(stmt: *c.sqlite3_stmt, index: c_int, value: usize) !void {
	if (c.sqlite3_bind_int64(stmt, index, @intCast(value)) != c.SQLITE_OK) {
		return error.SqlBindFailed;
	}
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

// --- File tracking for incremental indexing ---

pub const IndexedFile = struct {
	file_path: []const u8,
	mtime_ns: i64,
	size: i64,
};

pub fn upsertIndexedFile(db: Db, file_path: []const u8, mtime_ns: i64, size: i64) !void {
	const sql: [:0]const u8 =
		"INSERT OR REPLACE INTO indexed_files (file_path, mtime_ns, size, indexed_at) " ++
		"VALUES (?1, ?2, ?3, strftime('%s','now'));\x00";
	var stmt: ?*c.sqlite3_stmt = null;
	if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
		return error.SqlPrepareFailed;
	}
	defer _ = c.sqlite3_finalize(stmt.?);

	try bindText(stmt.?, 1, file_path);
	_ = c.sqlite3_bind_int64(stmt.?, 2, mtime_ns);
	_ = c.sqlite3_bind_int64(stmt.?, 3, size);

	if (c.sqlite3_step(stmt.?) != c.SQLITE_DONE) {
		return error.SqlStepFailed;
	}
}

pub fn getIndexedFileMtime(db: Db, file_path: []const u8) !?i64 {
	const sql: [:0]const u8 =
		"SELECT mtime_ns FROM indexed_files WHERE file_path = ?1;\x00";
	var stmt: ?*c.sqlite3_stmt = null;
	if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
		return error.SqlPrepareFailed;
	}
	defer _ = c.sqlite3_finalize(stmt.?);

	try bindText(stmt.?, 1, file_path);
	const rc = c.sqlite3_step(stmt.?);
	if (rc == c.SQLITE_ROW) {
		return c.sqlite3_column_int64(stmt.?, 0);
	}
	if (rc == c.SQLITE_DONE) return null;
	return error.SqlStepFailed;
}

pub fn getAllIndexedFiles(db: Db, allocator: std.mem.Allocator) ![]IndexedFile {
	const sql: [:0]const u8 =
		"SELECT file_path, mtime_ns, size FROM indexed_files;\x00";
	var stmt: ?*c.sqlite3_stmt = null;
	if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
		return error.SqlPrepareFailed;
	}
	defer _ = c.sqlite3_finalize(stmt.?);

	var list: std.ArrayListUnmanaged(IndexedFile) = .{};
	errdefer {
		for (list.items) |item| allocator.free(item.file_path);
		list.deinit(allocator);
	}

	while (true) {
		const rc = c.sqlite3_step(stmt.?);
		if (rc == c.SQLITE_DONE) break;
		if (rc != c.SQLITE_ROW) return error.SqlStepFailed;

		const ptr = c.sqlite3_column_text(stmt.?, 0) orelse continue;
		const path = try allocator.dupe(u8, std.mem.span(ptr));
		errdefer allocator.free(path);

		try list.append(allocator, .{
			.file_path = path,
			.mtime_ns = c.sqlite3_column_int64(stmt.?, 1),
			.size = c.sqlite3_column_int64(stmt.?, 2),
		});
	}

	return list.toOwnedSlice(allocator);
}

pub fn deleteIndexedFile(db: Db, file_path: []const u8) !void {
	const sql: [:0]const u8 =
		"DELETE FROM indexed_files WHERE file_path = ?1;\x00";
	var stmt: ?*c.sqlite3_stmt = null;
	if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
		return error.SqlPrepareFailed;
	}
	defer _ = c.sqlite3_finalize(stmt.?);

	try bindText(stmt.?, 1, file_path);
	if (c.sqlite3_step(stmt.?) != c.SQLITE_DONE) {
		return error.SqlStepFailed;
	}
}

pub fn deleteSymbolsByFile(db: Db, file_path: []const u8) !void {
	// First delete corresponding embeddings and FTS entries
	const del_embed_sql: [:0]const u8 =
		"DELETE FROM embeddings WHERE rowid IN (SELECT id FROM symbols WHERE file_path = ?1);\x00";
	const del_comment_sql: [:0]const u8 =
		"DELETE FROM embeddings_comment WHERE rowid IN (SELECT id FROM symbols WHERE file_path = ?1);\x00";
	const del_fts_sql: [:0]const u8 =
		"DELETE FROM symbols_fts WHERE rowid IN (SELECT id FROM symbols WHERE file_path = ?1);\x00";
	const del_sym_sql: [:0]const u8 =
		"DELETE FROM symbols WHERE file_path = ?1;\x00";

	inline for (.{ del_embed_sql, del_comment_sql }) |sql| {
		var stmt: ?*c.sqlite3_stmt = null;
		if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
			return error.SqlPrepareFailed;
		}
		defer _ = c.sqlite3_finalize(stmt.?);
		try bindText(stmt.?, 1, file_path);
		if (c.sqlite3_step(stmt.?) != c.SQLITE_DONE) {
			return error.SqlStepFailed;
		}
	}

	// FTS may not exist, so allow failure
	{
		var stmt: ?*c.sqlite3_stmt = null;
		if (c.sqlite3_prepare_v2(db, del_fts_sql, -1, &stmt, null) == c.SQLITE_OK) {
			defer _ = c.sqlite3_finalize(stmt.?);
			try bindText(stmt.?, 1, file_path);
			_ = c.sqlite3_step(stmt.?);
		}
	}

	// Delete symbols themselves
	{
		var stmt: ?*c.sqlite3_stmt = null;
		if (c.sqlite3_prepare_v2(db, del_sym_sql, -1, &stmt, null) != c.SQLITE_OK) {
			return error.SqlPrepareFailed;
		}
		defer _ = c.sqlite3_finalize(stmt.?);
		try bindText(stmt.?, 1, file_path);
		if (c.sqlite3_step(stmt.?) != c.SQLITE_DONE) {
			return error.SqlStepFailed;
		}
	}
}

fn allocPrintZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]u8 {
	const tmp = try std.fmt.allocPrint(allocator, fmt, args);
	defer allocator.free(tmp);
	return allocator.dupeZ(u8, tmp);
}

test "initSchema creates tables" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer _ = c.sqlite3_close(db);

	try initSchema(allocator, db, .{ .embedding_dim = 1024 });

	try std.testing.expect(try tableExists(db, allocator, "meta"));
	try std.testing.expect(try tableExists(db, allocator, "symbols"));
	try std.testing.expect(try tableExists(db, allocator, "embeddings"));
	try std.testing.expect(try tableExists(db, allocator, "embeddings_comment"));
}

test "openFileWithVecRecreate replaces existing file" {
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	try tmp.dir.writeFile(.{ .sub_path = "db.sqlite3", .data = "not a sqlite db" });
	const abs_path = try tmp.dir.realpathAlloc(allocator, "db.sqlite3");
	defer allocator.free(abs_path);

	const db = try openFileWithVecRecreate(allocator, abs_path);
	defer _ = c.sqlite3_close(db);
	try initSchema(allocator, db, .{ .embedding_dim = 2 });

	var file = try std.fs.openFileAbsolute(abs_path, .{});
	defer file.close();

	var header: [16]u8 = undefined;
	const n = try file.readAll(&header);
	try std.testing.expect(n >= 15);
	try std.testing.expectEqualStrings("SQLite format 3", header[0..15]);
}

test "insertSymbol and insertEmbedding" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer _ = c.sqlite3_close(db);

	try initSchema(allocator, db, .{ .embedding_dim = 2 });

	var symbol = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/main.zig"),
		.name = try allocator.dupe(u8, "add"),
		.signature = try allocator.dupe(u8, "pub fn add(a: i32, b: i32) i32"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 2,
	};
	defer symbol.deinit(allocator);

	const rowid = try insertSymbol(db, symbol);
	try std.testing.expect(rowid > 0);
	try std.testing.expectEqual(@as(i64, 1), try countRows(db, allocator, "symbols"));

	try insertEmbedding(db, allocator, rowid, &[_]f32{ 0.1, 0.2 });
	try std.testing.expectEqual(@as(i64, 1), try countRows(db, allocator, "embeddings"));
}

test "indexed_files tracking" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer _ = c.sqlite3_close(db);

	try initSchema(allocator, db, .{ .embedding_dim = 2 });

	// Initially no tracked files
	const initial = try getIndexedFileMtime(db, "src/main.zig");
	try std.testing.expect(initial == null);

	// Upsert a file
	try upsertIndexedFile(db, "src/main.zig", 1234567890, 1024);
	const mtime = try getIndexedFileMtime(db, "src/main.zig");
	try std.testing.expect(mtime != null);
	try std.testing.expectEqual(@as(i64, 1234567890), mtime.?);

	// Update same file
	try upsertIndexedFile(db, "src/main.zig", 9999999999, 2048);
	const mtime2 = try getIndexedFileMtime(db, "src/main.zig");
	try std.testing.expectEqual(@as(i64, 9999999999), mtime2.?);

	// Add another file and list all
	try upsertIndexedFile(db, "src/lib.zig", 5555555555, 512);
	const all = try getAllIndexedFiles(db, allocator);
	defer {
		for (all) |item| allocator.free(item.file_path);
		allocator.free(all);
	}
	try std.testing.expectEqual(@as(usize, 2), all.len);

	// Delete a file
	try deleteIndexedFile(db, "src/main.zig");
	const after_del = try getIndexedFileMtime(db, "src/main.zig");
	try std.testing.expect(after_del == null);
}

test "deleteSymbolsByFile removes symbols and embeddings" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer _ = c.sqlite3_close(db);

	try initSchema(allocator, db, .{ .embedding_dim = 2 });

	// Insert symbols for two files
	var sym1 = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/a.zig"),
		.name = try allocator.dupe(u8, "a"),
		.signature = try allocator.dupe(u8, "fn a() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym1.deinit(allocator);

	var sym2 = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/b.zig"),
		.name = try allocator.dupe(u8, "b"),
		.signature = try allocator.dupe(u8, "fn b() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym2.deinit(allocator);

	const rowid1 = try insertSymbol(db, sym1);
	try insertEmbedding(db, allocator, rowid1, &[_]f32{ 0.1, 0.2 });
	const rowid2 = try insertSymbol(db, sym2);
	try insertEmbedding(db, allocator, rowid2, &[_]f32{ 0.3, 0.4 });

	try std.testing.expectEqual(@as(i64, 2), try countRows(db, allocator, "symbols"));
	try std.testing.expectEqual(@as(i64, 2), try countRows(db, allocator, "embeddings"));

	// Delete symbols for file a
	try deleteSymbolsByFile(db, "src/a.zig");
	try std.testing.expectEqual(@as(i64, 1), try countRows(db, allocator, "symbols"));
	try std.testing.expectEqual(@as(i64, 1), try countRows(db, allocator, "embeddings"));
}

test "primaryLanguage selects most common language" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer _ = c.sqlite3_close(db);

	try initSchema(allocator, db, .{ .embedding_dim = 2 });

	var sym1 = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/a.zig"),
		.name = try allocator.dupe(u8, "a"),
		.signature = try allocator.dupe(u8, "fn a() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym1.deinit(allocator);

	var sym2 = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/b.zig"),
		.name = try allocator.dupe(u8, "b"),
		.signature = try allocator.dupe(u8, "fn b() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym2.deinit(allocator);

	var sym3 = model.Symbol{
		.language = try allocator.dupe(u8, "rust"),
		.file_path = try allocator.dupe(u8, "src/lib.rs"),
		.name = try allocator.dupe(u8, "c"),
		.signature = try allocator.dupe(u8, "fn c()"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym3.deinit(allocator);

	_ = try insertSymbol(db, sym1);
	_ = try insertSymbol(db, sym2);
	_ = try insertSymbol(db, sym3);

	const allowed = &[_][]const u8{ "zig", "rust" };
	const primary = try primaryLanguage(db, allocator, allowed);
	defer if (primary) |value| allocator.free(value);

	try std.testing.expect(primary != null);
	try std.testing.expectEqualStrings("zig", primary.?);
}

test "languageStats returns grouped data" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer _ = c.sqlite3_close(db);

	try initSchema(allocator, db, .{ .embedding_dim = 2 });

	var sym1 = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/a.zig"),
		.name = try allocator.dupe(u8, "a"),
		.signature = try allocator.dupe(u8, "fn a() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym1.deinit(allocator);

	var sym2 = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/b.zig"),
		.name = try allocator.dupe(u8, "b"),
		.signature = try allocator.dupe(u8, "fn b() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym2.deinit(allocator);

	var sym3 = model.Symbol{
		.language = try allocator.dupe(u8, "rust"),
		.file_path = try allocator.dupe(u8, "src/lib.rs"),
		.name = try allocator.dupe(u8, "c"),
		.signature = try allocator.dupe(u8, "fn c()"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym3.deinit(allocator);

	_ = try insertSymbol(db, sym1);
	_ = try insertSymbol(db, sym2);
	_ = try insertSymbol(db, sym3);

	const stats = try languageStats(db, allocator);
	defer {
		for (stats) |s| allocator.free(s.language);
		allocator.free(stats);
	}

	try std.testing.expectEqual(@as(usize, 2), stats.len);
	// zig has 2 files, should be first (ordered by file_count DESC)
	try std.testing.expectEqualStrings("zig", stats[0].language);
	try std.testing.expectEqual(@as(i64, 2), stats[0].file_count);
	try std.testing.expectEqual(@as(i64, 2), stats[0].symbol_count);
	try std.testing.expectEqualStrings("rust", stats[1].language);
	try std.testing.expectEqual(@as(i64, 1), stats[1].file_count);
	try std.testing.expectEqual(@as(i64, 1), stats[1].symbol_count);
}

test "lastIndexedFile returns most recent entry" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer _ = c.sqlite3_close(db);

	try initSchema(allocator, db, .{ .embedding_dim = 2 });

	// No files yet
	const empty = try lastIndexedFile(db, allocator);
	try std.testing.expect(empty == null);

	// Insert an indexed file
	try upsertIndexedFile(db, "src/a.zig", 100, 50);

	const result = try lastIndexedFile(db, allocator);
	try std.testing.expect(result != null);
	defer allocator.free(result.?.file_path);
	try std.testing.expectEqualStrings("src/a.zig", result.?.file_path);
	// indexed_at should be a recent epoch (just check it's > 0)
	try std.testing.expect(result.?.indexed_at > 0);
}

test "isIndexPopulated returns false on empty DB" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer _ = c.sqlite3_close(db);

	try initSchema(allocator, db, .{ .embedding_dim = 2 });
	try std.testing.expect(!isIndexPopulated(db));
}

test "isIndexPopulated returns true with data" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer _ = c.sqlite3_close(db);

	try initSchema(allocator, db, .{ .embedding_dim = 2 });

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

	_ = try insertSymbol(db, sym);
	try std.testing.expect(isIndexPopulated(db));
}

test "isIndexPopulated returns false without schema" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer _ = c.sqlite3_close(db);

	// No initSchema — table doesn't exist
	try std.testing.expect(!isIndexPopulated(db));
}
