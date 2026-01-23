const std = @import("std");

const c = @cImport({
	@cInclude("sqlite3.h");
});

pub const Schema = struct {
	embedding_dim: usize,
};

pub fn openMemoryWithVec(allocator: std.mem.Allocator) !*c.sqlite3 {
	var db: ?*c.sqlite3 = null;
	if (c.sqlite3_open(":memory:", &db) != c.SQLITE_OK) {
		return error.OpenFailed;
	}
	const handle = db orelse return error.OpenFailed;
	errdefer _ = c.sqlite3_close(handle);

	if (c.sqlite3_enable_load_extension(handle, 1) != c.SQLITE_OK) {
		return error.EnableExtensionFailed;
	}

	const path = try std.process.getEnvVarOwned(allocator, "CODESCAN_SQLITE_VEC_PATH");
	defer allocator.free(path);
	const path_z = try allocator.dupeZ(u8, path);
	defer allocator.free(path_z);

	var err_msg: [*c]u8 = null;
	const rc = c.sqlite3_load_extension(handle, path_z, null, &err_msg);
	if (rc != c.SQLITE_OK) {
		if (err_msg != null) {
			c.sqlite3_free(err_msg);
		}
		return error.LoadExtensionFailed;
	}

	return handle;
}

pub fn initSchema(allocator: std.mem.Allocator, db: *c.sqlite3, schema: Schema) !void {
	const meta_sql: [:0]const u8 = "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);\x00";
	const symbols_sql: [:0]const u8 = "CREATE TABLE IF NOT EXISTS symbols (id INTEGER PRIMARY KEY, lang TEXT NOT NULL, file_path TEXT NOT NULL, start_line INTEGER NOT NULL, end_line INTEGER NOT NULL, symbol_name TEXT NOT NULL, signature TEXT, doc_comment TEXT);\x00";
	try exec(db, meta_sql);
	try exec(db, symbols_sql);

	const vec_sql = try allocPrintZ(
		allocator,
		"CREATE VIRTUAL TABLE IF NOT EXISTS embeddings USING vec0(embedding float[{d}]);",
		.{schema.embedding_dim},
	);
	defer allocator.free(vec_sql);
	try exec(db, vec_sql);

	const version_sql: [:0]const u8 = "INSERT OR REPLACE INTO meta(key, value) VALUES ('schema_version', '1');\x00";
	try exec(db, version_sql);
	const dim_sql = try allocPrintZ(
		allocator,
		"INSERT OR REPLACE INTO meta(key, value) VALUES ('embedding_dim', '{d}');",
		.{schema.embedding_dim},
	);
	defer allocator.free(dim_sql);
	try exec(db, dim_sql);
}

fn exec(db: *c.sqlite3, sql: [:0]const u8) !void {
	var err_msg: [*c]u8 = null;
	const rc = c.sqlite3_exec(db, sql, null, null, &err_msg);
	if (rc != c.SQLITE_OK) {
		if (err_msg != null) {
			c.sqlite3_free(err_msg);
		}
		return error.SqlError;
	}
}

fn tableExists(db: *c.sqlite3, allocator: std.mem.Allocator, name: []const u8) !bool {
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
}
