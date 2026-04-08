const std = @import("std");
const storage = @import("storage.zig");
const embedding = @import("embedding.zig");
const indexer = @import("indexer.zig");
const search = @import("search.zig");
const output = @import("output.zig");
const plugin = @import("plugin.zig");
const embedding_http = @import("embedding_http.zig");
const config = @import("config.zig");
const filters = @import("filters.zig");
const weights = @import("weights.zig");
const main = @import("main.zig");
const cli = @import("cli.zig");
const hashline = @import("hashline.zig");

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
	search_symbol_kind: ?[]const u8,
	primary_lang: ?[]const u8,
	include_docs: bool,
	docs_only: bool,
	comments_only: bool,
	search_top_n: usize,
	search_mode: search.SearchMode,
	search_fusion: search.FusionMode,
	search_rrf_k: f32,
	search_fts_mode: search.FtsMode,
	search_weight_vector: f32,
	search_weight_lexical: f32,
	search_min_score: f32,
	ignore_global: []const []const u8,
	always_include: []const []const u8 = &[_][]const u8{},
	ignore_lang: []const config.IgnoreOverride,
	include_node_modules: bool,
	http_host: []const u8,
	http_port: u16,
	lsp_overrides: []const config.LspOverride = &[_]config.LspOverride{},
	search_weights: ?*const weights.Table = null,
};

pub fn serve(allocator: std.mem.Allocator, settings: Settings) !void {
	try ensureParentDir(settings.db_path);
	const db = try storage.openFileWithVec(allocator, settings.db_path);
	defer storage.close(db);
	var schema_result = try storage.initSchema(allocator, db, .{ .embedding_dim = settings.embedding_dim, .embedding_model = settings.ollama_model });
	defer schema_result.deinit(allocator);
	if (schema_result.did_schema_upgrade) {
		var sb: [4096]u8 = undefined;
		var sw = std.fs.File.stderr().writer(&sb);
		const se = &sw.interface;
		_ = se.print("note: Database schema upgraded. A full re-index is strongly recommended:\n  codescan index\n", .{}) catch {};
		_ = se.flush() catch {};
	}
	if (schema_result.embedding_model_mismatch or schema_result.embedding_dim_mismatch) {
		var sb: [4096]u8 = undefined;
		var sw = std.fs.File.stderr().writer(&sb);
		const se = &sw.interface;
		if (schema_result.embedding_model_mismatch) {
			_ = se.print("error: Embedding model mismatch. Index was built with '{s}', but current model is '{s}'.\n", .{ schema_result.stored_embedding_model orelse "unknown", settings.ollama_model }) catch {};
		}
		if (schema_result.embedding_dim_mismatch) {
			_ = se.print("error: Embedding dimension mismatch. Index was built with {d}, but current setting is {d}.\n", .{ schema_result.stored_embedding_dim orelse 0, settings.embedding_dim }) catch {};
		}
		_ = se.print("Run 'codescan index' to rebuild the index with the current model.\n", .{}) catch {};
		_ = se.flush() catch {};
		return error.EmbeddingMismatch;
	}

	var http_client = embedding_http.StdHttpTransport.init(allocator);
	defer http_client.deinit();

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
	transport: embedding_http.Transport,
	base_url: []const u8,
	model_name: []const u8,
) !void {
	embedding_http.ensureModelAvailable(allocator, transport, base_url, model_name) catch |err| switch (err) {
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
		error.ModelLoading => {
			// Model exists but not loaded — embed() will trigger loading
			var stderr_buf: [4096]u8 = undefined;
			var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
			const stderr = &stderr_writer.interface;
			_ = stderr.print(
				"note: Ollama model '{s}' is loading into memory. This may take a moment...\n",
				.{model_name},
			) catch {};
			_ = stderr.flush() catch {};
			// Continue — embed will block until loaded
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
	if (req.head.method == .GET and std.mem.eql(u8, path, "/status")) {
		var out: std.io.Writer.Allocating = .init(allocator);
		defer out.deinit();
		main.runStatus(allocator, settings.db_path, settings.root_path, .json, &out.writer) catch {
			try req.respond("{\"error\":\"status failed\"}\n", .{ .status = .internal_server_error });
			return;
		};
		const payload = try out.toOwnedSlice();
		defer allocator.free(payload);
		try respondJson(req, payload);
		return;
	}

	if (req.head.method == .POST and (std.mem.eql(u8, path, "/search") or std.mem.eql(u8, path, "/query"))) {
		const body = try readBody(allocator, req, 1024 * 1024);
		defer allocator.free(body);

		var parsed = try parseSearchRequest(allocator, body);
		defer parsed.deinit(allocator);

		var search_filters = try filters.buildSearchFilters(allocator, plugin.defaultRegistry(), db, .{
			.search_ext = parsed.ext orelse settings.search_ext,
			.search_type = parsed.type orelse settings.search_type,
			.search_lang = parsed.lang orelse settings.search_lang,
			.search_symbol_kind = parsed.symbol_kind orelse settings.search_symbol_kind,
			.primary_lang = settings.primary_lang,
			.include_docs = parsed.include_docs orelse settings.include_docs,
			.docs_only = parsed.docs_only orelse settings.docs_only,
		});
		defer search_filters.deinit(allocator);

		const top_n = parsed.top_n orelse settings.search_top_n;
		const request_has_weight_override = parsed.weight_vector != null or parsed.weight_lexical != null;
		const base_weight_vector = parsed.weight_vector orelse settings.search_weight_vector;
		const base_weight_lexical = parsed.weight_lexical orelse settings.search_weight_lexical;
		const effective_weights = weights.resolveSearchWeights(
			settings.search_weights,
			search_filters.langs.items,
			base_weight_vector,
			base_weight_lexical,
			request_has_weight_override,
		);
		const sr = try search.search(allocator, db, embedder, parsed.query, .{
			.top_n = top_n,
			.mode = parsed.mode orelse settings.search_mode,
			.fusion = parsed.fusion orelse settings.search_fusion,
			.rrf_k = parsed.rrf_k orelse settings.search_rrf_k,
			.fts_mode = parsed.fts_mode orelse settings.search_fts_mode,
			.weight_vector = effective_weights.weight_vector,
			.weight_lexical = effective_weights.weight_lexical,
			.weight_symbol_kind = effective_weights.weight_symbol_kind,
			.weight_symbol_visibility = effective_weights.weight_symbol_visibility,
			.weight_symbol_scope = effective_weights.weight_symbol_scope,
			.weight_symbol_arity = effective_weights.weight_symbol_arity,
			.min_score = parsed.min_score orelse settings.search_min_score,
			.allowed_langs = search_filters.langs.items,
			.allowed_exts = search_filters.exts.items,
			.allowed_symbol_kinds = search_filters.symbol_kinds.items,
			.comments_only = parsed.comments_only orelse settings.comments_only,
		});
		defer search.freeResults(allocator, sr.results);

		var out: std.io.Writer.Allocating = .init(allocator);
		defer out.deinit();
		try output.writeResults(allocator, &out.writer, .json, sr.results, .{
			.show_comments = false,
			.use_color = false,
			.total_relevant = sr.total_relevant,
			.top_n = top_n,
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
				.embedding_model = settings.ollama_model,
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

	if (req.head.method == .POST and (std.mem.eql(u8, path, "/symbols") or std.mem.eql(u8, path, "/find-symbol"))) {
		const body = try readBody(allocator, req, 1024 * 1024);
		defer allocator.free(body);

		var files = std.ArrayListUnmanaged([]const u8){};
		defer {
			for (files.items) |f| allocator.free(f);
			files.deinit(allocator);
		}
		var pattern_owned: ?[]const u8 = null;
		defer if (pattern_owned) |p| allocator.free(p);
		var include_body_flag: bool = false;
		{
			const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
				try req.respond("{\"error\":\"invalid JSON\"}\n", .{ .status = .bad_request });
				return;
			};
			defer parsed.deinit();
			const obj = parsed.value.object;

			// "file" can be a string or an array of strings (or absent)
			if (obj.get("file")) |f| {
				switch (f) {
					.string => |s| try files.append(allocator, try allocator.dupe(u8, s)),
					.array => |arr| {
						for (arr.items) |item| {
							if (item == .string) {
								try files.append(allocator, try allocator.dupe(u8, item.string));
							}
						}
					},
					else => {},
				}
			}

			if (obj.get("pattern")) |p| {
				if (p == .string) {
					pattern_owned = try allocator.dupe(u8, p.string);
				}
			}
			if (obj.get("include_body")) |ib| {
				if (ib == .bool) include_body_flag = ib.bool;
			}
		}

		var out: std.io.Writer.Allocating = .init(allocator);
		defer out.deinit();
		main.runSymbols(allocator, files.items, pattern_owned, include_body_flag, .json, &out.writer, settings.root_path) catch {
			try req.respond("{\"error\":\"failed to extract symbols\"}\n", .{ .status = .internal_server_error });
			return;
		};
		const payload = try out.toOwnedSlice();
		defer allocator.free(payload);
		try respondJson(req, payload);
		return;
	}

	if (req.head.method == .POST and std.mem.eql(u8, path, "/replace-symbol")) {
		const body = try readBody(allocator, req, 1024 * 1024);
		defer allocator.free(body);

		var file_path: []const u8 = undefined;
		var pattern: []const u8 = undefined;
		var new_body: []const u8 = undefined;
		var version_hash: ?[]const u8 = null;
		{
			const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
				try req.respond("{\"error\":\"invalid JSON\"}\n", .{ .status = .bad_request });
				return;
			};
			defer parsed.deinit();
			const obj = parsed.value.object;
			const f = obj.get("file") orelse {
				try req.respond("{\"error\":\"missing 'file' field\"}\n", .{ .status = .bad_request });
				return;
			};
			file_path = try allocator.dupe(u8, f.string);
			const p = obj.get("pattern") orelse {
				allocator.free(file_path);
				try req.respond("{\"error\":\"missing 'pattern' field\"}\n", .{ .status = .bad_request });
				return;
			};
			pattern = try allocator.dupe(u8, p.string);
			const b = obj.get("body") orelse {
				allocator.free(file_path);
				allocator.free(pattern);
				try req.respond("{\"error\":\"missing 'body' field\"}\n", .{ .status = .bad_request });
				return;
			};
			new_body = try allocator.dupe(u8, b.string);
			if (obj.get("version")) |v| version_hash = try allocator.dupe(u8, v.string);
		}
		defer allocator.free(file_path);
		defer allocator.free(pattern);
		defer allocator.free(new_body);
		defer if (version_hash) |vh| allocator.free(vh);

		var out: std.io.Writer.Allocating = .init(allocator);
		defer out.deinit();
		main.runReplaceSymbol(allocator, file_path, pattern, new_body, version_hash, &out.writer) catch {
			try req.respond("{\"error\":\"replace-symbol failed\"}\n", .{ .status = .internal_server_error });
			return;
		};
		const payload = try out.toOwnedSlice();
		defer allocator.free(payload);
		try respondJson(req, payload);
		return;
	}

	if (req.head.method == .POST and std.mem.eql(u8, path, "/insert-after")) {
		const body = try readBody(allocator, req, 1024 * 1024);
		defer allocator.free(body);

		var file_path: []const u8 = undefined;
		var pattern: []const u8 = undefined;
		var new_body: []const u8 = undefined;
		var version_hash: ?[]const u8 = null;
		{
			const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
				try req.respond("{\"error\":\"invalid JSON\"}\n", .{ .status = .bad_request });
				return;
			};
			defer parsed.deinit();
			const obj = parsed.value.object;
			const f = obj.get("file") orelse {
				try req.respond("{\"error\":\"missing 'file' field\"}\n", .{ .status = .bad_request });
				return;
			};
			file_path = try allocator.dupe(u8, f.string);
			const p = obj.get("pattern") orelse {
				allocator.free(file_path);
				try req.respond("{\"error\":\"missing 'pattern' field\"}\n", .{ .status = .bad_request });
				return;
			};
			pattern = try allocator.dupe(u8, p.string);
			const b = obj.get("body") orelse {
				allocator.free(file_path);
				allocator.free(pattern);
				try req.respond("{\"error\":\"missing 'body' field\"}\n", .{ .status = .bad_request });
				return;
			};
			new_body = try allocator.dupe(u8, b.string);
			if (obj.get("version")) |v| version_hash = try allocator.dupe(u8, v.string);
		}
		defer allocator.free(file_path);
		defer allocator.free(pattern);
		defer allocator.free(new_body);
		defer if (version_hash) |vh| allocator.free(vh);

		var out: std.io.Writer.Allocating = .init(allocator);
		defer out.deinit();
		main.runInsertAfter(allocator, file_path, pattern, new_body, version_hash, &out.writer) catch {
			try req.respond("{\"error\":\"insert-after failed\"}\n", .{ .status = .internal_server_error });
			return;
		};
		const payload = try out.toOwnedSlice();
		defer allocator.free(payload);
		try respondJson(req, payload);
		return;
	}

	if (req.head.method == .POST and std.mem.eql(u8, path, "/insert-before")) {
		const body = try readBody(allocator, req, 1024 * 1024);
		defer allocator.free(body);

		var file_path: []const u8 = undefined;
		var pattern: []const u8 = undefined;
		var new_body: []const u8 = undefined;
		var version_hash: ?[]const u8 = null;
		{
			const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
				try req.respond("{\"error\":\"invalid JSON\"}\n", .{ .status = .bad_request });
				return;
			};
			defer parsed.deinit();
			const obj = parsed.value.object;
			const f = obj.get("file") orelse {
				try req.respond("{\"error\":\"missing 'file' field\"}\n", .{ .status = .bad_request });
				return;
			};
			file_path = try allocator.dupe(u8, f.string);
			const p = obj.get("pattern") orelse {
				allocator.free(file_path);
				try req.respond("{\"error\":\"missing 'pattern' field\"}\n", .{ .status = .bad_request });
				return;
			};
			pattern = try allocator.dupe(u8, p.string);
			const b = obj.get("body") orelse {
				allocator.free(file_path);
				allocator.free(pattern);
				try req.respond("{\"error\":\"missing 'body' field\"}\n", .{ .status = .bad_request });
				return;
			};
			new_body = try allocator.dupe(u8, b.string);
			if (obj.get("version")) |v| version_hash = try allocator.dupe(u8, v.string);
		}
		defer allocator.free(file_path);
		defer allocator.free(pattern);
		defer allocator.free(new_body);
		defer if (version_hash) |vh| allocator.free(vh);

		var out: std.io.Writer.Allocating = .init(allocator);
		defer out.deinit();
		main.runInsertBefore(allocator, file_path, pattern, new_body, version_hash, &out.writer) catch {
			try req.respond("{\"error\":\"insert-before failed\"}\n", .{ .status = .internal_server_error });
			return;
		};
		const payload = try out.toOwnedSlice();
		defer allocator.free(payload);
		try respondJson(req, payload);
		return;
	}

	if (req.head.method == .POST and std.mem.eql(u8, path, "/replace-lines")) {
		const body = try readBody(allocator, req, 1024 * 1024);
		defer allocator.free(body);

		var file_path: []const u8 = undefined;
		var from_str: []const u8 = undefined;
		var to_str: []const u8 = undefined;
		var new_body: []const u8 = undefined;
		var version_hash: ?[]const u8 = null;
		{
			const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
				try req.respond("{\"error\":\"invalid JSON\"}\n", .{ .status = .bad_request });
				return;
			};
			defer parsed.deinit();
			const obj = parsed.value.object;
			const f = obj.get("file") orelse {
				try req.respond("{\"error\":\"missing 'file' field\"}\n", .{ .status = .bad_request });
				return;
			};
			file_path = try allocator.dupe(u8, f.string);
			const fr = obj.get("from") orelse {
				allocator.free(file_path);
				try req.respond("{\"error\":\"missing 'from' field\"}\n", .{ .status = .bad_request });
				return;
			};
			from_str = try allocator.dupe(u8, fr.string);
			const to = obj.get("to") orelse {
				allocator.free(file_path);
				allocator.free(from_str);
				try req.respond("{\"error\":\"missing 'to' field\"}\n", .{ .status = .bad_request });
				return;
			};
			to_str = try allocator.dupe(u8, to.string);
			const b = obj.get("body") orelse {
				allocator.free(file_path);
				allocator.free(from_str);
				allocator.free(to_str);
				try req.respond("{\"error\":\"missing 'body' field\"}\n", .{ .status = .bad_request });
				return;
			};
			new_body = try allocator.dupe(u8, b.string);
			if (obj.get("version")) |v| version_hash = try allocator.dupe(u8, v.string);
		}
		defer allocator.free(file_path);
		defer allocator.free(from_str);
		defer allocator.free(to_str);
		defer allocator.free(new_body);
		defer if (version_hash) |vh| allocator.free(vh);

		var out: std.io.Writer.Allocating = .init(allocator);
		defer out.deinit();
		main.runReplaceLines(allocator, file_path, from_str, to_str, new_body, version_hash, &out.writer) catch {
			try req.respond("{\"error\":\"replace-lines failed\"}\n", .{ .status = .internal_server_error });
			return;
		};
		const payload = try out.toOwnedSlice();
		defer allocator.free(payload);
		try respondJson(req, payload);
		return;
	}

	if (req.head.method == .POST and std.mem.eql(u8, path, "/insert-at")) {
		const body = try readBody(allocator, req, 1024 * 1024);
		defer allocator.free(body);

		var file_path: []const u8 = undefined;
		var ref_str: []const u8 = undefined;
		var new_body: []const u8 = undefined;
		var version_hash: ?[]const u8 = null;
		{
			const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
				try req.respond("{\"error\":\"invalid JSON\"}\n", .{ .status = .bad_request });
				return;
			};
			defer parsed.deinit();
			const obj = parsed.value.object;
			const f = obj.get("file") orelse {
				try req.respond("{\"error\":\"missing 'file' field\"}\n", .{ .status = .bad_request });
				return;
			};
			file_path = try allocator.dupe(u8, f.string);
			const r = obj.get("ref") orelse {
				allocator.free(file_path);
				try req.respond("{\"error\":\"missing 'ref' field\"}\n", .{ .status = .bad_request });
				return;
			};
			ref_str = try allocator.dupe(u8, r.string);
			const b = obj.get("body") orelse {
				allocator.free(file_path);
				allocator.free(ref_str);
				try req.respond("{\"error\":\"missing 'body' field\"}\n", .{ .status = .bad_request });
				return;
			};
			new_body = try allocator.dupe(u8, b.string);
			if (obj.get("version")) |v| version_hash = try allocator.dupe(u8, v.string);
		}
		defer allocator.free(file_path);
		defer allocator.free(ref_str);
		defer allocator.free(new_body);
		defer if (version_hash) |vh| allocator.free(vh);

		var out: std.io.Writer.Allocating = .init(allocator);
		defer out.deinit();
		main.runInsertAt(allocator, file_path, ref_str, new_body, version_hash, &out.writer) catch {
			try req.respond("{\"error\":\"insert-at failed\"}\n", .{ .status = .internal_server_error });
			return;
		};
		const payload = try out.toOwnedSlice();
		defer allocator.free(payload);
		try respondJson(req, payload);
		return;
	}

	if (req.head.method == .POST and std.mem.eql(u8, path, "/replace-content")) {
		const body = try readBody(allocator, req, 1024 * 1024);
		defer allocator.free(body);

		var file_path: []const u8 = undefined;
		var needle: []const u8 = undefined;
		var new_body: []const u8 = undefined;
		var regex_mode: bool = false;
		var replace_all_flag: bool = false;
		var version_hash: ?[]const u8 = null;
		{
			const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
				try req.respond("{\"error\":\"invalid JSON\"}\n", .{ .status = .bad_request });
				return;
			};
			defer parsed.deinit();
			const obj = parsed.value.object;
			const f = obj.get("file") orelse {
				try req.respond("{\"error\":\"missing 'file' field\"}\n", .{ .status = .bad_request });
				return;
			};
			file_path = try allocator.dupe(u8, f.string);
			const n = obj.get("needle") orelse {
				allocator.free(file_path);
				try req.respond("{\"error\":\"missing 'needle' field\"}\n", .{ .status = .bad_request });
				return;
			};
			needle = try allocator.dupe(u8, n.string);
			const b = obj.get("body") orelse {
				allocator.free(file_path);
				allocator.free(needle);
				try req.respond("{\"error\":\"missing 'body' field\"}\n", .{ .status = .bad_request });
				return;
			};
			new_body = try allocator.dupe(u8, b.string);
			if (obj.get("regex")) |r| regex_mode = r.bool;
			if (obj.get("all")) |a| replace_all_flag = a.bool;
			if (obj.get("version")) |v| version_hash = try allocator.dupe(u8, v.string);
		}
		defer allocator.free(file_path);
		defer allocator.free(needle);
		defer allocator.free(new_body);
		defer if (version_hash) |vh| allocator.free(vh);

		var out: std.io.Writer.Allocating = .init(allocator);
		defer out.deinit();
		main.runReplaceContent(allocator, file_path, needle, regex_mode, replace_all_flag, new_body, version_hash, &out.writer) catch {
			try req.respond("{\"error\":\"replace-content failed\"}\n", .{ .status = .internal_server_error });
			return;
		};
		const payload = try out.toOwnedSlice();
		defer allocator.free(payload);
		try respondJson(req, payload);
		return;
	}

	if (req.head.method == .POST and std.mem.eql(u8, path, "/rename")) {
		const body = try readBody(allocator, req, 1024 * 1024);
		defer allocator.free(body);

		var file_path: []const u8 = undefined;
		var pattern: []const u8 = undefined;
		var new_name: []const u8 = undefined;
		var dry_run: bool = false;
		{
			const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
				try req.respond("{\"error\":\"invalid JSON\"}\n", .{ .status = .bad_request });
				return;
			};
			defer parsed.deinit();
			const obj = parsed.value.object;
			const f = obj.get("file") orelse {
				try req.respond("{\"error\":\"missing 'file' field\"}\n", .{ .status = .bad_request });
				return;
			};
			file_path = try allocator.dupe(u8, f.string);
			const p = obj.get("pattern") orelse {
				allocator.free(file_path);
				try req.respond("{\"error\":\"missing 'pattern' field\"}\n", .{ .status = .bad_request });
				return;
			};
			pattern = try allocator.dupe(u8, p.string);
			const t = obj.get("to") orelse {
				allocator.free(file_path);
				allocator.free(pattern);
				try req.respond("{\"error\":\"missing 'to' field\"}\n", .{ .status = .bad_request });
				return;
			};
			new_name = try allocator.dupe(u8, t.string);
			if (obj.get("dry_run")) |d| dry_run = d.bool;
		}
		defer allocator.free(file_path);
		defer allocator.free(pattern);
		defer allocator.free(new_name);

		var out: std.io.Writer.Allocating = .init(allocator);
		defer out.deinit();
		main.runRename(allocator, file_path, pattern, new_name, .json, dry_run, settings.db_path, settings.root_path, plugin.defaultRegistry(), settings.lsp_overrides, settings.embedding_dim, &out.writer) catch {
			try req.respond("{\"error\":\"rename failed\"}\n", .{ .status = .internal_server_error });
			return;
		};
		const payload = try out.toOwnedSlice();
		defer allocator.free(payload);
		try respondJson(req, payload);
		return;
	}

	if (req.head.method == .POST and std.mem.eql(u8, path, "/references")) {
		const body = try readBody(allocator, req, 1024 * 1024);
		defer allocator.free(body);

		var file_path: []const u8 = undefined;
		var pattern: []const u8 = undefined;
		{
			const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
				try req.respond("{\"error\":\"invalid JSON\"}\n", .{ .status = .bad_request });
				return;
			};
			defer parsed.deinit();
			const obj = parsed.value.object;
			const f = obj.get("file") orelse {
				try req.respond("{\"error\":\"missing 'file' field\"}\n", .{ .status = .bad_request });
				return;
			};
			file_path = try allocator.dupe(u8, f.string);
			const p = obj.get("pattern") orelse {
				allocator.free(file_path);
				try req.respond("{\"error\":\"missing 'pattern' field\"}\n", .{ .status = .bad_request });
				return;
			};
			pattern = try allocator.dupe(u8, p.string);
		}
		defer allocator.free(file_path);
		defer allocator.free(pattern);

		var out: std.io.Writer.Allocating = .init(allocator);
		defer out.deinit();
		main.runReferences(allocator, file_path, pattern, .json, settings.root_path, settings.lsp_overrides, &out.writer) catch {
			try req.respond("{\"error\":\"references request failed\"}\n", .{ .status = .internal_server_error });
			return;
		};
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
	fusion: ?search.FusionMode = null,
	rrf_k: ?f32 = null,
	fts_mode: ?search.FtsMode = null,
	weight_vector: ?f32 = null,
	weight_lexical: ?f32 = null,
	min_score: ?f32 = null,
	ext: ?[]const u8 = null,
	type: ?[]const u8 = null,
	lang: ?[]const u8 = null,
	symbol_kind: ?[]const u8 = null,
	include_docs: ?bool = null,
	docs_only: ?bool = null,
	comments_only: ?bool = null,

	pub fn deinit(self: *SearchRequest, allocator: std.mem.Allocator) void {
		allocator.free(self.query);
		if (self.ext) |value| allocator.free(value);
		if (self.type) |value| allocator.free(value);
		if (self.lang) |value| allocator.free(value);
		if (self.symbol_kind) |value| allocator.free(value);
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
		req.mode = try search.SearchMode.parse(mode.string);
	}

	if (obj.get("fusion")) |fusion| {
		if (fusion != .string) return error.InvalidRequest;
		req.fusion = try search.FusionMode.parse(fusion.string);
	}

	if (obj.get("rrf_k")) |rrf_k_val| {
		req.rrf_k = try parseWeight(rrf_k_val);
	}

	if (obj.get("fts_mode")) |fts_mode_val| {
		if (fts_mode_val != .string) return error.InvalidRequest;
		req.fts_mode = try search.FtsMode.parse(fts_mode_val.string);
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
	if (obj.get("kind")) |kind_val| {
		req.symbol_kind = try parseStringOrArray(allocator, kind_val);
	}
	if (obj.get("symbol_kind")) |kind_val| {
		if (req.symbol_kind == null)
			req.symbol_kind = try parseStringOrArray(allocator, kind_val);
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
		if (n < buf.len) break; // Short read indicates end of content
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
	var out_buf: [4096]u8 = undefined;
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
		.search_symbol_kind = null,
		.primary_lang = null,
		.include_docs = false,
		.docs_only = false,
		.comments_only = false,
		.search_top_n = 5,
		.search_mode = .vector,
		.search_fusion = .weighted_sum,
		.search_rrf_k = 60,
		.search_fts_mode = .broad,
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
	"POST /search (also /query)\n" ++
	"  fields: query, top_n, mode, weight_vector, weight_lexical, min_score\n" ++
	"          ext, type, lang, kind, path, file, include_docs, docs/only_docs, comments/only_comments\n" ++
	"\n" ++
	"POST /index\n" ++
	"  fields: ext, type, include_node_modules\n" ++
	"\n" ++
	"POST /symbols (also /find-symbol)\n" ++
	"  fields: file (string or array, optional), pattern?, include_body?\n" ++
	"\n" ++
	"POST /replace-symbol\n" ++
	"  fields: file, pattern, body\n" ++
	"\n" ++
	"POST /insert-after\n" ++
	"  fields: file, pattern, body\n" ++
	"\n" ++
	"POST /insert-before\n" ++
	"  fields: file, pattern, body\n" ++
	"\n" ++
	"POST /replace-lines\n" ++
	"  fields: file, from, to, body\n" ++
	"\n" ++
	"POST /insert-at\n" ++
	"  fields: file, ref, body\n" ++
	"\n" ++
	"POST /replace-content\n" ++
	"  fields: file, needle, body, regex?, all?\n" ++
	"\n" ++
	"POST /references\n" ++
	"  fields: file, pattern\n" ++
	"\n" ++
	"POST /rename\n" ++
	"  fields: file, pattern, to, dry_run?\n" ++
	"\n" ++
	"GET /health\n" ++
	"GET /help\n" ++
	"\n" ++
	"cli note: --show-comments/--verbose shows doc comments in human output (default: hidden)\n";

test "handleRequest responds to POST /symbols" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	var fake = FakeEmbedder{};

	// Create a temp .zig file with known content
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	const zig_content = "const x = 42;\npub fn foo() void {}\n";
	try tmp.dir.writeFile(.{ .sub_path = "test.zig", .data = zig_content });
	const abs_path = try tmp.dir.realpathAlloc(allocator, "test.zig");
	defer allocator.free(abs_path);

	// Build HTTP POST request with JSON body
	const body = try std.fmt.allocPrint(allocator, "{{\"file\":\"{s}\"}}", .{abs_path});
	defer allocator.free(body);

	const header = try std.fmt.allocPrint(allocator, "POST /symbols HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\n\r\n", .{body.len});
	defer allocator.free(header);

	const request_bytes = try std.mem.concat(allocator, u8, &.{ header, body });
	defer allocator.free(request_bytes);

	var reader = std.Io.Reader.fixed(request_bytes);
	var out_buf: [8192]u8 = undefined;
	var writer = std.Io.Writer.fixed(&out_buf);
	var http_server = std.http.Server.init(&reader, &writer);

	var req = try http_server.receiveHead();
	try handleRequest(allocator, &req, db, fake.embedder(), testSettings());

	const response = std.Io.Writer.buffered(&writer);
	try std.testing.expect(std.mem.indexOf(u8, response, "200 OK") != null);
	try std.testing.expect(std.mem.indexOf(u8, response, "application/json") != null);
	// Should contain symbol names from the zig file
	try std.testing.expect(std.mem.indexOf(u8, response, "\"x\"") != null);
	try std.testing.expect(std.mem.indexOf(u8, response, "\"foo\"") != null);
}

test "handleRequest responds to POST /find-symbol" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	var fake = FakeEmbedder{};

	// Create a temp .zig file
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	const zig_content = "const x = 42;\npub fn foo() void {}\npub fn bar() u32 { return 1; }\n";
	try tmp.dir.writeFile(.{ .sub_path = "test.zig", .data = zig_content });
	const abs_path = try tmp.dir.realpathAlloc(allocator, "test.zig");
	defer allocator.free(abs_path);

	// Search for symbol "foo"
	const body = try std.fmt.allocPrint(allocator, "{{\"file\":\"{s}\",\"pattern\":\"foo\"}}", .{abs_path});
	defer allocator.free(body);

	const header = try std.fmt.allocPrint(allocator, "POST /find-symbol HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\n\r\n", .{body.len});
	defer allocator.free(header);

	const request_bytes = try std.mem.concat(allocator, u8, &.{ header, body });
	defer allocator.free(request_bytes);

	var reader = std.Io.Reader.fixed(request_bytes);
	var out_buf: [8192]u8 = undefined;
	var writer = std.Io.Writer.fixed(&out_buf);
	var http_server = std.http.Server.init(&reader, &writer);

	var req = try http_server.receiveHead();
	try handleRequest(allocator, &req, db, fake.embedder(), testSettings());

	const response = std.Io.Writer.buffered(&writer);
	try std.testing.expect(std.mem.indexOf(u8, response, "200 OK") != null);
	try std.testing.expect(std.mem.indexOf(u8, response, "application/json") != null);
	// Should find the "foo" symbol
	try std.testing.expect(std.mem.indexOf(u8, response, "\"foo\"") != null);
	// Should NOT contain "bar" since we searched for "foo"
	try std.testing.expect(std.mem.indexOf(u8, response, "\"bar\"") == null);
}

test "handleRequest responds to POST /replace-symbol" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	var fake = FakeEmbedder{};

	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	const zig_content = "pub fn foo() u32 { return 42; }\npub fn bar() void {}\n";
	try tmp.dir.writeFile(.{ .sub_path = "test.zig", .data = zig_content });
	const abs_path = try tmp.dir.realpathAlloc(allocator, "test.zig");
	defer allocator.free(abs_path);

	const ver = (try hashline.computeFileVersion(allocator, zig_content)).?;
	const body = try std.fmt.allocPrint(allocator, "{{\"file\":\"{s}\",\"pattern\":\"foo\",\"body\":\"pub fn foo() u32 {{ return 99; }}\",\"version\":\"{s}\"}}", .{ abs_path, &ver });
	defer allocator.free(body);

	const header = try std.fmt.allocPrint(allocator, "POST /replace-symbol HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\n\r\n", .{body.len});
	defer allocator.free(header);

	const request_bytes = try std.mem.concat(allocator, u8, &.{ header, body });
	defer allocator.free(request_bytes);

	var reader = std.Io.Reader.fixed(request_bytes);
	var out_buf: [8192]u8 = undefined;
	var writer = std.Io.Writer.fixed(&out_buf);
	var http_server = std.http.Server.init(&reader, &writer);

	var req = try http_server.receiveHead();
	try handleRequest(allocator, &req, db, fake.embedder(), testSettings());

	const response = std.Io.Writer.buffered(&writer);
	try std.testing.expect(std.mem.indexOf(u8, response, "200 OK") != null);
	// Verify the file was modified
	const modified = try tmp.dir.readFileAlloc(allocator, "test.zig", 8192);
	defer allocator.free(modified);
	try std.testing.expect(std.mem.indexOf(u8, modified, "return 99") != null);
	try std.testing.expect(std.mem.indexOf(u8, modified, "return 42") == null);
}

test "handleRequest responds to POST /insert-after" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	var fake = FakeEmbedder{};

	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	const zig_content = "pub fn foo() u32 { return 42; }\npub fn bar() void {}\n";
	try tmp.dir.writeFile(.{ .sub_path = "test.zig", .data = zig_content });
	const abs_path = try tmp.dir.realpathAlloc(allocator, "test.zig");
	defer allocator.free(abs_path);

	const ver = (try hashline.computeFileVersion(allocator, zig_content)).?;
	const body = try std.fmt.allocPrint(allocator, "{{\"file\":\"{s}\",\"pattern\":\"foo\",\"body\":\"pub fn baz() void {{}}\",\"version\":\"{s}\"}}", .{ abs_path, &ver });
	defer allocator.free(body);

	const header = try std.fmt.allocPrint(allocator, "POST /insert-after HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\n\r\n", .{body.len});
	defer allocator.free(header);

	const request_bytes = try std.mem.concat(allocator, u8, &.{ header, body });
	defer allocator.free(request_bytes);

	var reader = std.Io.Reader.fixed(request_bytes);
	var out_buf: [8192]u8 = undefined;
	var writer = std.Io.Writer.fixed(&out_buf);
	var http_server = std.http.Server.init(&reader, &writer);

	var req = try http_server.receiveHead();
	try handleRequest(allocator, &req, db, fake.embedder(), testSettings());

	const response = std.Io.Writer.buffered(&writer);
	try std.testing.expect(std.mem.indexOf(u8, response, "200 OK") != null);
	// Verify baz was inserted into the file
	const modified = try tmp.dir.readFileAlloc(allocator, "test.zig", 8192);
	defer allocator.free(modified);
	try std.testing.expect(std.mem.indexOf(u8, modified, "baz") != null);
}

test "handleRequest responds to POST /insert-before" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	var fake = FakeEmbedder{};

	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	const zig_content = "pub fn foo() u32 { return 42; }\npub fn bar() void {}\n";
	try tmp.dir.writeFile(.{ .sub_path = "test.zig", .data = zig_content });
	const abs_path = try tmp.dir.realpathAlloc(allocator, "test.zig");
	defer allocator.free(abs_path);

	const ver = (try hashline.computeFileVersion(allocator, zig_content)).?;
	const body = try std.fmt.allocPrint(allocator, "{{\"file\":\"{s}\",\"pattern\":\"foo\",\"body\":\"pub fn baz() void {{}}\",\"version\":\"{s}\"}}", .{ abs_path, &ver });
	defer allocator.free(body);

	const header = try std.fmt.allocPrint(allocator, "POST /insert-before HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\n\r\n", .{body.len});
	defer allocator.free(header);

	const request_bytes = try std.mem.concat(allocator, u8, &.{ header, body });
	defer allocator.free(request_bytes);

	var reader = std.Io.Reader.fixed(request_bytes);
	var out_buf: [8192]u8 = undefined;
	var writer = std.Io.Writer.fixed(&out_buf);
	var http_server = std.http.Server.init(&reader, &writer);

	var req = try http_server.receiveHead();
	try handleRequest(allocator, &req, db, fake.embedder(), testSettings());

	const response = std.Io.Writer.buffered(&writer);
	try std.testing.expect(std.mem.indexOf(u8, response, "200 OK") != null);
	// Verify baz was inserted into the file
	const modified = try tmp.dir.readFileAlloc(allocator, "test.zig", 8192);
	defer allocator.free(modified);
	try std.testing.expect(std.mem.indexOf(u8, modified, "baz") != null);
}

test "handleRequest responds to POST /replace-lines" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	var fake = FakeEmbedder{};

	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	// Write a file with known lines
	const content = "line1\nline2\nline3\nline4\n";
	try tmp.dir.writeFile(.{ .sub_path = "test.txt", .data = content });
	const abs_path = try tmp.dir.realpathAlloc(allocator, "test.txt");
	defer allocator.free(abs_path);

	// Hashline refs computed for "line1\nline2\nline3\nline4\n": line2=pZK, line3=yO7
	// Replace lines 2-3 with new text
	const ver = (try hashline.computeFileVersion(allocator, content)).?;
	const body = try std.fmt.allocPrint(allocator, "{{\"file\":\"{s}\",\"from\":\"2:pZK\",\"to\":\"3:yO7\",\"body\":\"replaced\\n\",\"version\":\"{s}\"}}", .{ abs_path, &ver });
	defer allocator.free(body);

	const header = try std.fmt.allocPrint(allocator, "POST /replace-lines HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\n\r\n", .{body.len});
	defer allocator.free(header);

	const request_bytes = try std.mem.concat(allocator, u8, &.{ header, body });
	defer allocator.free(request_bytes);

	var reader = std.Io.Reader.fixed(request_bytes);
	var out_buf: [8192]u8 = undefined;
	var writer = std.Io.Writer.fixed(&out_buf);
	var http_server = std.http.Server.init(&reader, &writer);

	var req = try http_server.receiveHead();
	try handleRequest(allocator, &req, db, fake.embedder(), testSettings());

	const response = std.Io.Writer.buffered(&writer);
	try std.testing.expect(std.mem.indexOf(u8, response, "200 OK") != null);
	// Verify the file was modified
	const modified = try tmp.dir.readFileAlloc(allocator, "test.txt", 8192);
	defer allocator.free(modified);
	try std.testing.expect(std.mem.indexOf(u8, modified, "replaced") != null);
	try std.testing.expect(std.mem.indexOf(u8, modified, "line2") == null);
}

test "handleRequest responds to POST /insert-at" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	var fake = FakeEmbedder{};

	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	const content = "line1\nline2\nline3\n";
	try tmp.dir.writeFile(.{ .sub_path = "test.txt", .data = content });
	const abs_path = try tmp.dir.realpathAlloc(allocator, "test.txt");
	defer allocator.free(abs_path);

	// Hashline ref computed for "line1\nline2\nline3\n": line2=pZK
	// Insert after line 2
	const ver = (try hashline.computeFileVersion(allocator, content)).?;
	const body = try std.fmt.allocPrint(allocator, "{{\"file\":\"{s}\",\"ref\":\"2:pZK\",\"body\":\"inserted\\n\",\"version\":\"{s}\"}}", .{ abs_path, &ver });
	defer allocator.free(body);

	const header = try std.fmt.allocPrint(allocator, "POST /insert-at HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\n\r\n", .{body.len});
	defer allocator.free(header);

	const request_bytes = try std.mem.concat(allocator, u8, &.{ header, body });
	defer allocator.free(request_bytes);

	var reader = std.Io.Reader.fixed(request_bytes);
	var out_buf: [8192]u8 = undefined;
	var writer = std.Io.Writer.fixed(&out_buf);
	var http_server = std.http.Server.init(&reader, &writer);

	var req = try http_server.receiveHead();
	try handleRequest(allocator, &req, db, fake.embedder(), testSettings());

	const response = std.Io.Writer.buffered(&writer);
	try std.testing.expect(std.mem.indexOf(u8, response, "200 OK") != null);
	const modified = try tmp.dir.readFileAlloc(allocator, "test.txt", 8192);
	defer allocator.free(modified);
	try std.testing.expect(std.mem.indexOf(u8, modified, "inserted") != null);
}

test "handleRequest responds to POST /replace-content" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	var fake = FakeEmbedder{};

	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	const content = "hello world\ngoodbye world\n";
	try tmp.dir.writeFile(.{ .sub_path = "test.txt", .data = content });
	const abs_path = try tmp.dir.realpathAlloc(allocator, "test.txt");
	defer allocator.free(abs_path);

	// Replace "hello" with "howdy" using literal mode
	const ver = (try hashline.computeFileVersion(allocator, content)).?;
	const body = try std.fmt.allocPrint(allocator, "{{\"file\":\"{s}\",\"needle\":\"hello\",\"body\":\"howdy\",\"version\":\"{s}\"}}", .{ abs_path, &ver });
	defer allocator.free(body);

	const header = try std.fmt.allocPrint(allocator, "POST /replace-content HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\n\r\n", .{body.len});
	defer allocator.free(header);

	const request_bytes = try std.mem.concat(allocator, u8, &.{ header, body });
	defer allocator.free(request_bytes);

	var reader = std.Io.Reader.fixed(request_bytes);
	var out_buf: [8192]u8 = undefined;
	var writer = std.Io.Writer.fixed(&out_buf);
	var http_server = std.http.Server.init(&reader, &writer);

	var req = try http_server.receiveHead();
	try handleRequest(allocator, &req, db, fake.embedder(), testSettings());

	const response = std.Io.Writer.buffered(&writer);
	try std.testing.expect(std.mem.indexOf(u8, response, "200 OK") != null);
	const modified = try tmp.dir.readFileAlloc(allocator, "test.txt", 8192);
	defer allocator.free(modified);
	try std.testing.expect(std.mem.indexOf(u8, modified, "howdy world") != null);
	try std.testing.expect(std.mem.indexOf(u8, modified, "hello") == null);
}

test "handleRequest responds to POST /rename" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	var fake = FakeEmbedder{};

	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	// Use a pattern that won't match any symbol — locateSymbol returns null,
	// so rename returns error msg without starting an LSP server
	const zig_content = "pub fn foo() u32 { return 42; }\n";
	try tmp.dir.writeFile(.{ .sub_path = "test.zig", .data = zig_content });
	const abs_path = try tmp.dir.realpathAlloc(allocator, "test.zig");
	defer allocator.free(abs_path);

	const body = try std.fmt.allocPrint(allocator, "{{\"file\":\"{s}\",\"pattern\":\"nonexistent_symbol\",\"to\":\"quux\",\"dry_run\":true}}", .{abs_path});
	defer allocator.free(body);

	const header = try std.fmt.allocPrint(allocator, "POST /rename HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\n\r\n", .{body.len});
	defer allocator.free(header);

	const request_bytes = try std.mem.concat(allocator, u8, &.{ header, body });
	defer allocator.free(request_bytes);

	var reader = std.Io.Reader.fixed(request_bytes);
	var out_buf: [8192]u8 = undefined;
	var writer = std.Io.Writer.fixed(&out_buf);
	var http_server = std.http.Server.init(&reader, &writer);

	var req = try http_server.receiveHead();
	try handleRequest(allocator, &req, db, fake.embedder(), testSettings());

	const response = std.Io.Writer.buffered(&writer);
	// Endpoint reached and returned a response (200 with error in body, since .xyz has no LSP)
	try std.testing.expect(std.mem.indexOf(u8, response, "200 OK") != null);
}

test "handleRequest responds to POST /find-symbol with include_body" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	var fake = FakeEmbedder{};

	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	const zig_content = "pub fn foo() u32 { return 42; }\n";
	try tmp.dir.writeFile(.{ .sub_path = "test.zig", .data = zig_content });
	const abs_path = try tmp.dir.realpathAlloc(allocator, "test.zig");
	defer allocator.free(abs_path);

	const body = try std.fmt.allocPrint(allocator, "{{\"file\":\"{s}\",\"pattern\":\"foo\",\"include_body\":true}}", .{abs_path});
	defer allocator.free(body);

	const header = try std.fmt.allocPrint(allocator, "POST /find-symbol HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\n\r\n", .{body.len});
	defer allocator.free(header);

	const request_bytes = try std.mem.concat(allocator, u8, &.{ header, body });
	defer allocator.free(request_bytes);

	var reader = std.Io.Reader.fixed(request_bytes);
	var out_buf: [8192]u8 = undefined;
	var writer = std.Io.Writer.fixed(&out_buf);
	var http_server = std.http.Server.init(&reader, &writer);

	var req = try http_server.receiveHead();
	try handleRequest(allocator, &req, db, fake.embedder(), testSettings());

	const response = std.Io.Writer.buffered(&writer);
	try std.testing.expect(std.mem.indexOf(u8, response, "200 OK") != null);
	// With include_body, the response should contain the function body
	try std.testing.expect(std.mem.indexOf(u8, response, "return 42") != null);
}
