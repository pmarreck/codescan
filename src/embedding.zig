const std = @import("std");
const embedding_http = @import("embedding_http.zig");

pub const Embedder = struct {
	ctx: *anyopaque,
	embed: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, inputs: []const []const u8) anyerror![][]f32,
	free: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, embeddings: [][]f32) void,
};

pub const HttpEmbedder = struct {
	transport: embedding_http.Transport,
	base_url: []const u8,
	model: []const u8,
	keep_alive: ?i64 = 900, // 15 minutes in seconds
	dialect: embedding_http.ApiDialect = .ollama,
	auth_header: ?[]const u8 = null,

	pub fn embedder(self: *HttpEmbedder) Embedder {
		return .{
			.ctx = self,
			.embed = embed_fn,
			.free = free_fn,
		};
	}

	fn embed_fn(ctx: *anyopaque, allocator: std.mem.Allocator, inputs: []const []const u8) ![][]f32 {
		const self: *HttpEmbedder = @ptrCast(@alignCast(ctx));
		return embedding_http.embed(allocator, self.transport, self.base_url, self.model, inputs, self.keep_alive, self.dialect, self.auth_header);
	}

	fn free_fn(ctx: *anyopaque, allocator: std.mem.Allocator, embeddings: [][]f32) void {
		_ = ctx;
		embedding_http.freeEmbeddings(allocator, embeddings);
	}
};
pub const NullEmbedder = struct {
	pub fn embedder() Embedder {
		return .{ .ctx = @ptrFromInt(1), .embed = embed_fn, .free = free_fn };
	}

	fn embed_fn(_: *anyopaque, allocator: std.mem.Allocator, _: []const []const u8) ![][]f32 {
		return try allocator.alloc([]f32, 0);
	}

	fn free_fn(_: *anyopaque, allocator: std.mem.Allocator, embeddings: [][]f32) void {
		allocator.free(embeddings);
	}
};
test "HttpEmbedder uses live Ollama" {
	const allocator = std.testing.allocator;
	try embedding_http.skipIfNoOllama(allocator);
	const inputs = [_][]const u8{ "hash functions" };

	var transport = embedding_http.StdHttpTransport.init(allocator);
	defer transport.deinit();

	const url = try envOrDefault(allocator, "OLLAMA_URL", "http://localhost:11434");
	defer allocator.free(url);
	const model = try envOrDefault(allocator, "OLLAMA_MODEL", "bge-large");
	defer allocator.free(model);

	embedding_http.ensureModelAvailable(allocator, transport.transport(), url, model, .ollama) catch |err| switch (err) {
		error.ModelLoading => {}, // Model exists, embed will trigger loading
		else => return err,
	};

	var adapter = HttpEmbedder{
		.transport = transport.transport(),
		.base_url = url,
		.model = model,
	};
	const embedder = adapter.embedder();
	const embeddings = try embedder.embed(embedder.ctx, allocator, &inputs);
	defer embedder.free(embedder.ctx, allocator, embeddings);

	try std.testing.expectEqual(@as(usize, 1), embeddings.len);
	try std.testing.expect(embeddings[0].len > 0);
}

test "NullEmbedder returns empty embeddings and free is safe" {
    const allocator = std.testing.allocator;
    const null_embedder = NullEmbedder.embedder();
    const inputs = [_][]const u8{ "hello", "world" };
    const embeddings = try null_embedder.embed(null_embedder.ctx, allocator, &inputs);
    defer null_embedder.free(null_embedder.ctx, allocator, embeddings);
    try std.testing.expectEqual(@as(usize, 0), embeddings.len);
}


fn envOrDefault(allocator: std.mem.Allocator, key: []const u8, fallback: []const u8) ![]u8 {
	const value = std.process.getEnvVarOwned(allocator, key) catch |err| switch (err) {
		error.EnvironmentVariableNotFound => return allocator.dupe(u8, fallback),
		else => return err,
	};
	return value;
}
