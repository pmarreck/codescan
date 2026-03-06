const std = @import("std");
const main = @import("main.zig");
const cli = @import("cli.zig");
const plugin = @import("plugin.zig");
const config = @import("config.zig");
const storage = @import("storage.zig");
const embedding = @import("embedding.zig");
const indexer = @import("indexer.zig");
const search = @import("search.zig");
const output = @import("output.zig");
const ollama = @import("ollama.zig");
const filters = @import("filters.zig");
const kind = @import("kind.zig");
const model = @import("model.zig");
const weights = @import("weights.zig");

/// Log an error to stderr (skipped during tests) and return error.ToolFailed.
/// Use at catch sites to make MCP errors visible instead of silently swallowing them.
fn toolError(comptime fmt: []const u8, args: anytype) error{ToolFailed} {
	if (!@import("builtin").is_test) {
		var sb: [4096]u8 = undefined;
		var sw = std.fs.File.stderr().writer(&sb);
		const se = &sw.interface;
		se.print(fmt, args) catch {};
		se.flush() catch {};
	}
	return error.ToolFailed;
}

pub const Settings = struct {
	root_path: []const u8,
	db_path: []const u8,
	lsp_overrides: []const config.LspOverride = &[_]config.LspOverride{},
	ollama_url: []const u8 = "http://localhost:11434",
	ollama_model: []const u8 = "bge-large",
	embedding_dim: usize = 1024,
	batch_size: usize = 16,
	max_file_size: usize = 1024 * 1024,
	search_top_n: usize = 20,
	search_mode: search.SearchMode = .hybrid,
	search_fusion: search.FusionMode = .weighted_sum,
	search_rrf_k: f32 = 60,
	search_fts_mode: search.FtsMode = .broad,
	search_weight_vector: f32 = 0.7,
	search_weight_lexical: f32 = 0.3,
	search_min_score: f32 = 0.0,
	search_ext: ?[]const u8 = null,
	search_type: ?[]const u8 = null,
	search_lang: ?[]const u8 = null,
	search_symbol_kind: ?[]const u8 = null,
	primary_lang: ?[]const u8 = null,
	include_docs: bool = false,
	docs_only: bool = false,
	comments_only: bool = false,
	ignore_global: []const []const u8 = &[_][]const u8{},
	ignore_lang: []const config.IgnoreOverride = &[_]config.IgnoreOverride{},
	include_node_modules: bool = false,
	search_weights: ?*const weights.Table = null,
};

/// Read a single JSON-RPC message from the reader.
/// MCP uses newline-delimited JSON (one JSON object per line).
pub fn readMessage(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
	var buf = std.ArrayListUnmanaged(u8){};
	errdefer buf.deinit(allocator);

	while (true) {
		var byte_buf: [1]u8 = undefined;
		const n = try reader.readSliceShort(&byte_buf);
		if (n == 0) return error.EndOfStream;
		if (byte_buf[0] == '\n') break;
		try buf.append(allocator, byte_buf[0]);
	}

	return buf.toOwnedSlice(allocator);
}

/// Write a JSON-RPC message followed by a newline.
/// Strips any embedded newlines from msg to ensure one-JSON-per-line protocol.
pub fn writeMessage(writer: *std.Io.Writer, msg: []const u8) !void {
	for (msg) |c| {
		if (c != '\n' and c != '\r') {
			try writer.writeByte(c);
		}
	}
	try writer.writeAll("\n");
	try writer.flush();
}

/// Parse a JSON-RPC request and extract method, id, and params.
/// The id is kept as a raw JSON value to support both string and integer IDs
/// per JSON-RPC 2.0 spec.
pub const RpcRequest = struct {
	method: []const u8,
	id: ?std.json.Value,
	params: ?std.json.Value,
};

pub fn parseRequest(allocator: std.mem.Allocator, msg: []const u8) !struct { parsed: std.json.Parsed(std.json.Value), req: RpcRequest } {
	var parsed = try std.json.parseFromSlice(std.json.Value, allocator, msg, .{});
	errdefer parsed.deinit();

	if (parsed.value != .object) return error.InvalidRequest;
	const obj = parsed.value.object;

	const method_val = obj.get("method") orelse return error.MissingMethod;
	if (method_val != .string) return error.InvalidMethod;

	const params = obj.get("params");

	return .{
		.parsed = parsed,
		.req = .{
			.method = method_val.string,
			.id = obj.get("id"),
			.params = params,
		},
	};
}

/// Format a JSON id value as a string (handles int, string, or null).
fn formatId(allocator: std.mem.Allocator, id: ?std.json.Value) ![]u8 {
	const id_val = id orelse return allocator.dupe(u8, "null");
	return switch (id_val) {
		.integer => |v| std.fmt.allocPrint(allocator, "{d}", .{v}),
		.string => |s| std.fmt.allocPrint(allocator, "\"{s}\"", .{s}),
		else => allocator.dupe(u8, "null"),
	};
}

/// Format a JSON-RPC success response.
pub fn formatResult(allocator: std.mem.Allocator, id: ?std.json.Value, result_json: []const u8) ![]u8 {
	const id_str = try formatId(allocator, id);
	defer allocator.free(id_str);
	return std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_str, result_json });
}

/// Format a JSON-RPC error response.
pub fn formatError(allocator: std.mem.Allocator, id: ?std.json.Value, code: i64, message: []const u8) ![]u8 {
	const id_str = try formatId(allocator, id);
	defer allocator.free(id_str);
	return std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}", .{ id_str, code, message });
}

/// Build the initialize response.
pub fn handleInitialize(allocator: std.mem.Allocator, id: ?std.json.Value) ![]u8 {
	const result =
		\\{"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"codescan","version":"0.1.0"}}
	;
	return formatResult(allocator, id, result);
}

/// Build the tools/list response.
pub fn handleToolsList(allocator: std.mem.Allocator, id: ?std.json.Value) ![]u8 {
	return formatResult(allocator, id, tools_list_json);
}

/// Handle a tools/call request. Returns the JSON-RPC response.
pub fn handleToolsCall(allocator: std.mem.Allocator, id: ?std.json.Value, params: ?std.json.Value, settings: Settings) ![]u8 {
	const p = params orelse return formatError(allocator, id, -32602, "missing params");
	if (p != .object) return formatError(allocator, id, -32602, "params must be object");
	const obj = p.object;

	const name_val = obj.get("name") orelse return formatError(allocator, id, -32602, "missing tool name");
	if (name_val != .string) return formatError(allocator, id, -32602, "tool name must be string");
	const name = name_val.string;

	const args = if (obj.get("arguments")) |a| blk: {
		if (a != .object) break :blk null;
		break :blk a.object;
	} else null;

	// Dispatch to tool handler
	const result = callTool(allocator, name, args, settings) catch |err| {
		const msg = switch (err) {
			error.OutOfMemory => "out of memory",
			error.ToolFailed => "tool execution failed (check stderr for details)",
			error.MissingArgument => "missing required argument",
			error.UnknownTool => "unknown tool",
			else => "tool execution failed",
		};
		// Log the actual error to stderr for debugging (skip during tests)
		if (!@import("builtin").is_test) {
			var sb: [4096]u8 = undefined;
			var sw = std.fs.File.stderr().writer(&sb);
			const se = &sw.interface;
			se.print("MCP tool '{s}' failed: {s} (error: {})\n", .{ name, msg, err }) catch {};
			se.flush() catch {};
		}
		return formatError(allocator, id, -32603, msg);
	};
	defer allocator.free(result);

	// Wrap in MCP tool result format
	return formatToolResult(allocator, id, result);
}

fn formatToolResult(allocator: std.mem.Allocator, id: ?std.json.Value, text: []const u8) ![]u8 {
	// Escape the text for JSON string embedding
	var escaped = std.ArrayListUnmanaged(u8){};
	defer escaped.deinit(allocator);
	for (text) |c| {
		switch (c) {
			'"' => try escaped.appendSlice(allocator, "\\\""),
			'\\' => try escaped.appendSlice(allocator, "\\\\"),
			'\n' => try escaped.appendSlice(allocator, "\\n"),
			'\r' => try escaped.appendSlice(allocator, "\\r"),
			'\t' => try escaped.appendSlice(allocator, "\\t"),
			else => {
				if (c < 0x20) {
					var buf: [6]u8 = undefined;
					const hex = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch continue;
					try escaped.appendSlice(allocator, hex);
				} else {
					try escaped.append(allocator, c);
				}
			},
		}
	}
	const escaped_text = try escaped.toOwnedSlice(allocator);
	defer allocator.free(escaped_text);

	const id_str = try formatId(allocator, id);
	defer allocator.free(id_str);
	return std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}]}}}}", .{ id_str, escaped_text });
}

fn ensureParentDir(path: []const u8) !void {
	const dir = std.fs.path.dirname(path) orelse return;
	try std.fs.cwd().makePath(dir);
}

fn callTool(allocator: std.mem.Allocator, name: []const u8, args: ?std.json.ObjectMap, settings: Settings) ![]u8 {
	var out: std.io.Writer.Allocating = .init(allocator);
	errdefer out.deinit();

	if (std.mem.eql(u8, name, "symbols")) {
		var files = getArgStringArray(allocator, args, "file") catch |err|
			return toolError("MCP symbols: failed to parse file args: {}\n", .{err});
		defer {
			for (files.items) |f| allocator.free(f);
			files.deinit(allocator);
		}
		const pattern = getArg(args, "pattern");
		const include_body = getArgBool(args, "include_body");
		main.runSymbols(allocator, files.items, pattern, include_body, .json, &out.writer, settings.root_path) catch |err|
			return toolError("MCP symbols: runSymbols failed: {}\n", .{err});
	} else if (std.mem.eql(u8, name, "replace_symbol")) {
		const file = getArg(args, "file") orelse return error.MissingArgument;
		const pattern = getArg(args, "pattern") orelse return error.MissingArgument;
		const body = getArg(args, "body") orelse return error.MissingArgument;
		main.runReplaceSymbol(allocator, file, pattern, body, &out.writer) catch |err|
			return toolError("MCP replace_symbol: failed on '{s}': {}\n", .{ file, err });
	} else if (std.mem.eql(u8, name, "insert_after")) {
		const file = getArg(args, "file") orelse return error.MissingArgument;
		const pattern = getArg(args, "pattern") orelse return error.MissingArgument;
		const body = getArg(args, "body") orelse return error.MissingArgument;
		main.runInsertAfter(allocator, file, pattern, body, &out.writer) catch |err|
			return toolError("MCP insert_after: failed on '{s}': {}\n", .{ file, err });
	} else if (std.mem.eql(u8, name, "insert_before")) {
		const file = getArg(args, "file") orelse return error.MissingArgument;
		const pattern = getArg(args, "pattern") orelse return error.MissingArgument;
		const body = getArg(args, "body") orelse return error.MissingArgument;
		main.runInsertBefore(allocator, file, pattern, body, &out.writer) catch |err|
			return toolError("MCP insert_before: failed on '{s}': {}\n", .{ file, err });
	} else if (std.mem.eql(u8, name, "replace_lines")) {
		const file = getArg(args, "file") orelse return error.MissingArgument;
		const from = getArg(args, "from") orelse return error.MissingArgument;
		const to = getArg(args, "to") orelse return error.MissingArgument;
		const body = getArg(args, "body") orelse return error.MissingArgument;
		main.runReplaceLines(allocator, file, from, to, body, &out.writer) catch |err|
			return toolError("MCP replace_lines: failed on '{s}': {}\n", .{ file, err });
	} else if (std.mem.eql(u8, name, "insert_at")) {
		const file = getArg(args, "file") orelse return error.MissingArgument;
		const ref = getArg(args, "ref") orelse return error.MissingArgument;
		const body = getArg(args, "body") orelse return error.MissingArgument;
		main.runInsertAt(allocator, file, ref, body, &out.writer) catch |err|
			return toolError("MCP insert_at: failed on '{s}': {}\n", .{ file, err });
	} else if (std.mem.eql(u8, name, "replace_content")) {
		const file = getArg(args, "file") orelse return error.MissingArgument;
		const needle = getArg(args, "needle") orelse return error.MissingArgument;
		const body = getArg(args, "body") orelse return error.MissingArgument;
		const regex = getArgBool(args, "regex");
		const all = getArgBool(args, "all");
		main.runReplaceContent(allocator, file, needle, regex, all, body, &out.writer) catch |err|
			return toolError("MCP replace_content: failed on '{s}': {}\n", .{ file, err });
	} else if (std.mem.eql(u8, name, "references")) {
		const file = getArg(args, "file") orelse return error.MissingArgument;
		const pattern = getArg(args, "pattern") orelse return error.MissingArgument;
		main.runReferences(allocator, file, pattern, .json, settings.root_path, settings.lsp_overrides, &out.writer) catch |err|
			return toolError("MCP references: failed on '{s}': {}\n", .{ file, err });
	} else if (std.mem.eql(u8, name, "rename")) {
		const file = getArg(args, "file") orelse return error.MissingArgument;
		const pattern = getArg(args, "pattern") orelse return error.MissingArgument;
		const to = getArg(args, "to") orelse return error.MissingArgument;
		const dry_run = getArgBool(args, "dry_run");
		main.runRename(allocator, file, pattern, to, .json, dry_run, settings.db_path, settings.root_path, plugin.defaultRegistry(), settings.lsp_overrides, settings.embedding_dim, &out.writer) catch |err|
			return toolError("MCP rename: failed on '{s}': {}\n", .{ file, err });
	} else if (std.mem.eql(u8, name, "search") or std.mem.eql(u8, name, "query")) {
		const query = getArg(args, "query") orelse return error.MissingArgument;
		try ensureParentDir(settings.db_path);
		const db = storage.openFileWithVec(allocator, settings.db_path) catch |err|
			return toolError("MCP search: failed to open DB '{s}': {}\n", .{ settings.db_path, err });
		defer storage.close(db);
		var schema_result = storage.initSchema(allocator, db, .{ .embedding_dim = settings.embedding_dim, .embedding_model = settings.ollama_model }) catch |err|
			return toolError("MCP search: schema init failed: {}\n", .{err});
		defer schema_result.deinit(allocator);
		if (schema_result.did_schema_upgrade) {
			var sb: [4096]u8 = undefined;
			var sw = std.fs.File.stderr().writer(&sb);
			const se = &sw.interface;
			_ = se.print("note: Database schema upgraded. A full re-index is strongly recommended.\n", .{}) catch {};
			_ = se.flush() catch {};
		}
		if (schema_result.embedding_model_mismatch or schema_result.embedding_dim_mismatch) {
			var msg_buf: [512]u8 = undefined;
			var msg_writer = std.io.fixedBufferStream(&msg_buf);
			const mw = msg_writer.writer();
			if (schema_result.embedding_model_mismatch) {
				mw.print("Embedding model mismatch: index built with '{s}', current is '{s}'. ", .{ schema_result.stored_embedding_model orelse "unknown", settings.ollama_model }) catch {};
			}
			if (schema_result.embedding_dim_mismatch) {
				mw.print("Embedding dim mismatch: index built with {d}, current is {d}. ", .{ schema_result.stored_embedding_dim orelse 0, settings.embedding_dim }) catch {};
			}
			mw.print("Run 'codescan index' to rebuild.", .{}) catch {};
			const msg = msg_buf[0..msg_writer.pos];
			return toolError("{s}", .{msg});
		}

		var http_client = ollama.StdHttpTransport.init(allocator);
		defer http_client.deinit();

		// Auto-index if DB is empty
		var effective_search_mode = settings.search_mode;
		if (!storage.isIndexPopulated(db)) {
			ollama.ensureModelAvailable(allocator, http_client.transport(), settings.ollama_url, settings.ollama_model) catch |err| {
				if (err != error.ModelLoading) {
					// ModelNotFound or connection error — fall back to lexical
					effective_search_mode = .lexical;
				}
				// ModelLoading: model exists, embed() will trigger loading — proceed
			};
			var embedder_for_index = embedding.OllamaEmbedder{
				.transport = http_client.transport(),
				.base_url = settings.ollama_url,
				.model = settings.ollama_model,
			};
			_ = indexer.indexAll(allocator, db, settings.root_path, plugin.defaultRegistry(), embedder_for_index.embedder(), .{
				.embedding_dim = settings.embedding_dim,
				.embedding_model = settings.ollama_model,
				.batch_size = settings.batch_size,
				.max_file_size = settings.max_file_size,
				.allowed_exts = &[_][]const u8{},
				.allowed_kinds = &[_]kind.Kind{},
				.ignore = .{
					.global = settings.ignore_global,
					.per_language = settings.ignore_lang,
					.include_node_modules = settings.include_node_modules,
				},
				.show_progress = false,
			}) catch |err|
				return toolError("MCP search: auto-index failed for root '{s}': {}\n", .{ settings.root_path, err });
		} else {
			if (effective_search_mode != .lexical) {
				ollama.ensureModelAvailable(allocator, http_client.transport(), settings.ollama_url, settings.ollama_model) catch |err| {
					if (err != error.ModelLoading) {
						// ModelNotFound or connection error — fall back to lexical
						effective_search_mode = .lexical;
					}
					// ModelLoading: model exists, embed() will trigger loading — proceed
				};
			}
		}

		var embedder_adapter = embedding.OllamaEmbedder{
			.transport = http_client.transport(),
			.base_url = settings.ollama_url,
			.model = settings.ollama_model,
		};

		var search_filters = filters.buildSearchFilters(allocator, plugin.defaultRegistry(), db, .{
			.search_ext = settings.search_ext,
			.search_type = settings.search_type,
			.search_lang = settings.search_lang,
			.search_symbol_kind = settings.search_symbol_kind,
			.primary_lang = settings.primary_lang,
			.include_docs = settings.include_docs,
			.docs_only = settings.docs_only,
		}) catch |err|
			return toolError("MCP search: failed to build search filters: {}\n", .{err});
		defer search_filters.deinit(allocator);
		const effective_weights = weights.resolveSearchWeights(
			settings.search_weights,
			search_filters.langs.items,
			settings.search_weight_vector,
			settings.search_weight_lexical,
			false,
		);

		const sr = search.search(allocator, db, embedder_adapter.embedder(), query, .{
			.top_n = settings.search_top_n,
			.mode = effective_search_mode,
			.fusion = settings.search_fusion,
			.rrf_k = settings.search_rrf_k,
			.fts_mode = settings.search_fts_mode,
			.weight_vector = effective_weights.weight_vector,
			.weight_lexical = effective_weights.weight_lexical,
			.weight_symbol_kind = effective_weights.weight_symbol_kind,
			.weight_symbol_visibility = effective_weights.weight_symbol_visibility,
			.weight_symbol_scope = effective_weights.weight_symbol_scope,
			.weight_symbol_arity = effective_weights.weight_symbol_arity,
			.min_score = settings.search_min_score,
			.allowed_langs = search_filters.langs.items,
			.allowed_exts = search_filters.exts.items,
			.allowed_symbol_kinds = search_filters.symbol_kinds.items,
			.comments_only = settings.comments_only,
		}) catch |err|
			return toolError("MCP search: search failed for query '{s}': {}\n", .{ query, err });
		defer search.freeResults(allocator, sr.results);

		output.writeResults(allocator, &out.writer, .json, sr.results, .{
			.show_comments = false,
			.use_color = false,
			.total_relevant = sr.total_relevant,
			.top_n = settings.search_top_n,
		}) catch |err|
			return toolError("MCP search: failed to write results: {}\n", .{err});
	} else if (std.mem.eql(u8, name, "index")) {
		try ensureParentDir(settings.db_path);
		const db = storage.openFileWithVecRecreate(allocator, settings.db_path) catch |err|
			return toolError("MCP index: failed to open DB '{s}': {}\n", .{ settings.db_path, err });
		defer storage.close(db);

		var http_client = ollama.StdHttpTransport.init(allocator);
		defer http_client.deinit();
		ollama.ensureModelAvailable(allocator, http_client.transport(), settings.ollama_url, settings.ollama_model) catch |err| {
			switch (err) {
				error.ModelLoading => {
					// Model exists but not loaded — embed() will trigger loading. Log and proceed.
					var sb: [4096]u8 = undefined;
					var sw = std.fs.File.stderr().writer(&sb);
					const se = &sw.interface;
					_ = se.print("MCP index: model '{s}' is loading into memory. This may take a moment...\n", .{settings.ollama_model}) catch {};
					_ = se.flush() catch {};
				},
				error.ModelNotFound => {
					try out.writer.print("error: Ollama model '{s}' not found. Run: ollama pull {s}", .{ settings.ollama_model, settings.ollama_model });
					return out.toOwnedSlice();
				},
				else => {
					try out.writer.print("error: Ollama model '{s}' not available: {}", .{ settings.ollama_model, err });
					return out.toOwnedSlice();
				},
			}
		};

		var embedder_adapter = embedding.OllamaEmbedder{
			.transport = http_client.transport(),
			.base_url = settings.ollama_url,
			.model = settings.ollama_model,
		};

		const stats = indexer.indexAll(allocator, db, settings.root_path, plugin.defaultRegistry(), embedder_adapter.embedder(), .{
			.embedding_dim = settings.embedding_dim,
			.embedding_model = settings.ollama_model,
			.batch_size = settings.batch_size,
			.max_file_size = settings.max_file_size,
			.allowed_exts = &[_][]const u8{},
			.allowed_kinds = &[_]kind.Kind{},
			.ignore = .{
				.global = settings.ignore_global,
				.per_language = settings.ignore_lang,
				.include_node_modules = settings.include_node_modules,
			},
			.show_progress = false,
		}) catch |err|
			return toolError("MCP index: indexAll failed for root '{s}': {}\n", .{ settings.root_path, err });

		try out.writer.print("{{\"status\":\"ok\",\"files\":{d},\"symbols\":{d}}}", .{ stats.files, stats.symbols });
	} else if (std.mem.eql(u8, name, "config")) {
		try out.writer.print("{{\"root\":\"{s}\",\"db_path\":\"{s}\",\"ollama_url\":\"{s}\",\"ollama_model\":\"{s}\",\"embedding_dim\":{d}}}", .{
			settings.root_path,
			settings.db_path,
			settings.ollama_url,
			settings.ollama_model,
			settings.embedding_dim,
		});
	} else if (std.mem.eql(u8, name, "status")) {
		main.runStatus(allocator, settings.db_path, settings.root_path, .json, &out.writer) catch |err|
			return toolError("MCP status: failed: {}\n", .{err});
	} else {
		return error.UnknownTool;
	}

	return out.toOwnedSlice();
}

fn getArg(args: ?std.json.ObjectMap, key: []const u8) ?[]const u8 {
	const a = args orelse return null;
	const val = a.get(key) orelse return null;
	if (val != .string) return null;
	return val.string;
}

fn getArgBool(args: ?std.json.ObjectMap, key: []const u8) bool {
	const a = args orelse return false;
	const val = a.get(key) orelse return false;
	if (val != .bool) return false;
	return val.bool;
}

/// Extract a string-or-array-of-strings arg into an owned ArrayList.
fn getArgStringArray(allocator: std.mem.Allocator, args: ?std.json.ObjectMap, key: []const u8) !std.ArrayListUnmanaged([]const u8) {
	var result = std.ArrayListUnmanaged([]const u8){};
	errdefer {
		for (result.items) |f| allocator.free(f);
		result.deinit(allocator);
	}
	const a = args orelse return result;
	const val = a.get(key) orelse return result;
	switch (val) {
		.string => |s| try result.append(allocator, try allocator.dupe(u8, s)),
		.array => |arr| {
			for (arr.items) |item| {
				if (item == .string) {
					try result.append(allocator, try allocator.dupe(u8, item.string));
				}
			}
		},
		else => {},
	}
	return result;
}

/// Main MCP server loop. Reads JSON-RPC messages from stdin, writes responses to stdout.
/// All diagnostic output goes to stderr.
pub fn serve(allocator: std.mem.Allocator, settings: Settings) !void {
	var in_buf: [16 * 1024]u8 = undefined;
	var stdin_reader = std.fs.File.stdin().reader(&in_buf);
	const reader = &stdin_reader.interface;

	var out_buf: [16 * 1024]u8 = undefined;
	var stdout_writer = std.fs.File.stdout().writer(&out_buf);
	const writer = &stdout_writer.interface;

	while (true) {
		const msg = readMessage(allocator, reader) catch |err| switch (err) {
			error.EndOfStream => return,
			else => return err,
		};
		defer allocator.free(msg);

		if (msg.len == 0) continue;

		const result = parseRequest(allocator, msg) catch {
			const err_resp = try formatError(allocator, null, -32700, "parse error");
			defer allocator.free(err_resp);
			try writeMessage(writer, err_resp);
			continue;
		};
		var parsed = result.parsed;
		defer parsed.deinit();
		const req = result.req;

		const response = if (std.mem.eql(u8, req.method, "initialize"))
			try handleInitialize(allocator, req.id)
		else if (std.mem.eql(u8, req.method, "tools/list"))
			try handleToolsList(allocator, req.id)
		else if (std.mem.eql(u8, req.method, "tools/call"))
			try handleToolsCall(allocator, req.id, req.params, settings)
		else if (std.mem.eql(u8, req.method, "notifications/initialized"))
			continue // notification, no response
		else if (std.mem.eql(u8, req.method, "shutdown"))
			try formatResult(allocator, req.id, "null")
		else
			try formatError(allocator, req.id, -32601, "method not found");

		defer allocator.free(response);
		try writeMessage(writer, response);
	}
}

// Tool definitions for MCP tools/list
const tools_list_json =
	\\{"tools":[
	\\{"name":"search","description":"Semantic code search across indexed repository","inputSchema":{"type":"object","properties":{"query":{"type":"string","description":"Search query"}},"required":["query"]}},
	\\{"name":"query","description":"Alias for search. Semantic code search.","inputSchema":{"type":"object","properties":{"query":{"type":"string","description":"Search query"}},"required":["query"]}},
	\\{"name":"index","description":"Index or reindex a repository for semantic search","inputSchema":{"type":"object","properties":{}}},
	\\{"name":"symbols","description":"List or find symbols in files. Omit file to scan all project files. Omit pattern to list all symbols.","inputSchema":{"type":"object","properties":{"file":{"oneOf":[{"type":"string"},{"type":"array","items":{"type":"string"}}],"description":"File path(s), optional"},"pattern":{"type":"string","description":"Symbol name path pattern, optional"},"include_body":{"type":"boolean","description":"Include symbol source code"}}}},
	\\{"name":"replace_symbol","description":"Replace a symbol's entire body with new code","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"File path"},"pattern":{"type":"string","description":"Symbol name path"},"body":{"type":"string","description":"New symbol body"}},"required":["file","pattern","body"]}},
	\\{"name":"insert_after","description":"Insert code after a symbol","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"File path"},"pattern":{"type":"string","description":"Symbol name path"},"body":{"type":"string","description":"Code to insert"}},"required":["file","pattern","body"]}},
	\\{"name":"insert_before","description":"Insert code before a symbol","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"File path"},"pattern":{"type":"string","description":"Symbol name path"},"body":{"type":"string","description":"Code to insert"}},"required":["file","pattern","body"]}},
	\\{"name":"replace_lines","description":"Replace a hashline-validated line range","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"File path"},"from":{"type":"string","description":"Start hashline ref (e.g. 10:k7m)"},"to":{"type":"string","description":"End hashline ref (e.g. 20:x9a)"},"body":{"type":"string","description":"Replacement text"}},"required":["file","from","to","body"]}},
	\\{"name":"insert_at","description":"Insert code after a hashline-validated line","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"File path"},"ref":{"type":"string","description":"Hashline ref (e.g. 47:3bw)"},"body":{"type":"string","description":"Code to insert"}},"required":["file","ref","body"]}},
	\\{"name":"replace_content","description":"Find and replace text or regex in a file","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"File path"},"needle":{"type":"string","description":"Text or regex to find"},"body":{"type":"string","description":"Replacement text"},"regex":{"type":"boolean","description":"Treat needle as regex"},"all":{"type":"boolean","description":"Replace all occurrences"}},"required":["file","needle","body"]}},
	\\{"name":"references","description":"Find all references to a symbol (via LSP)","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"File path"},"pattern":{"type":"string","description":"Symbol name path"}},"required":["file","pattern"]}},
	\\{"name":"rename","description":"Rename a symbol across the workspace (via LSP)","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"File path"},"pattern":{"type":"string","description":"Symbol name path"},"to":{"type":"string","description":"New name"},"dry_run":{"type":"boolean","description":"Preview changes without applying"}},"required":["file","pattern","to"]}},
	\\{"name":"config","description":"Show current codescan configuration","inputSchema":{"type":"object","properties":{}}},
		\\{"name":"status","description":"Show index and watcher status","inputSchema":{"type":"object","properties":{}}}
	\\]}
;

// ---- Tests ----

test "readMessage reads newline-delimited JSON" {
	const allocator = std.testing.allocator;
	const input = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}\n{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}\n";
	var reader = std.Io.Reader.fixed(input);

	const msg1 = try readMessage(allocator, &reader);
	defer allocator.free(msg1);
	try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}", msg1);

	const msg2 = try readMessage(allocator, &reader);
	defer allocator.free(msg2);
	try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}", msg2);
}

test "readMessage returns EndOfStream on empty input" {
	const allocator = std.testing.allocator;
	var reader = std.Io.Reader.fixed("");
	try std.testing.expectError(error.EndOfStream, readMessage(allocator, &reader));
}

test "parseRequest extracts method and id" {
	const allocator = std.testing.allocator;
	const msg = "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"tools/list\",\"params\":{}}";
	const result = try parseRequest(allocator, msg);
	var parsed = result.parsed;
	defer parsed.deinit();
	try std.testing.expectEqualStrings("tools/list", result.req.method);
	try std.testing.expectEqual(@as(i64, 42), result.req.id.?.integer);
}

test "handleInitialize returns server info" {
	const allocator = std.testing.allocator;
	// Test with integer ID
	const response = try handleInitialize(allocator, .{ .integer = 1 });
	defer allocator.free(response);
	try std.testing.expect(std.mem.indexOf(u8, response, "\"protocolVersion\"") != null);
	try std.testing.expect(std.mem.indexOf(u8, response, "\"codescan\"") != null);
	try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":1") != null);
}

test "handleInitialize with string ID echoes it back" {
	const allocator = std.testing.allocator;
	const response = try handleInitialize(allocator, .{ .string = "init-1" });
	defer allocator.free(response);
	try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":\"init-1\"") != null);
	try std.testing.expect(std.mem.indexOf(u8, response, "\"protocolVersion\"") != null);
}

test "handleToolsList returns all tools" {
	const allocator = std.testing.allocator;
	const response = try handleToolsList(allocator, .{ .integer = 1 });
	defer allocator.free(response);

	// Verify all tool names are present
	const tool_names = [_][]const u8{
		"search",
		"query",
		"index",
		"symbols",
		"replace_symbol",
		"insert_after",
		"insert_before",
		"replace_lines",
		"insert_at",
		"replace_content",
		"references",
		"rename",
		"config",
		"status",
	};
	for (tool_names) |tool_name| {
		try std.testing.expect(std.mem.indexOf(u8, response, tool_name) != null);
	}
}

test "handleToolsCall dispatches symbols" {
	const allocator = std.testing.allocator;

	// Create a temp Zig file
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	try tmp.dir.writeFile(.{ .sub_path = "test.zig", .data = "pub fn hello() void {}\n" });
	const abs_path = try tmp.dir.realpathAlloc(allocator, "test.zig");
	defer allocator.free(abs_path);

	// Build params JSON
	const params_str = try std.fmt.allocPrint(allocator, "{{\"name\":\"symbols\",\"arguments\":{{\"file\":\"{s}\"}}}}", .{abs_path});
	defer allocator.free(params_str);

	var parsed = try std.json.parseFromSlice(std.json.Value, allocator, params_str, .{});
	defer parsed.deinit();

	const response = try handleToolsCall(allocator, .{ .integer = 1 }, parsed.value, .{
		.root_path = ".",
		.db_path = ":memory:",
	});
	defer allocator.free(response);

	try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":1") != null);
	try std.testing.expect(std.mem.indexOf(u8, response, "hello") != null);
}

test "handleToolsCall returns error for unknown tool" {
	const allocator = std.testing.allocator;
	const params_str = "{\"name\":\"nonexistent_tool\",\"arguments\":{}}";
	var parsed = try std.json.parseFromSlice(std.json.Value, allocator, params_str, .{});
	defer parsed.deinit();

	const response = try handleToolsCall(allocator, .{ .integer = 1 }, parsed.value, .{
		.root_path = ".",
		.db_path = ":memory:",
	});
	defer allocator.free(response);

	try std.testing.expect(std.mem.indexOf(u8, response, "\"error\"") != null);
	try std.testing.expect(std.mem.indexOf(u8, response, "unknown tool") != null);
}

test "writeMessage strips embedded newlines" {
	const allocator = std.testing.allocator;
	var w: std.io.Writer.Allocating = .init(allocator);
	defer w.deinit();
	try writeMessage(&w.writer, "line1\nline2\nline3");
	const written = w.written();
	// Should be a single line with no embedded newlines, terminated by \n
	try std.testing.expectEqualStrings("line1line2line3\n", written);
}

test "handleToolsList response is single-line valid JSON" {
	const allocator = std.testing.allocator;
	// Write the tools/list response through writeMessage
	var w: std.io.Writer.Allocating = .init(allocator);
	defer w.deinit();
	const response = try handleToolsList(allocator, .{ .integer = 1 });
	defer allocator.free(response);
	try writeMessage(&w.writer, response);
	const written = w.written();
	// Should end with exactly one newline
	try std.testing.expect(written.len > 0);
	try std.testing.expect(written[written.len - 1] == '\n');
	// The content before the newline should have no embedded newlines
	const content = written[0 .. written.len - 1];
	try std.testing.expect(std.mem.indexOf(u8, content, "\n") == null);
	// And it should be valid JSON
	var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
	defer parsed.deinit();
}

test "handleToolsCall dispatches config with settings" {
	const allocator = std.testing.allocator;
	const params_str = "{\"name\":\"config\",\"arguments\":{}}";
	var parsed = try std.json.parseFromSlice(std.json.Value, allocator, params_str, .{});
	defer parsed.deinit();

	const response = try handleToolsCall(allocator, .{ .integer = 1 }, parsed.value, .{
		.root_path = "/test/root",
		.db_path = "/test/db",
		.ollama_url = "http://localhost:11434",
		.ollama_model = "bge-large",
	});
	defer allocator.free(response);

	// Response should contain config JSON with all settings
	try std.testing.expect(std.mem.indexOf(u8, response, "/test/root") != null);
	try std.testing.expect(std.mem.indexOf(u8, response, "/test/db") != null);
	try std.testing.expect(std.mem.indexOf(u8, response, "bge-large") != null);
	try std.testing.expect(std.mem.indexOf(u8, response, "11434") != null);
}

test "handleToolsCall dispatches symbols and config" {
	const allocator = std.testing.allocator;

	// Create a temp dir with a test file
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	try tmp.dir.writeFile(.{ .sub_path = "hello.zig", .data = "pub fn greet() void {}\n" });
	const root_path = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(root_path);

	const db_path = try std.fmt.allocPrint(allocator, "{s}/.codescan/index.sqlite3", .{root_path});
	defer allocator.free(db_path);

	// Build file path for symbols call
	const file_path = try std.fmt.allocPrint(allocator, "{s}/hello.zig", .{root_path});
	defer allocator.free(file_path);

	const test_settings: Settings = .{
		.root_path = root_path,
		.db_path = db_path,
		.ollama_url = "http://localhost:11434",
		.ollama_model = "bge-large",
	};

	// Test symbols tool — no Ollama needed
	const symbols_params_str = try std.fmt.allocPrint(allocator,
		"{{\"name\":\"symbols\",\"arguments\":{{\"file\":\"{s}\"}}}}",
		.{file_path},
	);
	defer allocator.free(symbols_params_str);
	var symbols_parsed = try std.json.parseFromSlice(std.json.Value, allocator, symbols_params_str, .{});
	defer symbols_parsed.deinit();

	const symbols_response = try handleToolsCall(allocator, .{ .integer = 1 }, symbols_parsed.value, test_settings);
	defer allocator.free(symbols_response);

	try std.testing.expect(std.mem.indexOf(u8, symbols_response, "greet") != null);

	// Test config tool
	const config_params_str = "{\"name\":\"config\",\"arguments\":{}}";
	var config_parsed = try std.json.parseFromSlice(std.json.Value, allocator, config_params_str, .{});
	defer config_parsed.deinit();

	const config_response = try handleToolsCall(allocator, .{ .integer = 2 }, config_parsed.value, test_settings);
	defer allocator.free(config_response);

	try std.testing.expect(std.mem.indexOf(u8, config_response, "root") != null);
	try std.testing.expect(std.mem.indexOf(u8, config_response, "ollama_url") != null);
}

test "handleToolsCall dispatches index gracefully without Ollama" {
	const allocator = std.testing.allocator;

	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	try tmp.dir.writeFile(.{ .sub_path = "hello.zig", .data = "pub fn greet() void {}\n" });
	const root_path = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(root_path);

	const db_path = try std.fmt.allocPrint(allocator, "{s}/.codescan/index.sqlite3", .{root_path});
	defer allocator.free(db_path);

	const test_settings: Settings = .{
		.root_path = root_path,
		.db_path = db_path,
		// Use a port that won't have Ollama running
		.ollama_url = "http://localhost:19999",
		.ollama_model = "bge-large",
	};

	const index_params_str = "{\"name\":\"index\",\"arguments\":{}}";
	var index_parsed = try std.json.parseFromSlice(std.json.Value, allocator, index_params_str, .{});
	defer index_parsed.deinit();

	const index_response = try handleToolsCall(allocator, .{ .integer = 1 }, index_parsed.value, test_settings);
	defer allocator.free(index_response);

	// Should dispatch to index and return a response (error about Ollama is fine)
	try std.testing.expect(index_response.len > 0);
	// Either successful index or Ollama unavailable error — both prove correct dispatch
	const has_status = std.mem.indexOf(u8, index_response, "status") != null;
	const has_error = std.mem.indexOf(u8, index_response, "error") != null;
	try std.testing.expect(has_status or has_error);
}

test "MCP protocol compliance: full handshake with string IDs" {
	// This test simulates exactly what Claude Code does when connecting:
	// 1. Sends initialize with a STRING id
	// 2. Sends notifications/initialized (no id, no response expected)
	// 3. Sends tools/list with a STRING id
	// Each response must be:
	//   - A single line (no embedded newlines before terminator)
	//   - Valid JSON
	//   - Echo back the exact id (string, not coerced to integer)
	const allocator = std.testing.allocator;

	// Simulate the full MCP handshake through the serve loop's message handling
	const input =
		"{\"jsonrpc\":\"2.0\",\"id\":\"init-42\",\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"claude-code\",\"version\":\"1.0\"}}}\n" ++
		"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n" ++
		"{\"jsonrpc\":\"2.0\",\"id\":\"list-7\",\"method\":\"tools/list\",\"params\":{}}\n";

	// Feed through readMessage + parseRequest + handler, collecting responses via writeMessage
	var reader = std.Io.Reader.fixed(input);
	var w: std.io.Writer.Allocating = .init(allocator);
	defer w.deinit();

	var response_count: usize = 0;
	while (true) {
		const msg = readMessage(allocator, &reader) catch |err| switch (err) {
			error.EndOfStream => break,
			else => return err,
		};
		defer allocator.free(msg);
		if (msg.len == 0) continue;

		const result = try parseRequest(allocator, msg);
		var parsed = result.parsed;
		defer parsed.deinit();
		const req = result.req;

		if (std.mem.eql(u8, req.method, "notifications/initialized")) continue;

		const response = if (std.mem.eql(u8, req.method, "initialize"))
			try handleInitialize(allocator, req.id)
		else if (std.mem.eql(u8, req.method, "tools/list"))
			try handleToolsList(allocator, req.id)
		else
			try formatError(allocator, req.id, -32601, "method not found");
		defer allocator.free(response);

		try writeMessage(&w.writer, response);
		response_count += 1;
	}

	// We should have exactly 2 responses (initialize + tools/list)
	try std.testing.expectEqual(@as(usize, 2), response_count);

	// Parse the collected output line by line
	const all_output = w.written();
	var line_iter = std.mem.splitScalar(u8, all_output, '\n');

	// Response 1: initialize — must echo string id "init-42"
	const line1 = line_iter.next() orelse return error.MissingResponse;
	try std.testing.expect(line1.len > 0);
	// Must be valid JSON
	var json1 = try std.json.parseFromSlice(std.json.Value, allocator, line1, .{});
	defer json1.deinit();
	// Must have string id echoed back
	const id1 = json1.value.object.get("id") orelse return error.MissingId;
	try std.testing.expect(id1 == .string);
	try std.testing.expectEqualStrings("init-42", id1.string);
	// Must have result with protocolVersion
	try std.testing.expect(json1.value.object.get("result") != null);

	// Response 2: tools/list — must echo string id "list-7"
	const line2 = line_iter.next() orelse return error.MissingResponse;
	try std.testing.expect(line2.len > 0);
	// Must be valid JSON
	var json2 = try std.json.parseFromSlice(std.json.Value, allocator, line2, .{});
	defer json2.deinit();
	// Must have string id echoed back
	const id2 = json2.value.object.get("id") orelse return error.MissingId;
	try std.testing.expect(id2 == .string);
	try std.testing.expectEqualStrings("list-7", id2.string);
	// Must have result.tools array
	const result2 = json2.value.object.get("result") orelse return error.MissingResult;
	const tools = result2.object.get("tools") orelse return error.MissingTools;
	try std.testing.expect(tools == .array);
	try std.testing.expect(tools.array.items.len > 0);
}

test "MCP protocol compliance: integer IDs also work" {
	const allocator = std.testing.allocator;

	const input = "{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1.0\"}}}\n";

	var reader = std.Io.Reader.fixed(input);
	var w: std.io.Writer.Allocating = .init(allocator);
	defer w.deinit();

	const msg = try readMessage(allocator, &reader);
	defer allocator.free(msg);
	const result = try parseRequest(allocator, msg);
	var parsed = result.parsed;
	defer parsed.deinit();

	const response = try handleInitialize(allocator, result.req.id);
	defer allocator.free(response);
	try writeMessage(&w.writer, response);

	const line = w.written();
	// Strip trailing newline for JSON parse
	const json_str = if (line.len > 0 and line[line.len - 1] == '\n') line[0 .. line.len - 1] else line;
	var json_parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
	defer json_parsed.deinit();

	const id = json_parsed.value.object.get("id") orelse return error.MissingId;
	try std.testing.expect(id == .integer);
	try std.testing.expectEqual(@as(i64, 99), id.integer);
}

test "MCP protocol compliance: every response line is valid single-line JSON" {
	// Regression test: tools/list was multi-line due to Zig multiline string literals.
	// This would have caught the bug immediately.
	const allocator = std.testing.allocator;

	const methods = [_]struct { method: []const u8, id: []const u8 }{
		.{ .method = "initialize", .id = "a" },
		.{ .method = "tools/list", .id = "b" },
	};

	for (methods) |m| {
		const input = try std.fmt.allocPrint(
			allocator,
			"{{\"jsonrpc\":\"2.0\",\"id\":\"{s}\",\"method\":\"{s}\",\"params\":{{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{{}},\"clientInfo\":{{\"name\":\"test\",\"version\":\"1.0\"}}}}}}\n",
			.{ m.id, m.method },
		);
		defer allocator.free(input);

		var reader = std.Io.Reader.fixed(input);
		var w: std.io.Writer.Allocating = .init(allocator);
		defer w.deinit();

		const msg = try readMessage(allocator, &reader);
		defer allocator.free(msg);
		const result = try parseRequest(allocator, msg);
		var parsed = result.parsed;
		defer parsed.deinit();

		const response = if (std.mem.eql(u8, result.req.method, "initialize"))
			try handleInitialize(allocator, result.req.id)
		else
			try handleToolsList(allocator, result.req.id);
		defer allocator.free(response);

		try writeMessage(&w.writer, response);
		const written = w.written();

		// Must end with exactly one newline
		try std.testing.expect(written.len > 1);
		try std.testing.expect(written[written.len - 1] == '\n');

		// Content before newline must have NO embedded newlines
		const content = written[0 .. written.len - 1];
		if (std.mem.indexOf(u8, content, "\n")) |pos| {
			std.debug.print("MULTI-LINE RESPONSE for {s} at byte {d}: {s}\n", .{ m.method, pos, content[0..@min(200, content.len)] });
		}
		try std.testing.expect(std.mem.indexOf(u8, content, "\n") == null);

		// Must be valid JSON
		var json_parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch |err| {
			std.debug.print("INVALID JSON for {s}: {}\ncontent: {s}\n", .{ m.method, err, content[0..@min(200, content.len)] });
			return err;
		};
		defer json_parsed.deinit();

		// ID must match
		const id = json_parsed.value.object.get("id") orelse return error.MissingId;
		try std.testing.expect(id == .string);
		try std.testing.expectEqualStrings(m.id, id.string);
	}
}

test "formatError produces valid JSON-RPC error" {
	const allocator = std.testing.allocator;
	const response = try formatError(allocator, .{ .integer = 5 }, -32601, "method not found");
	defer allocator.free(response);
	try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":5") != null);
	try std.testing.expect(std.mem.indexOf(u8, response, "-32601") != null);
	try std.testing.expect(std.mem.indexOf(u8, response, "method not found") != null);
}

test "MCP search applies language filters from settings" {
	// P0 #2: MCP search must use the same filter pipeline as CLI/HTTP.
	// Without the fix, MCP passes empty allowed_langs/allowed_exts,
	// so a search_lang="zig" setting is ignored and all languages appear.
	const allocator = std.testing.allocator;

	// Create a temp dir + pre-populated DB with symbols from two languages
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	try tmp.dir.makePath(".codescan");
	const root_path = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(root_path);
	const db_path = try std.fmt.allocPrint(allocator, "{s}/.codescan/index.sqlite3", .{root_path});
	defer allocator.free(db_path);

	// Create and populate the DB directly, then close it so MCP handler can open it
	{
		const db = try storage.openFileWithVec(allocator, db_path);
		defer storage.close(db);
		_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

		// Insert a Zig symbol
		var sym_zig = model.Symbol{
			.language = try allocator.dupe(u8, "zig"),
			.file_path = try allocator.dupe(u8, "src/a.zig"),
			.name = try allocator.dupe(u8, "hello_zig"),
			.signature = try allocator.dupe(u8, "fn hello_zig() void"),
			.doc_comment = null,
			.start_line = 1,
			.end_line = 1,
		};
		defer sym_zig.deinit(allocator);
		_ = try storage.insertSymbol(db, sym_zig);

		// Insert a Python symbol with similar name
		var sym_py = model.Symbol{
			.language = try allocator.dupe(u8, "python"),
			.file_path = try allocator.dupe(u8, "src/b.py"),
			.name = try allocator.dupe(u8, "hello_python"),
			.signature = try allocator.dupe(u8, "def hello_python():"),
			.doc_comment = null,
			.start_line = 1,
			.end_line = 1,
		};
		defer sym_py.deinit(allocator);
		_ = try storage.insertSymbol(db, sym_py);
	}

	// Search via MCP callTool with search_lang="zig", lexical-only mode
	const params_str = "{\"name\":\"search\",\"arguments\":{\"query\":\"hello\"}}";
	var parsed = try std.json.parseFromSlice(std.json.Value, allocator, params_str, .{});
	defer parsed.deinit();

	const response = try handleToolsCall(allocator, .{ .integer = 1 }, parsed.value, .{
		.root_path = root_path,
		.db_path = db_path,
		.embedding_dim = 2,
		.search_mode = .lexical,
		.search_lang = "zig",
		// Use a port that won't have Ollama running
		.ollama_url = "http://localhost:19999",
		.ollama_model = "bge-large",
	});
	defer allocator.free(response);

	// The response should contain the Zig symbol but NOT the Python one
	try std.testing.expect(std.mem.indexOf(u8, response, "hello_zig") != null);
	try std.testing.expect(std.mem.indexOf(u8, response, "hello_python") == null);
}
