const std = @import("std");
const storage = @import("storage.zig");
const embedding = @import("embedding.zig");
const indexer = @import("indexer.zig");
const search = @import("search.zig");
const output = @import("output.zig");
const plugin = @import("plugin.zig");
const ollama = @import("ollama.zig");
const config = @import("config.zig");
const filters = @import("filters.zig");

pub const Settings = struct {
	root_path: []const u8,
	db_path: []const u8,
	embedding_dim: usize,
	batch_size: usize,
	max_file_size: usize,
	ollama_url: []const u8,
	ollama_model: []const u8,
	index_ext: ?[]const u8,
	index_type: ?[]const u8,
	search_ext: ?[]const u8,
	search_type: ?[]const u8,
	search_lang: ?[]const u8,
	primary_lang: ?[]const u8,
	include_docs: bool,
	docs_only: bool,
	comments_only: bool,
	search_top_n: usize,
	search_mode: search.SearchMode,
	search_weight_vector: f32,
	search_weight_lexical: f32,
	search_min_score: f32,
	ignore_global: []const []const u8,
	ignore_lang: []const config.IgnoreOverride,
	include_node_modules: bool,
	http_host: []const u8,
	http_port: u16,
};

pub fn serve(allocator: std.mem.Allocator, settings: Settings) !void {
	try ensureParentDir(settings.db_path);
	const db = try storage.openFileWithVec(allocator, settings.db_path);
	defer storage.close(db);

	var http_client = ollama.StdHttpTransport.init(allocator);
	defer http_client.deinit();
	try ensureModelAvailableOrExit(allocator, http_client.transport(), settings.ollama_url, settings.ollama_model);

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

fn ensureModelAvailableOrExit(
	allocator: std.mem.Allocator,
	transport: ollama.Transport,
	base_url: []const u8,
	model_name: []const u8,
) !void {
	ollama.ensureModelAvailable(allocator, transport, base_url, model_name) catch |err| switch (err) {
		error.ModelNotFound => {
			var stderr_buf: [4096]u8 = undefined;
			var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
			const stderr = &stderr_writer.interface;
			_ = stderr.print(
				"error: Ollama model '{s}' not found. Run: ollama pull {s}\n",
				.{ model_name, model_name },
			) catch {};
			_ = stderr.flush() catch {};
			std.process.exit(1);
		},
		else => return err,
	};
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
	if (req.head.method == .GET and std.mem.eql(u8, path, "/help")) {
		try respondText(req, help_text);
		return;
	}

	if (req.head.method == .POST and std.mem.eql(u8, path, "/search")) {
		const body = try readBody(allocator, req, 1024 * 1024);
		defer allocator.free(body);

		var parsed = try parseSearchRequest(allocator, body);
		defer parsed.deinit(allocator);

		var search_filters = try filters.buildSearchFilters(allocator, plugin.defaultRegistry(), db, .{
			.search_ext = parsed.ext orelse settings.search_ext,
			.search_type = parsed.type orelse settings.search_type,
			.search_lang = parsed.lang orelse settings.search_lang,
			.primary_lang = settings.primary_lang,
			.include_docs = parsed.include_docs orelse settings.include_docs,
			.docs_only = parsed.docs_only orelse settings.docs_only,
		});
		defer search_filters.deinit(allocator);

		const results = try search.search(allocator, db, embedder, parsed.query, .{
			.top_n = parsed.top_n orelse settings.search_top_n,
			.mode = parsed.mode orelse settings.search_mode,
			.weight_vector = parsed.weight_vector orelse settings.search_weight_vector,
			.weight_lexical = parsed.weight_lexical orelse settings.search_weight_lexical,
			.min_score = parsed.min_score orelse settings.search_min_score,
			.allowed_langs = search_filters.langs.items,
			.allowed_exts = search_filters.exts.items,
			.comments_only = parsed.comments_only orelse settings.comments_only,
		});
		defer search.freeResults(allocator, results);

		var out: std.io.Writer.Allocating = .init(allocator);
		defer out.deinit();
		try output.writeResults(allocator, &out.writer, .json, results, .{
			.show_comments = false,
			.use_color = false,
		});
		const payload = try out.toOwnedSlice();
		defer allocator.free(payload);

		try respondJson(req, payload);
		return;
	}

	if (req.head.method == .POST and (std.mem.eql(u8, path, "/index") or std.mem.eql(u8, path, "/update"))) {
		const body = try readBody(allocator, req, 1024 * 1024);
		defer allocator.free(body);
		var parsed = try parseIndexRequest(allocator, body);
		defer parsed.deinit(allocator);

		var index_filters = try filters.buildIndexFilters(
			allocator,
			parsed.ext orelse settings.index_ext,
			parsed.type orelse settings.index_type,
		);
		defer index_filters.deinit(allocator);

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
				.allowed_exts = index_filters.exts.items,
				.allowed_kinds = index_filters.kinds.items,
				.ignore = .{
					.global = settings.ignore_global,
					.per_language = settings.ignore_lang,
					.include_node_modules = parsed.include_node_modules orelse settings.include_node_modules,
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

fn respondText(req: *std.http.Server.Request, body: []const u8) !void {
	const headers = [_]std.http.Header{
		.{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
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
	ext: ?[]const u8 = null,
	type: ?[]const u8 = null,
	lang: ?[]const u8 = null,
	include_docs: ?bool = null,
	docs_only: ?bool = null,
	comments_only: ?bool = null,

	pub fn deinit(self: *SearchRequest, allocator: std.mem.Allocator) void {
		allocator.free(self.query);
		if (self.ext) |value| allocator.free(value);
		if (self.type) |value| allocator.free(value);
		if (self.lang) |value| allocator.free(value);
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

	if (obj.get("ext")) |ext_val| {
		req.ext = try parseStringOrArray(allocator, ext_val);
	}
	if (obj.get("type")) |type_val| {
		req.type = try parseStringOrArray(allocator, type_val);
	}
	if (obj.get("lang")) |lang_val| {
		req.lang = try parseStringOrArray(allocator, lang_val);
	}

	if (obj.get("include_docs")) |flag| {
		if (flag != .bool) return error.InvalidDocsFlag;
		req.include_docs = flag.bool;
	}
	if (obj.get("docs")) |flag| {
		if (flag != .bool) return error.InvalidDocsFlag;
		req.docs_only = flag.bool;
	}
	if (obj.get("only_docs")) |flag| {
		if (flag != .bool) return error.InvalidDocsFlag;
		req.docs_only = flag.bool;
	}
	if (obj.get("docs_only")) |flag| {
		if (flag != .bool) return error.InvalidDocsFlag;
		req.docs_only = flag.bool;
	}
	if (obj.get("comments")) |flag| {
		if (flag != .bool) return error.InvalidCommentsFlag;
		req.comments_only = flag.bool;
	}
	if (obj.get("only_comments")) |flag| {
		if (flag != .bool) return error.InvalidCommentsFlag;
		req.comments_only = flag.bool;
	}
	if (obj.get("comments_only")) |flag| {
		if (flag != .bool) return error.InvalidCommentsFlag;
		req.comments_only = flag.bool;
	}

	return req;
}

pub const IndexRequest = struct {
	ext: ?[]const u8 = null,
	type: ?[]const u8 = null,
	include_node_modules: ?bool = null,

	pub fn deinit(self: *IndexRequest, allocator: std.mem.Allocator) void {
		if (self.ext) |value| allocator.free(value);
		if (self.type) |value| allocator.free(value);
		self.* = undefined;
	}
};

pub fn parseIndexRequest(allocator: std.mem.Allocator, body: []const u8) !IndexRequest {
	if (body.len == 0) return IndexRequest{};
	var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
	defer parsed.deinit();
	if (parsed.value != .object) return error.InvalidRequest;
	const obj = parsed.value.object;

	var req = IndexRequest{};
	if (obj.get("ext")) |ext_val| {
		req.ext = try parseStringOrArray(allocator, ext_val);
	}
	if (obj.get("type")) |type_val| {
		req.type = try parseStringOrArray(allocator, type_val);
	}
	if (obj.get("include_node_modules")) |flag| {
		if (flag != .bool) return error.InvalidIncludeNodeModules;
		req.include_node_modules = flag.bool;
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

fn parseStringOrArray(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
	switch (value) {
		.string => |str| return allocator.dupe(u8, str),
		.array => |arr| {
			var out = std.ArrayListUnmanaged(u8){};
			errdefer out.deinit(allocator);
			for (arr.items, 0..) |item, idx| {
				if (item != .string) return error.InvalidFilterValue;
				if (idx > 0) try out.append(allocator, ',');
				try out.appendSlice(allocator, item.string);
			}
			return out.toOwnedSlice(allocator);
		},
		else => return error.InvalidFilterValue,
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
	const body = "{\"query\":\"hash functions\",\"top_n\":5,\"mode\":\"vector\",\"weight_vector\":0.8,\"weight_lexical\":0.2,\"min_score\":0.4,\"ext\":\"zig,md\",\"type\":[\"code\",\"doc\"],\"lang\":\"zig\",\"include_docs\":true,\"docs\":false,\"comments\":true}";
	var req = try parseSearchRequest(allocator, body);
	defer req.deinit(allocator);
	try std.testing.expectEqualStrings("hash functions", req.query);
	try std.testing.expectEqual(@as(usize, 5), req.top_n.?);
	try std.testing.expectEqual(search.SearchMode.vector, req.mode.?);
	try std.testing.expectApproxEqAbs(@as(f32, 0.8), req.weight_vector.?, 0.0001);
	try std.testing.expectApproxEqAbs(@as(f32, 0.2), req.weight_lexical.?, 0.0001);
	try std.testing.expectApproxEqAbs(@as(f32, 0.4), req.min_score.?, 0.0001);
	try std.testing.expectEqualStrings("zig,md", req.ext.?);
	try std.testing.expectEqualStrings("code,doc", req.type.?);
	try std.testing.expectEqualStrings("zig", req.lang.?);
	try std.testing.expectEqual(true, req.include_docs.?);
	try std.testing.expectEqual(false, req.docs_only.?);
	try std.testing.expectEqual(true, req.comments_only.?);
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
	try std.testing.expect(req.ext == null);
	try std.testing.expect(req.type == null);
	try std.testing.expect(req.lang == null);
	try std.testing.expect(req.include_docs == null);
	try std.testing.expect(req.docs_only == null);
	try std.testing.expect(req.comments_only == null);
}

test "parseIndexRequest reads fields" {
	const allocator = std.testing.allocator;
	const body = "{\"ext\":[\"zig\"],\"type\":\"code\",\"include_node_modules\":true}";
	var req = try parseIndexRequest(allocator, body);
	defer req.deinit(allocator);
	try std.testing.expectEqualStrings("zig", req.ext.?);
	try std.testing.expectEqualStrings("code", req.type.?);
	try std.testing.expectEqual(true, req.include_node_modules.?);
}

test "handleRequest responds to /health" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	var fake = FakeEmbedder{};

	const request_bytes = "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n";
	var reader = std.Io.Reader.fixed(request_bytes);
	var out_buf: [512]u8 = undefined;
	var writer = std.Io.Writer.fixed(&out_buf);
	var http_server = std.http.Server.init(&reader, &writer);

	var req = try http_server.receiveHead();
	try handleRequest(allocator, &req, db, fake.embedder(), testSettings());

	const response = std.Io.Writer.buffered(&writer);
	try std.testing.expect(std.mem.indexOf(u8, response, "200 OK") != null);
	try std.testing.expect(std.mem.indexOf(u8, response, "Content-Type: application/json") != null);
	try std.testing.expect(std.mem.indexOf(u8, response, "\"status\":\"ok\"") != null);
}

test "handleRequest responds to /help" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	var fake = FakeEmbedder{};

	const request_bytes = "GET /help HTTP/1.1\r\nHost: localhost\r\n\r\n";
	var reader = std.Io.Reader.fixed(request_bytes);
	var out_buf: [512]u8 = undefined;
	var writer = std.Io.Writer.fixed(&out_buf);
	var http_server = std.http.Server.init(&reader, &writer);

	var req = try http_server.receiveHead();
	try handleRequest(allocator, &req, db, fake.embedder(), testSettings());

	const response = std.Io.Writer.buffered(&writer);
	try std.testing.expect(std.mem.indexOf(u8, response, "200 OK") != null);
	try std.testing.expect(std.mem.indexOf(u8, response, "show-comments") != null);
	try std.testing.expect(std.mem.indexOf(u8, response, "default: hidden") != null);
}

const FakeEmbedder = struct {
	pub fn embedder(self: *FakeEmbedder) embedding.Embedder {
		return .{
			.ctx = self,
			.embed = embed,
			.free = free,
		};
	}

	fn embed(ctx: *anyopaque, allocator: std.mem.Allocator, inputs: []const []const u8) ![][]f32 {
		_ = ctx;
		_ = allocator;
		_ = inputs;
		return error.UnexpectedEmbed;
	}

	fn free(ctx: *anyopaque, allocator: std.mem.Allocator, embeddings: [][]f32) void {
		_ = ctx;
		_ = allocator;
		_ = embeddings;
	}
};

fn testSettings() Settings {
	return .{
		.root_path = ".",
		.db_path = ":memory:",
		.embedding_dim = 8,
		.batch_size = 1,
		.max_file_size = 1024,
		.ollama_url = "http://localhost:11434",
		.ollama_model = "bge-large",
		.index_ext = null,
		.index_type = null,
		.search_ext = null,
		.search_type = null,
		.search_lang = null,
		.primary_lang = null,
		.include_docs = false,
		.docs_only = false,
		.comments_only = false,
		.search_top_n = 5,
		.search_mode = .vector,
		.search_weight_vector = 1.0,
		.search_weight_lexical = 0.0,
		.search_min_score = 0.0,
		.ignore_global = &[_][]const u8{},
		.ignore_lang = &[_]config.IgnoreOverride{},
		.include_node_modules = false,
		.http_host = "127.0.0.1",
		.http_port = 0,
	};
}

const help_text =
	"codescan http api\n" ++
	"\n" ++
	"POST /search\n" ++
	"  fields: query, top_n, mode, weight_vector, weight_lexical, min_score\n" ++
	"          ext, type, lang, include_docs, docs/only_docs, comments/only_comments\n" ++
	"\n" ++
	"POST /index\n" ++
	"  fields: ext, type, include_node_modules\n" ++
	"\n" ++
	"GET /health\n" ++
	"GET /help\n" ++
	"\n" ++
	"cli note: --show-comments/--verbose shows doc comments in human output (default: hidden)\n";
