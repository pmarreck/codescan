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
) ![][]f32 {
	const url = try buildEmbedUrl(allocator, base_url);
	defer allocator.free(url);
	const body = try buildEmbedRequest(allocator, model, inputs);
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

pub fn buildEmbedRequest(
	allocator: std.mem.Allocator,
	model: []const u8,
	inputs: []const []const u8,
) ![]u8 {
	const payload = EmbedRequest{ .model = model, .input = inputs };
	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	var stream: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
	try stream.write(payload);
	return out.toOwnedSlice();
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

		var request = try self.client.request(.POST, uri, .{
			.extra_headers = req.headers,
		});
		defer request.deinit();

		try request.sendBodyComplete(req.body);
		var response = try request.receiveHead(&.{});

		var buffer: [8192]u8 = undefined;
		const reader = response.reader(&buffer);
		const body = try reader.readAllAlloc(allocator, 1024 * 1024);

		return .{ .status = @intFromEnum(response.head.status), .body = body };
	}
};

test "buildEmbedUrl handles trailing slash" {
	const allocator = std.testing.allocator;
	const url = try buildEmbedUrl(allocator, "http://localhost:11434/");
	defer allocator.free(url);
	try std.testing.expectEqualStrings("http://localhost:11434/api/embed", url);
}

test "buildEmbedRequest serializes inputs" {
	const allocator = std.testing.allocator;
	const inputs = [_][]const u8{ "hello", "world" };
	const body = try buildEmbedRequest(allocator, "bge-large", &inputs);
	defer allocator.free(body);
	try std.testing.expectEqualStrings("{\"model\":\"bge-large\",\"input\":[\"hello\",\"world\"]}", body);
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

test "embed builds request and parses response" {
	const allocator = std.testing.allocator;

	const inputs = [_][]const u8{ "hash functions" };
	const expected_body = "{\"model\":\"bge-large\",\"input\":[\"hash functions\"]}";
	const response_body = "{\"embeddings\":[[0.3,0.4]]}";

	var fake = FakeTransport{
		.expected_url = "http://localhost:11434/api/embed",
		.expected_body = expected_body,
		.response_body = response_body,
	};

	const embeddings = try embed(allocator, fake.transport(), "http://localhost:11434", "bge-large", &inputs);
	defer freeEmbeddings(allocator, embeddings);
	try std.testing.expectEqual(@as(usize, 1), embeddings.len);
	try std.testing.expectEqual(@as(usize, 2), embeddings[0].len);
	try std.testing.expectApproxEqAbs(@as(f32, 0.3), embeddings[0][0], 0.0001);
}

const FakeTransport = struct {
	expected_url: []const u8,
	expected_body: []const u8,
	response_body: []const u8,

	pub fn transport(self: *FakeTransport) Transport {
		return .{ .ctx = self, .send = send };
	}

	fn send(ctx: *anyopaque, allocator: std.mem.Allocator, req: HttpRequest) !HttpResponse {
		const self: *FakeTransport = @ptrCast(@alignCast(ctx));
		try std.testing.expectEqualStrings(self.expected_url, req.url);
		try std.testing.expectEqualStrings(self.expected_body, req.body);
		try std.testing.expectEqualStrings("POST", req.method);
		try std.testing.expectEqual(@as(usize, 2), req.headers.len);
		const body = try allocator.dupe(u8, self.response_body);
		return .{ .status = 200, .body = body };
	}
};
