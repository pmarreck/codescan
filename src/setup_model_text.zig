const std = @import("std");

pub const Dialect = enum { ollama, openai };

pub fn print(writer: *std.io.Writer, current: Dialect) !void {
	try writer.print(
		\\Recommended model: jina-code-embeddings-1.5b
		\\  1536 dimensions, 32K token context, code-specific training
		\\  License: CC-BY-NC-4.0 (non-commercial)
		\\
		\\Two ways to serve it — pick one:
		\\
		\\Option A: Ollama
		\\
		\\  ollama pull hf.co/jinaai/jina-code-embeddings-1.5b-GGUF:Q8_0
		\\
		\\  Then in .codescan/config:
		\\
		\\    embedding_api=ollama
		\\    embedding_url=http://localhost:11434
		\\    embedding_model=hf.co/jinaai/jina-code-embeddings-1.5b-GGUF:Q8_0
		\\
		\\Option B: oMLX Server (OpenAI-compatible)
		\\
		\\  huggingface-cli download jinaai/jina-code-embeddings-1.5b-mlx
		\\
		\\  Then configure your oMLX Server to serve it and set in .codescan/config:
		\\
		\\    embedding_api=openai
		\\    embedding_url=http://localhost:8000
		\\    embedding_model=jinaai/jina-code-embeddings-1.5b-mlx
		\\    embedding_api_key=<your-omlx-key>
		\\
		\\
	, .{});

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
		\\Then reindex your project:
		\\
		\\  codescan index --force
		\\
		\\Note: If you use a different model, update embedding_model and embedding_dim
		\\in .codescan/config to match. Mismatched dimensions will cause search errors.
		\\
	, .{});
}

test "print shows both Ollama and oMLX options regardless of current dialect" {
	const allocator = std.testing.allocator;
	for ([_]Dialect{ .ollama, .openai }) |current| {
		var out: std.io.Writer.Allocating = .init(allocator);
		defer out.deinit();
		try print(&out.writer, current);
		const text = out.written();

		try std.testing.expect(std.mem.indexOf(u8, text, "ollama pull hf.co/jinaai/jina-code-embeddings-1.5b-GGUF:Q8_0") != null);
		try std.testing.expect(std.mem.indexOf(u8, text, "huggingface-cli download jinaai/jina-code-embeddings-1.5b-mlx") != null);
		try std.testing.expect(std.mem.indexOf(u8, text, "Recommended model: jina-code-embeddings-1.5b") != null);
		try std.testing.expect(std.mem.indexOf(u8, text, "codescan index --force") != null);
	}
}

test "print flags the current dialect" {
	const allocator = std.testing.allocator;

	var ollama_out: std.io.Writer.Allocating = .init(allocator);
	defer ollama_out.deinit();
	try print(&ollama_out.writer, .ollama);
	try std.testing.expect(std.mem.indexOf(u8, ollama_out.written(), "currently set for Ollama") != null);
	try std.testing.expect(std.mem.indexOf(u8, ollama_out.written(), "currently set for oMLX") == null);

	var openai_out: std.io.Writer.Allocating = .init(allocator);
	defer openai_out.deinit();
	try print(&openai_out.writer, .openai);
	try std.testing.expect(std.mem.indexOf(u8, openai_out.written(), "currently set for oMLX") != null);
	try std.testing.expect(std.mem.indexOf(u8, openai_out.written(), "currently set for Ollama") == null);
}
