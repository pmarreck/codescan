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
const current_schema_version = 4;

pub const InitSchemaResult = struct {
	did_schema_upgrade: bool = false,
	previous_schema_version: ?u32 = null,
	embedding_model_mismatch: bool = false,
	embedding_dim_mismatch: bool = false,
	stored_embedding_model: ?[]u8 = null,
	stored_embedding_dim: ?usize = null,

	/// Free any allocator-owned fields.
	pub fn deinit(self: *InitSchemaResult, allocator: std.mem.Allocator) void {
		if (self.stored_embedding_model) |m| allocator.free(m);
		self.stored_embedding_model = null;
	}
};

pub const Schema = struct {
	embedding_dim: usize,
	embedding_model: []const u8 = "",
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

pub fn initSchema(allocator: std.mem.Allocator, db: Db, schema: Schema) !InitSchemaResult {
	const had_meta_table = try tableExists(db, allocator, "meta");
	const had_symbols_table = try tableExists(db, allocator, "symbols");
	const previous_schema_version = if (had_meta_table) try schemaVersion(db, allocator) else null;
	const effective_version = previous_schema_version orelse if (had_symbols_table) @as(u32, 1) else 0;

	// Create base tables (all use IF NOT EXISTS, safe to run always)
	try createBaseTables(allocator, db, schema);

	// Run migrations for each version step
	var did_schema_upgrade = false;
	if (effective_version > 0 and effective_version < 3) {
		try migrateV2ToV3(allocator, db);
		did_schema_upgrade = true;
	}
	if (effective_version > 0 and effective_version < 4) {
		try migrateV3ToV4(allocator, db);
		did_schema_upgrade = true;
	}

	// Detect embedding model/dim mismatches BEFORE overwriting stored values
	var result = InitSchemaResult{
		.did_schema_upgrade = did_schema_upgrade,
		.previous_schema_version = previous_schema_version,
	};

	if (had_meta_table and isIndexPopulated(db)) {
		// Check embedding model mismatch
		if (schema.embedding_model.len > 0) {
			const stored_model = try metaValue(db, allocator, "embedding_model");
			if (stored_model) |sm| {
				if (!std.mem.eql(u8, sm, schema.embedding_model)) {
					result.embedding_model_mismatch = true;
					result.stored_embedding_model = sm;
				} else {
					allocator.free(sm);
				}
			}
		}

		// Check embedding dim mismatch
		const stored_dim_str = try metaValue(db, allocator, "embedding_dim");
		if (stored_dim_str) |ds| {
			defer allocator.free(ds);
			const stored_dim = std.fmt.parseInt(usize, ds, 10) catch null;
			if (stored_dim) |sd| {
				if (sd != schema.embedding_dim) {
					result.embedding_dim_mismatch = true;
					result.stored_embedding_dim = sd;
				}
			}
		}
	}

	// Always stamp schema version, but preserve embedding metadata when the
	// existing populated index does not match current embedding settings.
	try setSchemaVersion(allocator, db);
	if (!(result.embedding_model_mismatch or result.embedding_dim_mismatch)) {
		try setEmbeddingMeta(allocator, db, schema);
	}

	// Initialize FTS (idempotent)
	const fts_enabled = tryInitFts(allocator, db);
	const fts_sql = if (fts_enabled)
		"INSERT OR REPLACE INTO meta(key, value) VALUES ('fts_enabled', '1');"
	else
		"INSERT OR REPLACE INTO meta(key, value) VALUES ('fts_enabled', '0');";
	const fts_meta = try allocator.dupeZ(u8, fts_sql);
	defer allocator.free(fts_meta);
	try exec(db, fts_meta);

	return result;
}

/// Create all base tables at current schema version.
/// Uses IF NOT EXISTS so it's safe to call on existing DBs.
fn createBaseTables(allocator: std.mem.Allocator, db: Db, schema: Schema) !void {
	try exec(db, "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);\x00");
	try exec(db,
		"CREATE TABLE IF NOT EXISTS symbols (" ++
		"id INTEGER PRIMARY KEY, " ++
		"lang TEXT NOT NULL, " ++
		"file_path TEXT NOT NULL, " ++
		"start_line INTEGER NOT NULL, " ++
		"start_hash TEXT, " ++
		"end_line INTEGER NOT NULL, " ++
		"end_hash TEXT, " ++
		"symbol_name TEXT NOT NULL, " ++
		"signature TEXT, " ++
		"doc_comment TEXT, " ++
		"symbol_kind TEXT, " ++
		"symbol_visibility TEXT, " ++
		"symbol_scope TEXT, " ++
		"symbol_arity INTEGER, " ++
		"body TEXT" ++
		");\x00",
	);
	try exec(db, "CREATE UNIQUE INDEX IF NOT EXISTS idx_symbols_unique ON symbols (file_path, start_line, end_line, symbol_name);\x00");

	const vec_sql = try allocPrintZ(allocator,
		"CREATE VIRTUAL TABLE IF NOT EXISTS embeddings USING vec0(embedding float[{d}]);",
		.{schema.embedding_dim},
	);
	defer allocator.free(vec_sql);
	try exec(db, vec_sql);

	const vec_comment_sql = try allocPrintZ(allocator,
		"CREATE VIRTUAL TABLE IF NOT EXISTS embeddings_comment USING vec0(embedding float[{d}]);",
		.{schema.embedding_dim},
	);
	defer allocator.free(vec_comment_sql);
	try exec(db, vec_comment_sql);

	try exec(db,
		"CREATE TABLE IF NOT EXISTS indexed_files (" ++
		"file_path TEXT PRIMARY KEY, " ++
		"mtime_ns INTEGER NOT NULL, " ++
		"size INTEGER NOT NULL, " ++
		"indexed_at INTEGER NOT NULL" ++
		");\x00",
	);
}

/// Migrate from schema v2 (or v1/unversioned) to v3:
/// Adds symbol_kind, symbol_visibility, symbol_scope, symbol_arity columns.
fn migrateV2ToV3(allocator: std.mem.Allocator, db: Db) !void {
	try ensureColumnExists(db, allocator, "symbols", "symbol_kind", "TEXT");
	try ensureColumnExists(db, allocator, "symbols", "symbol_visibility", "TEXT");
	try ensureColumnExists(db, allocator, "symbols", "symbol_scope", "TEXT");
	try ensureColumnExists(db, allocator, "symbols", "symbol_arity", "INTEGER");
}

fn migrateV3ToV4(allocator: std.mem.Allocator, db: Db) !void {
	try ensureColumnExists(db, allocator, "symbols", "body", "TEXT");
	// Recreate FTS table to include the new body column
	_ = execMaybe(db, "DROP TABLE IF EXISTS symbols_fts;\x00");
}

/// Write the current schema version to meta.
fn setSchemaVersion(allocator: std.mem.Allocator, db: Db) !void {
	const version_sql = try allocPrintZ(allocator,
		"INSERT OR REPLACE INTO meta(key, value) VALUES ('schema_version', '{d}');",
		.{current_schema_version},
	);
	defer allocator.free(version_sql);
	try exec(db, version_sql);
}

/// Write embedding dim/model metadata to meta.
fn setEmbeddingMeta(allocator: std.mem.Allocator, db: Db, schema: Schema) !void {
	const dim_sql = try allocPrintZ(allocator,
		"INSERT OR REPLACE INTO meta(key, value) VALUES ('embedding_dim', '{d}');",
		.{schema.embedding_dim},
	);
	defer allocator.free(dim_sql);
	try exec(db, dim_sql);

	if (schema.embedding_model.len > 0) {
		const model_sql = try allocPrintZ(allocator,
			"INSERT OR REPLACE INTO meta(key, value) VALUES ('embedding_model', '{s}');",
			.{schema.embedding_model},
		);
		defer allocator.free(model_sql);
		try exec(db, model_sql);
	}
}

pub fn schemaVersion(db: Db, allocator: std.mem.Allocator) !?u32 {
	if (!try tableExists(db, allocator, "meta")) return null;
	const version_text = try metaValue(db, allocator, "schema_version");
	defer if (version_text) |value| allocator.free(value);
	if (version_text == null) return null;
	return std.fmt.parseInt(u32, version_text.?, 10) catch null;
}

pub fn isSchemaUpgradeRequired(db: Db, allocator: std.mem.Allocator) !bool {
	const has_symbols = try tableExists(db, allocator, "symbols");
	if (!has_symbols) return false;

	const version = try schemaVersion(db, allocator);
	if (version == null) return true;
	if (version.? < current_schema_version) return true;

	if (!try columnExists(db, allocator, "symbols", "symbol_kind")) return true;
	if (!try columnExists(db, allocator, "symbols", "symbol_visibility")) return true;
	if (!try columnExists(db, allocator, "symbols", "symbol_scope")) return true;
	if (!try columnExists(db, allocator, "symbols", "symbol_arity")) return true;
	if (!try columnExists(db, allocator, "symbols", "body")) return true;
	return false;
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
		"INSERT OR REPLACE INTO symbols (" ++
		"lang, file_path, start_line, start_hash, end_line, end_hash, symbol_name, signature, doc_comment, " ++
		"symbol_kind, symbol_visibility, symbol_scope, symbol_arity, body" ++
		") VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14);\x00";
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
	if (symbol.symbol_kind) |kind| {
		try bindText(stmt.?, 10, kind);
	} else {
		_ = c.sqlite3_bind_null(stmt.?, 10);
	}
	if (symbol.symbol_visibility) |visibility| {
		try bindText(stmt.?, 11, visibility);
	} else {
		_ = c.sqlite3_bind_null(stmt.?, 11);
	}
	if (symbol.symbol_scope) |scope| {
		try bindText(stmt.?, 12, scope);
	} else {
		_ = c.sqlite3_bind_null(stmt.?, 12);
	}
	if (symbol.symbol_arity) |arity| {
		_ = c.sqlite3_bind_int64(stmt.?, 13, arity);
	} else {
		_ = c.sqlite3_bind_null(stmt.?, 13);
	}
	if (symbol.body) |body| {
		try bindText(stmt.?, 14, body);
	} else {
		_ = c.sqlite3_bind_null(stmt.?, 14);
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

pub fn getSymbolBody(allocator: std.mem.Allocator, db: Db, id: i64) !?[]const u8 {
	const sql: [:0]const u8 = "SELECT body FROM symbols WHERE id = ?1;\x00";
	var stmt: ?*c.sqlite3_stmt = null;
	if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
		return error.SqlPrepareFailed;
	}
	defer _ = c.sqlite3_finalize(stmt.?);
	_ = c.sqlite3_bind_int64(stmt.?, 1, id);
	if (c.sqlite3_step(stmt.?) != c.SQLITE_ROW) return null;
	const ptr = c.sqlite3_column_text(stmt.?, 0) orelse return null;
	const len: usize = @intCast(c.sqlite3_column_bytes(stmt.?, 0));
	return try allocator.dupe(u8, ptr[0..len]);
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
		"CREATE VIRTUAL TABLE IF NOT EXISTS symbols_fts USING fts5(symbol_name, signature, doc_comment, file_path, body);\x00";
	if (!execMaybe(db, fts_sql)) return false;

	const fts_count = countRows(db, allocator, "symbols_fts") catch return true;
	if (fts_count == 0) {
		const rebuild_sql: [:0]const u8 =
			"INSERT OR REPLACE INTO symbols_fts(rowid, symbol_name, signature, doc_comment, file_path, body) "
			++ "SELECT id, symbol_name, signature, doc_comment, file_path, body FROM symbols;\x00";
		_ = execMaybe(db, rebuild_sql);
	}

	return true;
}

fn insertSymbolFts(db: Db, symbol: model.Symbol, rowid: i64) !void {
	const sql: [:0]const u8 =
		"INSERT INTO symbols_fts (rowid, symbol_name, signature, doc_comment, file_path, body) "
		++ "VALUES (?1, ?2, ?3, ?4, ?5, ?6);\x00";
	var stmt: ?*c.sqlite3_stmt = null;
	if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
		logSqliteError(db, "insertSymbolFts: prepare");
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
	if (symbol.body) |body| {
		try bindText(stmt.?, 6, body);
	} else {
		_ = c.sqlite3_bind_null(stmt.?, 6);
	}

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
		logSqliteError(db, "tableExists: prepare");
		return error.SqlPrepareFailed;
	}
	defer _ = c.sqlite3_finalize(stmt.?);

	const step_rc = c.sqlite3_step(stmt.?);
	if (step_rc == c.SQLITE_ROW) return true;
	if (step_rc == c.SQLITE_DONE) return false;
	logSqliteError(db, "tableExists: step");
	return error.SqlStepFailed;
}

fn columnExists(db: Db, allocator: std.mem.Allocator, table_name: []const u8, column_name: []const u8) !bool {
	const sql = try allocPrintZ(
		allocator,
		"PRAGMA table_info({s});",
		.{table_name},
	);
	defer allocator.free(sql);

	var stmt: ?*c.sqlite3_stmt = null;
	if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
		logSqliteError(db, "columnExists: prepare");
		return error.SqlPrepareFailed;
	}
	defer _ = c.sqlite3_finalize(stmt.?);

	while (true) {
		const rc = c.sqlite3_step(stmt.?);
		if (rc == c.SQLITE_DONE) break;
		if (rc != c.SQLITE_ROW) return error.SqlStepFailed;
		const ptr = c.sqlite3_column_text(stmt.?, 1) orelse continue; // name column
		const name = std.mem.span(ptr);
		if (std.mem.eql(u8, name, column_name)) return true;
	}
	return false;
}

fn ensureColumnExists(
	db: Db,
	allocator: std.mem.Allocator,
	table_name: []const u8,
	column_name: []const u8,
	column_type_sql: []const u8,
) !void {
	if (try columnExists(db, allocator, table_name, column_name)) return;
	const alter_sql = try allocPrintZ(
		allocator,
		"ALTER TABLE {s} ADD COLUMN {s} {s};",
		.{ table_name, column_name, column_type_sql },
	);
	defer allocator.free(alter_sql);
	try exec(db, alter_sql);
}

fn metaValue(db: Db, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
	const sql: [:0]const u8 = "SELECT value FROM meta WHERE key = ?1 LIMIT 1;\x00";
	var stmt: ?*c.sqlite3_stmt = null;
	if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
		logSqliteError(db, "metaValue: prepare");
		return error.SqlPrepareFailed;
	}
	defer _ = c.sqlite3_finalize(stmt.?);

	try bindText(stmt.?, 1, key);
	const rc = c.sqlite3_step(stmt.?);
	if (rc == c.SQLITE_ROW) {
		const ptr = c.sqlite3_column_text(stmt.?, 0) orelse return null;
		return @as(?[]u8, try allocator.dupe(u8, std.mem.span(ptr)));
	}
	if (rc == c.SQLITE_DONE) return null;
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
		logSqliteError(db, "countRows: prepare");
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
		logSqliteError(db, "countDistinctFiles: prepare");
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
		logSqliteError(db, "primaryLanguage: prepare");
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
		logSqliteError(db, "languageStats: prepare");
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
		logSqliteError(db, "lastIndexedFile: prepare");
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
		logSqliteError(db, "upsertIndexedFile: prepare");
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
		logSqliteError(db, "getIndexedFileMtime: prepare");
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
		logSqliteError(db, "getAllIndexedFiles: prepare");
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
		logSqliteError(db, "deleteIndexedFile: prepare");
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
			logSqliteError(db, "deleteSymbolsByFile: prepare");
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
			logSqliteError(db, "deleteSymbolsByFile: prepare symbols");
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

	_ = try initSchema(allocator, db, .{ .embedding_dim = 1024 });

	try std.testing.expect(try tableExists(db, allocator, "meta"));
	try std.testing.expect(try tableExists(db, allocator, "symbols"));
	try std.testing.expect(try tableExists(db, allocator, "embeddings"));
	try std.testing.expect(try tableExists(db, allocator, "embeddings_comment"));
	try std.testing.expect(try columnExists(db, allocator, "symbols", "symbol_kind"));
	try std.testing.expect(try columnExists(db, allocator, "symbols", "symbol_visibility"));
	try std.testing.expect(try columnExists(db, allocator, "symbols", "symbol_scope"));
	try std.testing.expect(try columnExists(db, allocator, "symbols", "symbol_arity"));
	const version = try metaValue(db, allocator, "schema_version");
	defer if (version) |v| allocator.free(v);
	try std.testing.expect(version != null);
	try std.testing.expectEqualStrings("4", version.?);
}

test "initSchema migrates v2 symbols table by adding metadata columns" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer _ = c.sqlite3_close(db);

	try exec(db, "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);\x00");
	try exec(db, "CREATE TABLE symbols (id INTEGER PRIMARY KEY, lang TEXT NOT NULL, file_path TEXT NOT NULL, start_line INTEGER NOT NULL, start_hash TEXT, end_line INTEGER NOT NULL, end_hash TEXT, symbol_name TEXT NOT NULL, signature TEXT, doc_comment TEXT);\x00");
	try exec(db, "INSERT INTO meta(key, value) VALUES ('schema_version', '2');\x00");
	try exec(db, "INSERT INTO symbols(id, lang, file_path, start_line, start_hash, end_line, end_hash, symbol_name, signature, doc_comment) VALUES (1, 'zig', 'src/main.zig', 1, NULL, 1, NULL, 'main', 'pub fn main() void', NULL);\x00");

	_ = try initSchema(allocator, db, .{ .embedding_dim = 2 });

	try std.testing.expect(try columnExists(db, allocator, "symbols", "symbol_kind"));
	try std.testing.expect(try columnExists(db, allocator, "symbols", "symbol_visibility"));
	try std.testing.expect(try columnExists(db, allocator, "symbols", "symbol_scope"));
	try std.testing.expect(try columnExists(db, allocator, "symbols", "symbol_arity"));
	try std.testing.expect(try columnExists(db, allocator, "symbols", "body"));
	try std.testing.expectEqual(@as(i64, 1), try countRows(db, allocator, "symbols"));
	const version = try metaValue(db, allocator, "schema_version");
	defer if (version) |v| allocator.free(v);
	try std.testing.expect(version != null);
	try std.testing.expectEqualStrings("4", version.?);
}

test "migrateV2ToV3 adds metadata columns to existing table" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer _ = c.sqlite3_close(db);

	// Create a v2 symbols table (no metadata columns)
	try exec(db, "CREATE TABLE symbols (id INTEGER PRIMARY KEY, lang TEXT NOT NULL, file_path TEXT NOT NULL, start_line INTEGER NOT NULL, start_hash TEXT, end_line INTEGER NOT NULL, end_hash TEXT, symbol_name TEXT NOT NULL, signature TEXT, doc_comment TEXT);\x00");

	try std.testing.expect(!try columnExists(db, allocator, "symbols", "symbol_kind"));
	try migrateV2ToV3(allocator, db);
	try std.testing.expect(try columnExists(db, allocator, "symbols", "symbol_kind"));
	try std.testing.expect(try columnExists(db, allocator, "symbols", "symbol_visibility"));
	try std.testing.expect(try columnExists(db, allocator, "symbols", "symbol_scope"));
	try std.testing.expect(try columnExists(db, allocator, "symbols", "symbol_arity"));
}

test "initSchema reports did_schema_upgrade for v2 DB" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer _ = c.sqlite3_close(db);

	try exec(db, "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);\x00");
	try exec(db, "CREATE TABLE symbols (id INTEGER PRIMARY KEY, lang TEXT NOT NULL, file_path TEXT NOT NULL, start_line INTEGER NOT NULL, start_hash TEXT, end_line INTEGER NOT NULL, end_hash TEXT, symbol_name TEXT NOT NULL, signature TEXT, doc_comment TEXT);\x00");
	try exec(db, "INSERT INTO meta(key, value) VALUES ('schema_version', '2');\x00");

	const result = try initSchema(allocator, db, .{ .embedding_dim = 2 });
	try std.testing.expect(result.did_schema_upgrade);
	try std.testing.expectEqual(@as(?u32, 2), result.previous_schema_version);
}

test "initSchema does not report upgrade for fresh DB" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer _ = c.sqlite3_close(db);

	const result = try initSchema(allocator, db, .{ .embedding_dim = 2 });
	try std.testing.expect(!result.did_schema_upgrade);
	try std.testing.expect(result.previous_schema_version == null);
}

test "initSchema does not report upgrade for current-version DB" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer _ = c.sqlite3_close(db);

	// First init creates at current version
	_ = try initSchema(allocator, db, .{ .embedding_dim = 2 });
	// Second init should not report upgrade
	const result = try initSchema(allocator, db, .{ .embedding_dim = 2 });
	try std.testing.expect(!result.did_schema_upgrade);
	try std.testing.expectEqual(@as(?u32, 4), result.previous_schema_version);
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
	_ = try initSchema(allocator, db, .{ .embedding_dim = 2 });

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

	_ = try initSchema(allocator, db, .{ .embedding_dim = 2 });

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

test "insertSymbol stores symbol metadata columns when provided" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer _ = c.sqlite3_close(db);

	_ = try initSchema(allocator, db, .{ .embedding_dim = 2 });

	var symbol = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/main.zig"),
		.name = try allocator.dupe(u8, "add"),
		.signature = try allocator.dupe(u8, "pub fn add(a: i32, b: i32) i32"),
		.doc_comment = null,
		.symbol_kind = try allocator.dupe(u8, "fn"),
		.symbol_visibility = try allocator.dupe(u8, "public"),
		.symbol_scope = try allocator.dupe(u8, "top_level"),
		.symbol_arity = 2,
		.start_line = 1,
		.end_line = 2,
	};
	defer symbol.deinit(allocator);

	_ = try insertSymbol(db, symbol);

	var stmt: ?*c.sqlite3_stmt = null;
	const sql: [:0]const u8 =
		"SELECT symbol_kind, symbol_visibility, symbol_scope, symbol_arity " ++
		"FROM symbols WHERE symbol_name = 'add' LIMIT 1;\x00";
	if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
		return error.SqlPrepareFailed;
	}
	defer _ = c.sqlite3_finalize(stmt.?);

	try std.testing.expectEqual(@as(c_int, c.SQLITE_ROW), c.sqlite3_step(stmt.?));
	const kind_ptr = c.sqlite3_column_text(stmt.?, 0) orelse return error.TestExpectedEqual;
	try std.testing.expectEqualStrings("fn", std.mem.span(kind_ptr));
	const vis_ptr = c.sqlite3_column_text(stmt.?, 1) orelse return error.TestExpectedEqual;
	try std.testing.expectEqualStrings("public", std.mem.span(vis_ptr));
	const scope_ptr = c.sqlite3_column_text(stmt.?, 2) orelse return error.TestExpectedEqual;
	try std.testing.expectEqualStrings("top_level", std.mem.span(scope_ptr));
	try std.testing.expectEqual(@as(i64, 2), c.sqlite3_column_int64(stmt.?, 3));
}

test "indexed_files tracking" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer _ = c.sqlite3_close(db);

	_ = try initSchema(allocator, db, .{ .embedding_dim = 2 });

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

	_ = try initSchema(allocator, db, .{ .embedding_dim = 2 });

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

	_ = try initSchema(allocator, db, .{ .embedding_dim = 2 });

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

	_ = try initSchema(allocator, db, .{ .embedding_dim = 2 });

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

	_ = try initSchema(allocator, db, .{ .embedding_dim = 2 });

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

	_ = try initSchema(allocator, db, .{ .embedding_dim = 2 });
	try std.testing.expect(!isIndexPopulated(db));
}

test "isIndexPopulated returns true with data" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer _ = c.sqlite3_close(db);

	_ = try initSchema(allocator, db, .{ .embedding_dim = 2 });

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

test "initSchema detects embedding model mismatch" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer _ = c.sqlite3_close(db);

	// Init with model A
	_ = try initSchema(allocator, db, .{ .embedding_dim = 2, .embedding_model = "bge-large" });

	// Insert a symbol so index is populated
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

	// Re-init with model B — should detect mismatch
	var result = try initSchema(allocator, db, .{ .embedding_dim = 2, .embedding_model = "nomic-embed-text" });
	defer result.deinit(allocator);
	try std.testing.expect(result.embedding_model_mismatch);
	try std.testing.expect(!result.embedding_dim_mismatch);
	try std.testing.expect(result.stored_embedding_model != null);
	try std.testing.expectEqualStrings("bge-large", result.stored_embedding_model.?);
}

test "initSchema detects embedding dim mismatch" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer _ = c.sqlite3_close(db);

	// Init with dim=2
	_ = try initSchema(allocator, db, .{ .embedding_dim = 2, .embedding_model = "bge-large" });

	// Insert a symbol so index is populated
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

	// Re-init with dim=4 — should detect mismatch
	var result = try initSchema(allocator, db, .{ .embedding_dim = 4, .embedding_model = "bge-large" });
	defer result.deinit(allocator);
	try std.testing.expect(!result.embedding_model_mismatch);
	try std.testing.expect(result.embedding_dim_mismatch);
	try std.testing.expectEqual(@as(?usize, 2), result.stored_embedding_dim);
}

test "initSchema mismatch does not overwrite stored embedding metadata" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer _ = c.sqlite3_close(db);

	_ = try initSchema(allocator, db, .{ .embedding_dim = 2, .embedding_model = "bge-large" });

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

	var result = try initSchema(allocator, db, .{ .embedding_dim = 4, .embedding_model = "nomic-embed-text" });
	defer result.deinit(allocator);
	try std.testing.expect(result.embedding_model_mismatch);
	try std.testing.expect(result.embedding_dim_mismatch);

	const stored_dim = try metaValue(db, allocator, "embedding_dim");
	defer if (stored_dim) |v| allocator.free(v);
	try std.testing.expect(stored_dim != null);
	try std.testing.expectEqualStrings("2", stored_dim.?);

	const stored_model = try metaValue(db, allocator, "embedding_model");
	defer if (stored_model) |v| allocator.free(v);
	try std.testing.expect(stored_model != null);
	try std.testing.expectEqualStrings("bge-large", stored_model.?);
}

test "initSchema no mismatch on fresh DB" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer _ = c.sqlite3_close(db);

	var result = try initSchema(allocator, db, .{ .embedding_dim = 2, .embedding_model = "bge-large" });
	defer result.deinit(allocator);
	try std.testing.expect(!result.embedding_model_mismatch);
	try std.testing.expect(!result.embedding_dim_mismatch);
}

test "initSchema no mismatch when model is same" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer _ = c.sqlite3_close(db);

	_ = try initSchema(allocator, db, .{ .embedding_dim = 2, .embedding_model = "bge-large" });

	// Insert a symbol
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

	// Re-init with same model — no mismatch
	var result = try initSchema(allocator, db, .{ .embedding_dim = 2, .embedding_model = "bge-large" });
	defer result.deinit(allocator);
	try std.testing.expect(!result.embedding_model_mismatch);
	try std.testing.expect(!result.embedding_dim_mismatch);
}

test "initSchema stores embedding_model in meta" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer _ = c.sqlite3_close(db);

	_ = try initSchema(allocator, db, .{ .embedding_dim = 2, .embedding_model = "bge-large" });

	const stored = try metaValue(db, allocator, "embedding_model");
	defer if (stored) |v| allocator.free(v);
	try std.testing.expect(stored != null);
	try std.testing.expectEqualStrings("bge-large", stored.?);
}

test "initSchema empty model does not overwrite stored model" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer _ = c.sqlite3_close(db);

	// First init with real model
	_ = try initSchema(allocator, db, .{ .embedding_dim = 2, .embedding_model = "bge-large" });

	// Second init with empty model (like tests or tryReindexFile)
	_ = try initSchema(allocator, db, .{ .embedding_dim = 2 });

	// Stored model should still be bge-large
	const stored = try metaValue(db, allocator, "embedding_model");
	defer if (stored) |v| allocator.free(v);
	try std.testing.expect(stored != null);
	try std.testing.expectEqualStrings("bge-large", stored.?);
}
