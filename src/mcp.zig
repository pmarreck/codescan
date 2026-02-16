const std = @import("std");
const main = @import("main.zig");
const cli = @import("cli.zig");
const plugin = @import("plugin.zig");
const config = @import("config.zig");

pub const Settings = struct {
	root_path: []const u8,
	db_path: []const u8,
	lsp_overrides: []const config.LspOverride = &[_]config.LspOverride{},
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
pub fn writeMessage(writer: *std.Io.Writer, msg: []const u8) !void {
	try writer.writeAll(msg);
	try writer.writeAll("\n");
	try writer.flush();
}

/// Parse a JSON-RPC request and extract method, id, and params.
pub const RpcRequest = struct {
	method: []const u8,
	id: ?i64,
	params: ?std.json.Value,
};

pub fn parseRequest(allocator: std.mem.Allocator, msg: []const u8) !struct { parsed: std.json.Parsed(std.json.Value), req: RpcRequest } {
	var parsed = try std.json.parseFromSlice(std.json.Value, allocator, msg, .{});
	errdefer parsed.deinit();

	if (parsed.value != .object) return error.InvalidRequest;
	const obj = parsed.value.object;

	const method_val = obj.get("method") orelse return error.MissingMethod;
	if (method_val != .string) return error.InvalidMethod;

	const id: ?i64 = if (obj.get("id")) |id_val| switch (id_val) {
		.integer => |v| v,
		else => null,
	} else null;

	const params = obj.get("params");

	return .{
		.parsed = parsed,
		.req = .{
			.method = method_val.string,
			.id = id,
			.params = params,
		},
	};
}

/// Format a JSON-RPC success response.
pub fn formatResult(allocator: std.mem.Allocator, id: i64, result_json: []const u8) ![]u8 {
	return std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}", .{ id, result_json });
}

/// Format a JSON-RPC error response.
pub fn formatError(allocator: std.mem.Allocator, id: ?i64, code: i64, message: []const u8) ![]u8 {
	if (id) |i| {
		return std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}", .{ i, code, message });
	} else {
		return std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}", .{ code, message });
	}
}

/// Build the initialize response.
pub fn handleInitialize(allocator: std.mem.Allocator, id: i64) ![]u8 {
	const result =
		\\{"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"codescan","version":"0.1.0"}}
	;
	return formatResult(allocator, id, result);
}

/// Build the tools/list response.
pub fn handleToolsList(allocator: std.mem.Allocator, id: i64) ![]u8 {
	return formatResult(allocator, id, tools_list_json);
}

/// Handle a tools/call request. Returns the JSON-RPC response.
pub fn handleToolsCall(allocator: std.mem.Allocator, id: i64, params: ?std.json.Value, settings: Settings) ![]u8 {
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
			else => "tool execution failed",
		};
		return formatError(allocator, id, -32603, msg);
	};
	defer allocator.free(result);

	// Wrap in MCP tool result format
	return formatToolResult(allocator, id, result);
}

fn formatToolResult(allocator: std.mem.Allocator, id: i64, text: []const u8) ![]u8 {
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

	return std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}]}}}}", .{ id, escaped_text });
}

fn callTool(allocator: std.mem.Allocator, name: []const u8, args: ?std.json.ObjectMap, settings: Settings) ![]u8 {
	var out: std.io.Writer.Allocating = .init(allocator);
	errdefer out.deinit();

	if (std.mem.eql(u8, name, "codescan_symbols")) {
		const file = getArg(args, "file") orelse return error.MissingArgument;
		main.runSymbols(allocator, file, .json, &out.writer) catch return error.ToolFailed;
	} else if (std.mem.eql(u8, name, "codescan_find_symbol")) {
		const file = getArg(args, "file") orelse return error.MissingArgument;
		const pattern = getArg(args, "pattern") orelse return error.MissingArgument;
		const include_body = getArgBool(args, "include_body");
		main.runFindSymbol(allocator, file, pattern, include_body, .json, &out.writer) catch return error.ToolFailed;
	} else if (std.mem.eql(u8, name, "codescan_replace_symbol")) {
		const file = getArg(args, "file") orelse return error.MissingArgument;
		const pattern = getArg(args, "pattern") orelse return error.MissingArgument;
		const body = getArg(args, "body") orelse return error.MissingArgument;
		main.runReplaceSymbol(allocator, file, pattern, body, &out.writer) catch return error.ToolFailed;
	} else if (std.mem.eql(u8, name, "codescan_insert_after")) {
		const file = getArg(args, "file") orelse return error.MissingArgument;
		const pattern = getArg(args, "pattern") orelse return error.MissingArgument;
		const body = getArg(args, "body") orelse return error.MissingArgument;
		main.runInsertAfter(allocator, file, pattern, body, &out.writer) catch return error.ToolFailed;
	} else if (std.mem.eql(u8, name, "codescan_insert_before")) {
		const file = getArg(args, "file") orelse return error.MissingArgument;
		const pattern = getArg(args, "pattern") orelse return error.MissingArgument;
		const body = getArg(args, "body") orelse return error.MissingArgument;
		main.runInsertBefore(allocator, file, pattern, body, &out.writer) catch return error.ToolFailed;
	} else if (std.mem.eql(u8, name, "codescan_replace_lines")) {
		const file = getArg(args, "file") orelse return error.MissingArgument;
		const from = getArg(args, "from") orelse return error.MissingArgument;
		const to = getArg(args, "to") orelse return error.MissingArgument;
		const body = getArg(args, "body") orelse return error.MissingArgument;
		main.runReplaceLines(allocator, file, from, to, body, &out.writer) catch return error.ToolFailed;
	} else if (std.mem.eql(u8, name, "codescan_insert_at")) {
		const file = getArg(args, "file") orelse return error.MissingArgument;
		const ref = getArg(args, "ref") orelse return error.MissingArgument;
		const body = getArg(args, "body") orelse return error.MissingArgument;
		main.runInsertAt(allocator, file, ref, body, &out.writer) catch return error.ToolFailed;
	} else if (std.mem.eql(u8, name, "codescan_replace_content")) {
		const file = getArg(args, "file") orelse return error.MissingArgument;
		const needle = getArg(args, "needle") orelse return error.MissingArgument;
		const body = getArg(args, "body") orelse return error.MissingArgument;
		const regex = getArgBool(args, "regex");
		const all = getArgBool(args, "all");
		main.runReplaceContent(allocator, file, needle, regex, all, body, &out.writer) catch return error.ToolFailed;
	} else if (std.mem.eql(u8, name, "codescan_references")) {
		const file = getArg(args, "file") orelse return error.MissingArgument;
		const pattern = getArg(args, "pattern") orelse return error.MissingArgument;
		main.runReferences(allocator, file, pattern, .json, settings.root_path, settings.lsp_overrides, &out.writer) catch return error.ToolFailed;
	} else if (std.mem.eql(u8, name, "codescan_rename")) {
		const file = getArg(args, "file") orelse return error.MissingArgument;
		const pattern = getArg(args, "pattern") orelse return error.MissingArgument;
		const to = getArg(args, "to") orelse return error.MissingArgument;
		const dry_run = getArgBool(args, "dry_run");
		main.runRename(allocator, file, pattern, to, .json, dry_run, settings.db_path, settings.root_path, plugin.defaultRegistry(), settings.lsp_overrides, &out.writer) catch return error.ToolFailed;
	} else if (std.mem.eql(u8, name, "codescan_search")) {
		// Search requires embedder — not available in MCP context without Ollama config
		// For now, return a descriptive error; full search needs the embedder wired in
		try out.writer.writeAll("error: search via MCP requires a running Ollama instance (not yet wired)");
	} else if (std.mem.eql(u8, name, "codescan_index")) {
		try out.writer.writeAll("error: index via MCP requires a running Ollama instance (not yet wired)");
	} else if (std.mem.eql(u8, name, "codescan_config")) {
		try out.writer.writeAll("error: config display not yet implemented via MCP");
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
			try handleInitialize(allocator, req.id orelse 0)
		else if (std.mem.eql(u8, req.method, "tools/list"))
			try handleToolsList(allocator, req.id orelse 0)
		else if (std.mem.eql(u8, req.method, "tools/call"))
			try handleToolsCall(allocator, req.id orelse 0, req.params, settings)
		else if (std.mem.eql(u8, req.method, "notifications/initialized"))
			continue // notification, no response
		else if (std.mem.eql(u8, req.method, "shutdown"))
			try formatResult(allocator, req.id orelse 0, "null")
		else
			try formatError(allocator, req.id, -32601, "method not found");

		defer allocator.free(response);
		try writeMessage(writer, response);
	}
}

// Tool definitions for MCP tools/list
const tools_list_json =
	\\{"tools":[
	\\{"name":"codescan_search","description":"Semantic code search across indexed repository","inputSchema":{"type":"object","properties":{"query":{"type":"string","description":"Search query"}},"required":["query"]}},
	\\{"name":"codescan_index","description":"Index or reindex a repository for semantic search","inputSchema":{"type":"object","properties":{}}},
	\\{"name":"codescan_symbols","description":"List all symbols (functions, classes, etc.) in a file","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"File path"}},"required":["file"]}},
	\\{"name":"codescan_find_symbol","description":"Find a symbol by name path pattern in a file","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"File path"},"pattern":{"type":"string","description":"Symbol name path pattern"},"include_body":{"type":"boolean","description":"Include symbol source code"}},"required":["file","pattern"]}},
	\\{"name":"codescan_replace_symbol","description":"Replace a symbol's entire body with new code","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"File path"},"pattern":{"type":"string","description":"Symbol name path"},"body":{"type":"string","description":"New symbol body"}},"required":["file","pattern","body"]}},
	\\{"name":"codescan_insert_after","description":"Insert code after a symbol","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"File path"},"pattern":{"type":"string","description":"Symbol name path"},"body":{"type":"string","description":"Code to insert"}},"required":["file","pattern","body"]}},
	\\{"name":"codescan_insert_before","description":"Insert code before a symbol","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"File path"},"pattern":{"type":"string","description":"Symbol name path"},"body":{"type":"string","description":"Code to insert"}},"required":["file","pattern","body"]}},
	\\{"name":"codescan_replace_lines","description":"Replace a hashline-validated line range","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"File path"},"from":{"type":"string","description":"Start hashline ref (e.g. 10:k7m)"},"to":{"type":"string","description":"End hashline ref (e.g. 20:x9a)"},"body":{"type":"string","description":"Replacement text"}},"required":["file","from","to","body"]}},
	\\{"name":"codescan_insert_at","description":"Insert code after a hashline-validated line","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"File path"},"ref":{"type":"string","description":"Hashline ref (e.g. 47:3bw)"},"body":{"type":"string","description":"Code to insert"}},"required":["file","ref","body"]}},
	\\{"name":"codescan_replace_content","description":"Find and replace text or regex in a file","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"File path"},"needle":{"type":"string","description":"Text or regex to find"},"body":{"type":"string","description":"Replacement text"},"regex":{"type":"boolean","description":"Treat needle as regex"},"all":{"type":"boolean","description":"Replace all occurrences"}},"required":["file","needle","body"]}},
	\\{"name":"codescan_references","description":"Find all references to a symbol (via LSP)","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"File path"},"pattern":{"type":"string","description":"Symbol name path"}},"required":["file","pattern"]}},
	\\{"name":"codescan_rename","description":"Rename a symbol across the workspace (via LSP)","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"File path"},"pattern":{"type":"string","description":"Symbol name path"},"to":{"type":"string","description":"New name"},"dry_run":{"type":"boolean","description":"Preview changes without applying"}},"required":["file","pattern","to"]}},
	\\{"name":"codescan_config","description":"Show current codescan configuration","inputSchema":{"type":"object","properties":{}}}
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
	try std.testing.expectEqual(@as(i64, 42), result.req.id.?);
}

test "handleInitialize returns server info" {
	const allocator = std.testing.allocator;
	const response = try handleInitialize(allocator, 1);
	defer allocator.free(response);
	try std.testing.expect(std.mem.indexOf(u8, response, "\"protocolVersion\"") != null);
	try std.testing.expect(std.mem.indexOf(u8, response, "\"codescan\"") != null);
	try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":1") != null);
}

test "handleToolsList returns all 13 tools" {
	const allocator = std.testing.allocator;
	const response = try handleToolsList(allocator, 1);
	defer allocator.free(response);

	// Verify all 13 tool names are present
	const tool_names = [_][]const u8{
		"codescan_search",
		"codescan_index",
		"codescan_symbols",
		"codescan_find_symbol",
		"codescan_replace_symbol",
		"codescan_insert_after",
		"codescan_insert_before",
		"codescan_replace_lines",
		"codescan_insert_at",
		"codescan_replace_content",
		"codescan_references",
		"codescan_rename",
		"codescan_config",
	};
	for (tool_names) |tool_name| {
		try std.testing.expect(std.mem.indexOf(u8, response, tool_name) != null);
	}
}

test "handleToolsCall dispatches codescan_symbols" {
	const allocator = std.testing.allocator;

	// Create a temp Zig file
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	try tmp.dir.writeFile(.{ .sub_path = "test.zig", .data = "pub fn hello() void {}\n" });
	const abs_path = try tmp.dir.realpathAlloc(allocator, "test.zig");
	defer allocator.free(abs_path);

	// Build params JSON
	const params_str = try std.fmt.allocPrint(allocator, "{{\"name\":\"codescan_symbols\",\"arguments\":{{\"file\":\"{s}\"}}}}", .{abs_path});
	defer allocator.free(params_str);

	var parsed = try std.json.parseFromSlice(std.json.Value, allocator, params_str, .{});
	defer parsed.deinit();

	const response = try handleToolsCall(allocator, 1, parsed.value, .{
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

	const response = try handleToolsCall(allocator, 1, parsed.value, .{
		.root_path = ".",
		.db_path = ":memory:",
	});
	defer allocator.free(response);

	try std.testing.expect(std.mem.indexOf(u8, response, "\"error\"") != null);
	try std.testing.expect(std.mem.indexOf(u8, response, "tool execution failed") != null);
}

test "formatError produces valid JSON-RPC error" {
	const allocator = std.testing.allocator;
	const response = try formatError(allocator, 5, -32601, "method not found");
	defer allocator.free(response);
	try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":5") != null);
	try std.testing.expect(std.mem.indexOf(u8, response, "-32601") != null);
	try std.testing.expect(std.mem.indexOf(u8, response, "method not found") != null);
}
