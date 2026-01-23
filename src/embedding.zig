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

	pub fn embedder(self: *OllamaEmbedder) Embedder {
		return .{
			.ctx = self,
			.embed = embed,
			.free = free,
		};
	}

	fn embed(ctx: *anyopaque, allocator: std.mem.Allocator, inputs: []const []const u8) ![][]f32 {
		const self: *OllamaEmbedder = @ptrCast(@alignCast(ctx));
		return ollama.embed(allocator, self.transport, self.base_url, self.model, inputs);
	}

	fn free(ctx: *anyopaque, allocator: std.mem.Allocator, embeddings: [][]f32) void {
		_ = ctx;
		ollama.freeEmbeddings(allocator, embeddings);
	}
};

test "OllamaEmbedder uses transport and model" {
	const allocator = std.testing.allocator;
	const inputs = [_][]const u8{ "hash functions" };
	const response_body = "{\"embeddings\":[[0.1,0.2]]}";

	var fake = FakeTransport{
		.expected_url = "http://localhost:11434/api/embed",
		.expected_body = "{\"model\":\"bge-large\",\"input\":[\"hash functions\"]}",
		.response_body = response_body,
	};

	var adapter = OllamaEmbedder{
		.transport = fake.transport(),
		.base_url = "http://localhost:11434",
		.model = "bge-large",
	};

	const embedder = adapter.embedder();
	const embeddings = try embedder.embed(embedder.ctx, allocator, &inputs);
	defer embedder.free(embedder.ctx, allocator, embeddings);

	try std.testing.expectEqual(@as(usize, 1), embeddings.len);
	try std.testing.expectApproxEqAbs(@as(f32, 0.1), embeddings[0][0], 0.0001);
}

const FakeTransport = struct {
	expected_url: []const u8,
	expected_body: []const u8,
	response_body: []const u8,

	pub fn transport(self: *FakeTransport) ollama.Transport {
		return .{ .ctx = self, .send = send };
	}

	fn send(ctx: *anyopaque, allocator: std.mem.Allocator, req: ollama.HttpRequest) !ollama.HttpResponse {
		const self: *FakeTransport = @ptrCast(@alignCast(ctx));
		try std.testing.expectEqualStrings(self.expected_url, req.url);
		try std.testing.expectEqualStrings(self.expected_body, req.body);
		try std.testing.expectEqualStrings("POST", req.method);
		const body = try allocator.dupe(u8, self.response_body);
		return .{ .status = 200, .body = body };
	}
};
