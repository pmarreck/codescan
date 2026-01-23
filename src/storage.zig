const std = @import("std");

const c = @cImport({
	@cInclude("sqlite3.h");
});
const model = @import("model.zig");

pub const Db = *c.sqlite3;

pub const Schema = struct {
	embedding_dim: usize,
};

pub fn openMemoryWithVec(allocator: std.mem.Allocator) !Db {
	var db: ?*c.sqlite3 = null;
	if (c.sqlite3_open(":memory:", &db) != c.SQLITE_OK) {
		return error.OpenFailed;
	}
	const handle = db orelse return error.OpenFailed;
	errdefer _ = c.sqlite3_close(handle);

	try loadVecExtension(allocator, handle);

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

	try loadVecExtension(allocator, handle);

	return handle;
}

pub fn initSchema(allocator: std.mem.Allocator, db: Db, schema: Schema) !void {
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

pub fn resetIndex(db: Db) !void {
	const symbols_sql: [:0]const u8 = "DELETE FROM symbols;\x00";
	const embeddings_sql: [:0]const u8 = "DELETE FROM embeddings;\x00";
	try exec(db, symbols_sql);
	try exec(db, embeddings_sql);
}

pub fn insertSymbol(db: Db, symbol: model.Symbol) !i64 {
	const sql: [:0]const u8 =
		"INSERT INTO symbols (lang, file_path, start_line, end_line, symbol_name, signature, doc_comment) "
		++ "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);\x00";
	var stmt: ?*c.sqlite3_stmt = null;
	if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
		return error.SqlPrepareFailed;
	}
	defer _ = c.sqlite3_finalize(stmt.?);

	try bindText(stmt.?, 1, symbol.language);
	try bindText(stmt.?, 2, symbol.file_path);
	try bindInt(stmt.?, 3, symbol.start_line);
	try bindInt(stmt.?, 4, symbol.end_line);
	try bindText(stmt.?, 5, symbol.name);
	try bindText(stmt.?, 6, symbol.signature);
	if (symbol.doc_comment) |doc| {
		try bindText(stmt.?, 7, doc);
	} else {
		_ = c.sqlite3_bind_null(stmt.?, 7);
	}

	if (c.sqlite3_step(stmt.?) != c.SQLITE_DONE) {
		return error.SqlStepFailed;
	}
	return c.sqlite3_last_insert_rowid(db);
}

pub fn insertEmbedding(db: Db, allocator: std.mem.Allocator, rowid: i64, vector: []const f32) !void {
	const sql: [:0]const u8 = "INSERT INTO embeddings (rowid, embedding) VALUES (?1, vec_f32(?2));\x00";
	var stmt: ?*c.sqlite3_stmt = null;
	if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
		return error.SqlPrepareFailed;
	}
	defer _ = c.sqlite3_finalize(stmt.?);

	const json = try vectorToJson(allocator, vector);
	defer allocator.free(json);

	_ = c.sqlite3_bind_int64(stmt.?, 1, rowid);
	_ = c.sqlite3_bind_text(stmt.?, 2, json.ptr, @intCast(json.len), null);

	if (c.sqlite3_step(stmt.?) != c.SQLITE_DONE) {
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

fn loadVecExtension(allocator: std.mem.Allocator, db: Db) !void {
	if (c.sqlite3_enable_load_extension(db, 1) != c.SQLITE_OK) {
		return error.EnableExtensionFailed;
	}

	const path = try std.process.getEnvVarOwned(allocator, "CODESCAN_SQLITE_VEC_PATH");
	defer allocator.free(path);
	const path_z = try allocator.dupeZ(u8, path);
	defer allocator.free(path_z);

	var err_msg: [*c]u8 = null;
	const rc = c.sqlite3_load_extension(db, path_z, null, &err_msg);
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
