const std = @import("std");
const io_singleton = @import("io_singleton.zig");

pub const HttpRequest = struct {
	method: []const u8,
	url: []const u8,
	headers: []const std.http.Header,
	body: []const u8,
};

pub const HttpResponse = struct {
	status: u16,
	body: []const u8,
};

pub const Transport = struct {
	ctx: *anyopaque,
	send: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, req: HttpRequest) anyerror!HttpResponse,
};

pub const ApiDialect = enum {
	ollama,
	openai,
};

pub fn embed(
	allocator: std.mem.Allocator,
	transport: Transport,
	base_url: []const u8,
	model: []const u8,
	inputs: []const []const u8,
	keep_alive: ?i64,
	dialect: ApiDialect,
	auth_header: ?[]const u8,
) ![][]f32 {
	const url = try buildEmbedUrl(allocator, base_url, dialect);
	defer allocator.free(url);
	const body = try buildEmbedRequest(allocator, model, inputs, keep_alive, dialect);
	defer allocator.free(body);

	var header_buf: [5]std.http.Header = undefined;
	var header_count: usize = 3;
	header_buf[0] = .{ .name = "Content-Type", .value = "application/json" };
	header_buf[1] = .{ .name = "Accept", .value = "application/json" };
	// std.http.Client reuses keep-alive sockets; servers may close them after
	// short idle windows, which surfaces as WriteFailed mid-batch on re-use.
	// Force a fresh TCP connection per embed request.
	header_buf[2] = .{ .name = "Connection", .value = "close" };
	if (dialect == .openai) {
		if (auth_header) |key| {
			header_buf[3] = .{ .name = "Authorization", .value = key };
			header_count = 4;
		}
	}

	const response = try transport.send(transport.ctx, allocator, .{
		.method = "POST",
		.url = url,
		.headers = header_buf[0..header_count],
		.body = body,
	});
	defer allocator.free(response.body);

	if (response.status != 200) {
		var stderr_buf: [256]u8 = undefined;
		var stderr_writer = std.Io.File.stderr().writer(io_singleton.getOrInit(), &stderr_buf);
		const stderr = &stderr_writer.interface;
		const preview_len = @min(response.body.len, 500);
		_ = stderr.print("error: embedding server returned HTTP {d}\n  url: {s}\n  model: {s}\n  body: {s}{s}\n", .{
			response.status,
			url,
			model,
			response.body[0..preview_len],
			if (response.body.len > preview_len) "..." else "",
		}) catch {};
		_ = stderr.flush() catch {};
		if (response.status == 401) return error.Unauthorized;
		return error.HttpStatus;
	}
	return parseEmbeddings(allocator, response.body, dialect);
}

pub fn buildEmbedUrl(allocator: std.mem.Allocator, base_url: []const u8, dialect: ApiDialect) ![]u8 {
	const path: []const u8 = switch (dialect) {
		.ollama => "api/embed",
		.openai => "v1/embeddings",
	};
	if (std.mem.endsWith(u8, base_url, "/")) {
		return std.fmt.allocPrint(allocator, "{s}{s}", .{ base_url, path });
	}
	return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_url, path });
}

pub fn buildTagsUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
	if (std.mem.endsWith(u8, base_url, "/")) {
		return std.fmt.allocPrint(allocator, "{s}api/tags", .{base_url});
	}
	return std.fmt.allocPrint(allocator, "{s}/api/tags", .{base_url});
}

pub fn buildPsUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
	if (std.mem.endsWith(u8, base_url, "/")) {
		return std.fmt.allocPrint(allocator, "{s}api/ps", .{base_url});
	}
	return std.fmt.allocPrint(allocator, "{s}/api/ps", .{base_url});
}

pub fn buildEmbedRequest(
	allocator: std.mem.Allocator,
	model: []const u8,
	inputs: []const []const u8,
	keep_alive: ?i64,
	dialect: ApiDialect,
) ![]u8 {
	// For OpenAI dialect, suppress keep_alive
	const effective_keep_alive: ?i64 = switch (dialect) {
		.ollama => keep_alive,
		.openai => null,
	};
	const payload = EmbedRequest{ .model = model, .input = inputs, .keep_alive = effective_keep_alive };
	var out: std.Io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	var stream: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
	try stream.write(payload);
	return out.toOwnedSlice();
}

pub fn ensureModelAvailable(
	allocator: std.mem.Allocator,
	transport: Transport,
	base_url: []const u8,
	model_name: []const u8,
	dialect: ApiDialect,
) !void {
	// OpenAI-compatible servers don't have /api/tags or /api/ps — skip entirely
	if (dialect == .openai) return;

	// Step 1: Check /api/tags — model exists on disk?
	{
		const url = try buildTagsUrl(allocator, base_url);
		defer allocator.free(url);

		const headers = [_]std.http.Header{
			.{ .name = "Accept", .value = "application/json" },
		};

		const response = try transport.send(transport.ctx, allocator, .{
			.method = "GET",
			.url = url,
			.headers = &headers,
			.body = "",
		});
		defer allocator.free(response.body);

		if (response.status != 200) return error.HttpStatus;
		if (!try hasModel(allocator, response.body, model_name)) return error.ModelNotFound;
	}

	// Step 2: Check /api/ps — model loaded in memory? (fast path)
	if (try isModelLoaded(allocator, transport, base_url, model_name)) return;

	// Step 3: Model exists on disk but not loaded in memory.
	// The next embed call will trigger loading, which can take minutes.
	// Return immediately so callers can show a helpful message or fall back.
	return error.ModelLoading;
}

/// Check if a model is currently loaded in memory via /api/ps.
pub fn isModelLoaded(
	allocator: std.mem.Allocator,
	transport: Transport,
	base_url: []const u8,
	model_name: []const u8,
) !bool {
	const url = try buildPsUrl(allocator, base_url);
	defer allocator.free(url);

	const headers = [_]std.http.Header{
		.{ .name = "Accept", .value = "application/json" },
	};

	const response = try transport.send(transport.ctx, allocator, .{
		.method = "GET",
		.url = url,
		.headers = &headers,
		.body = "",
	});
	defer allocator.free(response.body);

	if (response.status != 200) return false;
	return hasModel(allocator, response.body, model_name) catch false;
}

pub fn parseEmbeddings(allocator: std.mem.Allocator, body: []const u8, dialect: ApiDialect) ![][]f32 {
	return switch (dialect) {
		.ollama => parseOllamaEmbeddings(allocator, body),
		.openai => parseOpenAiEmbeddings(allocator, body),
	};
}

fn parseOllamaEmbeddings(allocator: std.mem.Allocator, body: []const u8) ![][]f32 {
	var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
	defer parsed.deinit();

	if (parsed.value != .object) return error.InvalidResponse;
	const embeddings_value = parsed.value.object.get("embeddings") orelse return error.MissingEmbeddings;
	if (embeddings_value != .array) return error.InvalidEmbeddings;

	const rows = embeddings_value.array.items;
	var result = try allocator.alloc([]f32, rows.len);
	errdefer freeEmbeddings(allocator, result);

	for (rows, 0..) |row_value, row_idx| {
		if (row_value != .array) return error.InvalidEmbeddings;
		const values = row_value.array.items;
		var vec = try allocator.alloc(f32, values.len);
		errdefer allocator.free(vec);
		for (values, 0..) |value, col_idx| {
			vec[col_idx] = try parseNumber(value);
		}
		result[row_idx] = vec;
	}

	return result;
}

fn parseOpenAiEmbeddings(allocator: std.mem.Allocator, body: []const u8) ![][]f32 {
	var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
	defer parsed.deinit();

	if (parsed.value != .object) return error.InvalidResponse;
	const data_value = parsed.value.object.get("data") orelse return error.MissingEmbeddings;
	if (data_value != .array) return error.InvalidEmbeddings;

	const items = data_value.array.items;
	var result = try allocator.alloc([]f32, items.len);
	// Initialize all slots to empty so partial-fill errdefer works cleanly
	for (result) |*slot| slot.* = &.{};
	errdefer freeEmbeddings(allocator, result);

	for (items) |item| {
		if (item != .object) return error.InvalidEmbeddings;
		const index_value = item.object.get("index") orelse return error.InvalidEmbeddings;
		if (index_value != .integer) return error.InvalidEmbeddings;
		const idx: usize = @intCast(index_value.integer);
		if (idx >= result.len) return error.InvalidEmbeddings;

		const embedding_value = item.object.get("embedding") orelse return error.InvalidEmbeddings;
		if (embedding_value != .array) return error.InvalidEmbeddings;
		const values = embedding_value.array.items;
		var vec = try allocator.alloc(f32, values.len);
		errdefer allocator.free(vec);
		for (values, 0..) |value, col_idx| {
			vec[col_idx] = try parseNumber(value);
		}
		result[idx] = vec;
	}

	return result;
}

fn hasModel(allocator: std.mem.Allocator, body: []const u8, model: []const u8) !bool {
	var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
	defer parsed.deinit();

	if (parsed.value != .object) return false;
	const models_value = parsed.value.object.get("models") orelse return false;
	if (models_value != .array) return false;

	for (models_value.array.items) |item| {
		if (item != .object) continue;
		const name_value = item.object.get("name") orelse continue;
		if (name_value != .string) continue;
		const name = name_value.string;
		if (std.mem.eql(u8, name, model)) return true;
		if (std.mem.indexOfScalar(u8, model, ':') == null) {
			if (std.mem.startsWith(u8, name, model) and name.len > model.len and name[model.len] == ':') {
				return true;
			}
		}
	}

	return false;
}

pub fn freeEmbeddings(allocator: std.mem.Allocator, embeddings: [][]f32) void {
	for (embeddings) |row| allocator.free(row);
	allocator.free(embeddings);
}

fn parseNumber(value: std.json.Value) !f32 {
	switch (value) {
		.integer => |v| return @floatFromInt(v),
		.float => |v| return @floatCast(v),
		else => return error.InvalidEmbeddings,
	}
}

const EmbedRequest = struct {
	model: []const u8,
	input: []const []const u8,
	keep_alive: ?i64 = null,
};

pub const StdHttpTransport = struct {
	client: std.http.Client,

	pub fn init(allocator: std.mem.Allocator) StdHttpTransport {
		return .{ .client = .{ .allocator = allocator } };
	}

	pub fn deinit(self: *StdHttpTransport) void {
		self.client.deinit();
	}

	pub fn transport(self: *StdHttpTransport) Transport {
		return .{ .ctx = self, .send = send };
	}

	fn send(ctx: *anyopaque, allocator: std.mem.Allocator, req: HttpRequest) !HttpResponse {
		const self: *StdHttpTransport = @ptrCast(@alignCast(ctx));
		const uri = try std.Uri.parse(req.url);

		const method = try parseMethod(req.method);
		var request = try self.client.request(method, uri, .{
			.extra_headers = req.headers,
		});
		defer request.deinit();

		if (method.requestHasBody()) {
			const payload = try allocator.dupe(u8, req.body);
			defer allocator.free(payload);
			try request.sendBodyComplete(payload);
		} else {
			try request.sendBodiless();
		}
		var response = try request.receiveHead(&.{});

		var buffer: [8192]u8 = undefined;
		const reader = response.reader(&buffer);
		const body = try readAllAlloc(allocator, reader, 1024 * 1024);

		return .{ .status = @intFromEnum(response.head.status), .body = body };
	}
};

fn parseMethod(value: []const u8) !std.http.Method {
	if (std.mem.eql(u8, value, "POST")) return .POST;
	if (std.mem.eql(u8, value, "GET")) return .GET;
	return error.UnsupportedMethod;
}

fn readAllAlloc(allocator: std.mem.Allocator, reader: *std.Io.Reader, max_size: usize) ![]u8 {
	return reader.allocRemaining(allocator, .limited(max_size));
}

/// A mock transport for unit tests — returns canned responses based on URL path.
pub const MockTransportCtx = struct {	tags_body: []const u8,
	ps_body: []const u8,
	embed_should_fail: bool = false,
	status_override: ?u16 = null,
	auth_header_sent: bool = false,
	connection_close_sent: bool = false,

	pub fn send(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, req: HttpRequest) !HttpResponse {		const self: *MockTransportCtx = @ptrCast(@alignCast(ctx_ptr));
		for (req.headers) |h| {
			if (std.mem.eql(u8, h.name, "Authorization")) {
				self.auth_header_sent = true;
			} else if (std.ascii.eqlIgnoreCase(h.name, "Connection") and std.ascii.eqlIgnoreCase(h.value, "close")) {
				self.connection_close_sent = true;
			}
		}
		if (std.mem.endsWith(u8, req.url, "/api/tags")) {
			return .{ .status = 200, .body = try allocator.dupe(u8, self.tags_body) };
		}
		if (std.mem.endsWith(u8, req.url, "/api/ps")) {
			return .{ .status = 200, .body = try allocator.dupe(u8, self.ps_body) };
		}
		if (std.mem.endsWith(u8, req.url, "/api/embed")) {
			if (self.embed_should_fail) return error.ConnectionRefused;
			if (self.status_override) |status| {
				return .{ .status = status, .body = try allocator.dupe(u8, "{\"error\":\"unauthorized\"}") };
			}
			return .{ .status = 200, .body = try allocator.dupe(u8, "{\"embeddings\":[[0.1,0.2]]}") };
		}
		if (std.mem.endsWith(u8, req.url, "/v1/embeddings")) {
			if (self.embed_should_fail) return error.ConnectionRefused;
			if (self.status_override) |status| {
				return .{ .status = status, .body = try allocator.dupe(u8, "{\"error\":\"unauthorized\"}") };
			}
			return .{ .status = 200, .body = try allocator.dupe(u8,
				\\{"data":[{"embedding":[0.1,0.2],"index":0}],"model":"test"}
			) };
		}
		return error.UnsupportedMethod;
	}

	pub fn transport(self: *MockTransportCtx) Transport {		return .{ .ctx = self, .send = send };
	}
};

// ── Tests ────────────────────────────────────────────────────────────────────

test "buildEmbedUrl handles trailing slash" {
	const allocator = std.testing.allocator;
	const url = try buildEmbedUrl(allocator, "http://localhost:11434/", .ollama);
	defer allocator.free(url);
	try std.testing.expectEqualStrings("http://localhost:11434/api/embed", url);
}

test "buildEmbedUrl returns openai path for openai dialect" {
	const allocator = std.testing.allocator;
	const url = try buildEmbedUrl(allocator, "https://api.openai.com", .openai);
	defer allocator.free(url);
	try std.testing.expectEqualStrings("https://api.openai.com/v1/embeddings", url);
}

test "buildEmbedRequest serializes inputs" {
	const allocator = std.testing.allocator;
	const inputs = [_][]const u8{ "hello", "world" };
	const body = try buildEmbedRequest(allocator, "bge-large", &inputs, null, .ollama);
	defer allocator.free(body);
	try std.testing.expectEqualStrings("{\"model\":\"bge-large\",\"input\":[\"hello\",\"world\"]}", body);
}

test "buildEmbedRequest includes keep_alive for ollama dialect" {
	const allocator = std.testing.allocator;
	const inputs = [_][]const u8{"hello"};
	const body = try buildEmbedRequest(allocator, "bge-large", &inputs, -1, .ollama);
	defer allocator.free(body);
	try std.testing.expectEqualStrings("{\"model\":\"bge-large\",\"input\":[\"hello\"],\"keep_alive\":-1}", body);
}

test "buildEmbedRequest omits keep_alive for openai dialect" {
	const allocator = std.testing.allocator;
	const inputs = [_][]const u8{"hello"};
	// Pass keep_alive=-1 but expect it to be suppressed for openai dialect
	const body = try buildEmbedRequest(allocator, "text-embedding-3-small", &inputs, -1, .openai);
	defer allocator.free(body);
	// keep_alive must NOT appear in output
	try std.testing.expectEqualStrings("{\"model\":\"text-embedding-3-small\",\"input\":[\"hello\"]}", body);
}

test "parseEmbeddings reads vectors" {
	const allocator = std.testing.allocator;
	const body = "{\"embeddings\":[[0.1,0.2],[1,2]]}";
	const embeddings = try parseEmbeddings(allocator, body, .ollama);
	defer freeEmbeddings(allocator, embeddings);
	try std.testing.expectEqual(@as(usize, 2), embeddings.len);
	try std.testing.expectEqual(@as(usize, 2), embeddings[0].len);
	try std.testing.expectApproxEqAbs(@as(f32, 0.1), embeddings[0][0], 0.0001);
	try std.testing.expectEqual(@as(f32, 2), embeddings[1][1]);
}

test "parseEmbeddings reads openai format" {
	const allocator = std.testing.allocator;
	const body =
		\\{"data":[{"embedding":[0.1,0.2],"index":0}],"model":"test"}
	;
	const embeddings = try parseEmbeddings(allocator, body, .openai);
	defer freeEmbeddings(allocator, embeddings);
	try std.testing.expectEqual(@as(usize, 1), embeddings.len);
	try std.testing.expectEqual(@as(usize, 2), embeddings[0].len);
	try std.testing.expectApproxEqAbs(@as(f32, 0.1), embeddings[0][0], 0.0001);
	try std.testing.expectApproxEqAbs(@as(f32, 0.2), embeddings[0][1], 0.0001);
}

test "parseEmbeddings reads openai format sorted by index" {
	const allocator = std.testing.allocator;
	// index 1 comes before index 0 in the JSON array — result must be sorted
	const body =
		\\{"data":[{"embedding":[9.0,8.0],"index":1},{"embedding":[1.0,2.0],"index":0}],"model":"test"}
	;
	const embeddings = try parseEmbeddings(allocator, body, .openai);
	defer freeEmbeddings(allocator, embeddings);
	try std.testing.expectEqual(@as(usize, 2), embeddings.len);
	// index 0 => [1.0, 2.0]
	try std.testing.expectApproxEqAbs(@as(f32, 1.0), embeddings[0][0], 0.0001);
	try std.testing.expectApproxEqAbs(@as(f32, 2.0), embeddings[0][1], 0.0001);
	// index 1 => [9.0, 8.0]
	try std.testing.expectApproxEqAbs(@as(f32, 9.0), embeddings[1][0], 0.0001);
	try std.testing.expectApproxEqAbs(@as(f32, 8.0), embeddings[1][1], 0.0001);
}

test "ensureModelAvailable is no-op for openai dialect" {
	const allocator = std.testing.allocator;
	// tags_body and ps_body contain invalid JSON — if we tried to parse them the test would fail
	var mock = MockTransportCtx{
		.tags_body = "NOT_VALID_JSON",
		.ps_body = "NOT_VALID_JSON",
	};
	// Should return immediately without touching the network
	try ensureModelAvailable(allocator, mock.transport(), "https://api.openai.com", "text-embedding-3-small", .openai);
}

test "embed with openai dialect returns correct embeddings" {
	const allocator = std.testing.allocator;
	var mock = MockTransportCtx{
		.tags_body = "",
		.ps_body = "",
	};
	const inputs = [_][]const u8{"hello"};
	const embeddings = try embed(allocator, mock.transport(), "https://api.openai.com", "text-embedding-3-small", &inputs, null, .openai, null);
	defer freeEmbeddings(allocator, embeddings);
	try std.testing.expectEqual(@as(usize, 1), embeddings.len);
	try std.testing.expectEqual(@as(usize, 2), embeddings[0].len);
	try std.testing.expectApproxEqAbs(@as(f32, 0.1), embeddings[0][0], 0.0001);
	try std.testing.expectApproxEqAbs(@as(f32, 0.2), embeddings[0][1], 0.0001);
}

test "embed returns Unauthorized on 401" {
	const allocator = std.testing.allocator;
	var mock = MockTransportCtx{
		.tags_body = "",
		.ps_body = "",
		.status_override = 401,
	};
	const inputs = [_][]const u8{"hello"};
	try std.testing.expectError(
		error.Unauthorized,
		embed(allocator, mock.transport(), "https://api.openai.com", "text-embedding-3-small", &inputs, null, .openai, "Bearer bad-key"),
	);
}

test "embed with ollama dialect does not send auth header" {
	const allocator = std.testing.allocator;
	var mock = MockTransportCtx{
		.tags_body = "",
		.ps_body = "",
	};
	const inputs = [_][]const u8{"hello"};
	const embeddings = try embed(allocator, mock.transport(), "http://localhost:11434", "bge-large", &inputs, null, .ollama, "Bearer should-be-ignored");
	defer freeEmbeddings(allocator, embeddings);
	try std.testing.expect(!mock.auth_header_sent);
}

test "embed sends Connection: close to force fresh TCP connections" {
	const allocator = std.testing.allocator;
	var mock = MockTransportCtx{
		.tags_body = "",
		.ps_body = "",
	};
	const inputs = [_][]const u8{"hello"};
	const embeddings = try embed(allocator, mock.transport(), "http://localhost:11434", "bge-large", &inputs, null, .ollama, null);
	defer freeEmbeddings(allocator, embeddings);
	try std.testing.expect(mock.connection_close_sent);
}

test "ensureModelAvailable reports missing model" {
	const allocator = std.testing.allocator;
	try skipIfNoOllama(allocator);

	var transport = StdHttpTransport.init(allocator);
	defer transport.deinit();

	const url = try envOrDefault(allocator, "OLLAMA_URL", "http://localhost:11434");
	defer allocator.free(url);

	try std.testing.expectError(
		error.ModelNotFound,
		ensureModelAvailable(allocator, transport.transport(), url, "codescan-does-not-exist", .ollama),
	);
}

test "embed uses live Ollama" {
	const allocator = std.testing.allocator;
	try skipIfNoOllama(allocator);

	var transport = StdHttpTransport.init(allocator);
	defer transport.deinit();

	const url = try envOrDefault(allocator, "OLLAMA_URL", "http://localhost:11434");
	defer allocator.free(url);
	const model = try envOrDefault(allocator, "OLLAMA_MODEL", "bge-large");
	defer allocator.free(model);

	ensureModelAvailable(allocator, transport.transport(), url, model, .ollama) catch |err| switch (err) {
		error.ModelLoading => {}, // Model exists, embed will trigger loading
		else => return err,
	};

	const inputs = [_][]const u8{ "hash functions" };
	const embeddings = try embed(allocator, transport.transport(), url, model, &inputs, null, .ollama, null);
	defer freeEmbeddings(allocator, embeddings);
	try std.testing.expect(embeddings.len == 1);
	try std.testing.expect(embeddings[0].len > 0);
}

fn envOrDefault(allocator: std.mem.Allocator, key: []const u8, fallback: []const u8) ![]u8 {
	const value = io_singleton.getEnvVarOwned(allocator, key) catch |err| switch (err) {
		error.EnvironmentVariableNotFound => return allocator.dupe(u8, fallback),
		else => return err,
	};
	return value;
}

test "isModelLoaded returns true when model is in ps" {
	const allocator = std.testing.allocator;
	var mock = MockTransportCtx{
		.tags_body = "",
		.ps_body =
		\\{"models":[{"name":"bge-large:latest","model":"bge-large:latest","size":1234}]}
		,
	};
	const loaded = try isModelLoaded(allocator, mock.transport(), "http://localhost:11434", "bge-large");
	try std.testing.expect(loaded);
}

test "isModelLoaded returns false when model is not in ps" {
	const allocator = std.testing.allocator;
	var mock = MockTransportCtx{
		.tags_body = "",
		.ps_body =
		\\{"models":[{"name":"other-model:latest","model":"other-model:latest","size":1234}]}
		,
	};
	const loaded = try isModelLoaded(allocator, mock.transport(), "http://localhost:11434", "bge-large");
	try std.testing.expect(!loaded);
}

test "isModelLoaded returns false on empty ps" {
	const allocator = std.testing.allocator;
	var mock = MockTransportCtx{
		.tags_body = "",
		.ps_body =
		\\{"models":[]}
		,
	};
	const loaded = try isModelLoaded(allocator, mock.transport(), "http://localhost:11434", "bge-large");
	try std.testing.expect(!loaded);
}

test "ensureModelAvailable returns ModelNotFound when not in tags" {
	const allocator = std.testing.allocator;
	var mock = MockTransportCtx{
		.tags_body =
		\\{"models":[{"name":"other-model:latest"}]}
		,
		.ps_body =
		\\{"models":[]}
		,
	};
	try std.testing.expectError(
		error.ModelNotFound,
		ensureModelAvailable(allocator, mock.transport(), "http://localhost:11434", "bge-large", .ollama),
	);
}

test "ensureModelAvailable succeeds when model is loaded in ps" {
	const allocator = std.testing.allocator;
	var mock = MockTransportCtx{
		.tags_body =
		\\{"models":[{"name":"bge-large:latest"}]}
		,
		.ps_body =
		\\{"models":[{"name":"bge-large:latest"}]}
		,
	};
	try ensureModelAvailable(allocator, mock.transport(), "http://localhost:11434", "bge-large", .ollama);
}

test "ensureModelAvailable returns ModelLoading when in tags but not ps and embed fails" {
	const allocator = std.testing.allocator;
	var mock = MockTransportCtx{
		.tags_body =
		\\{"models":[{"name":"bge-large:latest"}]}
		,
		.ps_body =
		\\{"models":[]}
		,
		.embed_should_fail = true,
	};
	try std.testing.expectError(
		error.ModelLoading,
		ensureModelAvailable(allocator, mock.transport(), "http://localhost:11434", "bge-large", .ollama),
	);
}

test "ensureModelAvailable returns ModelLoading when in tags but not ps" {
	const allocator = std.testing.allocator;
	var mock = MockTransportCtx{
		.tags_body =
		\\{"models":[{"name":"bge-large:latest"}]}
		,
		.ps_body =
		\\{"models":[]}
		,
		.embed_should_fail = false,
	};
	try std.testing.expectError(
		error.ModelLoading,
		ensureModelAvailable(allocator, mock.transport(), "http://localhost:11434", "bge-large", .ollama),
	);
}

test "buildPsUrl handles trailing slash" {
	const allocator = std.testing.allocator;
	const url = try buildPsUrl(allocator, "http://localhost:11434/");
	defer allocator.free(url);
	try std.testing.expectEqualStrings("http://localhost:11434/api/ps", url);
}

/// Skip test if Ollama is not reachable (for CI environments without Ollama).
pub fn skipIfNoOllama(allocator: std.mem.Allocator) !void {
	const url = try envOrDefault(allocator, "OLLAMA_URL", "http://localhost:11434");
	defer allocator.free(url);

	var transport = StdHttpTransport.init(allocator);
	defer transport.deinit();

	// Try a lightweight request via the Transport interface — if connection refused, skip.
	const t = transport.transport();
	const resp = t.send(t.ctx, allocator, .{
		.method = "GET",
		.url = url,
		.headers = &.{},
		.body = "",
	}) catch return error.SkipZigTest;
	allocator.free(resp.body);
}
