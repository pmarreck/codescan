const std = @import("std");

/// Minimal LSP client for cross-file operations (references, rename).
/// Spawns a language server as a child process, communicates via JSON-RPC 2.0
/// over stdin/stdout with Content-Length framing.

pub const LspError = error{
	ServerNotFound,
	InitializeFailed,
	RequestFailed,
	InvalidResponse,
	ProtocolError,
	Timeout,
	UnsupportedLanguage,
};

/// Language server binary for each supported language.
pub const ServerInfo = struct {
	binary: []const u8,
	args: []const []const u8,
};

pub fn serverForExtension(ext: []const u8) ?ServerInfo {
	const static = struct {
		const zls_args = [_][]const u8{};
		const ra_args = [_][]const u8{};
		const clangd_args = [_][]const u8{};
		const ts_args = [_][]const u8{"--stdio"};
		const pyright_args = [_][]const u8{"--stdio"};
		const gopls_args = [_][]const u8{"serve"};
		const elixir_ls_args = [_][]const u8{};
		const lua_ls_args = [_][]const u8{};
		const nil_args = [_][]const u8{};
		const hls_args = [_][]const u8{"--lsp"};
		const bash_ls_args = [_][]const u8{"--stdio"};
		const nim_args = [_][]const u8{};
	};

	if (std.mem.eql(u8, ext, ".zig"))
		return .{ .binary = "zls", .args = &static.zls_args };
	if (std.mem.eql(u8, ext, ".rs"))
		return .{ .binary = "rust-analyzer", .args = &static.ra_args };
	if (std.mem.eql(u8, ext, ".c") or std.mem.eql(u8, ext, ".h") or
		std.mem.eql(u8, ext, ".cpp") or std.mem.eql(u8, ext, ".hpp") or
		std.mem.eql(u8, ext, ".cc") or std.mem.eql(u8, ext, ".cxx"))
		return .{ .binary = "clangd", .args = &static.clangd_args };
	if (std.mem.eql(u8, ext, ".ts") or std.mem.eql(u8, ext, ".tsx") or
		std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".jsx"))
		return .{ .binary = "typescript-language-server", .args = &static.ts_args };
	if (std.mem.eql(u8, ext, ".py"))
		return .{ .binary = "pyright-langserver", .args = &static.pyright_args };
	if (std.mem.eql(u8, ext, ".go"))
		return .{ .binary = "gopls", .args = &static.gopls_args };
	if (std.mem.eql(u8, ext, ".ex") or std.mem.eql(u8, ext, ".exs"))
		return .{ .binary = "elixir-ls", .args = &static.elixir_ls_args };
	if (std.mem.eql(u8, ext, ".lua"))
		return .{ .binary = "lua-language-server", .args = &static.lua_ls_args };
	if (std.mem.eql(u8, ext, ".nix"))
		return .{ .binary = "nil", .args = &static.nil_args };
	if (std.mem.eql(u8, ext, ".hs"))
		return .{ .binary = "haskell-language-server-wrapper", .args = &static.hls_args };
	if (std.mem.eql(u8, ext, ".sh") or std.mem.eql(u8, ext, ".bash"))
		return .{ .binary = "bash-language-server", .args = &static.bash_ls_args };
	if (std.mem.eql(u8, ext, ".nim"))
		return .{ .binary = "nimlangserver", .args = &static.nim_args };
	return null;
}

/// A location returned by textDocument/references.
pub const Location = struct {
	uri: []const u8,
	start_line: u32,
	start_col: u32,
	end_line: u32,
	end_col: u32,
};

/// A single text edit within a file, returned by textDocument/rename.
pub const TextEdit = struct {
	start_line: u32,
	start_col: u32,
	end_line: u32,
	end_col: u32,
	new_text: []const u8,
};

/// A file's edits from a workspace edit.
pub const FileEdits = struct {
	uri: []const u8,
	edits: []const TextEdit,
};

/// Result of a rename operation.
pub const WorkspaceEdit = struct {
	file_edits: []const FileEdits,
};

pub const LspClient = struct {
	allocator: std.mem.Allocator,
	child: std.process.Child,
	next_id: i64 = 1,
	initialized: bool = false,

	/// Spawn the language server and perform the initialize handshake.
	pub fn start(allocator: std.mem.Allocator, server: ServerInfo, root_uri: []const u8) !LspClient {
		// Build argv: binary + args
		var argv_list: std.ArrayList([]const u8) = .{};
		defer argv_list.deinit(allocator);
		try argv_list.append(allocator, server.binary);
		for (server.args) |arg| {
			try argv_list.append(allocator, arg);
		}

		var child = std.process.Child.init(argv_list.items, allocator);
		child.stdin_behavior = .Pipe;
		child.stdout_behavior = .Pipe;
		child.stderr_behavior = .Pipe;

		child.spawn() catch return error.ServerNotFound;

		var client = LspClient{
			.allocator = allocator,
			.child = child,
		};

		try client.sendInitialize(root_uri);
		client.initialized = true;
		return client;
	}

	/// Shut down the language server cleanly.
	pub fn shutdown(self: *LspClient) void {
		if (self.initialized) {
			// Send shutdown request
			const shutdown_json =
				\\{"jsonrpc":"2.0","id":-1,"method":"shutdown","params":null}
			;
			self.writeMessage(shutdown_json) catch {};

			// Send exit notification
			const exit_json =
				\\{"jsonrpc":"2.0","method":"exit","params":null}
			;
			self.writeMessage(exit_json) catch {};
			self.initialized = false;
		}

		// Close pipes
		if (self.child.stdin) |f| f.close();
		self.child.stdin = null;
		if (self.child.stdout) |f| f.close();
		self.child.stdout = null;
		if (self.child.stderr) |f| f.close();
		self.child.stderr = null;

		// Wait for process to exit
		_ = self.child.wait() catch {};
	}

	pub fn deinit(self: *LspClient) void {
		self.shutdown();
	}

	/// Find all references to the symbol at the given position.
	/// Returns locations allocated with the client's allocator.
	pub fn references(self: *LspClient, file_uri: []const u8, line: u32, col: u32) ![]Location {
		const id = self.nextId();

		// Build request JSON
		var buf: [4096]u8 = undefined;
		const json_msg = std.fmt.bufPrint(&buf,
			\\{{"jsonrpc":"2.0","id":{d},"method":"textDocument/references","params":{{"textDocument":{{"uri":"{s}"}},"position":{{"line":{d},"character":{d}}},"context":{{"includeDeclaration":true}}}}}}
		, .{ id, file_uri, line, col }) catch return error.RequestFailed;

		try self.writeMessage(json_msg);

		// Read response
		const response = try self.readResponse(self.allocator, id);
		defer self.allocator.free(response);

		// Parse response JSON
		const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response, .{
			.ignore_unknown_fields = true,
		}) catch return error.InvalidResponse;
		defer parsed.deinit();

		return self.parseLocations(parsed.value);
	}

	/// Rename the symbol at the given position across the project.
	/// Returns workspace edits allocated with the client's allocator.
	pub fn rename(self: *LspClient, file_uri: []const u8, line: u32, col: u32, new_name: []const u8) !WorkspaceEdit {
		const id = self.nextId();

		// Build request JSON using Writer.Allocating
		var aw: std.Io.Writer.Allocating = .init(self.allocator);
		defer aw.deinit();
		const w = &aw.writer;

		try w.print(
			\\{{"jsonrpc":"2.0","id":{d},"method":"textDocument/rename","params":{{"textDocument":{{"uri":"{s}"}},"position":{{"line":{d},"character":{d}}},"newName":"
		, .{ id, file_uri, line, col });
		try writeJsonStr(w, new_name);
		try w.writeAll("\"}}");

		try self.writeMessage(aw.written());

		// Read response
		const response = try self.readResponse(self.allocator, id);
		defer self.allocator.free(response);

		// Parse response JSON
		const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response, .{
			.ignore_unknown_fields = true,
		}) catch return error.InvalidResponse;
		defer parsed.deinit();

		return self.parseWorkspaceEdit(parsed.value);
	}

	// ── Internal ──────────────────────────────────────────────

	fn nextId(self: *LspClient) i64 {
		const id = self.next_id;
		self.next_id += 1;
		return id;
	}

	fn sendInitialize(self: *LspClient, root_uri: []const u8) !void {
		const id = self.nextId();

		var buf: [4096]u8 = undefined;
		const json_msg = std.fmt.bufPrint(&buf,
			\\{{"jsonrpc":"2.0","id":{d},"method":"initialize","params":{{"processId":{d},"rootUri":"{s}","capabilities":{{"textDocument":{{"references":{{"dynamicRegistration":false}},"rename":{{"dynamicRegistration":false,"prepareSupport":false}}}}}}}}}}
		, .{ id, std.c.getpid(), root_uri }) catch return error.InitializeFailed;

		try self.writeMessage(json_msg);

		// Read initialize response
		const response = try self.readResponse(self.allocator, id);
		defer self.allocator.free(response);

		// Validate we got a result (not an error)
		const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response, .{
			.ignore_unknown_fields = true,
		}) catch return error.InitializeFailed;
		defer parsed.deinit();

		if (parsed.value != .object) return error.InitializeFailed;
		if (parsed.value.object.get("error")) |_| return error.InitializeFailed;

		// Send initialized notification
		const initialized_json =
			\\{"jsonrpc":"2.0","method":"initialized","params":{}}
		;
		try self.writeMessage(initialized_json);
	}

	/// Send textDocument/didOpen notification.
	pub fn didOpen(self: *LspClient, file_uri: []const u8, language_id_str: []const u8, source: []const u8) !void {
		// Build the JSON using Writer.Allocating since source may be large
		var aw: std.Io.Writer.Allocating = .init(self.allocator);
		defer aw.deinit();
		const w = &aw.writer;

		try w.print(
			\\{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":{{"uri":"{s}","languageId":"{s}","version":1,"text":"
		, .{ file_uri, language_id_str });
		try writeJsonStr(w, source);
		try w.writeAll("\"}}}}");

		try self.writeMessage(aw.written());
	}

	/// Write a JSON-RPC message with Content-Length framing.
	fn writeMessage(self: *LspClient, json_body: []const u8) !void {
		const stdin = self.child.stdin orelse return error.ProtocolError;
		var write_buf: [256]u8 = undefined;
		var w = stdin.writer(&write_buf);
		const wr = &w.interface;

		// Write Content-Length header
		try wr.print("Content-Length: {d}\r\n\r\n", .{json_body.len});
		// Write body
		try wr.writeAll(json_body);
		try wr.flush();
	}

	/// Read a JSON-RPC response matching the given request id.
	/// Skips notifications and responses for other ids.
	fn readResponse(self: *LspClient, allocator: std.mem.Allocator, expected_id: i64) ![]u8 {
		var attempts: usize = 0;
		while (attempts < 100) : (attempts += 1) {
			const msg = try self.readMessage(allocator);

			// Check if this response matches our expected id
			const parsed = std.json.parseFromSlice(std.json.Value, allocator, msg, .{
				.ignore_unknown_fields = true,
			}) catch {
				allocator.free(msg);
				continue;
			};

			if (parsed.value == .object) {
				if (parsed.value.object.get("id")) |id_val| {
					if (id_val == .integer and id_val.integer == expected_id) {
						parsed.deinit();
						return msg;
					}
				}
			}

			// Not our response — discard
			parsed.deinit();
			allocator.free(msg);
		}
		return error.Timeout;
	}

	/// Read a single JSON-RPC message (Content-Length framed).
	fn readMessage(self: *LspClient, allocator: std.mem.Allocator) ![]u8 {
		const stdout = self.child.stdout orelse return error.ProtocolError;
		var read_buf: [4096]u8 = undefined;
		var r = stdout.readerStreaming(&read_buf);
		const reader = &r.interface;

		// Read headers byte-by-byte until \r\n\r\n
		var content_length: usize = 0;
		var header_buf: [512]u8 = undefined;
		var header_pos: usize = 0;

		while (true) {
			const byte = reader.takeByte() catch return error.ProtocolError;
			if (header_pos >= header_buf.len) return error.ProtocolError;
			header_buf[header_pos] = byte;
			header_pos += 1;

			// Check for \r\n\r\n (end of headers)
			if (header_pos >= 4 and
				header_buf[header_pos - 4] == '\r' and
				header_buf[header_pos - 3] == '\n' and
				header_buf[header_pos - 2] == '\r' and
				header_buf[header_pos - 1] == '\n')
			{
				content_length = parseContentLength(header_buf[0..header_pos]) orelse return error.ProtocolError;
				break;
			}
		}

		if (content_length == 0 or content_length > 10 * 1024 * 1024) return error.ProtocolError;

		// Read the JSON body
		const body = try allocator.alloc(u8, content_length);
		errdefer allocator.free(body);

		reader.readSliceAll(body) catch return error.ProtocolError;
		return body;
	}

	fn parseLocations(self: *LspClient, value: std.json.Value) ![]Location {
		if (value != .object) return error.InvalidResponse;

		const result = value.object.get("result") orelse return error.InvalidResponse;
		if (result == .null) {
			const empty = try self.allocator.alloc(Location, 0);
			return empty;
		}
		if (result != .array) return error.InvalidResponse;

		var locations: std.ArrayList(Location) = .{};
		errdefer locations.deinit(self.allocator);

		for (result.array.items) |item| {
			if (item != .object) continue;
			var loc = parseOneLocation(item) orelse continue;
			// Dupe the URI so it outlives the JSON parse tree
			loc.uri = try self.allocator.dupe(u8, loc.uri);
			try locations.append(self.allocator, loc);
		}

		return locations.toOwnedSlice(self.allocator);
	}

	fn parseWorkspaceEdit(self: *LspClient, value: std.json.Value) !WorkspaceEdit {
		if (value != .object) return error.InvalidResponse;

		const result = value.object.get("result") orelse return error.InvalidResponse;
		if (result != .object) return error.InvalidResponse;

		const changes = result.object.get("changes") orelse
			return WorkspaceEdit{ .file_edits = &.{} };
		if (changes != .object) return error.InvalidResponse;

		var file_edits: std.ArrayList(FileEdits) = .{};
		errdefer file_edits.deinit(self.allocator);

		var it = changes.object.iterator();
		while (it.next()) |entry| {
			const uri = entry.key_ptr.*;
			const edits_val = entry.value_ptr.*;
			if (edits_val != .array) continue;

			var edits: std.ArrayList(TextEdit) = .{};
			errdefer edits.deinit(self.allocator);

			for (edits_val.array.items) |edit_val| {
				if (edit_val != .object) continue;
				var te = parseOneTextEdit(edit_val) orelse continue;
				// Dupe new_text so it outlives the JSON parse tree
				te.new_text = try self.allocator.dupe(u8, te.new_text);
				try edits.append(self.allocator, te);
			}

			try file_edits.append(self.allocator, .{
				.uri = try self.allocator.dupe(u8, uri),
				.edits = try edits.toOwnedSlice(self.allocator),
			});
		}

		return WorkspaceEdit{ .file_edits = try file_edits.toOwnedSlice(self.allocator) };
	}
};

// ── Helpers ──────────────────────────────────────────────

fn parseContentLength(headers: []const u8) ?usize {
	const needle = "Content-Length: ";
	const idx = std.mem.indexOf(u8, headers, needle) orelse return null;
	const start = idx + needle.len;
	const end = std.mem.indexOfPos(u8, headers, start, "\r\n") orelse return null;
	return std.fmt.parseInt(usize, headers[start..end], 10) catch null;
}

fn parseOneLocation(item: std.json.Value) ?Location {
	if (item != .object) return null;
	const uri_val = item.object.get("uri") orelse return null;
	if (uri_val != .string) return null;
	const range = item.object.get("range") orelse return null;
	if (range != .object) return null;

	const s = range.object.get("start") orelse return null;
	const e = range.object.get("end") orelse return null;

	return Location{
		.uri = uri_val.string,
		.start_line = positionField(s, "line") orelse return null,
		.start_col = positionField(s, "character") orelse return null,
		.end_line = positionField(e, "line") orelse return null,
		.end_col = positionField(e, "character") orelse return null,
	};
}

fn parseOneTextEdit(item: std.json.Value) ?TextEdit {
	if (item != .object) return null;
	const range = item.object.get("range") orelse return null;
	if (range != .object) return null;
	const new_text_val = item.object.get("newText") orelse return null;
	if (new_text_val != .string) return null;

	const s = range.object.get("start") orelse return null;
	const e = range.object.get("end") orelse return null;

	return TextEdit{
		.start_line = positionField(s, "line") orelse return null,
		.start_col = positionField(s, "character") orelse return null,
		.end_line = positionField(e, "line") orelse return null,
		.end_col = positionField(e, "character") orelse return null,
		.new_text = new_text_val.string,
	};
}

fn positionField(pos: std.json.Value, field: []const u8) ?u32 {
	if (pos != .object) return null;
	const val = pos.object.get(field) orelse return null;
	if (val != .integer) return null;
	if (val.integer < 0) return null;
	return @intCast(val.integer);
}

/// Write a JSON-safe escaped string (without surrounding quotes).
fn writeJsonStr(writer: *std.Io.Writer, s: []const u8) !void {
	for (s) |c| {
		switch (c) {
			'"' => try writer.writeAll("\\\""),
			'\\' => try writer.writeAll("\\\\"),
			'\n' => try writer.writeAll("\\n"),
			'\r' => try writer.writeAll("\\r"),
			'\t' => try writer.writeAll("\\t"),
			else => {
				if (c < 0x20) {
					try writer.print("\\u{x:0>4}", .{@as(u16, c)});
				} else {
					try writer.writeByte(c);
				}
			},
		}
	}
}

/// Convert a file system path to a file:// URI.
pub fn pathToUri(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
	const prefix = "file://";
	const uri = try allocator.alloc(u8, prefix.len + path.len);
	@memcpy(uri[0..prefix.len], prefix);
	@memcpy(uri[prefix.len..], path);
	return uri;
}

/// Extract file path from a file:// URI.
pub fn uriToPath(uri: []const u8) ?[]const u8 {
	const prefix = "file://";
	if (std.mem.startsWith(u8, uri, prefix)) {
		return uri[prefix.len..];
	}
	return null;
}

/// Map file extension to LSP language identifier.
pub fn languageId(ext: []const u8) []const u8 {
	if (std.mem.eql(u8, ext, ".zig")) return "zig";
	if (std.mem.eql(u8, ext, ".rs")) return "rust";
	if (std.mem.eql(u8, ext, ".c") or std.mem.eql(u8, ext, ".h")) return "c";
	if (std.mem.eql(u8, ext, ".cpp") or std.mem.eql(u8, ext, ".hpp") or
		std.mem.eql(u8, ext, ".cc") or std.mem.eql(u8, ext, ".cxx")) return "cpp";
	if (std.mem.eql(u8, ext, ".ts")) return "typescript";
	if (std.mem.eql(u8, ext, ".tsx")) return "typescriptreact";
	if (std.mem.eql(u8, ext, ".js")) return "javascript";
	if (std.mem.eql(u8, ext, ".jsx")) return "javascriptreact";
	if (std.mem.eql(u8, ext, ".py")) return "python";
	if (std.mem.eql(u8, ext, ".go")) return "go";
	if (std.mem.eql(u8, ext, ".ex") or std.mem.eql(u8, ext, ".exs")) return "elixir";
	if (std.mem.eql(u8, ext, ".lua")) return "lua";
	if (std.mem.eql(u8, ext, ".nix")) return "nix";
	if (std.mem.eql(u8, ext, ".hs")) return "haskell";
	if (std.mem.eql(u8, ext, ".sh") or std.mem.eql(u8, ext, ".bash")) return "shellscript";
	if (std.mem.eql(u8, ext, ".nim")) return "nim";
	return "plaintext";
}

// ── Tests ────────────────────────────────────────────────

test "parseContentLength" {
	try std.testing.expectEqual(@as(?usize, 42), parseContentLength("Content-Length: 42\r\n\r\n"));
	try std.testing.expectEqual(@as(?usize, 1234), parseContentLength("Content-Type: application/json\r\nContent-Length: 1234\r\n\r\n"));
	try std.testing.expectEqual(@as(?usize, null), parseContentLength("No-Header: here\r\n\r\n"));
}

test "pathToUri" {
	const uri = try pathToUri(std.testing.allocator, "/home/user/project");
	defer std.testing.allocator.free(uri);
	try std.testing.expectEqualStrings("file:///home/user/project", uri);
}

test "uriToPath" {
	const path = uriToPath("file:///home/user/project").?;
	try std.testing.expectEqualStrings("/home/user/project", path);

	try std.testing.expect(uriToPath("https://example.com") == null);
}

test "languageId" {
	try std.testing.expectEqualStrings("zig", languageId(".zig"));
	try std.testing.expectEqualStrings("rust", languageId(".rs"));
	try std.testing.expectEqualStrings("python", languageId(".py"));
	try std.testing.expectEqualStrings("plaintext", languageId(".xyz"));
}

test "serverForExtension" {
	const zig_server = serverForExtension(".zig").?;
	try std.testing.expectEqualStrings("zls", zig_server.binary);

	const rust_server = serverForExtension(".rs").?;
	try std.testing.expectEqualStrings("rust-analyzer", rust_server.binary);

	try std.testing.expect(serverForExtension(".unknown") == null);
}

test "writeJsonStr escaping" {
	var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
	defer aw.deinit();
	try writeJsonStr(&aw.writer, "hello\n\"world\"\t\\end");
	const result = aw.written();
	try std.testing.expectEqualStrings("hello\\n\\\"world\\\"\\t\\\\end", result);
}
