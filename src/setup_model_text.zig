const std = @import("std");

pub const Dialect = enum { ollama, openai };

pub const recommendation = .{
	.name = "jina-code-embeddings:1.5b",
	.rationale = "code-specific training, 1536 dimensions, and strong local search quality",
	.setup_guide = "docs/jina-code-embeddings-ollama.md",
};

pub fn print(writer: *std.Io.Writer, current: Dialect) !void {
	try writer.print(
		\\Recommended model: {s}
		\\  1536 dimensions, 32K token context, code-specific training
		\\  License: CC-BY-NC-4.0 (non-commercial)
		\\
		\\Two ways to serve it — pick one:
		\\
		\\Option A: Ollama
		\\
		\\  The upstream GGUF needs pooling metadata before Ollama recognizes it
		\\  as an embedding model. Follow {s}; it imports the model as:
		\\
		\\    {s}
		\\
		\\  Then in .codescan/config.ini:
		\\
		\\    embedding_api=ollama
		\\    embedding_url=http://localhost:11434
		\\    embedding_model={s}
		\\
		\\Option B: oMLX Server (OpenAI-compatible)
		\\
		\\  huggingface-cli download jinaai/jina-code-embeddings-1.5b-mlx
		\\
		\\  Then configure your oMLX Server to serve it and set in .codescan/config.ini:
		\\
		\\    embedding_api=openai
		\\    embedding_url=http://localhost:8000
		\\    embedding_model=jinaai/jina-code-embeddings-1.5b-mlx
		\\    embedding_api_key=<your-omlx-key>
		\\
		\\
	, .{
		recommendation.name,
		recommendation.setup_guide,
		recommendation.name,
		recommendation.name,
	});

	switch (current) {
		.ollama => try writer.print(
			"Your .codescan/config is currently set for Ollama (embedding_api=ollama).\n\n",
			.{},
		),
		.openai => try writer.print(
			"Your .codescan/config is currently set for oMLX / OpenAI-compatible (embedding_api=openai).\n\n",
			.{},
		),
	}

	try writer.print(
		\\Then update your project index:
		\\
		\\  codescan update
		\\
		\\codescan init validates a real embedding before saving a selected model and
		\\records its returned dimension. A changed model is regenerated on update.
		\\
	, .{});
}

test "print shows both Ollama and oMLX options regardless of current dialect" {
	const allocator = std.testing.allocator;
	for ([_]Dialect{ .ollama, .openai }) |current| {
		var out: std.Io.Writer.Allocating = .init(allocator);
		defer out.deinit();
		try print(&out.writer, current);
		const text = out.written();

		try std.testing.expect(std.mem.indexOf(u8, text, recommendation.name) != null);
		try std.testing.expect(std.mem.indexOf(u8, text, recommendation.setup_guide) != null);
		try std.testing.expect(std.mem.indexOf(u8, text, "pooling metadata") != null);
		try std.testing.expect(std.mem.indexOf(u8, text, "huggingface-cli download jinaai/jina-code-embeddings-1.5b-mlx") != null);
		try std.testing.expect(std.mem.indexOf(u8, text, "codescan update") != null);
	}
}

test "print flags the current dialect" {
	const allocator = std.testing.allocator;

	var ollama_out: std.Io.Writer.Allocating = .init(allocator);
	defer ollama_out.deinit();
	try print(&ollama_out.writer, .ollama);
	try std.testing.expect(std.mem.indexOf(u8, ollama_out.written(), "currently set for Ollama") != null);
	try std.testing.expect(std.mem.indexOf(u8, ollama_out.written(), "currently set for oMLX") == null);

	var openai_out: std.Io.Writer.Allocating = .init(allocator);
	defer openai_out.deinit();
	try print(&openai_out.writer, .openai);
	try std.testing.expect(std.mem.indexOf(u8, openai_out.written(), "currently set for oMLX") != null);
	try std.testing.expect(std.mem.indexOf(u8, openai_out.written(), "currently set for Ollama") == null);
}
