const std = @import("std");

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

pub fn embed(
	allocator: std.mem.Allocator,
	transport: Transport,
	base_url: []const u8,
	model: []const u8,
	inputs: []const []const u8,
	keep_alive: ?i64,
) ![][]f32 {
	const url = try buildEmbedUrl(allocator, base_url);
	defer allocator.free(url);
	const body = try buildEmbedRequest(allocator, model, inputs, keep_alive);
	defer allocator.free(body);

	const headers = [_]std.http.Header{
		.{ .name = "Content-Type", .value = "application/json" },
		.{ .name = "Accept", .value = "application/json" },
	};

	const response = try transport.send(transport.ctx, allocator, .{
		.method = "POST",
		.url = url,
		.headers = &headers,
		.body = body,
	});
	defer allocator.free(response.body);

	if (response.status != 200) return error.HttpStatus;
	return parseEmbeddings(allocator, response.body);
}

pub fn buildEmbedUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
	if (std.mem.endsWith(u8, base_url, "/")) {
		return std.fmt.allocPrint(allocator, "{s}api/embed", .{base_url});
	}
	return std.fmt.allocPrint(allocator, "{s}/api/embed", .{base_url});
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
) ![]u8 {
	const payload = EmbedRequest{ .model = model, .input = inputs, .keep_alive = keep_alive };
	var out: std.io.Writer.Allocating = .init(allocator);
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
) !void {
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

pub fn parseEmbeddings(allocator: std.mem.Allocator, body: []const u8) ![][]f32 {
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
		for (values, 0..) |value, col_idx| {
			vec[col_idx] = try parseNumber(value);
		}
		result[row_idx] = vec;
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

test "buildEmbedUrl handles trailing slash" {
	const allocator = std.testing.allocator;
	const url = try buildEmbedUrl(allocator, "http://localhost:11434/");
	defer allocator.free(url);
	try std.testing.expectEqualStrings("http://localhost:11434/api/embed", url);
}

test "buildEmbedRequest serializes inputs" {
	const allocator = std.testing.allocator;
	const inputs = [_][]const u8{ "hello", "world" };
	const body = try buildEmbedRequest(allocator, "bge-large", &inputs, null);
	defer allocator.free(body);
	try std.testing.expectEqualStrings("{\"model\":\"bge-large\",\"input\":[\"hello\",\"world\"]}", body);
}

test "buildEmbedRequest includes keep_alive when set" {
	const allocator = std.testing.allocator;
	const inputs = [_][]const u8{"hello"};
	const body = try buildEmbedRequest(allocator, "bge-large", &inputs, -1);
	defer allocator.free(body);
	try std.testing.expectEqualStrings("{\"model\":\"bge-large\",\"input\":[\"hello\"],\"keep_alive\":-1}", body);
}

test "parseEmbeddings reads vectors" {
	const allocator = std.testing.allocator;
	const body = "{\"embeddings\":[[0.1,0.2],[1,2]]}";
	const embeddings = try parseEmbeddings(allocator, body);
	defer freeEmbeddings(allocator, embeddings);
	try std.testing.expectEqual(@as(usize, 2), embeddings.len);
	try std.testing.expectEqual(@as(usize, 2), embeddings[0].len);
	try std.testing.expectApproxEqAbs(@as(f32, 0.1), embeddings[0][0], 0.0001);
	try std.testing.expectEqual(@as(f32, 2), embeddings[1][1]);
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
		ensureModelAvailable(allocator, transport.transport(), url, "codescan-does-not-exist"),
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

	ensureModelAvailable(allocator, transport.transport(), url, model) catch |err| switch (err) {
		error.ModelLoading => {}, // Model exists, embed will trigger loading
		else => return err,
	};

	const inputs = [_][]const u8{ "hash functions" };
	const embeddings = try embed(allocator, transport.transport(), url, model, &inputs, null);
	defer freeEmbeddings(allocator, embeddings);
	try std.testing.expect(embeddings.len == 1);
	try std.testing.expect(embeddings[0].len > 0);
}

fn envOrDefault(allocator: std.mem.Allocator, key: []const u8, fallback: []const u8) ![]u8 {
	const value = std.process.getEnvVarOwned(allocator, key) catch |err| switch (err) {
		error.EnvironmentVariableNotFound => return allocator.dupe(u8, fallback),
		else => return err,
	};
	return value;
}

/// A mock transport for unit tests — returns canned responses based on URL path.
const MockTransportCtx = struct {
	tags_body: []const u8,
	ps_body: []const u8,
	embed_should_fail: bool = false,

	fn send(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, req: HttpRequest) !HttpResponse {
		const self: *MockTransportCtx = @ptrCast(@alignCast(ctx_ptr));
		if (std.mem.endsWith(u8, req.url, "/api/tags")) {
			return .{ .status = 200, .body = try allocator.dupe(u8, self.tags_body) };
		}
		if (std.mem.endsWith(u8, req.url, "/api/ps")) {
			return .{ .status = 200, .body = try allocator.dupe(u8, self.ps_body) };
		}
		if (std.mem.endsWith(u8, req.url, "/api/embed")) {
			if (self.embed_should_fail) return error.ConnectionRefused;
			return .{ .status = 200, .body = try allocator.dupe(u8, "{\"embeddings\":[[0.1,0.2]]}") };
		}
		return error.UnsupportedMethod;
	}

	fn transport(self: *MockTransportCtx) Transport {
		return .{ .ctx = self, .send = send };
	}
};

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
		ensureModelAvailable(allocator, mock.transport(), "http://localhost:11434", "bge-large"),
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
	try ensureModelAvailable(allocator, mock.transport(), "http://localhost:11434", "bge-large");
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
		ensureModelAvailable(allocator, mock.transport(), "http://localhost:11434", "bge-large"),
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
		ensureModelAvailable(allocator, mock.transport(), "http://localhost:11434", "bge-large"),
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
