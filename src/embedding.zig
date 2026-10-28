const std = @import("std");
const io_singleton = @import("io_singleton.zig");
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
	/// Caller-owned diagnostic state; access is serialized like the transport.
	/// A successful retry clears the preceding attempt's error.
	error_capture: ?*?anyerror = null,

	pub fn embedder(self: *HttpEmbedder) Embedder {
		return .{
			.ctx = self,
			.embed = embed_fn,
			.free = free_fn,
		};
	}

	fn embed_fn(ctx: *anyopaque, allocator: std.mem.Allocator, inputs: []const []const u8) ![][]f32 {
		const self: *HttpEmbedder = @ptrCast(@alignCast(ctx));
		if (self.error_capture) |capture| capture.* = null;
		return embedding_http.embed(allocator, self.transport, self.base_url, self.model, inputs, self.keep_alive, self.dialect, self.auth_header) catch |err| {
			if (self.error_capture) |capture| capture.* = err;
			return err;
		};
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
test "HttpEmbedder embeds via the transport (mocked)" {
	const allocator = std.testing.allocator;
	const inputs = [_][]const u8{ "hash functions" };

	// Hermetic: a mock transport returns a canned ollama /api/embed response — no
	// network. (HttpEmbedder.embed delegates straight to embedding_http.embed.)
	var mock = embedding_http.MockTransportCtx{ .tags_body = "{}", .ps_body = "{}" };

	var adapter = HttpEmbedder{
		.transport = mock.transport(),
		.base_url = "http://localhost:11434",
		.model = "bge-large",
		.dialect = .ollama,
	};
	const embedder = adapter.embedder();
	const embeddings = try embedder.embed(embedder.ctx, allocator, &inputs);
	defer embedder.free(embedder.ctx, allocator, embeddings);

	try std.testing.expectEqual(@as(usize, 1), embeddings.len);
	try std.testing.expect(embeddings[0].len > 0);
	try std.testing.expect(mock.embed_count >= 1);
}

test "HttpEmbedder captures original attempt errors and clears them after recovery" {
	const allocator = std.testing.allocator;
	var captured: ?anyerror = null;
	var mock = embedding_http.MockTransportCtx{ .tags_body = "{}", .ps_body = "{}", .status_override = 503 };
	var adapter = HttpEmbedder{
		.transport = mock.transport(), .base_url = "http://localhost:11434", .model = "test-model",
		.error_capture = &captured,
	};
	const embedder = adapter.embedder();
	const inputs = [_][]const u8{"fixture"};
	try std.testing.expectError(error.HttpStatus, embedder.embed(embedder.ctx, allocator, &inputs));
	try std.testing.expectEqual(@as(?anyerror, error.HttpStatus), captured);
	mock.status_override = null;
	mock.embed_should_fail = true;
	try std.testing.expectError(error.ConnectionRefused, embedder.embed(embedder.ctx, allocator, &inputs));
	try std.testing.expectEqual(@as(?anyerror, error.ConnectionRefused), captured);
	mock.embed_should_fail = false;
	const values = try embedder.embed(embedder.ctx, allocator, &inputs);
	defer embedder.free(embedder.ctx, allocator, values);
	try std.testing.expectEqual(@as(?anyerror, null), captured);
	var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
	try std.testing.expectError(error.OutOfMemory, embedder.embed(embedder.ctx, failing.allocator(), &inputs));
	try std.testing.expectEqual(@as(?anyerror, error.OutOfMemory), captured);
	const recovered = try embedder.embed(embedder.ctx, allocator, &inputs);
	defer embedder.free(embedder.ctx, allocator, recovered);
	try std.testing.expectEqual(@as(?anyerror, null), captured);
}

test "NullEmbedder returns empty embeddings and free is safe" {
    const allocator = std.testing.allocator;
    const null_embedder = NullEmbedder.embedder();
    const inputs = [_][]const u8{ "hello", "world" };
    const embeddings = try null_embedder.embed(null_embedder.ctx, allocator, &inputs);
    defer null_embedder.free(null_embedder.ctx, allocator, embeddings);
    try std.testing.expectEqual(@as(usize, 0), embeddings.len);
}


