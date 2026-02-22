const std = @import("std");
const ollama = @import("ollama.zig");

pub const Embedder = struct {
	ctx: *anyopaque,
	embed: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, inputs: []const []const u8) anyerror![][]f32,
	free: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, embeddings: [][]f32) void,
};

pub const OllamaEmbedder = struct {
	transport: ollama.Transport,
	base_url: []const u8,
	model: []const u8,
	keep_alive: ?i64 = 900, // 15 minutes in seconds

	pub fn embedder(self: *OllamaEmbedder) Embedder {
		return .{
			.ctx = self,
			.embed = embed,
			.free = free,
		};
	}

	fn embed(ctx: *anyopaque, allocator: std.mem.Allocator, inputs: []const []const u8) ![][]f32 {
		const self: *OllamaEmbedder = @ptrCast(@alignCast(ctx));
		return ollama.embed(allocator, self.transport, self.base_url, self.model, inputs, self.keep_alive);
	}

	fn free(ctx: *anyopaque, allocator: std.mem.Allocator, embeddings: [][]f32) void {
		_ = ctx;
		ollama.freeEmbeddings(allocator, embeddings);
	}
};

test "OllamaEmbedder uses live Ollama" {
	const allocator = std.testing.allocator;
	try ollama.skipIfNoOllama(allocator);
	const inputs = [_][]const u8{ "hash functions" };

	var transport = ollama.StdHttpTransport.init(allocator);
	defer transport.deinit();

	const url = try envOrDefault(allocator, "OLLAMA_URL", "http://localhost:11434");
	defer allocator.free(url);
	const model = try envOrDefault(allocator, "OLLAMA_MODEL", "bge-large");
	defer allocator.free(model);

	ollama.ensureModelAvailable(allocator, transport.transport(), url, model) catch |err| switch (err) {
		error.ModelLoading => {}, // Model exists, embed will trigger loading
		else => return err,
	};

	var adapter = OllamaEmbedder{
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

fn envOrDefault(allocator: std.mem.Allocator, key: []const u8, fallback: []const u8) ![]u8 {
	const value = std.process.getEnvVarOwned(allocator, key) catch |err| switch (err) {
		error.EnvironmentVariableNotFound => return allocator.dupe(u8, fallback),
		else => return err,
	};
	return value;
}
