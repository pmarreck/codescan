const std = @import("std");
const storage = @import("storage.zig");
const embedding = @import("embedding.zig");
const indexer = @import("indexer.zig");
const search = @import("search.zig");
const output = @import("output.zig");
const plugin = @import("plugin.zig");
const ollama = @import("ollama.zig");
const config = @import("config.zig");

pub const Settings = struct {
	root_path: []const u8,
	db_path: []const u8,
	embedding_dim: usize,
	batch_size: usize,
	max_file_size: usize,
	ollama_url: []const u8,
	ollama_model: []const u8,
	search_top_n: usize,
	search_mode: search.SearchMode,
	search_weight_vector: f32,
	search_weight_lexical: f32,
	search_min_score: f32,
	ignore_global: []const []const u8,
	ignore_lang: []const config.IgnoreOverride,
	http_host: []const u8,
	http_port: u16,
};

pub fn serve(allocator: std.mem.Allocator, settings: Settings) !void {
	try ensureParentDir(settings.db_path);
	const db = try storage.openFileWithVec(allocator, settings.db_path);
	defer storage.close(db);

	var http_client = ollama.StdHttpTransport.init(allocator);
	defer http_client.deinit();

	var embedder_adapter = embedding.OllamaEmbedder{
		.transport = http_client.transport(),
		.base_url = settings.ollama_url,
		.model = settings.ollama_model,
	};

	const address = try parseAddress(settings.http_host, settings.http_port);
	var listener = try std.net.Address.listen(address, .{ .reuse_address = true });
	defer listener.deinit();

	while (true) {
		var conn = try listener.accept();
		defer conn.stream.close();

		var in_buf: [16 * 1024]u8 = undefined;
		var out_buf: [16 * 1024]u8 = undefined;
		var in_reader = conn.stream.reader(&in_buf);
		var out_writer = conn.stream.writer(&out_buf);
		var http_server = std.http.Server.init(in_reader.interface(), &out_writer.interface);

		while (true) {
			var req = http_server.receiveHead() catch break;
			try handleRequest(
				allocator,
				&req,
				db,
				embedder_adapter.embedder(),
				settings,
			);
		}
	}
}

fn handleRequest(
	allocator: std.mem.Allocator,
	req: *std.http.Server.Request,
	db: storage.Db,
	embedder: embedding.Embedder,
	settings: Settings,
) !void {
	const path = stripQuery(req.head.target);
	if (req.head.method == .GET and std.mem.eql(u8, path, "/health")) {
		try respondJson(req, "{\"status\":\"ok\"}");
		return;
	}

	if (req.head.method == .POST and std.mem.eql(u8, path, "/search")) {
		const body = try readBody(allocator, req, 1024 * 1024);
		defer allocator.free(body);

		var parsed = try parseSearchRequest(allocator, body);
		defer parsed.deinit(allocator);

		const results = try search.search(allocator, db, embedder, parsed.query, .{
			.top_n = parsed.top_n orelse settings.search_top_n,
			.mode = parsed.mode orelse settings.search_mode,
			.weight_vector = parsed.weight_vector orelse settings.search_weight_vector,
			.weight_lexical = parsed.weight_lexical orelse settings.search_weight_lexical,
			.min_score = parsed.min_score orelse settings.search_min_score,
		});
		defer search.freeResults(allocator, results);

		var out: std.io.Writer.Allocating = .init(allocator);
		defer out.deinit();
		try output.writeResults(allocator, &out.writer, .json, results);
		const payload = try out.toOwnedSlice();
		defer allocator.free(payload);

		try respondJson(req, payload);
		return;
	}

	if (req.head.method == .POST and (std.mem.eql(u8, path, "/index") or std.mem.eql(u8, path, "/update"))) {
		const stats = try indexer.indexAll(
			allocator,
			db,
			settings.root_path,
			plugin.defaultRegistry(),
			embedder,
			.{
				.embedding_dim = settings.embedding_dim,
				.batch_size = settings.batch_size,
				.max_file_size = settings.max_file_size,
				.ignore = .{
					.global = settings.ignore_global,
					.per_language = settings.ignore_lang,
				},
			},
		);

		var out: std.io.Writer.Allocating = .init(allocator);
		defer out.deinit();
		try out.writer.print(
			"{{\"status\":\"ok\",\"files\":{d},\"symbols\":{d}}}",
			.{ stats.files, stats.symbols },
		);
		const payload = try out.toOwnedSlice();
		defer allocator.free(payload);

		try respondJson(req, payload);
		return;
	}

	try req.respond("Not found\n", .{ .status = .not_found, .keep_alive = false });
}

fn respondJson(req: *std.http.Server.Request, body: []const u8) !void {
	const headers = [_]std.http.Header{
		.{ .name = "Content-Type", .value = "application/json" },
	};
	try req.respond(body, .{ .status = .ok, .extra_headers = &headers });
}

fn readBody(allocator: std.mem.Allocator, req: *std.http.Server.Request, max_size: usize) ![]u8 {
	var buffer: [8192]u8 = undefined;
	const reader = req.readerExpectNone(&buffer);
	return readAllAlloc(allocator, reader, max_size);
}

fn stripQuery(target: []const u8) []const u8 {
	if (std.mem.indexOfScalar(u8, target, '?')) |idx| {
		return target[0..idx];
	}
	return target;
}

fn ensureParentDir(path: []const u8) !void {
	const dir = std.fs.path.dirname(path) orelse return;
	try std.fs.cwd().makePath(dir);
}

fn parseAddress(host: []const u8, port: u16) !std.net.Address {
	if (std.mem.eql(u8, host, "localhost")) {
		return std.net.Address.parseIp("127.0.0.1", port);
	}
	return std.net.Address.parseIp(host, port);
}

pub const SearchRequest = struct {
	query: []const u8,
	top_n: ?usize = null,
	mode: ?search.SearchMode = null,
	weight_vector: ?f32 = null,
	weight_lexical: ?f32 = null,
	min_score: ?f32 = null,

	pub fn deinit(self: *SearchRequest, allocator: std.mem.Allocator) void {
		allocator.free(self.query);
		self.* = undefined;
	}
};

pub fn parseSearchRequest(allocator: std.mem.Allocator, body: []const u8) !SearchRequest {
	var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
	defer parsed.deinit();

	if (parsed.value != .object) return error.InvalidRequest;
	const obj = parsed.value.object;

	const query_value = obj.get("query") orelse return error.MissingQuery;
	if (query_value != .string) return error.InvalidQuery;

	var req = SearchRequest{
		.query = try allocator.dupe(u8, query_value.string),
	};

	if (obj.get("top_n")) |top| {
		if (top != .integer) return error.InvalidTopN;
		req.top_n = @as(usize, @intCast(top.integer));
	}

	if (obj.get("mode")) |mode| {
		if (mode != .string) return error.InvalidMode;
		req.mode = try parseMode(mode.string);
	}

	if (obj.get("weight_vector")) |weight| {
		req.weight_vector = try parseWeight(weight);
	}

	if (obj.get("weight_lexical")) |weight| {
		req.weight_lexical = try parseWeight(weight);
	}

	if (obj.get("min_score")) |min_score| {
		req.min_score = try parseWeight(min_score);
	}

	return req;
}

fn parseMode(value: []const u8) !search.SearchMode {
	if (std.mem.eql(u8, value, "vector")) return .vector;
	if (std.mem.eql(u8, value, "lexical")) return .lexical;
	if (std.mem.eql(u8, value, "hybrid")) return .hybrid;
	return error.InvalidMode;
}

fn parseWeight(value: std.json.Value) !f32 {
	switch (value) {
		.float => |val| return @floatCast(val),
		.integer => |val| return @floatFromInt(val),
		else => return error.InvalidWeight,
	}
}

fn readAllAlloc(allocator: std.mem.Allocator, reader: *std.Io.Reader, max_size: usize) ![]u8 {
	var out = std.ArrayListUnmanaged(u8){};
	errdefer out.deinit(allocator);

	var buf: [8192]u8 = undefined;
	while (true) {
		const n = try reader.readSliceShort(&buf);
		if (n == 0) break;
		if (out.items.len + n > max_size) return error.StreamTooLong;
		try out.appendSlice(allocator, buf[0..n]);
	}

	return out.toOwnedSlice(allocator);
}

test "parseSearchRequest reads fields" {
	const allocator = std.testing.allocator;
	const body = "{\"query\":\"hash functions\",\"top_n\":5,\"mode\":\"vector\",\"weight_vector\":0.8,\"weight_lexical\":0.2,\"min_score\":0.4}";
	var req = try parseSearchRequest(allocator, body);
	defer req.deinit(allocator);
	try std.testing.expectEqualStrings("hash functions", req.query);
	try std.testing.expectEqual(@as(usize, 5), req.top_n.?);
	try std.testing.expectEqual(search.SearchMode.vector, req.mode.?);
	try std.testing.expectApproxEqAbs(@as(f32, 0.8), req.weight_vector.?, 0.0001);
	try std.testing.expectApproxEqAbs(@as(f32, 0.2), req.weight_lexical.?, 0.0001);
	try std.testing.expectApproxEqAbs(@as(f32, 0.4), req.min_score.?, 0.0001);
}

test "parseSearchRequest defaults optional fields" {
	const allocator = std.testing.allocator;
	const body = "{\"query\":\"hash\"}";
	var req = try parseSearchRequest(allocator, body);
	defer req.deinit(allocator);
	try std.testing.expect(req.top_n == null);
	try std.testing.expect(req.mode == null);
	try std.testing.expect(req.weight_vector == null);
	try std.testing.expect(req.weight_lexical == null);
	try std.testing.expect(req.min_score == null);
}
