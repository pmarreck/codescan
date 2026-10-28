const std = @import("std");
const io_singleton = @import("io_singleton.zig");

const c = @cImport({
	@cDefine("SQLITE_VEC_STATIC", "1");
	@cInclude("sqlite3.h");
	@cInclude("sqlite-vec.h");
});
const model = @import("model.zig");
const hashline = @import("hashline.zig");

pub const sqlite = c;
pub const Db = *c.sqlite3;
const current_schema_version = 5;

/// Connection-owned operations copy error details before finalize/rollback/close.
/// The capture itself is caller-owned and must outlive the attached connection.
/// Access follows the connection's serialized writer ownership.
pub const ErrorCapture = struct {
	present: bool = false,
	code: c_int = 0,
	extended_code: c_int = 0,
	operation: [128]u8 = undefined,
	operation_len: usize = 0,
	message: [512]u8 = undefined,
	message_len: usize = 0,

	pub fn clear(self: *ErrorCapture) void {
		self.present = false;
	}

	fn record(self: *ErrorCapture, db: Db, operation: []const u8) void {
		self.code = c.sqlite3_errcode(db);
		self.extended_code = c.sqlite3_extended_errcode(db);
		self.operation_len = @min(operation.len, self.operation.len);
		@memcpy(self.operation[0..self.operation_len], operation[0..self.operation_len]);
		const message = std.mem.span(c.sqlite3_errmsg(db));
		self.message_len = @min(message.len, self.message.len);
		@memcpy(self.message[0..self.message_len], message[0..self.message_len]);
		self.present = true;
	}

	pub fn describe(self: *const ErrorCapture, buf: []u8, base: []const u8, err: anyerror) []const u8 {
		const sqlite_error = switch (err) {
			error.OpenFailed, error.SqlError, error.SqlPrepareFailed, error.SqlStepFailed, error.SqlBindFailed => true,
			else => false,
		};
		if (!sqlite_error or !self.present or self.code == c.SQLITE_OK) return base;
		return std.fmt.bufPrint(buf, "{s}; SQLite operation={s} sqlite_code={d} sqlite_extended_code={d}: {s}", .{
			base, self.operation[0..self.operation_len], self.code, self.extended_code, self.message[0..self.message_len],
		}) catch base;
	}
};

const error_capture_key = "codescan.error-capture";

pub fn attachErrorCapture(db: Db, capture: *ErrorCapture) !void {
	if (c.sqlite3_set_clientdata(db, error_capture_key, capture, null) != c.SQLITE_OK) return error.OutOfMemory;
}

test "SQLite failure capture survives rollback and close without mislabeling provider failures" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	var closed = false;
	defer if (!closed) close(db);
	var capture: ErrorCapture = .{};
	try attachErrorCapture(db, &capture);
	try exec(db, "CREATE TABLE unique_values(value TEXT UNIQUE);\x00");
	try exec(db, "INSERT INTO unique_values VALUES ('same');\x00");
	try exec(db, "BEGIN;\x00");
	try std.testing.expectError(error.SqlError, exec(db, "INSERT INTO unique_values VALUES ('same');\x00"));
	try std.testing.expectEqual(@as(c_int, c.SQLITE_CONSTRAINT), capture.code);
	try std.testing.expectEqual(@as(c_int, c.SQLITE_CONSTRAINT_UNIQUE), capture.extended_code);
	try exec(db, "ROLLBACK;\x00");
	close(db);
	closed = true;
	var buf: [2048]u8 = undefined;
	const detail = capture.describe(&buf, "index error: SqlError", error.SqlError);
	try std.testing.expect(std.mem.indexOf(u8, detail, "operation=exec sqlite_code=19") != null);
	try std.testing.expect(std.mem.indexOf(u8, detail, "UNIQUE constraint failed: unique_values.value") != null);
	try std.testing.expectEqualStrings("provider timed out", capture.describe(&buf, "provider timed out", error.Timeout));
	capture.clear();
	try std.testing.expectEqualStrings("next error", capture.describe(&buf, "next error", error.SqlError));
}

test "SQLite failure capture distinguishes schema and read-only errors and bounds copied details" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer close(db);
	var capture: ErrorCapture = .{};
	try attachErrorCapture(db, &capture);
	try std.testing.expectError(error.SqlError, exec(db, "SELECT * FROM missing_table;\x00"));
	try std.testing.expectEqual(@as(c_int, c.SQLITE_ERROR), capture.code);
	try std.testing.expectEqualStrings("no such table: missing_table", capture.message[0..capture.message_len]);
	try exec(db, "CREATE TABLE values_table(value INTEGER);\x00");
	try exec(db, "PRAGMA query_only=ON;\x00");
	try std.testing.expectError(error.SqlError, exec(db, "INSERT INTO values_table VALUES (1);\x00"));
	try std.testing.expectEqual(@as(c_int, c.SQLITE_READONLY), capture.code);
	const long_name = "x" ** 1024;
	const sql = try allocPrintZ(allocator, "SELECT * FROM {s};", .{long_name});
	defer allocator.free(sql);
	try std.testing.expectError(error.SqlError, exec(db, sql));
	capture.record(db, long_name);
	try std.testing.expectEqual(capture.operation.len, capture.operation_len);
	try std.testing.expectEqual(capture.message.len, capture.message_len);
}

test "SQLite busy diagnostics are connection-local and database open failures retain their message" {
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const root = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
	defer allocator.free(root);
	const path = try std.fs.path.join(allocator, &.{ root, "busy.sqlite3" });
	defer allocator.free(path);
	var first: ErrorCapture = .{};
	var second: ErrorCapture = .{};
	const writer = try openFileWithVecDiagnostics(allocator, path, &first);
	defer close(writer);
	try exec(writer, "CREATE TABLE values_table(value INTEGER);\x00");
	const contender = try openFileWithVecDiagnostics(allocator, path, &second);
	defer close(contender);
	try exec(contender, "PRAGMA busy_timeout=0;\x00");
	try exec(writer, "BEGIN IMMEDIATE;\x00");
	try std.testing.expectError(error.SqlError, exec(contender, "INSERT INTO values_table VALUES (1);\x00"));
	try std.testing.expectEqual(@as(c_int, c.SQLITE_BUSY), second.code);
	try std.testing.expect(!first.present);
	try std.testing.expectError(error.SqlError, exec(writer, "SELECT * FROM missing_table;\x00"));
	try std.testing.expectEqual(@as(c_int, c.SQLITE_ERROR), first.code);
	try std.testing.expectEqual(@as(c_int, c.SQLITE_BUSY), second.code);
	try exec(writer, "ROLLBACK;\x00");
	const missing = try std.fs.path.join(allocator, &.{ root, "absent-parent", "index.sqlite3" });
	defer allocator.free(missing);
	var inaccessible: ErrorCapture = .{};
	try std.testing.expectError(error.OpenFailed, openFileWithVecDiagnostics(allocator, missing, &inaccessible));
	try std.testing.expectEqual(@as(c_int, c.SQLITE_CANTOPEN), inaccessible.code);
	try std.testing.expect(inaccessible.message_len > 0);
}

const ReadFaultFixture = struct {
	calls: usize = 0,
	successful_calls: usize = 0,

	fn read(context: ?*c.sqlite3_context, _: c_int, _: [*c]?*c.sqlite3_value) callconv(.c) void {
		const self: *@This() = @ptrCast(@alignCast(c.sqlite3_user_data(context).?));
		self.calls += 1;
		if (self.calls <= self.successful_calls) {
			c.sqlite3_result_int64(context, 1);
		} else {
			// Inject SQLite's extended read-error result through its real VM.
			c.sqlite3_result_error_code(context, c.SQLITE_IOERR_READ);
		}
	}

	fn install(self: *@This(), db: Db) !void {
		try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_create_function_v2(db, "fault_read", 0, c.SQLITE_UTF8, self, read, null, null, null));
	}
};

test "indexed file cursor retains a read failure after a successful row" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer close(db);
	var capture: ErrorCapture = .{};
	try attachErrorCapture(db, &capture);
	var fault: ReadFaultFixture = .{ .successful_calls = 1 };
	try fault.install(db);
	try exec(db, "CREATE VIEW indexed_files AS SELECT 'first.zig' file_path, fault_read() mtime_ns, 1 size " ++
		"UNION ALL SELECT 'second.zig', fault_read(), 1;\x00");
	try std.testing.expectError(error.SqlStepFailed, getAllIndexedFiles(db, allocator));
	try std.testing.expectEqual(@as(usize, 2), fault.calls);
	try exec(db, "SELECT 1;\x00");
	try std.testing.expectEqual(@as(c_int, c.SQLITE_IOERR), capture.code);
	try std.testing.expectEqual(@as(c_int, c.SQLITE_IOERR_READ), capture.extended_code);
	try std.testing.expectEqualStrings("getAllIndexedFiles: step", capture.operation[0..capture.operation_len]);
	try std.testing.expect(capture.message_len > 0);
}

test "storage readers distinguish SQLite read failures from missing rows and retain diagnostics" {
	const allocator = std.testing.allocator;
	const Reader = enum { body, mtime, meta, count, file_count, language, stats, last_file, incomplete };
	for (std.meta.tags(Reader)) |reader| {
		const db = try openMemoryWithVec(allocator);
		defer close(db);
		var capture: ErrorCapture = .{};
		try attachErrorCapture(db, &capture);
		var fault: ReadFaultFixture = .{};
		try fault.install(db);
		try exec(db,
			"CREATE VIEW symbols AS SELECT 1 id, fault_read() body, 'zig' lang, 'fixture.zig' file_path WHERE fault_read();" ++
			"CREATE VIEW indexed_files AS SELECT 'fixture.zig' file_path, fault_read() mtime_ns, fault_read() indexed_at;" ++
			"CREATE VIEW meta AS SELECT 'schema_version' key, fault_read() value;" ++
			"CREATE VIEW fault_rows AS SELECT 1 value WHERE fault_read();" ++
			"CREATE VIEW embeddings AS SELECT fault_read() rowid;\x00");
		const operation = switch (reader) {
			.body => "getSymbolBody: step",
			.mtime => "getIndexedFileMtime: step",
			.meta => "metaValue: step",
			.count => "countRows: step",
			.file_count => "countDistinctFiles: step",
			.language => "primaryLanguage: step",
			.stats => "languageStats: step",
			.last_file => "lastIndexedFile: step",
			.incomplete => "collectRowids: step",
		};
		switch (reader) {
			.body => try std.testing.expectError(error.SqlStepFailed, getSymbolBody(allocator, db, 1)),
			.mtime => try std.testing.expectError(error.SqlStepFailed, getIndexedFileMtime(db, "fixture.zig")),
			.meta => try std.testing.expectError(error.SqlStepFailed, metaValue(db, allocator, "schema_version")),
			.count => try std.testing.expectError(error.SqlStepFailed, countRows(db, allocator, "fault_rows")),
			.file_count => try std.testing.expectError(error.SqlStepFailed, countDistinctFiles(db, allocator)),
			.language => try std.testing.expectError(error.SqlStepFailed, primaryLanguage(db, allocator, &.{"zig"})),
			.stats => try std.testing.expectError(error.SqlStepFailed, languageStats(db, allocator)),
			.last_file => try std.testing.expectError(error.SqlStepFailed, lastIndexedFile(db, allocator)),
			.incomplete => try std.testing.expectError(error.SqlStepFailed, getIncompleteIndexedFiles(db, allocator)),
		}
		try std.testing.expect(fault.calls > 0);
		try exec(db, "SELECT 1;\x00");
		try std.testing.expectEqual(@as(c_int, c.SQLITE_IOERR), capture.code);
		try std.testing.expectEqual(@as(c_int, c.SQLITE_IOERR_READ), capture.extended_code);
		try std.testing.expectEqualStrings(operation, capture.operation[0..capture.operation_len]);
	}
}

const ReadAuthorizationFixture = struct {
	deny_presence: bool = false,
	deny_body: bool = false,
	deny_metadata_read: usize = 0,
	metadata_reads: usize = 0,
	denials: usize = 0,

	fn authorize(context: ?*anyopaque, action: c_int, table: [*c]const u8, column: [*c]const u8, _: [*c]const u8, _: [*c]const u8) callconv(.c) c_int {
		if (action != c.SQLITE_READ or table == null or column == null) return c.SQLITE_OK;
		const self: *@This() = @ptrCast(@alignCast(context.?));
		var deny = self.deny_presence and std.mem.eql(u8, std.mem.span(table), "symbols") and column[0] == 0;
		deny = deny or (self.deny_body and std.mem.eql(u8, std.mem.span(table), "symbols") and std.mem.eql(u8, std.mem.span(column), "body"));
		if (std.mem.eql(u8, std.mem.span(table), "meta") and std.mem.eql(u8, std.mem.span(column), "value")) {
			self.metadata_reads += 1;
			deny = deny or (self.deny_metadata_read > 0 and self.metadata_reads == self.deny_metadata_read);
		}
		if (!deny) return c.SQLITE_OK;
		self.denials += 1;
		return c.SQLITE_DENY;
	}

	fn install(self: *@This(), db: Db) !void {
		try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_set_authorizer(db, authorize, self));
	}
};

test "symbol body preparation failures retain their SQLite diagnostics" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer close(db);
	try exec(db, "CREATE TABLE symbols(id INTEGER PRIMARY KEY, body TEXT);\x00");
	try exec(db, "INSERT INTO symbols VALUES(1, 'preserved body');\x00");
	var capture: ErrorCapture = .{};
	try attachErrorCapture(db, &capture);
	var authorization: ReadAuthorizationFixture = .{ .deny_body = true };
	try authorization.install(db);
	defer _ = c.sqlite3_set_authorizer(db, null, null);
	try std.testing.expectError(error.SqlPrepareFailed, getSymbolBody(allocator, db, 1));
	try std.testing.expectEqual(@as(usize, 1), authorization.denials);
	try std.testing.expectEqual(@as(c_int, c.SQLITE_AUTH), capture.code);
	try std.testing.expectEqualStrings("getSymbolBody: prepare", capture.operation[0..capture.operation_len]);
	try std.testing.expect(capture.message_len > 0);
	try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_set_authorizer(db, null, null));
	const body = (try getSymbolBody(allocator, db, 1)).?;
	defer allocator.free(body);
	try std.testing.expectEqualStrings("preserved body", body);
	try std.testing.expectEqual(@as(c_int, c.SQLITE_AUTH), capture.code);
}

test "schema initialization preserves embedding metadata when populated-index inspection fails" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer close(db);
	_ = try initSchema(allocator, db, .{ .embedding_dim = 2, .embedding_model = "original-model" });
	_ = try insertSymbol(db, .{
		.language = "zig", .file_path = "fixture.zig", .name = "kept", .signature = "fn kept() void",
		.start_line = 1, .end_line = 1, .doc_comment = null,
	});
	var capture: ErrorCapture = .{};
	try attachErrorCapture(db, &capture);
	var authorization: ReadAuthorizationFixture = .{ .deny_presence = true };
	try authorization.install(db);
	defer _ = c.sqlite3_set_authorizer(db, null, null);
	var failure: ?anyerror = null;
	if (initSchema(allocator, db, .{ .embedding_dim = 2, .embedding_model = "replacement-model" })) |value| {
		var result = value;
		result.deinit(allocator);
	} else |err| failure = err;
	try std.testing.expectEqual(@as(usize, 1), authorization.denials);
	try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_set_authorizer(db, null, null));
	const stored = (try metaValue(db, allocator, "embedding_model")).?;
	defer allocator.free(stored);
	try std.testing.expectEqualStrings("original-model", stored);
	try std.testing.expectEqual(@as(?anyerror, error.SqlPrepareFailed), failure);
	try std.testing.expectEqual(@as(c_int, c.SQLITE_AUTH), capture.code);
	try std.testing.expectEqualStrings("isIndexPopulated: prepare", capture.operation[0..capture.operation_len]);
	try std.testing.expectEqual(@as(i64, 1), try countRows(db, allocator, "symbols"));
}

test "schema initialization frees owned model metadata when the later dimension read fails" {
	var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
	defer arena.deinit();
	var accounting = std.testing.FailingAllocator.init(arena.allocator(), .{});
	const allocator = accounting.allocator();
	const db = try openMemoryWithVec(allocator);
	defer close(db);
	_ = try initSchema(allocator, db, .{ .embedding_dim = 2, .embedding_model = "original-model" });
	_ = try insertSymbol(db, .{
		.language = "zig", .file_path = "fixture.zig", .name = "kept", .signature = "fn kept() void",
		.start_line = 1, .end_line = 1, .doc_comment = null,
	});
	var capture: ErrorCapture = .{};
	try attachErrorCapture(db, &capture);
	// schema_version, embedding_model, then embedding_dim are distinct reads.
	var authorization: ReadAuthorizationFixture = .{ .deny_metadata_read = 3 };
	try authorization.install(db);
	defer _ = c.sqlite3_set_authorizer(db, null, null);
	try std.testing.expectError(error.SqlPrepareFailed, initSchema(allocator, db, .{ .embedding_dim = 2, .embedding_model = "replacement-model" }));
	try std.testing.expectEqual(@as(usize, 3), authorization.metadata_reads);
	try std.testing.expectEqual(@as(usize, 1), authorization.denials);
	try std.testing.expectEqual(@as(c_int, c.SQLITE_AUTH), capture.code);
	try std.testing.expectEqualStrings("metaValue: prepare", capture.operation[0..capture.operation_len]);
	try std.testing.expectEqual(accounting.allocated_bytes, accounting.freed_bytes);
}

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
	return openFileWithVecDiagnostics(allocator, path, null);
}

pub fn openFileWithVecDiagnostics(allocator: std.mem.Allocator, path: []const u8, capture: ?*ErrorCapture) !Db {
	const path_z = try allocator.dupeZ(u8, path);
	defer allocator.free(path_z);

	var db: ?*c.sqlite3 = null;
	if (c.sqlite3_open(path_z, &db) != c.SQLITE_OK) {
		if (db) |handle| {
			if (capture) |details| details.record(handle, "openFileWithVec: open");
			_ = c.sqlite3_close(handle);
		}
		return error.OpenFailed;
	}
	const handle = db orelse return error.OpenFailed;
	errdefer _ = c.sqlite3_close(handle);
	if (capture) |details| try attachErrorCapture(handle, details);

	try initVecStatic(handle);

	// Enable WAL mode for concurrent access (watcher + CLI commands)
	_ = execMaybe(handle, "PRAGMA journal_mode=WAL;\x00");
	// Indexes are rebuildable; NORMAL avoids one WAL fsync per autocommit while
	// preserving consistency and syncing at checkpoints.
	try exec(handle, "PRAGMA synchronous=NORMAL;\x00");
	// Wait up to 5s if another process holds the write lock
	_ = execMaybe(handle, "PRAGMA busy_timeout=5000;\x00");

	return handle;
}

pub fn openFileWithVecRecreate(allocator: std.mem.Allocator, path: []const u8) !Db {
	try deleteFileIfExists(path);
	return openFileWithVec(allocator, path);
}

/// Runs SQLite's built-in integrity check without changing the database.
/// The returned message is normally "ok"; callers own it and must free it.
pub fn checkIntegrity(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
	const path_z = try allocator.dupeZ(u8, path);
	defer allocator.free(path_z);

	var db_opt: ?Db = null;
	if (c.sqlite3_open_v2(path_z, &db_opt, c.SQLITE_OPEN_READONLY, null) != c.SQLITE_OK) {
		if (db_opt) |db| close(db);
		return error.OpenFailed;
	}
	const db = db_opt orelse return error.OpenFailed;
	defer close(db);

	const sql: [:0]const u8 = "PRAGMA integrity_check;\x00";
	var stmt: ?*c.sqlite3_stmt = null;
	if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.IntegrityCheckFailed;
	defer _ = c.sqlite3_finalize(stmt.?);

	if (c.sqlite3_step(stmt.?) != c.SQLITE_ROW) return error.IntegrityCheckFailed;
	const text = c.sqlite3_column_text(stmt.?, 0) orelse return error.IntegrityCheckFailed;
	const len: usize = @intCast(c.sqlite3_column_bytes(stmt.?, 0));
	return allocator.dupe(u8, text[0..len]);
}

test "checkIntegrity accepts a valid database and rejects invalid database bytes" {
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	const root = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
	defer allocator.free(root);
	const valid_path = try std.fs.path.join(allocator, &.{ root, "valid.sqlite3" });
	defer allocator.free(valid_path);
	const db = try openFileWithVec(allocator, valid_path);
	close(db);

	const valid_result = try checkIntegrity(allocator, valid_path);
	defer allocator.free(valid_result);
	try std.testing.expectEqualStrings("ok", valid_result);

	try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = "invalid.sqlite3", .data = "not a SQLite database" });
	const invalid_path = try std.fs.path.join(allocator, &.{ root, "invalid.sqlite3" });
	defer allocator.free(invalid_path);
	try std.testing.expectError(error.IntegrityCheckFailed, checkIntegrity(allocator, invalid_path));
}

fn deleteFileIfExists(path: []const u8) !void {
	std.Io.Dir.cwd().deleteFile(io_singleton.getOrInit(), path) catch |err| switch (err) {
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
	if (effective_version > 0 and effective_version < 5) {
		try migrateV4ToV5(db);
		did_schema_upgrade = true;
	}

	// Detect embedding model/dim mismatches BEFORE overwriting stored values
	var result = InitSchemaResult{
		.did_schema_upgrade = did_schema_upgrade,
		.previous_schema_version = previous_schema_version,
	};
	errdefer result.deinit(allocator);

	if (had_meta_table and (try isIndexPopulated(db, allocator))) {
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
	try setSchemaVersion(db);
	if (!(result.embedding_model_mismatch or result.embedding_dim_mismatch)) {
		try setEmbeddingMeta(db, schema);
	}

	// Initialize FTS (idempotent)
	const fts_enabled = tryInitFts(allocator, db);
	try setMetaValue(db, "fts_enabled", if (fts_enabled) "1" else "0");

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

fn migrateV4ToV5(db: Db) !void {
	// symbol_kind values changed from full words to short forms.
	// Update existing records so searches work without a full reindex,
	// though a full reindex is still recommended (picks up const/var split).
	const updates = [_][:0]const u8{
		"UPDATE symbols SET symbol_kind = 'fn' WHERE symbol_kind = 'function';\x00",
		"UPDATE symbols SET symbol_kind = 'var' WHERE symbol_kind = 'variable';\x00",
		"UPDATE symbols SET symbol_kind = 'mod' WHERE symbol_kind = 'module';\x00",
		"UPDATE symbols SET symbol_kind = 'const' WHERE symbol_kind = 'constant';\x00",
	};
	for (updates) |sql| {
		_ = execMaybe(db, sql);
	}
}

/// Write the current schema version to meta.
fn setSchemaVersion(db: Db) !void {
	var buffer: [32]u8 = undefined;
	const value = try std.fmt.bufPrint(&buffer, "{d}", .{current_schema_version});
	try setMetaValue(db, "schema_version", value);
}

/// Write embedding dim/model metadata to meta.
fn setEmbeddingMeta(db: Db, schema: Schema) !void {
	var buffer: [32]u8 = undefined;
	const dimension = try std.fmt.bufPrint(&buffer, "{d}", .{schema.embedding_dim});
	try setMetaValue(db, "embedding_dim", dimension);

	if (schema.embedding_model.len > 0) {
		try setMetaValue(db, "embedding_model", schema.embedding_model);
	}
}

/// Updates schema metadata only when its value changed, keeping read-only
/// reconciliation free of WAL writes and fsyncs.
fn setMetaValue(db: Db, key: []const u8, value: []const u8) !void {
	const sql: [:0]const u8 =
		"INSERT INTO meta(key, value) VALUES (?1, ?2) " ++
		"ON CONFLICT(key) DO UPDATE SET value = excluded.value " ++
		"WHERE meta.value <> excluded.value;\x00";
	var stmt: ?*c.sqlite3_stmt = null;
	if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
		logSqliteError(db, "setMetaValue: prepare");
		return error.SqlPrepareFailed;
	}
	defer _ = c.sqlite3_finalize(stmt.?);

	try bindText(stmt.?, 1, key);
	try bindText(stmt.?, 2, value);
	if (c.sqlite3_step(stmt.?) != c.SQLITE_DONE) {
		logSqliteError(db, "setMetaValue: step");
		return error.SqlStepFailed;
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
	var start_hash_buffer: hashline.Hash = undefined;
	if (symbol.start_hash) |hash| {
		start_hash_buffer = hash;
		try bindText(stmt.?, 4, &start_hash_buffer);
	} else {
		_ = c.sqlite3_bind_null(stmt.?, 4);
	}
	try bindInt(stmt.?, 5, symbol.end_line);
	var end_hash_buffer: hashline.Hash = undefined;
	if (symbol.end_hash) |hash| {
		end_hash_buffer = hash;
		try bindText(stmt.?, 6, &end_hash_buffer);
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
		error.SqlPrepareFailed => clearCapturedError(db),
		else => {
			logSqliteError(db, "insertSymbolFts");
			clearCapturedError(db);
			// Non-fatal: symbol is indexed, just FTS entry failed. Continue.
		},
	};
	return rowid;
}

pub fn getSymbolBody(allocator: std.mem.Allocator, db: Db, id: i64) !?[]const u8 {
	const sql: [:0]const u8 = "SELECT body FROM symbols WHERE id = ?1;\x00";
	var stmt: ?*c.sqlite3_stmt = null;
	if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
		logSqliteError(db, "getSymbolBody: prepare");
		return error.SqlPrepareFailed;
	}
	defer _ = c.sqlite3_finalize(stmt.?);
	_ = c.sqlite3_bind_int64(stmt.?, 1, id);
	if (!try stepRow(db, stmt.?, "getSymbolBody: step")) return null;
	const ptr = c.sqlite3_column_text(stmt.?, 0) orelse return null;
	const len: usize = @intCast(c.sqlite3_column_bytes(stmt.?, 0));
	return try allocator.dupe(u8, ptr[0..len]);
}

pub fn insertEmbedding(db: Db, allocator: std.mem.Allocator, rowid: i64, vector: []const f32) !void {
	const sql: [:0]const u8 = "INSERT OR REPLACE INTO embeddings (rowid, embedding) VALUES (?1, vec_f32(?2));\x00";
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
	const sql: [:0]const u8 = "INSERT OR REPLACE INTO embeddings_comment (rowid, embedding) VALUES (?1, vec_f32(?2));\x00";
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
		_ = captureSqliteError(db, "exec");
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

	const fts_count = countRows(db, allocator, "symbols_fts") catch {
		clearCapturedError(db);
		return true;
	};
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
		"INSERT OR REPLACE INTO symbols_fts (rowid, symbol_name, signature, doc_comment, file_path, body) "
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
		if (!try stepRow(db, stmt.?, "columnExists: step")) break;
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
	if (try stepRow(db, stmt.?, "metaValue: step")) {
		const ptr = c.sqlite3_column_text(stmt.?, 0) orelse return null;
		return @as(?[]u8, try allocator.dupe(u8, std.mem.span(ptr)));
	}
	return null;
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

	if (!try stepRow(db, stmt.?, "countRows: step")) {
		return error.SqlStepFailed;
	}
	return c.sqlite3_column_int64(stmt.?, 0);
}

/// Returns true if the symbols table exists and contains at least one row.
/// Missing/empty is false; an unreadable index is an error, never empty.
pub fn isIndexPopulated(db: Db, allocator: std.mem.Allocator) !bool {
	if (!try tableExists(db, allocator, "symbols")) return false;
	var stmt: ?*c.sqlite3_stmt = null;
	const sql = "SELECT 1 FROM symbols LIMIT 1;";
	if (c.sqlite3_prepare_v2(db, sql, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) {
		logSqliteError(db, "isIndexPopulated: prepare");
		return error.SqlPrepareFailed;
	}
	defer _ = c.sqlite3_finalize(stmt.?);
	return stepRow(db, stmt.?, "isIndexPopulated: step");
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

	if (!try stepRow(db, stmt.?, "countDistinctFiles: step")) {
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

	var out: std.Io.Writer.Allocating = .init(allocator);
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

	if (try stepRow(db, stmt.?, "primaryLanguage: step")) {
		const ptr = c.sqlite3_column_text(stmt.?, 0) orelse return null;
		const slice = std.mem.span(ptr);
		return @as(?[]const u8, try allocator.dupe(u8, slice));
	}
	return null;
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

	var results: std.ArrayListUnmanaged(LangStat) = .empty;
	errdefer {
		for (results.items) |item| allocator.free(item.language);
		results.deinit(allocator);
	}

	while (try stepRow(db, stmt.?, "languageStats: step")) {
		const lang_ptr = c.sqlite3_column_text(stmt.?, 0) orelse continue;
		const lang_slice = std.mem.span(lang_ptr);
		const lang = try allocator.dupe(u8, lang_slice);
		errdefer allocator.free(lang);
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

	if (try stepRow(db, stmt.?, "lastIndexedFile: step")) {
		const path_ptr = c.sqlite3_column_text(stmt.?, 0) orelse return null;
		const path_slice = std.mem.span(path_ptr);
		return .{
			.file_path = try allocator.dupe(u8, path_slice),
			.indexed_at = c.sqlite3_column_int64(stmt.?, 1),
		};
	}
	return null;
}

/// A cursor is exhausted only on DONE; copy terminal errors before finalize.
fn stepRow(db: Db, stmt: *c.sqlite3_stmt, operation: []const u8) !bool {
	return switch (c.sqlite3_step(stmt)) {
		c.SQLITE_ROW => true,
		c.SQLITE_DONE => false,
		else => {
			_ = captureSqliteError(db, operation);
			return error.SqlStepFailed;
		},
	};
}

fn captureSqliteError(db: Db, context: []const u8) bool {
	if (c.sqlite3_get_clientdata(db, error_capture_key)) |pointer| {
		const capture: *ErrorCapture = @ptrCast(@alignCast(pointer));
		capture.record(db, context);
		return true;
	}
	return false;
}

fn clearCapturedError(db: Db) void {
	if (c.sqlite3_get_clientdata(db, error_capture_key)) |pointer| {
		const capture: *ErrorCapture = @ptrCast(@alignCast(pointer));
		capture.clear();
	}
}

fn logSqliteError(db: Db, context: []const u8) void {
	if (captureSqliteError(db, context)) return;
	const msg = c.sqlite3_errmsg(db);
	if (msg != null) {
		const msg_slice = std.mem.span(msg);
		var stderr_buf: [4096]u8 = undefined;
		var stderr_writer = io_singleton.stderrWriter(&stderr_buf);
		const stderr = &stderr_writer.interface;
		_ = stderr.print("sqlite error ({s}): {s}\n", .{ context, msg_slice }) catch {};
		_ = stderr.flush() catch {};
	}
}

/// Bind `text` to parameter `index` of `stmt`.
///
/// LIFETIME CONTRACT: passes `null` as the destructor, which SQLite treats as
/// `SQLITE_STATIC` — SQLite does NOT copy `text`. The caller must keep `text`
/// alive until the statement has been stepped to `SQLITE_DONE` and finalized.
/// Every call site in this module satisfies this by stepping+finalizing
/// before the caller frees the buffer (the caller's `defer free` runs after
/// the function's `defer sqlite3_finalize` in scope-unwind order).
///
/// The defensive alternative is `SQLITE_TRANSIENT`, which forces SQLite to
/// copy the buffer on bind. Zig 0.16's function-pointer alignment check
/// rejects every reasonable construction of the `(void*)-1` sentinel
/// (`@ptrFromInt(-1)` is misaligned; `@alignCast` would panic), so we hold
/// the lifetime invariant by code review rather than at the API level.
fn bindText(stmt: *c.sqlite3_stmt, index: c_int, text: []const u8) !void {
	if (c.sqlite3_bind_text(stmt, index, text.ptr, @intCast(text.len), null) != c.SQLITE_OK) {
		_ = captureSqliteError(c.sqlite3_db_handle(stmt).?, "bindText");
		return error.SqlBindFailed;
	}
}

fn bindInt(stmt: *c.sqlite3_stmt, index: c_int, value: usize) !void {
	if (c.sqlite3_bind_int64(stmt, index, @intCast(value)) != c.SQLITE_OK) {
		_ = captureSqliteError(c.sqlite3_db_handle(stmt).?, "bindInt");
		return error.SqlBindFailed;
	}
}

pub fn vectorToJson(allocator: std.mem.Allocator, vector: []const f32) ![]u8 {
	var out: std.Io.Writer.Allocating = .init(allocator);
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
		_ = captureSqliteError(db, "upsertIndexedFile: step");
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
	if (try stepRow(db, stmt.?, "getIndexedFileMtime: step")) {
		return c.sqlite3_column_int64(stmt.?, 0);
	}
	return null;
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

	var list: std.ArrayListUnmanaged(IndexedFile) = .empty;
	errdefer {
		for (list.items) |item| allocator.free(item.file_path);
		list.deinit(allocator);
	}

	while (try stepRow(db, stmt.?, "getAllIndexedFiles: step")) {

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

/// Returns completion-marked files whose code or attached-comment vectors are
/// missing, allowing update to repair indexes created by interrupted old runs.
pub fn getIncompleteIndexedFiles(db: Db, allocator: std.mem.Allocator) ![][]const u8 {
	var code_rowids = try collectRowids(db, allocator, "SELECT rowid FROM embeddings;\x00");
	defer code_rowids.deinit();
	var comment_rowids = try collectRowids(db, allocator, "SELECT rowid FROM embeddings_comment;\x00");
	defer comment_rowids.deinit();

	const sql: [:0]const u8 =
		"SELECT s.id, s.file_path, s.doc_comment IS NOT NULL " ++
		"FROM symbols AS s " ++
		"JOIN indexed_files AS f ON f.file_path = s.file_path " ++
		"ORDER BY s.file_path, s.id;\x00";
	var stmt: ?*c.sqlite3_stmt = null;
	if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
		logSqliteError(db, "getIncompleteIndexedFiles: prepare");
		return error.SqlPrepareFailed;
	}
	defer _ = c.sqlite3_finalize(stmt.?);

	var paths: std.ArrayListUnmanaged([]const u8) = .empty;
	errdefer {
		for (paths.items) |path| allocator.free(path);
		paths.deinit(allocator);
	}
	while (try stepRow(db, stmt.?, "getIncompleteIndexedFiles: step")) {
		const rowid = c.sqlite3_column_int64(stmt.?, 0);
		const requires_comment = c.sqlite3_column_int(stmt.?, 2) != 0;
		if (code_rowids.contains(rowid) and (!requires_comment or comment_rowids.contains(rowid))) continue;

		const ptr = c.sqlite3_column_text(stmt.?, 1) orelse continue;
		const path = std.mem.span(ptr);
		if (paths.items.len > 0 and std.mem.eql(u8, paths.items[paths.items.len - 1], path)) continue;
		try paths.append(allocator, try allocator.dupe(u8, path));
	}
	return paths.toOwnedSlice(allocator);
}

/// Materializes virtual-table rowids once so completeness checks stay linear
/// instead of issuing one sqlite-vec point probe for every indexed symbol.
fn collectRowids(
	db: Db,
	allocator: std.mem.Allocator,
	sql: [:0]const u8,
) !std.AutoHashMap(i64, void) {
	var rowids = std.AutoHashMap(i64, void).init(allocator);
	errdefer rowids.deinit();

	var stmt: ?*c.sqlite3_stmt = null;
	if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) {
		logSqliteError(db, "collectRowids: prepare");
		return error.SqlPrepareFailed;
	}
	defer _ = c.sqlite3_finalize(stmt.?);

	while (try stepRow(db, stmt.?, "collectRowids: step")) {
		try rowids.put(c.sqlite3_column_int64(stmt.?, 0), {});
	}
	return rowids;
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
		_ = captureSqliteError(db, "deleteIndexedFile: step");
		return error.SqlStepFailed;
	}
}

pub fn deleteSymbolsByFile(db: Db, file_path: []const u8) !void {
	try exec(db, "BEGIN IMMEDIATE;\x00");
	errdefer _ = execMaybe(db, "ROLLBACK;\x00");

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
			_ = captureSqliteError(db, "deleteSymbolsByFile: step embeddings");
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
			_ = captureSqliteError(db, "deleteSymbolsByFile: step symbols");
			return error.SqlStepFailed;
		}
	}

	try exec(db, "COMMIT;\x00");
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
	try std.testing.expectEqualStrings("5", version.?);
}

test "initSchema repeated with matching metadata performs no data writes" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer _ = c.sqlite3_close(db);

	var first = try initSchema(allocator, db, .{
		.embedding_dim = 2,
		.embedding_model = "jina-code-embeddings:1.5b",
	});
	defer first.deinit(allocator);
	const changes_before = c.sqlite3_total_changes64(db);

	var repeated = try initSchema(allocator, db, .{
		.embedding_dim = 2,
		.embedding_model = "jina-code-embeddings:1.5b",
	});
	defer repeated.deinit(allocator);

	try std.testing.expectEqual(changes_before, c.sqlite3_total_changes64(db));
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
	try std.testing.expectEqualStrings("5", version.?);
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
	try std.testing.expectEqual(@as(?u32, 5), result.previous_schema_version);
}

test "openFileWithVecRecreate replaces existing file" {
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = "db.sqlite3", .data = "not a sqlite db" });
	const abs_path = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), "db.sqlite3", allocator);
	defer allocator.free(abs_path);

	const db = try openFileWithVecRecreate(allocator, abs_path);
	defer _ = c.sqlite3_close(db);
	_ = try initSchema(allocator, db, .{ .embedding_dim = 2 });

	var file = try std.Io.Dir.openFileAbsolute(io_singleton.getOrInit(), abs_path, .{});
	defer file.close(io_singleton.getOrInit());

	var header: [16]u8 = undefined;
	const n = try file.readPositionalAll(io_singleton.getOrInit(), &header, 0);
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

test "file databases use WAL with NORMAL synchronization" {
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = "index.sqlite3", .data = "" });
	const path = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), "index.sqlite3", allocator);
	defer allocator.free(path);

	const db = try openFileWithVec(allocator, path);
	defer close(db);

	var stmt: ?*c.sqlite3_stmt = null;
	try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(db, "PRAGMA synchronous;\x00", -1, &stmt, null));
	defer _ = c.sqlite3_finalize(stmt.?);
	try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt.?));
	try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_column_int(stmt.?, 0));
}

test "insertSymbol round-trips distinct hashline boundaries" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer close(db);
	_ = try initSchema(allocator, db, .{ .embedding_dim = 2 });

	var symbol = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/main.zig"),
		.name = try allocator.dupe(u8, "main"),
		.signature = try allocator.dupe(u8, "pub fn main() void"),
		.doc_comment = null,
		.start_hash = .{ 'a', '1', 'Z' },
		.end_hash = .{ 'x', '9', 'Q' },
		.start_line = 3,
		.end_line = 7,
	};
	defer symbol.deinit(allocator);
	const rowid = try insertSymbol(db, symbol);

	var stmt: ?*c.sqlite3_stmt = null;
	const sql: [:0]const u8 = "SELECT start_hash, end_hash FROM symbols WHERE id = ?1;\x00";
	try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(db, sql, -1, &stmt, null));
	defer _ = c.sqlite3_finalize(stmt.?);
	_ = c.sqlite3_bind_int64(stmt.?, 1, rowid);
	try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt.?));
	try std.testing.expectEqualStrings("a1Z", std.mem.span(c.sqlite3_column_text(stmt.?, 0).?));
	try std.testing.expectEqualStrings("x9Q", std.mem.span(c.sqlite3_column_text(stmt.?, 1).?));
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

test "deleteSymbolsByFile rolls back related-table deletes on failure" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer close(db);
	_ = try initSchema(allocator, db, .{ .embedding_dim = 2 });

	var symbol = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/a.zig"),
		.name = try allocator.dupe(u8, "a"),
		.signature = try allocator.dupe(u8, "fn a() void"),
		.doc_comment = try allocator.dupe(u8, "Attached comment"),
		.start_line = 1,
		.end_line = 1,
	};
	defer symbol.deinit(allocator);
	const rowid = try insertSymbol(db, symbol);
	try insertEmbedding(db, allocator, rowid, &[_]f32{ 0.1, 0.2 });
	try insertCommentEmbedding(db, allocator, rowid, &[_]f32{ 0.3, 0.4 });
	try exec(
		db,
		"CREATE TRIGGER reject_symbol_delete BEFORE DELETE ON symbols "
		++ "BEGIN SELECT RAISE(ABORT, 'deliberate delete failure'); END;\x00",
	);

	try std.testing.expectError(error.SqlStepFailed, deleteSymbolsByFile(db, "src/a.zig"));
	try std.testing.expectEqual(@as(i64, 1), try countRows(db, allocator, "symbols"));
	try std.testing.expectEqual(@as(i64, 1), try countRows(db, allocator, "embeddings"));
	try std.testing.expectEqual(@as(i64, 1), try countRows(db, allocator, "embeddings_comment"));
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
	try std.testing.expect(!try isIndexPopulated(db, allocator));
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
	try std.testing.expect(try isIndexPopulated(db, allocator));
}

test "isIndexPopulated returns false without schema" {
	const allocator = std.testing.allocator;
	const db = try openMemoryWithVec(allocator);
	defer _ = c.sqlite3_close(db);

	// No initSchema — table doesn't exist
	try std.testing.expect(!try isIndexPopulated(db, allocator));
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
