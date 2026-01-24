const std = @import("std");

const c = @cImport({
	@cDefine("SQLITE_VEC_STATIC", "1");
	@cInclude("sqlite3.h");
	@cInclude("sqlite-vec.h");
});
const model = @import("model.zig");

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
	try exec(db, symbols_sql);
	try exec(db, embeddings_sql);
	try exec(db, comment_sql);
	_ = execMaybe(db, "DELETE FROM symbols_fts;\x00");
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
	const rowid = c.sqlite3_last_insert_rowid(db);
	insertSymbolFts(db, symbol, rowid) catch |err| switch (err) {
		error.SqlPrepareFailed => {},
		else => return err,
	};
	return rowid;
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

pub fn insertCommentEmbedding(db: Db, allocator: std.mem.Allocator, rowid: i64, vector: []const f32) !void {
	const sql: [:0]const u8 = "INSERT INTO embeddings_comment (rowid, embedding) VALUES (?1, vec_f32(?2));\x00";
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
