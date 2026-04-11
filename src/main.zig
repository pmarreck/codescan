const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const config = @import("config.zig");
const storage = @import("storage.zig");
const embedding = @import("embedding.zig");
const embedding_http = @import("embedding_http.zig");
const indexer = @import("indexer.zig");
const search = @import("search.zig");
const output = @import("output.zig");
const server = @import("server.zig");
const plugin = @import("plugin.zig");
const scan = @import("scan.zig");
const filters = @import("filters.zig");
const model = @import("model.zig");
const symbol_tree = @import("symbol_tree.zig");
const ts_symbols = @import("ts_symbols.zig");
const hashline = @import("hashline.zig");
const diff = @import("diff.zig");
const lsp = @import("lsp.zig");
const pcre2 = @import("pcre2.zig");
const watcher = @import("watcher.zig");
const pidfile = @import("pidfile.zig");
const watcher_mgmt = @import("watcher_mgmt.zig");
const progress_mod = @import("progress.zig");
const fs_watch = @import("fs_watch.zig");
const weights = @import("weights.zig");
const diagnostics = @import("diagnostics.zig");

/// File-scope atomic flag for POSIX signal handlers (which cannot capture closures).
var g_stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

const Defaults = struct {
	output: cli.OutputFormat = .human,
	top_n: usize = 5,
	root_path: []const u8 = ".",
	db_path: []const u8 = ".codescan/index.sqlite3",
	embedding_url: []const u8 = "http://localhost:11434",
	embedding_model: []const u8 = "bge-large",
	embedding_dim: usize = 1024,	batch_size: usize = 16,
	max_file_size: usize = 5 * 1024 * 1024,
	search_mode: search.SearchMode = .hybrid,
	fusion: search.FusionMode = .weighted_sum,
	rrf_k: f32 = 60,
	fts_mode: search.FtsMode = .broad,
	weight_vector: f32 = 0.7,
	weight_lexical: f32 = 0.3,
	min_score: f32 = 0.0,
	http_host: []const u8 = "127.0.0.1",
	http_port: u16 = 8123,
	include_docs: bool = false,
	include_node_modules: bool = false,
	index_type: []const u8 = "code,doc",
};

const Settings = struct {
	output: cli.OutputFormat,
	show_comments: bool,
	top_n: usize,
	root_path: []const u8,
	db_path: []const u8,
	db_path_owned: bool,
	embedding_url: []const u8,
	embedding_model: []const u8,
	embedding_model_owned: bool,
	embedding_dialect: embedding_http.ApiDialect = .ollama,
	embedding_auth_header: ?[]const u8 = null,
	embedding_auth_header_owned: bool = false,
	embedding_dim: usize,
	batch_size: usize,
	max_file_size: usize,
	search_mode: search.SearchMode,
	fusion: search.FusionMode,
	rrf_k: f32,
	fts_mode: search.FtsMode,
	weight_vector: f32,
	weight_lexical: f32,
	min_score: f32,
	include_docs: bool,
	docs_only: bool,
	comments_only: bool,
	include_node_modules: bool,
	index_ext: ?[]const u8,
	index_type: ?[]const u8,
	search_ext: ?[]const u8,
	search_type: ?[]const u8,
	search_lang: ?[]const u8,
	search_symbol_kind: ?[]const u8,
	primary_lang: ?[]const u8,
	ignore_global: []const []const u8,
	always_include: []const []const u8,
	ignore_lang: []const config.IgnoreOverride,
	lsp_overrides: []const config.LspOverride,
	http_host: []const u8,
	http_port: u16,
	search_weights: ?*const weights.Table,
};

pub fn main() !void {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = gpa.deinit();
	const allocator = gpa.allocator();

	const args = try std.process.argsAlloc(allocator);
	defer std.process.argsFree(allocator, args);

    var built_json_args: ?JsonEnvelopeArgs = null;
    defer if (built_json_args) |*value| value.deinit(allocator);

    const parse_args = blk: {
        if (shouldAttemptJsonEnvelope(args, std.fs.File.stdin().isTty())) {
            const stdin_text = try readStdin(allocator);
            defer allocator.free(stdin_text);
            const trimmed = std.mem.trim(u8, stdin_text, " \t\r\n");
            if (trimmed.len > 0 and (trimmed[0] == '{' or trimmed[0] == '[')) {
                built_json_args = try parseJsonEnvelopeArgs(allocator, trimmed, args[0]);
                break :blk built_json_args.?.args;
            }
        }
        break :blk args;
    };

	var stdout_buf: [4096]u8 = undefined;
	var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
	const stdout = &stdout_writer.interface;

    var parsed = cli.parse(allocator, parse_args) catch |err| {
		if (isUsageError(err)) {
			var stderr_buf: [4096]u8 = undefined;
			var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
			const stderr = &stderr_writer.interface;
			if (cli.last_err_context.len > 0) {
				_ = stderr.print("error: {s} for {s}\n\n", .{ usageErrorMessage(err), cli.last_err_context }) catch {};
			} else {
				_ = stderr.print("error: {s}\n\n", .{usageErrorMessage(err)}) catch {};
			}            _ = printUsage(stderr, null) catch {};
			_ = stderr.flush() catch {};
			std.process.exit(64);
		}
		return err;
	};
	defer parsed.deinit(allocator);

	if (parsed.command == .help) {
        try printUsage(stdout, parsed.help_topic);
		try stdout.flush();
		return;
	}

	if (parsed.assumed_search) {
		var stderr_buf: [256]u8 = undefined;
		var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
		const stderr = &stderr_writer.interface;
		_ = stderr.print("note: No verb specified, assuming 'search'.\n", .{}) catch {};
		_ = stderr.flush() catch {};
	}

	var discovered_root: ?[]u8 = null;
	defer if (discovered_root) |path| allocator.free(path);

	var config_root = parsed.root_path;
	if (!parsed.seen.root_path and parsed.command != .init and parsed.command != .clean) {
		discovered_root = try findRepoRoot(allocator, parsed.root_path);
		if (discovered_root) |root| {
			config_root = root;
		}
	}

	var cfg = try loadConfig(allocator, config_root);
	defer cfg.deinit(allocator);

	var search_weights = try loadWeights(allocator, config_root);
	defer search_weights.deinit(allocator);

	var settings = try resolveSettings(allocator, parsed, cfg, config_root);
	settings.search_weights = &search_weights;
	defer if (settings.db_path_owned) allocator.free(settings.db_path);
	defer if (settings.embedding_model_owned) allocator.free(settings.embedding_model);
	defer if (settings.embedding_auth_header_owned) allocator.free(settings.embedding_auth_header.?);

	if (settings.embedding_dialect == .openai and settings.embedding_auth_header == null) {
		var stderr_buf: [4096]u8 = undefined;
		var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
		const se = &stderr_writer.interface;
		_ = se.print("error: embedding_api=openai requires embedding_api_key to be set in config\n", .{}) catch {};
		std.process.exit(1);
	}

	const registry = plugin.defaultRegistry();

	switch (parsed.command) {
		.config => {
			const cfg_path = try configPath(allocator, config_root);
			defer allocator.free(cfg_path);

			if (parsed.config_action == .show) {
				try showConfig(allocator, cfg_path, stdout);
				try stdout.flush();
			} else {
				try editConfig(allocator, cfg_path);
			}
		},
		.init => {
			var stderr_buf: [4096]u8 = undefined;
			var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
			const stderr = &stderr_writer.interface;

			const codescan_dir = std.fs.path.dirname(settings.db_path) orelse ".codescan";

			// Check if .codescan/ already exists
			const dir_exists = blk: {
				var d = std.fs.cwd().openDir(codescan_dir, .{}) catch break :blk false;
				d.close();
				break :blk true;
			};

			if (dir_exists) {
				if (parsed.force) {
					// --force: delete and recreate
					std.fs.cwd().deleteTree(codescan_dir) catch |err| {
						_ = stderr.print("error: could not remove {s}: {s}\n", .{ codescan_dir, @errorName(err) }) catch {};
						_ = stderr.flush() catch {};
						std.process.exit(1);
					};
				} else if (std.fs.File.stdin().isTty()) {
					// Interactive: prompt user
					_ = stderr.print("{s}/ already exists. Remove and reinitialize? [y/N] ", .{codescan_dir}) catch {};
					_ = stderr.flush() catch {};
					var input_buf: [16]u8 = undefined;
					const stdin = std.fs.File.stdin();
					const n = stdin.read(&input_buf) catch 0;
					if (n > 0 and (input_buf[0] == 'y' or input_buf[0] == 'Y')) {
						std.fs.cwd().deleteTree(codescan_dir) catch |err| {
							_ = stderr.print("error: could not remove {s}: {s}\n", .{ codescan_dir, @errorName(err) }) catch {};
							_ = stderr.flush() catch {};
							std.process.exit(1);
						};
					} else {
						try stdout.print("Using existing index.\n", .{});
						try stdout.flush();
						return;
					}
				} else {
					// Non-interactive: bail
					try stdout.print("Already initialized. Use --force to reinitialize.\n", .{});
					try stdout.flush();
					return;
				}
			}

			// Create .codescan/ directory and write default config
			try ensureParentDir(settings.db_path);
			{
				const cfg_path = try configPath(allocator, config_root);
				defer allocator.free(cfg_path);
				try ensureConfigWithDefaults(cfg_path);
			}
			{
				const weights_cfg_path = try weightsPath(allocator, config_root);
				defer allocator.free(weights_cfg_path);
				try ensureWeightsWithDefaults(weights_cfg_path);
			}

			// Open DB and init schema; if the DB is corrupt, recreate it
			var db = try storage.openFileWithVec(allocator, settings.db_path);
			_ = storage.initSchema(allocator, db, .{ .embedding_dim = settings.embedding_dim, .embedding_model = settings.embedding_model }) catch {
				storage.close(db);
				_ = stderr.print("\x1b[33mnote: Database corrupt or incompatible; recreating index.\x1b[0m\n", .{}) catch {};
				_ = stderr.flush() catch {};
				db = try storage.openFileWithVecRecreate(allocator, settings.db_path);
				_ = try storage.initSchema(allocator, db, .{ .embedding_dim = settings.embedding_dim, .embedding_model = settings.embedding_model });
			};
			defer storage.close(db);

			// Try Ollama; fall back to lexical-only if unavailable
			var http_client = embedding_http.StdHttpTransport.init(allocator);
			defer http_client.deinit();
			const ollama_ok = tryInitOllama(allocator, &http_client, settings.embedding_url, settings.embedding_model, settings.embedding_dialect, stderr);

			var embedder_adapter = embedding.HttpEmbedder{
				.transport = http_client.transport(),
				.base_url = settings.embedding_url,
				.model = settings.embedding_model,
				.dialect = settings.embedding_dialect,
				.auth_header = settings.embedding_auth_header,
			};

			const show_progress = shouldShowProgress(std.fs.File.stderr().isTty(), settings.output);

			// Perform full index
			const stats = try performFullIndex(
				allocator,
				db,
				settings,
				registry,
				embedder_adapter.embedder(),
				stderr,
				show_progress,
			);

			// Print summary
			if (settings.output == .json) {
				try stdout.print("{{\"status\":\"ok\",\"files\":{d},\"symbols\":{d},\"semantic\":{s}}}\n", .{
					stats.files, stats.symbols, if (ollama_ok) "true" else "false",
				});
			} else {
				try stdout.print("Initialized codescan: {d} files, {d} symbols indexed", .{ stats.files, stats.symbols });
				if (!ollama_ok) {
					try stdout.print(" (lexical only)", .{});
				}
				try stdout.print("\n", .{});
			}
			try stdout.flush();

			// Start background watcher
			maybeStartWatcher(allocator, settings, stderr);
		},
		.index => {
			checkTmpSpace();
			try ensureParentDir(settings.db_path);
			const db = try storage.openFileWithVecRecreate(allocator, settings.db_path);
			defer storage.close(db);

			var http_client = embedding_http.StdHttpTransport.init(allocator);
			defer http_client.deinit();
			try ensureModelAvailableOrExit(allocator, http_client.transport(), settings.embedding_url, settings.embedding_model, settings.embedding_dialect);
			var embedder_adapter = embedding.HttpEmbedder{
				.transport = http_client.transport(),
				.base_url = settings.embedding_url,
				.model = settings.embedding_model,
				.dialect = settings.embedding_dialect,
				.auth_header = settings.embedding_auth_header,
			};

			var index_filters = try filters.buildIndexFilters(allocator, settings.index_ext, settings.index_type);
			defer index_filters.deinit(allocator);

			const stats = try indexer.indexAll(
				allocator,
				db,
				settings.root_path,
				registry,
				embedder_adapter.embedder(),
				.{
					.embedding_dim = settings.embedding_dim,
					.embedding_model = settings.embedding_model,
					.batch_size = settings.batch_size,
					.max_file_size = settings.max_file_size,
					.allowed_exts = index_filters.exts.items,
					.allowed_kinds = index_filters.kinds.items,
					.ignore = .{
						.global = settings.ignore_global,
						.per_language = settings.ignore_lang,
						.include_node_modules = settings.include_node_modules,
						.always_include = settings.always_include,
					},
					.show_progress = shouldShowProgress(std.fs.File.stderr().isTty(), settings.output),
				},
			);

			if (settings.output == .json) {
				try stdout.print("{{\"status\":\"ok\",\"files\":{d},\"symbols\":{d}}}\n", .{ stats.files, stats.symbols });
			} else {
				try stdout.print("Indexed {d} files, {d} symbols\n", .{ stats.files, stats.symbols });
			}
			try stdout.flush();
		},
		.update => {
			checkTmpSpace();
			try ensureParentDir(settings.db_path);
			// Warn if watcher is already running (concurrent indexing causes constraint errors)
			{
				const codescan_dir = std.fs.path.dirname(settings.db_path) orelse ".codescan";
				if (pidfile.isWatcherRunning(allocator, codescan_dir)) {
					var sb: [4096]u8 = undefined;
					var sw = std.fs.File.stderr().writer(&sb);
					const se = &sw.interface;
					_ = se.print("note: watcher is already running and keeping the index up to date.\n      Manual update is unnecessary. Use 'codescan watch stop' first if you need to force an update.\n", .{}) catch {};
					_ = se.flush() catch {};
					return;
				}
			}
			var db = try storage.openFileWithVec(allocator, settings.db_path);
			var schema_result: storage.InitSchemaResult = storage.initSchema(allocator, db, .{ .embedding_dim = settings.embedding_dim, .embedding_model = settings.embedding_model }) catch blk_retry: {
				storage.close(db);
				{
					var sb2: [4096]u8 = undefined;
					var sw2 = std.fs.File.stderr().writer(&sb2);
					const se2 = &sw2.interface;
					_ = se2.print("\x1b[33mnote: Database corrupt or incompatible; recreating index.\x1b[0m\n", .{}) catch {};
					_ = se2.flush() catch {};
				}
				db = try storage.openFileWithVecRecreate(allocator, settings.db_path);
				break :blk_retry try storage.initSchema(allocator, db, .{ .embedding_dim = settings.embedding_dim, .embedding_model = settings.embedding_model });
			};
			defer storage.close(db);
			defer schema_result.deinit(allocator);
			if (schema_result.did_schema_upgrade) {
				var sb: [4096]u8 = undefined;
				var sw = std.fs.File.stderr().writer(&sb);
				const se = &sw.interface;
				_ = se.print("\x1b[33mnote: Database schema upgraded. A full re-index is strongly recommended:\n  codescan index\x1b[0m\n", .{}) catch {};
				_ = se.flush() catch {};
			}
			if (schema_result.embedding_model_mismatch or schema_result.embedding_dim_mismatch) {
				var sb: [4096]u8 = undefined;
				var sw = std.fs.File.stderr().writer(&sb);
				const se = &sw.interface;
				if (schema_result.embedding_model_mismatch) {
					_ = se.print("error: Embedding model mismatch. Index was built with '{s}', but current model is '{s}'.\n", .{ schema_result.stored_embedding_model orelse "unknown", settings.embedding_model }) catch {};
				}
				if (schema_result.embedding_dim_mismatch) {
					_ = se.print("error: Embedding dimension mismatch. Index was built with {d}, but current setting is {d}.\n", .{ schema_result.stored_embedding_dim orelse 0, settings.embedding_dim }) catch {};
				}
				_ = se.print("Run 'codescan index' to rebuild the index with the current model.\n", .{}) catch {};
				_ = se.flush() catch {};
				std.process.exit(1);
			}

			var http_client = embedding_http.StdHttpTransport.init(allocator);
			defer http_client.deinit();
			try ensureModelAvailableOrExit(allocator, http_client.transport(), settings.embedding_url, settings.embedding_model, settings.embedding_dialect);
			var embedder_adapter = embedding.HttpEmbedder{
				.transport = http_client.transport(),
				.base_url = settings.embedding_url,
				.model = settings.embedding_model,
				.dialect = settings.embedding_dialect,
				.auth_header = settings.embedding_auth_header,
			};

			var index_filters = try filters.buildIndexFilters(allocator, settings.index_ext, settings.index_type);
			defer index_filters.deinit(allocator);

			const stats = try indexer.indexIncremental(
				allocator,
				db,
				settings.root_path,
				registry,
				embedder_adapter.embedder(),
				.{
					.embedding_dim = settings.embedding_dim,
					.embedding_model = settings.embedding_model,
					.batch_size = settings.batch_size,
					.max_file_size = settings.max_file_size,
					.allowed_exts = index_filters.exts.items,
					.allowed_kinds = index_filters.kinds.items,
					.ignore = .{
						.global = settings.ignore_global,
						.per_language = settings.ignore_lang,
						.include_node_modules = settings.include_node_modules,
						.always_include = settings.always_include,
					},
					.show_progress = shouldShowProgress(std.fs.File.stderr().isTty(), settings.output),
				},
			);

			if (settings.output == .json) {
				try stdout.print("{{\"status\":\"ok\",\"new\":{d},\"modified\":{d},\"deleted\":{d},\"unchanged\":{d},\"symbols\":{d}}}\n", .{
					stats.new_files,
					stats.modified_files,
					stats.deleted_files,
					stats.unchanged_files,
					stats.symbols,
				});
			} else {
				try stdout.print("+{d} new, ~{d} modified, -{d} deleted, ={d} unchanged ({d} symbols re-embedded)\n", .{
					stats.new_files,
					stats.modified_files,
					stats.deleted_files,
					stats.unchanged_files,
					stats.symbols,
				});
			}
			try stdout.flush();

			// Auto-launch background watcher after update
			{
				var update_stderr_buf: [4096]u8 = undefined;
				var update_stderr_writer = std.fs.File.stderr().writer(&update_stderr_buf);
				const update_stderr = &update_stderr_writer.interface;
				maybeStartWatcher(allocator, settings, update_stderr);
			}
		},
		.search => {
			const query = parsed.query orelse "";
			try ensureParentDir(settings.db_path);
			var db = try storage.openFileWithVec(allocator, settings.db_path);

			var stderr_buf: [4096]u8 = undefined;
			var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
			const stderr = &stderr_writer.interface;

			// Always run schema init/migration so older DBs get new columns
			var schema_result: storage.InitSchemaResult = storage.initSchema(allocator, db, .{ .embedding_dim = settings.embedding_dim, .embedding_model = settings.embedding_model }) catch blk_retry: {
				storage.close(db);
				_ = stderr.print("\x1b[33mnote: Database corrupt or incompatible; recreating index.\x1b[0m\n", .{}) catch {};
				_ = stderr.flush() catch {};
				db = try storage.openFileWithVecRecreate(allocator, settings.db_path);
				break :blk_retry try storage.initSchema(allocator, db, .{ .embedding_dim = settings.embedding_dim, .embedding_model = settings.embedding_model });
			};
			defer storage.close(db);
			defer schema_result.deinit(allocator);
			if (schema_result.did_schema_upgrade) {
				_ = stderr.print("\x1b[33mnote: Database schema upgraded. A full re-index is strongly recommended:\n  codescan index\x1b[0m\n", .{}) catch {};
				_ = stderr.flush() catch {};
			}
			if (schema_result.embedding_model_mismatch or schema_result.embedding_dim_mismatch) {
				if (schema_result.embedding_model_mismatch) {
					_ = stderr.print("error: Embedding model mismatch. Index was built with '{s}', but current model is '{s}'.\n", .{ schema_result.stored_embedding_model orelse "unknown", settings.embedding_model }) catch {};
				}
				if (schema_result.embedding_dim_mismatch) {
					_ = stderr.print("error: Embedding dimension mismatch. Index was built with {d}, but current setting is {d}.\n", .{ schema_result.stored_embedding_dim orelse 0, settings.embedding_dim }) catch {};
				}
				_ = stderr.print("Run 'codescan index' to rebuild the index with the current model.\n", .{}) catch {};
				_ = stderr.flush() catch {};
				std.process.exit(1);
			}

			// Regex search: skip vector/FTS entirely
			if (parsed.regex_search) {
				if (query.len == 0) {
					_ = stderr.print("error: --regex requires a search query\n", .{}) catch {};
					_ = stderr.flush() catch {};
					std.process.exit(1);
				}
				var path_filters_regex = std.ArrayListUnmanaged([]const u8){};
				defer path_filters_regex.deinit(allocator);
				for (parsed.path_filters.items) |p| {
					try path_filters_regex.append(allocator, p);
				}
				if (parsed.file_filter) |f| {
					try path_filters_regex.append(allocator, f);
				}
				try runRegexSearch(
					allocator,
					db,
					query,
					parsed.context_lines,
					settings.top_n,
					path_filters_regex.items,
					settings.search_lang,
					parsed.ignore_case,
					registry,
					settings.root_path,
					settings.output,
					stdout,
					parsed.include_body,
				);
				try stdout.flush();
				return;
			}

			var http_client = embedding_http.StdHttpTransport.init(allocator);
			defer http_client.deinit();

			// Track whether we should use lexical-only (Ollama unavailable)
			var effective_search_mode = settings.search_mode;
			var did_auto_index = false;

			// Auto-index if DB is empty
			if (!storage.isIndexPopulated(db)) {
				_ = stderr.print("note: No index found. Setting up codescan for this project...\n", .{}) catch {};
				_ = stderr.flush() catch {};

				// Auto-detect embedding server; use NullEmbedder if unavailable
				const detected = detectEmbeddingServer(allocator, http_client.transport(), settings.embedding_url, settings.embedding_model);
				const use_embeddings = detected != null and detected.?.model_available;

				if (!use_embeddings) {
					effective_search_mode = .lexical;
					if (detected) |d| {
						if (!d.model_available) {
							_ = stderr.print("  note: Embedding server found at {s} but model '{s}' not installed.\n" ++
								"  Run 'codescan setup-model' then 'codescan update' for semantic search.\n", .{ d.url, settings.embedding_model }) catch {};
						}
					} else {
						_ = stderr.print("  note: No embedding server found. Using lexical-only search.\n" ++
							"  Run 'codescan setup-model' for semantic search.\n", .{}) catch {};
					}
					_ = stderr.flush() catch {};
				}

				var embedder_adapter = embedding.HttpEmbedder{
					.transport = http_client.transport(),
					.base_url = settings.embedding_url,
					.model = settings.embedding_model,
					.dialect = settings.embedding_dialect,
					.auth_header = settings.embedding_auth_header,
				};
				const active_embedder = if (use_embeddings)
					embedder_adapter.embedder()
				else
					embedding.NullEmbedder.embedder();

				_ = try performFullIndex(
					allocator,
					db,
					settings,
					registry,
					active_embedder,
					stderr,
					shouldShowProgress(std.fs.File.stderr().isTty(), settings.output),
				);
				did_auto_index = true;
			} else {
				// Normal path: ensure Ollama if needed
				if (effective_search_mode != .lexical) {
					try ensureModelAvailableOrExit(allocator, http_client.transport(), settings.embedding_url, settings.embedding_model, settings.embedding_dialect);
				}
			}

			var embedder_adapter = embedding.HttpEmbedder{
				.transport = http_client.transport(),
				.base_url = settings.embedding_url,
				.model = settings.embedding_model,
				.dialect = settings.embedding_dialect,
				.auth_header = settings.embedding_auth_header,
			};

			var search_filters = try filters.buildSearchFilters(allocator, registry, db, .{
				.search_ext = settings.search_ext,
				.search_type = settings.search_type,
				.search_lang = settings.search_lang,
				.search_symbol_kind = settings.search_symbol_kind,
				.primary_lang = settings.primary_lang,
				.include_docs = settings.include_docs,
				.docs_only = settings.docs_only,
			});
			defer search_filters.deinit(allocator);

			const effective_weights = weights.resolveSearchWeights(
				settings.search_weights,
				search_filters.langs.items,
				settings.weight_vector,
				settings.weight_lexical,
				parsed.seen.weight_vector or parsed.seen.weight_lexical,
			);

			// Build path filters from --path and --file flags
			var path_filters = std.ArrayListUnmanaged([]const u8){};
			defer path_filters.deinit(allocator);
			for (parsed.path_filters.items) |p| {
				try path_filters.append(allocator, p);
			}
			if (parsed.file_filter) |f| {
				try path_filters.append(allocator, f);
			}

			const search_opts = search.Options{
				.top_n = settings.top_n,
				.mode = effective_search_mode,
				.fusion = settings.fusion,
				.rrf_k = settings.rrf_k,
				.fts_mode = settings.fts_mode,
				.weight_vector = effective_weights.weight_vector,
				.weight_lexical = effective_weights.weight_lexical,
				.weight_symbol_kind = effective_weights.weight_symbol_kind,
				.weight_symbol_visibility = effective_weights.weight_symbol_visibility,
				.weight_symbol_scope = effective_weights.weight_symbol_scope,
				.weight_symbol_arity = effective_weights.weight_symbol_arity,
				.min_score = settings.min_score,
				.allowed_langs = search_filters.langs.items,
				.allowed_exts = search_filters.exts.items,
				.allowed_symbol_kinds = search_filters.symbol_kinds.items,
				.allowed_paths = path_filters.items,
				.comments_only = settings.comments_only,
			};
			const sr = try search.search(
				allocator,
				db,
				embedder_adapter.embedder(),
				query,
				search_opts,
			);
			defer search.freeResults(allocator, sr.results);

			if (sr.results.len == 0) {
				const codescan_dir = std.fs.path.dirname(settings.db_path) orelse ".codescan";
				// Show per-filter diagnostic counts when 2+ filter dimensions were active
				const diag = diagnostics.countDiagnostics(allocator, db, embedder_adapter.embedder(), query, search_opts) catch null;
				const has_diag = diag != null and (diag.?.query_only != null or diag.?.kind_only != null or diag.?.lang_only != null);
				if (has_diag) {
					const d = diag.?;
					// Build a short description of active filters for the note header
					const kind_str = if (search_opts.allowed_symbol_kinds.len > 0) search_opts.allowed_symbol_kinds[0] else "";
					const lang_str = if (search_opts.allowed_langs.len > 0) search_opts.allowed_langs[0] else "";
					if (kind_str.len > 0 and lang_str.len > 0) {
						_ = stderr.print("note: no results for query \"{s}\" with kind={s} lang={s}\n", .{ query, kind_str, lang_str }) catch {};
					} else if (kind_str.len > 0) {
						_ = stderr.print("note: no results for query \"{s}\" with kind={s}\n", .{ query, kind_str }) catch {};
					} else if (lang_str.len > 0) {
						_ = stderr.print("note: no results for query \"{s}\" with lang={s}\n", .{ query, lang_str }) catch {};
					} else {
						_ = stderr.print("note: no results for query \"{s}\" with active filters\n", .{query}) catch {};
					}
					if (d.query_only) |n| {
						_ = stderr.print("  -> query alone: {d} result(s)\n", .{n}) catch {};
					}
					if (d.kind_only) |n| {
						_ = stderr.print("  -> kind filter alone: {d} result(s)\n", .{n}) catch {};
					}
					if (d.lang_only) |n| {
						_ = stderr.print("  -> lang filter alone: {d} result(s)\n", .{n}) catch {};
					}
				} else if (pidfile.isWatcherRunning(allocator, codescan_dir)) {
					_ = stderr.print(
						"note: no results found (watcher is running and index is up to date).\n",
						.{},
					) catch {};
				} else {
					_ = stderr.print(
						"note: no results found; consider re-indexing with `codescan update` or starting the watcher with `codescan watch start`.\n",
						.{},
					) catch {};
				}
				_ = stderr.flush() catch {};
			}

			// When --include-body is set, cap results at 3 unless user explicitly set --top
			var display_results = sr.results;
			const body_limit: usize = 3;
			if (parsed.include_body and !parsed.seen.top_n and sr.results.len > body_limit) {
				display_results = sr.results[0..body_limit];
				_ = stderr.print("note: --include-body limits output to {d} results to avoid overfilling context (use --top N to override).\n", .{body_limit}) catch {};
				_ = stderr.flush() catch {};
			}

			// Fetch body text for each result when --include-body is set
			if (parsed.include_body) {
				for (display_results) |*res| {
					if (res.symbol.body == null) {
						res.symbol.body = storage.getSymbolBody(allocator, db, res.id) catch null;
					}
				}
			}

			const use_color = settings.output == .human and !std.process.hasEnvVarConstant("NO_COLOR");
			try output.writeResults(allocator, stdout, settings.output, display_results, .{
				.show_comments = settings.show_comments,
				.show_body = parsed.include_body,
				.use_color = use_color,
				.total_relevant = sr.total_relevant,
				.top_n = settings.top_n,
			});
			try stdout.flush();

			// Auto-launch background watcher after first auto-index
			if (did_auto_index) {
				maybeStartWatcher(allocator, settings, stderr);
			}
		},
		.serve => {
			try server.serve(allocator, .{
				.root_path = settings.root_path,
				.db_path = settings.db_path,
				.embedding_dim = settings.embedding_dim,
				.batch_size = settings.batch_size,
				.max_file_size = settings.max_file_size,
				.embedding_url = settings.embedding_url,
				.embedding_dialect = settings.embedding_dialect,
				.embedding_auth_header = settings.embedding_auth_header,
				.embedding_model = settings.embedding_model,
				.index_ext = settings.index_ext,
				.index_type = settings.index_type,
				.search_ext = settings.search_ext,
				.search_type = settings.search_type,
				.search_lang = settings.search_lang,
				.search_symbol_kind = settings.search_symbol_kind,
				.primary_lang = settings.primary_lang,
				.include_docs = settings.include_docs,
				.docs_only = settings.docs_only,
				.comments_only = settings.comments_only,
				.search_top_n = settings.top_n,
				.search_mode = settings.search_mode,
				.search_fusion = settings.fusion,
				.search_rrf_k = settings.rrf_k,
				.search_fts_mode = settings.fts_mode,
				.search_weight_vector = settings.weight_vector,
				.search_weight_lexical = settings.weight_lexical,
				.search_min_score = settings.min_score,
				.ignore_global = settings.ignore_global,
				.always_include = settings.always_include,
				.ignore_lang = settings.ignore_lang,
				.include_node_modules = settings.include_node_modules,
				.http_host = settings.http_host,
				.http_port = settings.http_port,
				.lsp_overrides = settings.lsp_overrides,
				.search_weights = settings.search_weights,
			});
		},
		.symbols => {
			try runSymbols(allocator, parsed.symbols_files.items, parsed.pattern, parsed.include_body, parsed.output, stdout, settings.root_path);
			try stdout.flush();
		},
		.replace_symbol => {
			const pattern = parsed.pattern orelse
				exitWithError("error: replace-symbol requires a name path\nusage: echo 'new body' | codescan replace-symbol <name_path> --file <path>\n");
            const file_path = if (parsed.symbols_files.items.len > 0) parsed.symbols_files.items[0] else exitWithError("error: replace-symbol requires --file <path>\n");
			const input_text = try readStdin(allocator);
			defer allocator.free(input_text);
			try runReplaceSymbol(allocator, file_path, pattern, input_text, parsed.version_hash, stdout);
			tryReindexFile(allocator, settings.db_path, settings.root_path, file_path, registry, settings.embedding_dim);
			try stdout.flush();
		},
		.insert_after => {
			const pattern = parsed.pattern orelse
				exitWithError("error: insert-after requires a name path\nusage: echo 'code' | codescan insert-after <name_path> --file <path>\n");
            const file_path = if (parsed.symbols_files.items.len > 0) parsed.symbols_files.items[0] else exitWithError("error: insert-after requires --file <path>\n");
			const input_text = try readStdin(allocator);
			defer allocator.free(input_text);
			try runInsertAfter(allocator, file_path, pattern, input_text, parsed.version_hash, stdout);
			tryReindexFile(allocator, settings.db_path, settings.root_path, file_path, registry, settings.embedding_dim);
			try stdout.flush();
		},
		.insert_before => {
			const pattern = parsed.pattern orelse
				exitWithError("error: insert-before requires a name path\nusage: echo 'code' | codescan insert-before <name_path> --file <path>\n");
            const file_path = if (parsed.symbols_files.items.len > 0) parsed.symbols_files.items[0] else exitWithError("error: insert-before requires --file <path>\n");
			const input_text = try readStdin(allocator);
			defer allocator.free(input_text);
			try runInsertBefore(allocator, file_path, pattern, input_text, parsed.version_hash, stdout);
			tryReindexFile(allocator, settings.db_path, settings.root_path, file_path, registry, settings.embedding_dim);
			try stdout.flush();
		},
		.replace_lines => {
            const file_path = if (parsed.symbols_files.items.len > 0) parsed.symbols_files.items[0] else exitWithError("error: replace-lines requires --file <path>\n");
			const from_ref = parsed.from_ref orelse
				exitWithError("error: replace-lines requires --from <line:hash>\n");
			const to_ref = parsed.to_ref orelse
				exitWithError("error: replace-lines requires --to <line:hash>\n");
			const input_text = try readStdin(allocator);
			defer allocator.free(input_text);
			try runReplaceLines(allocator, file_path, from_ref, to_ref, input_text, parsed.version_hash, stdout);
			tryReindexFile(allocator, settings.db_path, settings.root_path, file_path, registry, settings.embedding_dim);
			try stdout.flush();
		},
		.insert_at => {
            const file_path = if (parsed.symbols_files.items.len > 0) parsed.symbols_files.items[0] else exitWithError("error: insert-at requires --file <path>\n");
			const ref = parsed.hashline_ref orelse
				exitWithError("error: insert-at requires a hashline ref\nusage: echo 'code' | codescan insert-at <line:hash> --file <path>\n");
			const input_text = try readStdin(allocator);
			defer allocator.free(input_text);
			try runInsertAt(allocator, file_path, ref, input_text, parsed.version_hash, stdout);
			tryReindexFile(allocator, settings.db_path, settings.root_path, file_path, registry, settings.embedding_dim);
			try stdout.flush();
		},
		.replace_content => {
			const needle = parsed.pattern orelse
				exitWithError("error: replace-content requires a pattern\n" ++
					"usage: echo 'replacement' | codescan replace-content '<needle>' --file <path> [--regex] [--all]\n");
			const input_text = try readStdin(allocator);
			defer allocator.free(input_text);
			if (parsed.path_filters.items.len > 0) {
				// Multi-file mode with --path
				const db = try storage.openFileWithVec(allocator, settings.db_path);
				defer storage.close(db);
				var schema_result = try storage.initSchema(allocator, db, .{ .embedding_dim = settings.embedding_dim, .embedding_model = settings.embedding_model });
				defer schema_result.deinit(allocator);
				try runReplaceContentMultiFile(allocator, db, needle, parsed.regex_mode, parsed.replace_all, input_text, parsed.path_filters.items, parsed.confirm_hash, settings.root_path, stdout);
			} else {
				// Single-file mode with --file
				const file_path = if (parsed.symbols_files.items.len > 0) parsed.symbols_files.items[0] else exitWithError("error: replace-content requires --file <path> or --path <glob>\n");
				try runReplaceContent(allocator, file_path, needle, parsed.regex_mode, parsed.replace_all, input_text, parsed.version_hash, stdout);
				tryReindexFile(allocator, settings.db_path, settings.root_path, file_path, registry, settings.embedding_dim);
			}
			try stdout.flush();
		},
		.create_file => {
			const file_path = if (parsed.symbols_files.items.len > 0) parsed.symbols_files.items[0] else exitWithError("error: create-file requires --file <path>\nusage: echo 'content' | codescan create-file --file <path>\n");
			const input_text = try readStdin(allocator);
			defer allocator.free(input_text);
			try runCreateFile(allocator, file_path, input_text, stdout);
			tryReindexFile(allocator, settings.db_path, settings.root_path, file_path, registry, settings.embedding_dim);
			try stdout.flush();
		},
		.read_file => {
			const file_path = parsed.pattern orelse
				if (parsed.symbols_files.items.len > 0) parsed.symbols_files.items[0] else exitWithError("error: read-file requires a file path\nusage: codescan read-file <path> [--from N] [--to N]\n");
			try runReadFile(allocator, file_path, parsed.from_line, parsed.to_line, parsed.output, stdout);
			try stdout.flush();
		},
		.destroy_file => {
			const file_path = if (parsed.symbols_files.items.len > 0) parsed.symbols_files.items[0] else exitWithError("error: destroy-file requires --file <path>\nusage: codescan destroy-file --file <path> [--version <hash>]\n");
			try runDestroyFile(allocator, file_path, parsed.version_hash, stdout);
			try stdout.flush();
		},
		.diff => {
			try runDiff(allocator, parsed.staged, settings.root_path, settings.output, stdout);
			try stdout.flush();
		},
		.references => {
			const pattern = parsed.pattern orelse
				exitWithError("error: references requires a name path pattern\nusage: codescan references <pattern> --file <path>\n");
            const file_path = if (parsed.symbols_files.items.len > 0) parsed.symbols_files.items[0] else exitWithError("error: references requires --file <path>\n");
			try runReferences(allocator, file_path, pattern, parsed.output, settings.root_path, settings.lsp_overrides, stdout);
			try stdout.flush();
		},
		.rename => {
			const pattern = parsed.pattern orelse
				exitWithError("error: rename requires a name path pattern\nusage: codescan rename <pattern> --file <path> --to <new_name>\n");
            const file_path = if (parsed.symbols_files.items.len > 0) parsed.symbols_files.items[0] else exitWithError("error: rename requires --file <path>\n");
			const new_name = parsed.rename_to orelse
				exitWithError("error: rename requires --to <new_name>\n");
			try runRename(allocator, file_path, pattern, new_name, parsed.output, parsed.dry_run, settings.db_path, settings.root_path, registry, settings.lsp_overrides, settings.embedding_dim, stdout);
			try stdout.flush();
		},
		.mcp_serve => {
			const mcp = @import("mcp.zig");
			try mcp.serve(allocator, .{
				.root_path = settings.root_path,
				.db_path = settings.db_path,
				.lsp_overrides = settings.lsp_overrides,
				.embedding_url = settings.embedding_url,
				.embedding_dialect = settings.embedding_dialect,
				.embedding_auth_header = settings.embedding_auth_header,
				.embedding_model = settings.embedding_model,
				.embedding_dim = settings.embedding_dim,
				.batch_size = settings.batch_size,
				.max_file_size = settings.max_file_size,
				.search_top_n = settings.top_n,
				.search_mode = settings.search_mode,
				.search_fusion = settings.fusion,
				.search_rrf_k = settings.rrf_k,
				.search_fts_mode = settings.fts_mode,
				.search_weight_vector = settings.weight_vector,
				.search_weight_lexical = settings.weight_lexical,
				.search_min_score = settings.min_score,
				.search_ext = settings.search_ext,
				.search_type = settings.search_type,
				.search_lang = settings.search_lang,
				.search_symbol_kind = settings.search_symbol_kind,
				.primary_lang = settings.primary_lang,
				.include_docs = settings.include_docs,
				.docs_only = settings.docs_only,
				.comments_only = settings.comments_only,
				.ignore_global = settings.ignore_global,
				.always_include = settings.always_include,
				.ignore_lang = settings.ignore_lang,
				.include_node_modules = settings.include_node_modules,
				.search_weights = settings.search_weights,
			});
		},
		.watch => {
			const codescan_dir = std.fs.path.dirname(settings.db_path) orelse ".codescan";

			switch (parsed.watch_action) {
				.stop => {
					if (comptime builtin.os.tag == .windows) {
						try stdout.print("error: watch stop is not supported on Windows\n", .{});
						try stdout.flush();
					} else {
						if (pidfile.readAndCheckPid(allocator, codescan_dir) catch null) |pid_val| {
							_ = std.c.kill(pid_val, std.posix.SIG.TERM);
							try stdout.print("Stopped watcher (PID {d})\n", .{pid_val});
							try stdout.flush();
							pidfile.removePid(allocator, codescan_dir);
						} else {
							try stdout.print("No watcher running\n", .{});
							try stdout.flush();
						}
					}
				},
				.start => {
					if (pidfile.isWatcherRunning(allocator, codescan_dir)) {
						if (pidfile.readAndCheckPid(allocator, codescan_dir) catch null) |existing_pid| {
							try stdout.print("Watcher already running (PID {d})\n", .{existing_pid});
						} else {
							try stdout.print("Watcher already running\n", .{});
						}
						try stdout.flush();
					} else {
						maybeStartWatcher(allocator, settings, stdout);
					}
				},
				.restart => {
					if (comptime builtin.os.tag == .windows) {
						try stdout.print("error: watch restart is not supported on Windows\n", .{});
						try stdout.flush();
					} else {
						// Stop if running
						if (pidfile.readAndCheckPid(allocator, codescan_dir) catch null) |pid_val| {
							_ = std.c.kill(pid_val, std.posix.SIG.TERM);
							try stdout.print("Stopped watcher (PID {d})\n", .{pid_val});
							// Brief pause for process cleanup
							std.Thread.sleep(200 * std.time.ns_per_ms);
							pidfile.removePid(allocator, codescan_dir);
						}
						maybeStartWatcher(allocator, settings, stdout);
					}
				},
				.status => {
					if (pidfile.readAndCheckPid(allocator, codescan_dir) catch null) |pid_val| {
						try stdout.print("Watcher running (PID {d})\n", .{pid_val});
					} else {
						try stdout.print("No watcher running\n", .{});
					}
					try stdout.flush();
				},
				.pid => {
					if (pidfile.readAndCheckPid(allocator, codescan_dir) catch null) |pid_val| {
						try stdout.print("{d}\n", .{pid_val});
					}
					try stdout.flush();
				},
				.list => {
					var watchers = watcher_mgmt.discoverWatchers(allocator) catch |err| {
						try stdout.print("error: failed to discover watchers: {}\n", .{err});
						try stdout.flush();
						std.process.exit(1);
					};
					defer {
						for (watchers.items) |*w| w.deinit(allocator);
						watchers.deinit(allocator);
					}

					if (watchers.items.len == 0) {
						try stdout.print("No codescan watchers running.\n", .{});
						try stdout.flush();
					} else {
						// Get active cwds to mark orphans
						var cwds = watcher_mgmt.getActiveCwds(allocator) catch std.ArrayListUnmanaged(watcher_mgmt.LsofEntry){};
						defer {
							for (cwds.items) |e| e.deinit(allocator);
							cwds.deinit(allocator);
						}
						watcher_mgmt.markActiveWatchers(watchers.items, cwds.items);

						try stdout.print("{s:<8}{s:<7}{s:<14}{s:<6}{s}\n", .{ "PID", "CPU%", "UPTIME", "USED", "ROOT" });
						for (watchers.items) |w| {
							try stdout.print("{:<8}{s:<7}{s:<14}{s:<6}{s}\n", .{
								@as(u32, @intCast(w.pid)),
								w.cpu_pct,
								w.elapsed,
								if (w.active) "yes" else "no",
								w.root,
							});						}
						var orphan_count: usize = 0;
						for (watchers.items) |w| {
							if (!w.active) orphan_count += 1;
						}
						try stdout.print("\n{d} watcher{s}, {d} orphaned\n", .{
							watchers.items.len,
							if (watchers.items.len != 1) "s" else "",
							orphan_count,
						});
						try stdout.flush();
					}
				},
				.prune => {
					var watchers = watcher_mgmt.discoverWatchers(allocator) catch |err| {
						try stdout.print("error: failed to discover watchers: {}\n", .{err});
						try stdout.flush();
						std.process.exit(1);
					};
					defer {
						for (watchers.items) |*w| w.deinit(allocator);
						watchers.deinit(allocator);
					}

					var cwds = watcher_mgmt.getActiveCwds(allocator) catch std.ArrayListUnmanaged(watcher_mgmt.LsofEntry){};
					defer {
						for (cwds.items) |e| e.deinit(allocator);
						cwds.deinit(allocator);
					}
					watcher_mgmt.markActiveWatchers(watchers.items, cwds.items);

					var orphan_count: usize = 0;
					for (watchers.items) |w| {
						if (!w.active) orphan_count += 1;
					}

					if (orphan_count == 0) {
						try stdout.print("No orphaned watchers found.\n", .{});
						try stdout.flush();
					} else if (!parsed.confirm) {
						try stdout.print("Orphaned watchers (no active sessions):\n", .{});
						for (watchers.items) |w| {
							if (!w.active) {
								try stdout.print("  PID {d}  {s}\n", .{ w.pid, w.root });
							}
						}
						try stdout.print("\nRun with --confirm to stop {d} orphaned watcher{s}.\n", .{
							orphan_count,
							if (orphan_count != 1) "s" else "",
						});
						try stdout.flush();
					} else {
						var stopped: usize = 0;
						for (watchers.items) |w| {
							if (!w.active) {
								if (watcher_mgmt.stopWatcher(w.pid)) {
									try stdout.print("Stopped watcher for {s} (PID {d})\n", .{ w.root, w.pid });
									stopped += 1;
								} else {
									try stdout.print("Failed to stop watcher for {s} (PID {d})\n", .{ w.root, w.pid });
								}
							}
						}
						const remaining = watchers.items.len - stopped;
						try stdout.print("\nStopped {d} orphaned watcher{s}. {d} active watcher{s} remain.\n", .{
							stopped,
							if (stopped != 1) "s" else "",
							remaining,
							if (remaining != 1) "s" else "",
						});
						try stdout.flush();
					}
				},
				.run => {
					try ensureParentDir(settings.db_path);
					// Open existing DB or create new one (don't destroy existing index)
					var db = try storage.openFileWithVec(allocator, settings.db_path);
					var schema_result: storage.InitSchemaResult = storage.initSchema(allocator, db, .{ .embedding_dim = settings.embedding_dim, .embedding_model = settings.embedding_model }) catch blk_retry: {
						storage.close(db);
						{
							var sb2: [4096]u8 = undefined;
							var sw2 = std.fs.File.stderr().writer(&sb2);
							const se2 = &sw2.interface;
							_ = se2.print("\x1b[33mnote: Database corrupt or incompatible; recreating index.\x1b[0m\n", .{}) catch {};
							_ = se2.flush() catch {};
						}
						db = try storage.openFileWithVecRecreate(allocator, settings.db_path);
						break :blk_retry try storage.initSchema(allocator, db, .{ .embedding_dim = settings.embedding_dim, .embedding_model = settings.embedding_model });
					};
					defer storage.close(db);
					defer schema_result.deinit(allocator);
					if (schema_result.did_schema_upgrade) {
						var sb: [4096]u8 = undefined;
						var sw = std.fs.File.stderr().writer(&sb);
						const se = &sw.interface;
						_ = se.print("\x1b[33mnote: Database schema upgraded. A full re-index is strongly recommended:\n  codescan index\x1b[0m\n", .{}) catch {};
						_ = se.flush() catch {};
					}
					if (schema_result.embedding_model_mismatch or schema_result.embedding_dim_mismatch) {
						var sb: [4096]u8 = undefined;
						var sw = std.fs.File.stderr().writer(&sb);
						const se = &sw.interface;
						if (schema_result.embedding_model_mismatch) {
							_ = se.print("error: Embedding model mismatch. Index was built with '{s}', but current model is '{s}'.\n", .{ schema_result.stored_embedding_model orelse "unknown", settings.embedding_model }) catch {};
						}
						if (schema_result.embedding_dim_mismatch) {
							_ = se.print("error: Embedding dimension mismatch. Index was built with {d}, but current setting is {d}.\n", .{ schema_result.stored_embedding_dim orelse 0, settings.embedding_dim }) catch {};
						}
						_ = se.print("Run 'codescan index' to rebuild the index with the current model.\n", .{}) catch {};
						_ = se.flush() catch {};
						std.process.exit(1);
					}

					var http_client = embedding_http.StdHttpTransport.init(allocator);
					defer http_client.deinit();
					try ensureModelAvailableOrExit(allocator, http_client.transport(), settings.embedding_url, settings.embedding_model, settings.embedding_dialect);
					var embedder_adapter = embedding.HttpEmbedder{
						.transport = http_client.transport(),
						.base_url = settings.embedding_url,
						.model = settings.embedding_model,
						.dialect = settings.embedding_dialect,
						.auth_header = settings.embedding_auth_header,
					};

					var index_filters = try filters.buildIndexFilters(allocator, settings.index_ext, settings.index_type);
					defer index_filters.deinit(allocator);

					g_stop_flag.store(false, .release);
					if (comptime builtin.os.tag != .windows) {
						const act = std.posix.Sigaction{
							.handler = .{ .handler = struct {
								fn handler(_: c_int) callconv(.c) void {
									g_stop_flag.store(true, .release);
								}
							}.handler },
							.mask = std.posix.sigemptyset(),
							.flags = 0,
						};
						std.posix.sigaction(std.posix.SIG.INT, &act, null);
						std.posix.sigaction(std.posix.SIG.TERM, &act, null);
					}

					watcher.watchLoop(
						allocator,
						db,
						settings.root_path,
						registry,
						embedder_adapter.embedder(),
						.{
							.interval_ms = parsed.watch_interval,
							.codescan_dir = codescan_dir,
							.index_options = .{
								.embedding_dim = settings.embedding_dim,
								.embedding_model = settings.embedding_model,
								.batch_size = settings.batch_size,
								.max_file_size = settings.max_file_size,
								.allowed_exts = index_filters.exts.items,
								.allowed_kinds = index_filters.kinds.items,
								.ignore = .{
									.global = settings.ignore_global,
									.per_language = settings.ignore_lang,
									.include_node_modules = settings.include_node_modules,
									.always_include = settings.always_include,
								},
								.show_progress = false,
							},
						},
						&g_stop_flag,
					) catch |err| switch (err) {
						error.WatcherAlreadyRunning => return, // message already printed
						else => return err,
					};
				},
			}
		},
		.status => {
			try runStatus(allocator, settings.db_path, settings.root_path, parsed.output, stdout);
			try stdout.flush();
		},
        .setup_model => {
            _ = stdout.print(
                \\Recommended model: jina-code-embeddings-1.5b
                \\  1536 dimensions, 32K token context, code-specific training
                \\  License: CC-BY-NC-4.0 (non-commercial)
                \\
                \\
            , .{}) catch {};

            if (settings.embedding_dialect == .openai) {
                _ = stdout.print(
                    \\For oMLX Server, download the MLX model from HuggingFace:
                    \\
                    \\  huggingface-cli download jinaai/jina-code-embeddings-1.5b-mlx
                    \\
                    \\Then configure your oMLX Server to serve it and set in .codescan/config:
                    \\
                    \\  embedding_api=openai
                    \\  embedding_url=http://localhost:8000
                    \\  embedding_model=jinaai/jina-code-embeddings-1.5b-mlx
                    \\  embedding_api_key=<your-omlx-key>
                    \\
                    \\
                , .{}) catch {};
            } else {
                _ = stdout.print(
                    \\To install via Ollama, run:
                    \\
                    \\  ollama pull hf.co/jinaai/jina-code-embeddings-1.5b-GGUF:Q8_0
                    \\
                    \\
                , .{}) catch {};
            }

            _ = stdout.print(
                \\Then reindex your project:
                \\
                \\  codescan index --force
                \\
                \\Note: If you use a different model, update embedding_model and embedding_dim
                \\in .codescan/config to match. Mismatched dimensions will cause search errors.
                \\
            , .{}) catch {};

            try stdout.flush();
        },
		.clean => {			const codescan_dir = std.fs.path.dirname(settings.db_path) orelse ".codescan";

			// Require confirmation to prevent accidental data loss
			if (!parsed.confirm) {
				if (std.fs.File.stdin().isTty()) {
					var stderr_buf: [4096]u8 = undefined;
					var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
					const stderr = &stderr_writer.interface;
					_ = stderr.print("This will stop the watcher and delete {s}/. Continue? [y/N] ", .{codescan_dir}) catch {};
					_ = stderr.flush() catch {};
					var input_buf: [16]u8 = undefined;
					const n = std.fs.File.stdin().read(&input_buf) catch 0;
					if (n == 0 or (input_buf[0] != 'y' and input_buf[0] != 'Y')) {
						try stdout.print("Aborted.\n", .{});
						try stdout.flush();
						return;
					}
				} else {
					try stdout.print("error: clean/clear requires confirmation in non-interactive mode\n", .{});
					try stdout.print("usage: codescan clean --confirm\n", .{});
					try stdout.flush();
					std.process.exit(1);
				}
			}

			// Stop watcher if running
			if (comptime builtin.os.tag != .windows) {
				if (pidfile.readAndCheckPid(allocator, codescan_dir) catch null) |pid_val| {
					_ = std.c.kill(pid_val, std.posix.SIG.TERM);
					try stdout.print("Stopped watcher (PID {d})\n", .{pid_val});
					pidfile.removePid(allocator, codescan_dir);
				}
			}

			// Delete .codescan/ directory
			std.fs.cwd().deleteTree(codescan_dir) catch |err| {
				try stdout.print("error: could not remove {s}: {s}\n", .{ codescan_dir, @errorName(err) });
				try stdout.flush();
				std.process.exit(1);
			};
			try stdout.print("Removed {s}/\n", .{codescan_dir});
			try stdout.flush();
		},
		.help => {},
	}
}

fn resolveSettings(allocator: std.mem.Allocator, parsed: cli.Parsed, cfg: config.Config, default_root: []const u8) !Settings {
	const defaults = Defaults{};
	var settings = Settings{
		.output = defaults.output,
		.show_comments = false,
		.top_n = defaults.top_n,
		.root_path = default_root,
		.db_path = defaults.db_path,
		.db_path_owned = false,
		.embedding_url = defaults.embedding_url,
		.embedding_model = defaults.embedding_model,
		.embedding_model_owned = false,
		.embedding_dim = defaults.embedding_dim,
		.batch_size = defaults.batch_size,
		.max_file_size = defaults.max_file_size,
		.search_mode = defaults.search_mode,
		.fusion = defaults.fusion,
		.rrf_k = defaults.rrf_k,
		.fts_mode = defaults.fts_mode,
		.weight_vector = defaults.weight_vector,
		.weight_lexical = defaults.weight_lexical,
		.min_score = defaults.min_score,
		.include_docs = defaults.include_docs,
		.docs_only = false,
		.comments_only = false,
		.include_node_modules = defaults.include_node_modules,
		.index_ext = null,
		.index_type = defaults.index_type,
		.search_ext = null,
		.search_type = null,
		.search_lang = null,
		.search_symbol_kind = null,
		.primary_lang = null,
		.ignore_global = &[_][]const u8{},
		.always_include = &[_][]const u8{},
		.ignore_lang = &[_]config.IgnoreOverride{},
		.lsp_overrides = &[_]config.LspOverride{},
		.http_host = defaults.http_host,
		.http_port = defaults.http_port,
		.search_weights = null,
	};

	var env_model: ?[]u8 = null;
	if (std.process.getEnvVarOwned(allocator, "OLLAMA_MODEL")) |value| {
		env_model = value;
	} else |err| switch (err) {
		error.EnvironmentVariableNotFound => {},
		else => return err,
	}

	if (cfg.output) |value| settings.output = value;
	if (cfg.top_n) |value| settings.top_n = value;
	if (cfg.root_path) |value| settings.root_path = value;
	if (cfg.db_path) |value| settings.db_path = value;
	if (cfg.embedding_url) |value| settings.embedding_url = value;
	if (cfg.embedding_model) |value| settings.embedding_model = value;
	if (cfg.embedding_dim) |value| settings.embedding_dim = value;
	if (cfg.batch_size) |value| settings.batch_size = value;
	if (cfg.max_file_size) |value| settings.max_file_size = value;
	if (cfg.search_mode) |value| settings.search_mode = try search.SearchMode.parse(value);
	if (cfg.fusion) |value| settings.fusion = try search.FusionMode.parse(value);
	if (cfg.rrf_k) |value| settings.rrf_k = value;
	if (cfg.fts_mode) |value| settings.fts_mode = try search.FtsMode.parse(value);
	if (cfg.weight_vector) |value| settings.weight_vector = value;
	if (cfg.weight_lexical) |value| settings.weight_lexical = value;
	if (cfg.min_score) |value| settings.min_score = value;
	if (cfg.index_ext) |value| settings.index_ext = value;
	if (cfg.index_type) |value| settings.index_type = value;
	if (cfg.search_ext) |value| settings.search_ext = value;
	if (cfg.search_type) |value| settings.search_type = value;
	if (cfg.search_lang) |value| settings.search_lang = value;
	if (cfg.search_symbol_kind) |value| settings.search_symbol_kind = value;
	if (cfg.primary_lang) |value| settings.primary_lang = value;
	if (cfg.include_docs) |value| settings.include_docs = value;
	if (cfg.docs_only) |value| settings.docs_only = value;
	if (cfg.comments_only) |value| settings.comments_only = value;
	if (cfg.include_node_modules) |value| settings.include_node_modules = value;
	settings.ignore_global = cfg.ignore_global.items;
	settings.always_include = cfg.always_include.items;
	settings.ignore_lang = cfg.ignore_lang.items;
	settings.lsp_overrides = cfg.lsp_overrides.items;
	if (cfg.http_host) |value| settings.http_host = value;
	if (cfg.http_port) |value| settings.http_port = value;

	if (env_model) |value| {
		settings.embedding_model = value;
		settings.embedding_model_owned = true;
	}

	if (parsed.seen.output) settings.output = parsed.output;
	if (parsed.seen.show_comments) settings.show_comments = parsed.show_comments;
	if (parsed.seen.top_n) settings.top_n = parsed.top_n;
	if (parsed.seen.root_path) settings.root_path = parsed.root_path;
	if (parsed.seen.db_path) settings.db_path = parsed.db_path;
	if (parsed.seen.embedding_url) settings.embedding_url = parsed.embedding_url;
	if (parsed.seen.embedding_model) {
		if (settings.embedding_model_owned) {
			allocator.free(settings.embedding_model);
			settings.embedding_model_owned = false;
		}
		settings.embedding_model = parsed.embedding_model;
	}
	if (parsed.seen.embedding_dim) settings.embedding_dim = parsed.embedding_dim;
	if (parsed.seen.batch_size) settings.batch_size = parsed.batch_size;
	if (parsed.seen.max_file_size) settings.max_file_size = parsed.max_file_size;
	if (parsed.seen.search_mode) settings.search_mode = parsed.search_mode;
	if (parsed.seen.fusion) settings.fusion = parsed.fusion;
	if (parsed.seen.rrf_k) settings.rrf_k = parsed.rrf_k;
	if (parsed.seen.fts_mode) settings.fts_mode = parsed.fts_mode;
	if (parsed.seen.weight_vector) settings.weight_vector = parsed.weight_vector;
	if (parsed.seen.weight_lexical) settings.weight_lexical = parsed.weight_lexical;
	if (parsed.seen.min_score) settings.min_score = parsed.min_score;
	if (parsed.seen.include_docs) settings.include_docs = parsed.include_docs;
	if (parsed.seen.docs_only) settings.docs_only = parsed.docs_only;
	if (parsed.seen.comments_only) settings.comments_only = parsed.comments_only;
	if (parsed.seen.include_node_modules) settings.include_node_modules = parsed.include_node_modules;
	if (parsed.seen.ext_filter) {
		if (parsed.command == .index or parsed.command == .update or parsed.command == .watch) {
			settings.index_ext = parsed.ext_filter;
		} else if (parsed.command == .search) {
			settings.search_ext = parsed.ext_filter;
		}
	}
	if (parsed.seen.type_filter) {
		if (parsed.command == .index or parsed.command == .update or parsed.command == .watch) {
			settings.index_type = parsed.type_filter;
		} else if (parsed.command == .search) {
			settings.search_type = parsed.type_filter;
		}
	}
	if (parsed.seen.lang_filter and parsed.command == .search) {
		settings.search_lang = parsed.lang_filter;
	}
	if (parsed.seen.kind_filter and parsed.command == .search) {
		settings.search_symbol_kind = parsed.kind_filter;
	}
	if (parsed.seen.http_host) settings.http_host = parsed.http_host;
	if (parsed.seen.http_port) settings.http_port = parsed.http_port;

	// --comments / --only-comments implies --show-comments
	if (settings.comments_only) settings.show_comments = true;

	if (!std.fs.path.isAbsolute(settings.db_path) and !std.mem.eql(u8, settings.root_path, ".")) {
		settings.db_path = try std.fs.path.join(allocator, &.{ settings.root_path, settings.db_path });
		settings.db_path_owned = true;
	}

	// Parse embedding_api dialect from config
	if (cfg.embedding_api) |api_str| {
		if (std.mem.eql(u8, api_str, "openai")) {
			settings.embedding_dialect = .openai;
		}
	}

	// Format Bearer token from api key
	if (cfg.embedding_api_key) |key| {
		settings.embedding_auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{key});
		settings.embedding_auth_header_owned = true;
	}

	return settings;
}

fn ensureModelAvailableOrExit(
	allocator: std.mem.Allocator,
	transport: embedding_http.Transport,
	base_url: []const u8,
	model_name: []const u8,
	dialect: embedding_http.ApiDialect,
) !void {
	if (dialect == .openai) return;
	embedding_http.ensureModelAvailable(allocator, transport, base_url, model_name, dialect) catch |err| switch (err) {
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
			// Model exists but not loaded — the first embed call will trigger loading.
			var stderr_buf: [4096]u8 = undefined;
			var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
			const stderr = &stderr_writer.interface;
			_ = stderr.print(
				"note: Ollama model '{s}' is loading into memory. This may take a moment...\n",
				.{model_name},
			) catch {};
			_ = stderr.flush() catch {};
			// Continue — embed() will block until model is loaded
		},
		else => {
			var stderr_buf: [4096]u8 = undefined;
			var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
			const stderr = &stderr_writer.interface;
			_ = stderr.print(
				"error: Cannot connect to embedding server at {s}\n" ++
					"  Is Ollama running? Start it with: ollama serve\n",
				.{ base_url },
			) catch {};
			_ = stderr.flush() catch {};
			std.process.exit(1);
		},
	};
}

fn shouldShowProgress(is_tty: bool, out_format: cli.OutputFormat) bool {
	return is_tty and out_format == .human;
}

/// Tries to connect to Ollama and ensure the model is available.
/// Returns whether Ollama is available. On failure, prints a warning to stderr.
fn tryInitOllama(
	allocator: std.mem.Allocator,
	http_client: *embedding_http.StdHttpTransport,
	embedding_url: []const u8,
	embedding_model: []const u8,
	dialect: embedding_http.ApiDialect,
	stderr: *std.Io.Writer,
) bool {
	if (dialect == .openai) return true;
	embedding_http.ensureModelAvailable(
		allocator,
		http_client.transport(),
		embedding_url,
		embedding_model,
		dialect,
	) catch |err| {
		switch (err) {
			error.ModelNotFound => {
				_ = stderr.print(
					"  note: Ollama model '{s}' not found. Using lexical-only search.\n" ++
						"  Run 'ollama pull {s}' then 'codescan update' for semantic search.\n",
					.{ embedding_model, embedding_model },
				) catch {};
				_ = stderr.flush() catch {};
				return false;
			},
			error.ModelLoading => {
				// Model exists but not loaded — embed() will trigger loading
				_ = stderr.print(
					"  note: Ollama model '{s}' is loading into memory. This may take a moment...\n",
					.{embedding_model},
				) catch {};
				_ = stderr.flush() catch {};
				return true; // Proceed — embed will block until loaded
			},
			else => {
				_ = stderr.print(
					"  note: Ollama not available. Using lexical-only search.\n" ++
						"  Run 'codescan update' after starting Ollama for semantic search.\n",
					.{},
				) catch {};
				_ = stderr.flush() catch {};
				return false;
			},
		}
	};
	return true;
}

const DetectedServer = struct {
    url: []const u8,
    dialect: embedding_http.ApiDialect,
    model_available: bool,
};

/// Probes well-known embedding server ports and returns the first that responds.
/// Tries Ollama on the configured URL first, then oMLX on :8000.
/// Returns null if no server responds.
fn detectEmbeddingServer(
    allocator: std.mem.Allocator,
    transport: embedding_http.Transport,
    configured_url: []const u8,
    model_name: []const u8,
) ?DetectedServer {
    // Try 1: Ollama at configured URL (default http://localhost:11434)
    if (probeOllama(allocator, transport, configured_url, model_name)) |result| {
        return result;
    }

    // Try 2: oMLX at http://localhost:8000 (OpenAI-compatible)
    if (probeOpenAI(allocator, transport, "http://localhost:8000")) |result| {
        return result;
    }

    return null;
}

fn probeOllama(
    allocator: std.mem.Allocator,
    transport: embedding_http.Transport,
    base_url: []const u8,
    model_name: []const u8,
) ?DetectedServer {
    embedding_http.ensureModelAvailable(allocator, transport, base_url, model_name, .ollama) catch |err| {
        switch (err) {
            error.ModelNotFound => return .{
                .url = base_url,
                .dialect = .ollama,
                .model_available = false,
            },
            error.ModelLoading => return .{
                .url = base_url,
                .dialect = .ollama,
                .model_available = true,
            },
            else => return null, // Server not reachable
        }
    };
    return .{
        .url = base_url,
        .dialect = .ollama,
        .model_available = true,
    };
}

fn probeOpenAI(
    allocator: std.mem.Allocator,
    transport: embedding_http.Transport,
    base_url: []const u8,
) ?DetectedServer {
    const url = buildOpenAIModelsUrl(allocator, base_url) catch return null;
    defer allocator.free(url);

    const headers = [_]std.http.Header{
        .{ .name = "Accept", .value = "application/json" },
    };

    const response = transport.send(transport.ctx, allocator, .{
        .method = "GET",
        .url = url,
        .headers = &headers,
        .body = "",
    }) catch return null;
    defer allocator.free(response.body);

    if (response.status != 200) return null;

    return .{
        .url = base_url,
        .dialect = .openai,
        .model_available = true,
    };
}

fn buildOpenAIModelsUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    const trimmed = std.mem.trimRight(u8, base_url, "/");
    return std.fmt.allocPrint(allocator, "{s}/v1/models", .{trimmed});
}

/// Prompts the user with a yes/no question. Returns true for yes.
/// In non-TTY mode, returns `non_tty_default`.
fn promptYesNo(stderr: *std.Io.Writer, non_tty_default: bool) bool {
    _ = stderr.flush() catch {};
    if (!std.fs.File.stdin().isTty()) return non_tty_default;
    var input_buf: [16]u8 = undefined;
    const stdin = std.fs.File.stdin();
    const n = stdin.read(&input_buf) catch return false;
    if (n == 0) return false;
    return input_buf[0] == 'y' or input_buf[0] == 'Y';
}


/// Performs a full index (shared between `codescan index` and auto-index-before-search).
fn performFullIndex(
	allocator: std.mem.Allocator,
	db: storage.Db,
	settings: Settings,
	registry: plugin.Registry,
	embedder: embedding.Embedder,
	stderr: *std.Io.Writer,
	show_progress: bool,
) !indexer.Stats {
	var index_filters = try filters.buildIndexFilters(allocator, settings.index_ext, settings.index_type);
	defer index_filters.deinit(allocator);

	const stats = try indexer.indexAll(
		allocator,
		db,
		settings.root_path,
		registry,
		embedder,
		.{
			.embedding_dim = settings.embedding_dim,
			.embedding_model = settings.embedding_model,
			.batch_size = settings.batch_size,
			.max_file_size = settings.max_file_size,
			.allowed_exts = index_filters.exts.items,
			.allowed_kinds = index_filters.kinds.items,
			.ignore = .{
				.global = settings.ignore_global,
				.per_language = settings.ignore_lang,
				.include_node_modules = settings.include_node_modules,
				.always_include = settings.always_include,
			},
			.show_progress = show_progress,
		},
	);

	if (show_progress) {
		_ = stderr.print("  Indexed {d} files, {d} symbols\n", .{ stats.files, stats.symbols }) catch {};
		_ = stderr.flush() catch {};
	}

	return stats;
}

/// Spawns `codescan watch` in the background if not already running.
fn maybeStartWatcher(allocator: std.mem.Allocator, settings: Settings, stderr: *std.Io.Writer) void {

	// Derive the .codescan dir from db_path (parent of index.sqlite3)
	const codescan_dir = std.fs.path.dirname(settings.db_path) orelse return;

	// Check if watcher is already running
	if (pidfile.isWatcherRunning(allocator, codescan_dir)) {
		return;
	}

	// Clean up stale PID file if it exists (process is dead)
	pidfile.removePid(allocator, codescan_dir);

	// Find our own binary
	const self_exe = std.fs.selfExePathAlloc(allocator) catch |err| {
		_ = stderr.print("note: could not find codescan binary to start watcher: {s}\n", .{@errorName(err)}) catch {};
		_ = stderr.flush() catch {};
		return;
	};
	defer allocator.free(self_exe);

	// Spawn: codescan watch --root <path>
	var child = std.process.Child.init(
		&.{ self_exe, "watch", "--root", settings.root_path },
		allocator,
	);
	child.stdin_behavior = .Close;
	child.stdout_behavior = .Close;
	child.stderr_behavior = .Close;

	child.spawn() catch |err| {
		_ = stderr.print("note: failed to start watcher: {s}\n", .{@errorName(err)}) catch {};
		_ = stderr.flush() catch {};
		return;
	};

	// Don't wait — let it run in background (init adopts on parent exit)
	if (comptime builtin.os.tag == .windows) {
		_ = stderr.print("note: Started background watcher\n", .{}) catch {};
	} else {
		_ = stderr.print("note: Started background watcher (PID {d})\n", .{child.id}) catch {};
	}
	_ = stderr.flush() catch {};
}

fn findRepoRoot(allocator: std.mem.Allocator, start_path: []const u8) !?[]u8 {
	return findRepoRootUntil(allocator, start_path, null);
}

fn findRepoRootUntil(
	allocator: std.mem.Allocator,
	start_path: []const u8,
	stop_at: ?[]const u8,
) !?[]u8 {
	const start_abs = try std.fs.cwd().realpathAlloc(allocator, start_path);
	errdefer allocator.free(start_abs);

	var stop_abs: ?[]u8 = null;
	defer if (stop_abs) |path| allocator.free(path);
	if (stop_at) |stop_path| {
		stop_abs = try std.fs.cwd().realpathAlloc(allocator, stop_path);
	}

	var current = start_abs;
	while (true) {
		if (try hasCodescanDir(current)) {
			return current;
		}

		if (stop_abs) |stop_path| {
			if (std.mem.eql(u8, current, stop_path)) break;
		}

		const parent = std.fs.path.dirname(current) orelse break;
		if (std.mem.eql(u8, parent, current)) break;

		const next = try allocator.dupe(u8, parent);
		allocator.free(current);
		current = next;
	}

	allocator.free(current);
	return null;
}

fn hasCodescanDir(path: []const u8) !bool {
	var dir = try std.fs.openDirAbsolute(path, .{});
	defer dir.close();
	var codescan_dir = dir.openDir(".codescan", .{}) catch |err| switch (err) {
		error.FileNotFound, error.NotDir => return false,
		else => return err,
	};
	codescan_dir.close();
	return true;
}

fn loadConfig(allocator: std.mem.Allocator, root_path: []const u8) !config.Config {
	const path = try configPath(allocator, root_path);
	defer allocator.free(path);

	return config.loadFromPath(allocator, path) catch |err| switch (err) {
		error.FileNotFound => config.Config{},
		error.NotDir => config.Config{},
		else => err,
	};
}

fn loadWeights(allocator: std.mem.Allocator, root_path: []const u8) !weights.Table {
	const path = try weightsPath(allocator, root_path);
	defer allocator.free(path);

	return weights.loadFromPath(allocator, path) catch |err| switch (err) {
		error.FileNotFound => weights.Table{},
		error.NotDir => weights.Table{},
		else => err,
	};
}

fn configPath(allocator: std.mem.Allocator, root_path: []const u8) ![]u8 {
	// Prefer config.ini, fall back to legacy config for backwards compatibility
	const ini_path = try std.fs.path.join(allocator, &.{ root_path, ".codescan", "config.ini" });
	if (std.fs.cwd().statFile(ini_path)) |_| {
		return ini_path;
	} else |_| {
		allocator.free(ini_path);
		const legacy_path = try std.fs.path.join(allocator, &.{ root_path, ".codescan", "config" });
		if (std.fs.cwd().statFile(legacy_path)) |_| {
			return legacy_path;
		} else |_| {
			allocator.free(legacy_path);
			// Neither exists — return config.ini for creation
			return std.fs.path.join(allocator, &.{ root_path, ".codescan", "config.ini" });
		}
	}
}

fn weightsPath(allocator: std.mem.Allocator, root_path: []const u8) ![]u8 {
	return std.fs.path.join(allocator, &.{ root_path, ".codescan", "weights.toml" });
}

fn showConfig(allocator: std.mem.Allocator, path: []const u8, writer: *std.Io.Writer) !void {
	const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
		error.FileNotFound => {
			try writer.print("No config found at {s}\n", .{path});
			try writer.writeAll("Use: codescan config edit\n");
			return;
		},
		error.NotDir => {
			try writer.print("No config found at {s}\n", .{path});
			try writer.writeAll("Use: codescan config edit\n");
			return;
		},
		else => return err,
	};
	defer file.close();

	const data = try file.readToEndAlloc(allocator, 1024 * 1024);
	defer allocator.free(data);
	try writer.writeAll(data);
	if (data.len == 0 or data[data.len - 1] != '\n') {
		try writer.writeAll("\n");
	}
	try writer.writeAll("# To edit: codescan config edit\n");
}

fn editConfig(allocator: std.mem.Allocator, path: []const u8) !void {
	try ensureParentDir(path);
	try ensureConfigWithDefaults(path);

	const editor = getEditor(allocator) catch |err| switch (err) {
		error.MissingEditor => {
			var stderr_buf: [4096]u8 = undefined;
			var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
			const stderr = &stderr_writer.interface;
			_ = stderr.writeAll("error: $VISUAL or $EDITOR is not set\n") catch {};
			_ = stderr.flush() catch {};
			std.process.exit(1);
		},
		else => return err,
	};
	defer allocator.free(editor);

	const quoted_path = try shellQuote(allocator, path);
	defer allocator.free(quoted_path);
	const cmd = try std.fmt.allocPrint(allocator, "{s} {s}", .{ editor, quoted_path });
	defer allocator.free(cmd);

	const argv = &[_][]const u8{ "sh", "-c", cmd };
	var child = std.process.Child.init(argv, allocator);
	child.stdin_behavior = .Inherit;
	child.stdout_behavior = .Inherit;
	child.stderr_behavior = .Inherit;

	const term = try child.spawnAndWait();
	switch (term) {
		.Exited => |code| {
			if (code != 0) return error.EditorFailed;
		},
		else => return error.EditorFailed,
	}
}

fn getEditor(allocator: std.mem.Allocator) ![]u8 {
	const visual = std.process.getEnvVarOwned(allocator, "VISUAL") catch |err| switch (err) {
		error.EnvironmentVariableNotFound => null,
		else => return err,
	};
	if (visual) |value| return value;
	const editor = std.process.getEnvVarOwned(allocator, "EDITOR") catch |err| switch (err) {
		error.EnvironmentVariableNotFound => return error.MissingEditor,
		else => return err,
	};
	return editor;
}

fn shellQuote(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();
	try out.writer.writeAll("'");
	for (value) |ch| {
		if (ch == '\'') {
			try out.writer.writeAll("'\"'\"'");
		} else {
			try out.writer.writeByte(ch);
		}
	}
	try out.writer.writeAll("'");
	return out.toOwnedSlice();
}

fn ensureFileExists(path: []const u8) !void {
	const result = std.fs.cwd().openFile(path, .{});
	if (result) |file| {
		file.close();
		return;
	} else |err| switch (err) {
		error.FileNotFound => {
			const file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = false });
			file.close();
		},
		else => return err,
	}
}

fn ensureConfigWithDefaults(path: []const u8) !void {
	const result = std.fs.cwd().openFile(path, .{});
	if (result) |file| {
		// File exists — check if it's empty
		const stat = try file.stat();
		file.close();
		if (stat.size == 0) {
			const f = try std.fs.cwd().createFile(path, .{ .truncate = true });
			defer f.close();
			try f.writeAll(config.default_template);
		}
	} else |err| switch (err) {
		error.FileNotFound => {
			const file = try std.fs.cwd().createFile(path, .{});
			defer file.close();
			try file.writeAll(config.default_template);
		},
		else => return err,
	}
}

fn ensureWeightsWithDefaults(path: []const u8) !void {
	const result = std.fs.cwd().openFile(path, .{});
	if (result) |file| {
		const stat = try file.stat();
		file.close();
		if (stat.size == 0) {
			const f = try std.fs.cwd().createFile(path, .{ .truncate = true });
			defer f.close();
			try f.writeAll(weights.default_template);
		}
	} else |err| switch (err) {
		error.FileNotFound => {
			const file = try std.fs.cwd().createFile(path, .{});
			defer file.close();
			try file.writeAll(weights.default_template);
		},
		else => return err,
	}
}

/// Try to reindex a file after an edit. Logs errors to stderr as warnings.
/// Opens the DB, calls indexer.reindexFile, and closes the DB.
/// If no index exists or any step fails, the edit is still successful —
/// the background watcher will eventually catch up.
fn tryReindexFile(allocator: std.mem.Allocator, db_path: []const u8, root_path: []const u8, file_path: []const u8, registry: plugin.Registry, embedding_dim: usize) void {
	var stderr_buf: [4096]u8 = undefined;
	var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
	const stderr = &stderr_writer.interface;

	const db = storage.openFileWithVec(allocator, db_path) catch |err| {
		_ = stderr.print("warning: reindex skipped (could not open index): {}\n", .{err}) catch {};
		_ = stderr.flush() catch {};
		return;
	};
	defer storage.close(db);
	_ = storage.initSchema(allocator, db, .{ .embedding_dim = embedding_dim }) catch |err| {
		_ = stderr.print("warning: reindex skipped (schema migration failed): {}\n", .{err}) catch {};
		_ = stderr.flush() catch {};
		return;
	};
	const abs_root = std.fs.cwd().realpathAlloc(allocator, root_path) catch |err| {
		_ = stderr.print("warning: reindex skipped (could not resolve root): {}\n", .{err}) catch {};
		_ = stderr.flush() catch {};
		return;
	};
	defer allocator.free(abs_root);
	const abs_file = std.fs.cwd().realpathAlloc(allocator, file_path) catch |err| {
		_ = stderr.print("warning: reindex skipped (could not resolve file): {}\n", .{err}) catch {};
		_ = stderr.flush() catch {};
		return;
	};
	defer allocator.free(abs_file);
	const rel_path = std.fs.path.relative(allocator, abs_root, abs_file) catch |err| {
		_ = stderr.print("warning: reindex skipped (could not compute relative path): {}\n", .{err}) catch {};
		_ = stderr.flush() catch {};
		return;
	};
	defer allocator.free(rel_path);
	indexer.reindexFile(allocator, db, rel_path, root_path, registry) catch |err| {
		_ = stderr.print("warning: reindex failed for '{s}': {}\n", .{ file_path, err }) catch {};
		_ = stderr.flush() catch {};
		return;
	};
}

fn ensureParentDir(path: []const u8) !void {
	const dir = std.fs.path.dirname(path) orelse return;
	try std.fs.cwd().makePath(dir);
}

const MIN_TMP_SPACE_BYTES: u64 = 50 * 1024 * 1024; // 50 MB

/// Platform-dispatched statvfs: manual extern struct for Linux (musl
/// cross-compilation makes @cImport opaque), @cImport for macOS.
const posix_fs = if (builtin.os.tag == .linux) struct {
	const Statvfs = extern struct {
		f_bsize: c_ulong,
		f_frsize: c_ulong,
		f_blocks: c_ulonglong,
		f_bfree: c_ulonglong,
		f_bavail: c_ulonglong,
		f_files: c_ulonglong,
		f_ffree: c_ulonglong,
		f_favail: c_ulonglong,
		f_fsid: c_ulong,
		f_flag: c_ulong,
		f_namemax: c_ulong,
		f_type: c_uint,
		__reserved: [5]c_int,
	};
	extern "c" fn statvfs(path: [*:0]const u8, buf: *Statvfs) c_int;

	fn avail(path: [*:0]const u8) ?u64 {
		var st: Statvfs = undefined;
		if (statvfs(path, &st) != 0) return null;
		return @as(u64, st.f_bavail) * @as(u64, st.f_frsize);
	}
} else if (builtin.os.tag == .macos) struct {
	const c_fs = @cImport(@cInclude("sys/statvfs.h"));

	fn avail(path: [*:0]const u8) ?u64 {
		var st: c_fs.struct_statvfs = undefined;
		if (c_fs.statvfs(path, &st) != 0) return null;
		return @as(u64, st.f_bavail) * @as(u64, st.f_frsize);
	}
} else struct {
	fn avail(_: [*:0]const u8) ?u64 {
		return null;
	}
};

/// Check that the temp directory has sufficient free space for SQLite
/// journal/WAL writes. Prints an error to stderr and exits if space
/// is below the threshold. Best-effort: silently succeeds on any
/// failure to read filesystem stats (e.g. unsupported platform).
fn checkTmpSpace() void {
	const tmp_path: [*:0]const u8 = if (std.posix.getenv("TMPDIR")) |t|
		@ptrCast(t.ptr)
	else
		"/tmp";
	const avail = posix_fs.avail(tmp_path) orelse return;
	if (avail >= MIN_TMP_SPACE_BYTES) return;
	var eb: [512]u8 = undefined;
	var ew = std.fs.File.stderr().writer(&eb);
	const se = &ew.interface;
	_ = se.print("error: insufficient disk space on temp directory ({d} MB free, need at least {d} MB)\n", .{
		avail / (1024 * 1024),
		MIN_TMP_SPACE_BYTES / (1024 * 1024),
	}) catch {};
	_ = se.print("hint: clean up $TMPDIR or /tmp, or set TMPDIR to a path with more space\n", .{}) catch {};
	_ = se.flush() catch {};
	std.process.exit(1);
}

/// Compute the hashline hash for a specific 1-indexed line in a file.
/// Returns the 3-char hash or null on any failure.
fn computeHashAtLine(allocator: std.mem.Allocator, file_path: []const u8, line_1: usize) ?hashline.Hash {
	const source = readFileContents(allocator, file_path) catch return null;
	defer allocator.free(source);
	const hashes = hashline.computeSourceHashes(allocator, source) catch return null;
	defer allocator.free(hashes);
	if (line_1 == 0 or line_1 > hashes.len) return null;
	return hashes[line_1 - 1];
}

fn exitWithError(comptime msg: []const u8) noreturn {
	var eb: [512]u8 = undefined;
	var ew = std.fs.File.stderr().writer(&eb);
	const se = &ew.interface;
	_ = se.writeAll(msg) catch {};
	_ = se.flush() catch {};
	std.process.exit(1);
}

fn readFileContents(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
	const file = try std.fs.cwd().openFile(path, .{});
	defer file.close();
	return try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
}

pub fn runSymbols(
	allocator: std.mem.Allocator,
	files: []const []const u8,
	pattern: ?[]const u8,
	include_body: bool,
	out_fmt: cli.OutputFormat,
	writer: *std.Io.Writer,
	root_path: ?[]const u8,
) !void {
	// If no files specified, discover all code files under root
	var discovered_files: ?[]const []const u8 = null;
	defer if (discovered_files) |df| {
		for (df) |f| allocator.free(f);
		allocator.free(df);
	};

	const file_list: []const []const u8 = if (files.len > 0)
		files
	else blk: {
		discovered_files = scan.findFiles(allocator, root_path orelse ".", plugin.defaultRegistry(), .{
			.global = &.{},
			.per_language = &.{},
			.include_node_modules = false,
		}) catch {
			try writer.writeAll("error: failed to scan files\n");
			return;
		};
		break :blk discovered_files.?;
	};

	const multi = file_list.len > 1;

	if (out_fmt == .json and multi) {
		try writer.writeAll("[");
	}

	var first_file = true;
	var any_found = false;
	for (file_list) |file_path| {
		const source = readFileContents(allocator, file_path) catch continue;
		defer allocator.free(source);

		const ext = std.fs.path.extension(file_path);
		var tree: symbol_tree.SymbolTree = undefined;
		var tree_valid = false;

		if (std.mem.eql(u8, ext, ".zig")) {
			tree = symbol_tree.extractZig(allocator, source) catch continue;
			tree_valid = true;
		} else if (ts_symbols.Language.fromExtension(ext) orelse ts_symbols.Language.fromShebang(source)) |lang| {
			tree = ts_symbols.extract(allocator, source, lang) catch continue;
			tree_valid = true;
		}

		if (!tree_valid) continue;
		defer tree.deinit(allocator);

		// Compute per-file chain hashes
		var lines_list: std.ArrayListUnmanaged([]const u8) = .{};
		defer lines_list.deinit(allocator);
		{
			var it = std.mem.splitScalar(u8, source, '\n');
			while (it.next()) |line| {
				try lines_list.append(allocator, line);
			}
		}
		const lines = lines_list.items;
		const all_hashes = try hashline.computeChainHashes(allocator, lines);
		defer allocator.free(all_hashes);

		if (pattern) |pat| {
			// Find matching symbols
			var found = false;
			if (out_fmt == .json) {
				if (multi) {
					// In multi-file JSON, each match is a separate object with file field
					for (tree.symbols) |*sym| {
						try findAndPrintMatchMulti(allocator, sym, pat, null, include_body, lines, all_hashes, file_path, out_fmt, writer, &found, &first_file);
					}
				} else {
					for (tree.symbols) |*sym| {
						try findAndPrintMatch(allocator, sym, pat, null, include_body, lines, all_hashes, out_fmt, writer, &found);
					}
				}
			} else {
				if (multi and tree.symbols.len > 0) {
					// Check if any matches exist before printing header
					var file_found = false;
					for (tree.symbols) |*sym| {
						try findAndPrintMatchCheck(sym, pat, null, &file_found);
					}
					if (file_found) {
						try writer.print("\n==> {s} <==\n", .{file_path});
						for (tree.symbols) |*sym| {
							try findAndPrintMatch(allocator, sym, pat, null, include_body, lines, all_hashes, out_fmt, writer, &found);
						}
					}
				} else {
					for (tree.symbols) |*sym| {
						try findAndPrintMatch(allocator, sym, pat, null, include_body, lines, all_hashes, out_fmt, writer, &found);
					}
				}
			}
			if (found) any_found = true;
		} else {
			// List all symbols
			any_found = true;
			if (out_fmt == .json) {
				if (multi) {
					if (!first_file) try writer.writeAll(",");
					first_file = false;
					try writer.writeAll("{\"file\":");
					try writeJsonString(file_path, writer);
					try writer.writeAll(",\"symbols\":");
					try writeSymbolsJson(tree.symbols, all_hashes, writer);
					try writer.writeAll("}");
				} else {
					try writeSymbolsJson(tree.symbols, all_hashes, writer);
				}
			} else {
				if (multi) {
					try writer.print("\n==> {s} <==\n", .{file_path});
				}
				try formatSymbolsWithHashes(tree.symbols, all_hashes, writer, 0);
			}
		}
	}

	if (out_fmt == .json and multi) {
		try writer.writeAll("]\n");
	}

	if (pattern != null and !any_found and out_fmt != .json) {
		if (files.len == 1) {
			try writer.print("No symbols matching '{s}' found in {s}\n", .{ pattern.?, files[0] });
		} else {
			try writer.print("No symbols matching '{s}' found\n", .{pattern.?});
		}
	}
}

fn findAndPrintMatch(
	allocator: std.mem.Allocator,
	sym: *const symbol_tree.SymbolNode,
	pattern: []const u8,
	parent_path: ?[]const u8,
	include_body: bool,
	lines: []const []const u8,
	all_hashes: []const hashline.Hash,
	out_fmt: cli.OutputFormat,
	writer: *std.Io.Writer,
	found: *bool,
) !void {
	const name_path = try sym.namePath(allocator, parent_path);
	defer allocator.free(name_path);

	const start_idx = if (sym.start_line > 0) sym.start_line - 1 else 0;
	const end_idx = if (sym.end_line > 0) sym.end_line - 1 else 0;

	if (matchesNamePath(pattern, name_path, sym.name)) {
		found.* = true;
		if (out_fmt == .json) {
			try writer.writeAll("{\"name_path\":");
			try writeJsonString(name_path, writer);
			try writer.print(",\"kind\":\"{s}\",\"start_line\":{d},\"end_line\":{d}", .{
				sym.kind.label(), sym.start_line, sym.end_line,
			});
			if (start_idx < all_hashes.len) {
				try writer.print(",\"start_hash\":\"{s}\"", .{&all_hashes[start_idx]});
			}
			if (end_idx < all_hashes.len) {
				try writer.print(",\"end_hash\":\"{s}\"", .{&all_hashes[end_idx]});
			}
			if (include_body) {
				const start = start_idx;
				const end = @min(sym.end_line, lines.len);
				try writer.writeAll(",\"body\":[");
				for (lines[start..end], 0..) |line, li| {
					if (li > 0) try writer.writeAll(",");
					try writeJsonString(line, writer);
				}
				try writer.writeAll("]");
			}
			try writer.writeAll("}\n");
		} else {
			if (sym.start_line == sym.end_line) {
				if (start_idx < all_hashes.len) {
					try writer.print("{s} {s} ({d}:{s})\n", .{
						sym.kind.label(), name_path, sym.start_line, &all_hashes[start_idx],
					});
				} else {
					try writer.print("{s} {s} ({d})\n", .{
						sym.kind.label(), name_path, sym.start_line,
					});
				}
			} else {
				if (start_idx < all_hashes.len and end_idx < all_hashes.len) {
					try writer.print("{s} {s} ({d}:{s}-{d}:{s})\n", .{
						sym.kind.label(), name_path, sym.start_line, &all_hashes[start_idx], sym.end_line, &all_hashes[end_idx],
					});
				} else {
					try writer.print("{s} {s} ({d}-{d})\n", .{
						sym.kind.label(), name_path, sym.start_line, sym.end_line,
					});
				}
			}
			if (include_body) {
				const start = start_idx;
				const end = @min(sym.end_line, lines.len);
				for (lines[start..end], all_hashes[start..end], 0..) |line, hash, idx| {
					try hashline.formatHashline(start + idx + 1, hash, line, writer);
					try writer.writeAll("\n");
				}
			}
		}
	}

	for (sym.children) |*child| {
		try findAndPrintMatch(allocator, child, pattern, name_path, include_body, lines, all_hashes, out_fmt, writer, found);
	}
}

/// Like findAndPrintMatch but adds "file" field to JSON output for multi-file results.
fn findAndPrintMatchMulti(
	allocator: std.mem.Allocator,
	sym: *const symbol_tree.SymbolNode,
	pattern: []const u8,
	parent_path: ?[]const u8,
	include_body: bool,
	lines: []const []const u8,
	all_hashes: []const hashline.Hash,
	file_path: []const u8,
	out_fmt: cli.OutputFormat,
	writer: *std.Io.Writer,
	found: *bool,
	first_file: *bool,
) !void {
	_ = out_fmt;
	const name_path = try sym.namePath(allocator, parent_path);
	defer allocator.free(name_path);

	const start_idx = if (sym.start_line > 0) sym.start_line - 1 else 0;
	const end_idx = if (sym.end_line > 0) sym.end_line - 1 else 0;

	if (matchesNamePath(pattern, name_path, sym.name)) {
		found.* = true;
		if (!first_file.*) try writer.writeAll(",");
		first_file.* = false;
		try writer.writeAll("{\"file\":");
		try writeJsonString(file_path, writer);
		try writer.writeAll(",\"name_path\":");
		try writeJsonString(name_path, writer);
		try writer.print(",\"kind\":\"{s}\",\"start_line\":{d},\"end_line\":{d}", .{
			sym.kind.label(), sym.start_line, sym.end_line,
		});
		if (start_idx < all_hashes.len) {
			try writer.print(",\"start_hash\":\"{s}\"", .{&all_hashes[start_idx]});
		}
		if (end_idx < all_hashes.len) {
			try writer.print(",\"end_hash\":\"{s}\"", .{&all_hashes[end_idx]});
		}
		if (include_body) {
			const start = start_idx;
			const end = @min(sym.end_line, lines.len);
			try writer.writeAll(",\"body\":[");
			for (lines[start..end], 0..) |line, li| {
				if (li > 0) try writer.writeAll(",");
				try writeJsonString(line, writer);
			}
			try writer.writeAll("]");
		}
		try writer.writeAll("}");
	}

	for (sym.children) |*child| {
		try findAndPrintMatchMulti(allocator, child, pattern, name_path, include_body, lines, all_hashes, file_path, .json, writer, found, first_file);
	}
}

/// Check if any symbols match without printing (for deciding whether to show file header).
fn findAndPrintMatchCheck(
	sym: *const symbol_tree.SymbolNode,
	pattern: []const u8,
	parent_path: ?[]const u8,
	found: *bool,
) !void {
	if (found.*) return; // short-circuit once found
	const name_path = try sym.namePath(std.heap.page_allocator, parent_path);
	defer std.heap.page_allocator.free(name_path);

	if (matchesNamePath(pattern, name_path, sym.name)) {
		found.* = true;
		return;
	}

	for (sym.children) |*child| {
		try findAndPrintMatchCheck(child, pattern, name_path, found);
		if (found.*) return;
	}
}

// ─── Shared Editing Utilities ────────────────────────────────────────

const HashlineRef = struct {
	line: usize,
	hash: hashline.Hash,
};

fn parseHashlineRef(s: []const u8) !HashlineRef {
	const colon = std.mem.indexOf(u8, s, ":") orelse return error.InvalidHashlineRef;
	const line = std.fmt.parseInt(usize, s[0..colon], 10) catch return error.InvalidHashlineRef;
	const hash_str = s[colon + 1 ..];
	if (hash_str.len != hashline.HASH_LEN) return error.InvalidHashlineRef;
	return .{
		.line = line,
		.hash = hash_str[0..hashline.HASH_LEN].*,
	};
}

fn readStdin(allocator: std.mem.Allocator) ![]u8 {
	const stdin = std.fs.File.stdin();
	return try stdin.readToEndAlloc(allocator, 10 * 1024 * 1024);
}

fn spliceFile(allocator: std.mem.Allocator, file_path: []const u8, start_byte: usize, end_byte: usize, new_content: []const u8) !void {
	const source = try readFileContents(allocator, file_path);
	defer allocator.free(source);

	if (start_byte > source.len or end_byte > source.len or start_byte > end_byte)
		return error.InvalidByteRange;

	const result_len = source.len - (end_byte - start_byte) + new_content.len;
	const result = try allocator.alloc(u8, result_len);
	defer allocator.free(result);

	@memcpy(result[0..start_byte], source[0..start_byte]);
	@memcpy(result[start_byte .. start_byte + new_content.len], new_content);
	@memcpy(result[start_byte + new_content.len ..], source[end_byte..]);

	const file = try std.fs.cwd().createFile(file_path, .{});
	defer file.close();
	try file.writeAll(result);
}

fn extractFileAndTree(allocator: std.mem.Allocator, file_path: []const u8) !struct { source: []u8, tree: symbol_tree.SymbolTree } {
	const source = try readFileContents(allocator, file_path);
	errdefer allocator.free(source);

	const ext = std.fs.path.extension(file_path);
	var tree: symbol_tree.SymbolTree = undefined;
	var tree_valid = false;

	if (std.mem.eql(u8, ext, ".zig")) {
		tree = try symbol_tree.extractZig(allocator, source);
		tree_valid = true;
	} else if (ts_symbols.Language.fromExtension(ext) orelse ts_symbols.Language.fromShebang(source)) |lang| {
		tree = try ts_symbols.extract(allocator, source, lang);
		tree_valid = true;
	}

	if (!tree_valid) {
		return error.UnsupportedFileType; // errdefer frees source
	}

	return .{ .source = source, .tree = tree };
}

const SymbolMatch = struct {
	start_byte: usize,
	end_byte: usize,
	start_line: usize,
	end_line: usize,
	name: []const u8, // points into SymbolNode.name (no ownership)
};

/// Given source text, a byte offset within a line, and a symbol name,
/// find the 0-based column where that name first appears on that line.
/// The byte offset can be anywhere on the line (not just the start).
/// Returns 0 as fallback if the name isn't found.
fn findNameCol(source: []const u8, byte_offset: usize, name: []const u8) u32 {
	if (byte_offset >= source.len or name.len == 0) return 0;
	// Find the actual start of the line containing byte_offset
	const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..byte_offset], '\n')) |nl| nl + 1 else 0;
	// Find end of this line
	const line_end = std.mem.indexOfScalarPos(u8, source, byte_offset, '\n') orelse source.len;
	const line = source[line_start..line_end];
	// Find the name within the full line
	const col = std.mem.indexOf(u8, line, name) orelse return 0;
	return @intCast(col);
}

/// Fallback symbol finder for files without tree-sitter support (e.g. .ll).
/// Searches source text for the pattern and returns 0-based line and column.
fn findPatternPosition(source: []const u8, pattern: []const u8) ?struct { line: u32, col: u32 } {
	const pos = std.mem.indexOf(u8, source, pattern) orelse return null;
	// Count newlines before pos to get line number
	var line: u32 = 0;
	var last_newline: usize = 0;
	for (source[0..pos], 0..) |c, i| {
		if (c == '\n') {
			line += 1;
			last_newline = i + 1;
		}
	}
	const col: u32 = @intCast(pos - last_newline);
	return .{ .line = line, .col = col };
}

fn findFirstMatch(
	allocator: std.mem.Allocator,
	symbols: []const symbol_tree.SymbolNode,
	pattern: []const u8,
	parent_path: ?[]const u8,
) !?SymbolMatch {
	for (symbols) |*sym| {
		const name_path = try sym.namePath(allocator, parent_path);
		defer allocator.free(name_path);

		if (matchesNamePath(pattern, name_path, sym.name)) {
			return .{
				.start_byte = sym.start_byte,
				.end_byte = sym.end_byte,
				.start_line = sym.start_line,
				.end_line = sym.end_line,
				.name = sym.name,
			};
		}

		if (sym.children.len > 0) {
			if (try findFirstMatch(allocator, sym.children, pattern, name_path)) |m| {
				return m;
			}
		}
	}
	return null;
}

fn splitLines(allocator: std.mem.Allocator, source: []const u8) !std.ArrayListUnmanaged([]const u8) {
	var list: std.ArrayListUnmanaged([]const u8) = .{};
	var it = std.mem.splitScalar(u8, source, '\n');
	while (it.next()) |line| {
		try list.append(allocator, line);
	}
	return list;
}

fn lineByteOffsets(source: []const u8, allocator: std.mem.Allocator) ![]usize {
	// Returns byte offset of the start of each line (0-indexed line numbers)
	var offsets: std.ArrayListUnmanaged(usize) = .{};
	defer offsets.deinit(allocator);
	try offsets.append(allocator, 0);
	for (source, 0..) |ch, i| {
		if (ch == '\n' and i + 1 <= source.len) {
			try offsets.append(allocator, i + 1);
		}
	}
	return offsets.toOwnedSlice(allocator);
}

// ─── Read File Command ──────────────────────────────────────────────

pub fn runReadFile(allocator: std.mem.Allocator, file_path: []const u8, from_line: ?usize, to_line: ?usize, format: cli.OutputFormat, writer: *std.Io.Writer) !void {
	const source = try readFileContents(allocator, file_path);
	defer allocator.free(source);

	// Split into lines and compute chain hashes
	var lines_list = try splitLines(allocator, source);
	defer lines_list.deinit(allocator);
	const lines = lines_list.items;
	const total_lines = lines.len;

	const hashes = try hashline.computeChainHashes(allocator, lines);
	defer allocator.free(hashes);

	// Version is the hash of the last line of the entire file
	const version: hashline.Hash = if (hashes.len > 0) hashes[hashes.len - 1] else .{ '0', '0', '0' };

	// Determine range (1-indexed, inclusive)
	const from: usize = if (from_line) |f| if (f >= 1 and f <= total_lines) f else 1 else 1;
	const to: usize = if (to_line) |t| if (t >= 1 and t <= total_lines) t else total_lines else total_lines;

	if (from > to) {
		try writer.print("error: --from ({d}) must be <= --to ({d})\n", .{ from, to });
		return;
	}

	switch (format) {
		.json => {
			// Build the hashlined content as a string
			var content_buf = std.ArrayListUnmanaged(u8){};
			defer content_buf.deinit(allocator);
			for (from - 1..to) |idx| {
				if (content_buf.items.len > 0) {
					try content_buf.append(allocator, '\n');
				}
				// Format: line_num:hash|content
				var line_header: [32]u8 = undefined;
				const header_len = (std.fmt.bufPrint(&line_header, "{d}:{s}|", .{ idx + 1, @as([]const u8, &hashes[idx]) }) catch unreachable).len;
				try content_buf.appendSlice(allocator, line_header[0..header_len]);
				try content_buf.appendSlice(allocator, lines[idx]);
			}

			// Write JSON object
			try writer.writeAll("{\"file\":");
			try writeJsonString(file_path, writer);
			try writer.print(",\"version\":\"{s}\",\"total_lines\":{d},\"from\":{d},\"to\":{d},\"content\":", .{
				@as([]const u8, &version), total_lines, from, to,
			});
			try writeJsonString(content_buf.items, writer);
			try writer.writeAll("}\n");
		},
		.human => {
			try writer.print("# {s}  (version: {s}, lines: {d})\n", .{
				file_path, @as([]const u8, &version), total_lines,
			});
			for (from - 1..to) |idx| {
				try writer.print("{d}:{s}|{s}\n", .{ idx + 1, @as([]const u8, &hashes[idx]), lines[idx] });
			}
		},
	}
}

// ─── Editing Command Implementations ─────────────────────────────────

pub fn runCreateFile(allocator: std.mem.Allocator, file_path: []const u8, body: []const u8, writer: *std.Io.Writer) !void {
	// Check file doesn't already exist
	if (std.fs.cwd().access(file_path, .{})) |_| {
		try writer.print("error: file already exists: {s} (use replace_content to modify)\n", .{file_path});
		return;
	} else |_| {}

	// Create parent directories as needed
	if (std.fs.path.dirname(file_path)) |dir| {
		std.fs.cwd().makePath(dir) catch {};
	}

	// Write the file
	const file = try std.fs.cwd().createFile(file_path, .{});
	defer file.close();
	try file.writeAll(body);

	// Compute version and line count
	const version = hashline.computeFileVersionFromPath(allocator, file_path);
	var line_count: usize = 0;
	var i: usize = 0;
	while (i < body.len) : (i += 1) {
		if (body[i] == '\n') line_count += 1;
	}
	if (body.len > 0 and body[body.len - 1] != '\n') line_count += 1;

	if (version) |v| {
		try writer.print("Created {s} ({d} lines, version: {s})\n", .{ file_path, line_count, &v });
	} else {
		try writer.print("Created {s} ({d} lines, version: ---)\n", .{ file_path, line_count });
	}
}

pub fn runDestroyFile(allocator: std.mem.Allocator, file_path: []const u8, version: ?[]const u8, writer: *std.Io.Writer) !void {
	// Read source for version check (also verifies file exists)
	const source = readFileContents(allocator, file_path) catch |err| {
		try writer.print("error: cannot read file '{s}': {}\n", .{ file_path, err });
		return;
	};
	defer allocator.free(source);

	// Version check is optional for destroy — soft mode
	if (version) |expected| {
		if (hashline.computeFileVersion(allocator, source) catch null) |current| {
			if (!std.mem.eql(u8, expected, &current)) {
				try writer.print("error: file modified since last read (expected version {s}, current {s}) — re-read and retry\n", .{ expected, &current });
				return;
			}
		}
	}

	// Get absolute path for trash commands
	const abs_path = try std.fs.cwd().realpathAlloc(allocator, file_path);
	defer allocator.free(abs_path);

	if (comptime builtin.os.tag == .macos) {
		// macOS: move directly to ~/.Trash/ (avoids needing a Finder/UI session).
		// Files moved here appear in Trash and support "Put Back".
		const home = std.posix.getenv("HOME") orelse "/tmp";
		const trash_dir = try std.fs.path.join(allocator, &.{ home, ".Trash" });
		defer allocator.free(trash_dir);
		std.fs.cwd().makePath(trash_dir) catch {};
		const basename = std.fs.path.basename(abs_path);
		const dest = try std.fs.path.join(allocator, &.{ trash_dir, basename });
		defer allocator.free(dest);
		std.fs.renameAbsolute(abs_path, dest) catch {
			try writer.print("error: could not move '{s}' to trash\n", .{file_path});
			return;
		};
	} else {
		// Linux: try gio trash, then trash-put, then manual move
		// Try gio trash
		const gio_ok = blk: {
			var child = std.process.Child.init(
				&[_][]const u8{ "gio", "trash", abs_path },
				allocator,
			);
			child.stderr_behavior = .Ignore;
			child.stdout_behavior = .Ignore;
			if (child.spawnAndWait()) |term| {
				break :blk term.Exited == 0;
			} else |_| {
				break :blk false;
			}
		};

		// Try trash-put
		const trash_put_ok = if (!gio_ok) blk: {
			var child = std.process.Child.init(
				&[_][]const u8{ "trash-put", abs_path },
				allocator,
			);
			child.stderr_behavior = .Ignore;
			child.stdout_behavior = .Ignore;
			if (child.spawnAndWait()) |term| {
				break :blk term.Exited == 0;
			} else |_| {
				break :blk false;
			}
		} else true;

		// Fallback: move to ~/.local/share/Trash/files/
		if (!trash_put_ok) {
			const home = std.posix.getenv("HOME") orelse "/tmp";
			const trash_dir = try std.fs.path.join(allocator, &.{ home, ".local/share/Trash/files" });
			defer allocator.free(trash_dir);
			std.fs.cwd().makePath(trash_dir) catch {};
			const basename = std.fs.path.basename(abs_path);
			const dest = try std.fs.path.join(allocator, &.{ trash_dir, basename });
			defer allocator.free(dest);
			std.fs.renameAbsolute(abs_path, dest) catch {
				try writer.print("error: could not move '{s}' to trash\n", .{file_path});
				return;
			};
		}
	}

	if (version != null) {
		try writer.print("Moved {s} to trash\n", .{file_path});
	} else {
		try writer.print("Moved {s} to trash (without version check)\n", .{file_path});
	}
}

pub fn runDiff(allocator: std.mem.Allocator, staged: bool, root_path: []const u8, format: cli.OutputFormat, writer: *std.Io.Writer) !void {
	// Run git diff
	var argv = std.ArrayListUnmanaged([]const u8){};
	defer argv.deinit(allocator);
	try argv.appendSlice(allocator, &.{ "git", "diff", "-U3" });
	if (staged) try argv.append(allocator, "--staged");

	var child = std.process.Child.init(argv.items, allocator);
	child.stdout_behavior = .Pipe;
	child.stderr_behavior = .Ignore;
	child.cwd = root_path;
	_ = try child.spawn();
	const git_output = try child.stdout.?.readToEndAlloc(allocator, 10 * 1024 * 1024);
	defer allocator.free(git_output);
	const term = try child.wait();
	if (term.Exited != 0) {
		try writer.print("error: git diff failed (exit code {d})\n", .{term.Exited});
		return;
	}

	if (git_output.len == 0) {
		if (format == .json) {
			try writer.writeAll("{\"files\":[]}\n");
		} else {
			try writer.writeAll("No changes.\n");
		}
		return;
	}

	// Parse unified diff and annotate with hashlines
	var lines_iter = std.mem.splitScalar(u8, git_output, '\n');
	var current_file: ?[]const u8 = null;
	var current_hashes: ?[]hashline.Hash = null;
	defer if (current_hashes) |h| allocator.free(h);
	var new_line_num: usize = 0;
	var first_file = true;

	if (format == .json) {
		try writer.writeAll("{\"files\":[");
	}

	while (lines_iter.next()) |line| {
		if (std.mem.startsWith(u8, line, "+++ b/")) {
			// New file in diff
			const rel_path = line[6..];

			// Close previous JSON file object
			if (format == .json and !first_file) {
				try writer.writeAll("]},");
			}

			current_file = rel_path;
			if (current_hashes) |h| allocator.free(h);
			current_hashes = null;

			// Compute hashlines for the current file on disk
			const abs_path = std.fs.path.join(allocator, &.{ root_path, rel_path }) catch continue;
			defer allocator.free(abs_path);
			const source = readFileContents(allocator, abs_path) catch continue;
			defer allocator.free(source);
			current_hashes = hashline.computeSourceHashes(allocator, source) catch null;

			const version = if (current_hashes) |h| (if (h.len > 0) h[h.len - 1] else null) else null;

			if (format == .json) {
				try writer.writeAll("{\"file\":");
				try writeJsonString(rel_path, writer);
				if (version) |v| {
					try writer.print(",\"version\":\"{s}\"", .{v});
				}
				try writer.writeAll(",\"hunks\":[");
				first_file = false;
			} else {
				if (version) |v| {
					try writer.print("--- a/{s}  (version: {s})\n+++ b/{s}\n", .{ rel_path, v, rel_path });
				} else {
					try writer.print("--- a/{s}\n+++ b/{s}\n", .{ rel_path, rel_path });
				}
			}
			continue;
		}

		if (std.mem.startsWith(u8, line, "--- ")) continue; // skip old file header
		if (std.mem.startsWith(u8, line, "diff --git")) continue;
		if (std.mem.startsWith(u8, line, "index ")) continue;

		if (std.mem.startsWith(u8, line, "@@ ")) {
			// Parse hunk header to get new-file line number
			// Format: @@ -old_start,old_count +new_start,new_count @@
			if (std.mem.indexOf(u8, line, "+")) |plus_idx| {
				const after_plus = line[plus_idx + 1 ..];
				if (std.mem.indexOfAny(u8, after_plus, ",@ ")) |end| {
					new_line_num = std.fmt.parseInt(usize, after_plus[0..end], 10) catch 0;
				}
			}
			if (format == .json) {
				// Not tracking hunks separately in JSON for simplicity
			} else {
				try writer.print("{s}\n", .{line});
			}
			continue;
		}

		if (current_file == null) continue;

		if (line.len == 0) {
			if (format == .human) try writer.writeAll("\n");
			continue;
		}

		const prefix = line[0];
		const content = if (line.len > 1) line[1..] else "";

		switch (prefix) {
			' ' => {
				// Context line — use new file line number
				const hash_str = getHash(current_hashes, new_line_num);
				if (format == .json) {
					// skip context in JSON for brevity
				} else {
					try writer.print("  {d}:{s}|{s}\n", .{ new_line_num, hash_str, content });
				}
				new_line_num += 1;
			},
			'-' => {
				// Deleted line — no hash (doesn't exist in current file)
				if (format == .json) {
					// skip deletes in JSON for brevity
				} else {
					try writer.print("- {s}|{s}\n", .{ "---", content });
				}
			},
			'+' => {
				// Added line — hash from current file
				const hash_str = getHash(current_hashes, new_line_num);
				if (format == .json) {
					// skip adds in JSON for brevity
				} else {
					try writer.print("+ {d}:{s}|{s}\n", .{ new_line_num, hash_str, content });
				}
				new_line_num += 1;
			},
			else => {
				if (format == .human) {
					try writer.print("{s}\n", .{line});
				}
			},
		}
	}

	if (format == .json) {
		if (!first_file) try writer.writeAll("]}");
		try writer.writeAll("]}\n");
	}
}

fn getHash(hashes: ?[]hashline.Hash, line_1: usize) [3]u8 {
	if (hashes) |h| {
		if (line_1 > 0 and line_1 <= h.len) return h[line_1 - 1];
	}
	return .{ '-', '-', '-' };
}

pub fn runReplaceSymbol(allocator: std.mem.Allocator, file_path: []const u8, pattern: []const u8, input_text: []const u8, version: ?[]const u8, writer: *std.Io.Writer) !void {
	const result = try extractFileAndTree(allocator, file_path);
	var tree = result.tree;
	defer tree.deinit(allocator);
	defer allocator.free(result.source);

	// Version check for optimistic concurrency
	if (!try checkFileVersion(allocator, result.source, version, writer)) return;

	const match = try findFirstMatch(allocator, tree.symbols, pattern, null) orelse {
		try writer.print("error: no symbol matching '{s}' found in {s}\n", .{ pattern, file_path });
		return;
	};

	try spliceFile(allocator, file_path, match.start_byte, match.end_byte, input_text);
	// Compute new hashlines at the replacement boundaries
	if (computeHashAtLine(allocator, file_path, match.start_line)) |start_hash| {
		try writer.print("Replaced {s} (lines {d}:{s}-{d}, bytes {d}-{d})\n", .{
			pattern, match.start_line, &start_hash, match.end_line, match.start_byte, match.end_byte,
		});
	} else {
		try writer.print("Replaced {s} (lines {d}-{d}, bytes {d}-{d})\n", .{
			pattern, match.start_line, match.end_line, match.start_byte, match.end_byte,
		});
	}
	try emitNewVersion(allocator, file_path, writer);
}

pub fn runInsertAfter(allocator: std.mem.Allocator, file_path: []const u8, pattern: []const u8, input_text: []const u8, version: ?[]const u8, writer: *std.Io.Writer) !void {
	const result = try extractFileAndTree(allocator, file_path);
	var tree = result.tree;
	defer tree.deinit(allocator);
	defer allocator.free(result.source);

	// Version check for optimistic concurrency
	if (!try checkFileVersion(allocator, result.source, version, writer)) return;

	const match = try findFirstMatch(allocator, tree.symbols, pattern, null) orelse {
		try writer.print("error: no symbol matching '{s}' found in {s}\n", .{ pattern, file_path });
		return;
	};

	// Insert after the symbol's end byte with a newline separator
	const insert_content = try std.fmt.allocPrint(allocator, "\n{s}", .{input_text});
	defer allocator.free(insert_content);

	try spliceFile(allocator, file_path, match.end_byte, match.end_byte, insert_content);
	// The inserted content starts right after end_line, so line end_line+1 is the new content
	const new_line = match.end_line + 1;
	if (computeHashAtLine(allocator, file_path, new_line)) |h| {
		try writer.print("Inserted after {s} (after line {d}, new content at {d}:{s})\n", .{ pattern, match.end_line, new_line, &h });
	} else {
		try writer.print("Inserted after {s} (after line {d})\n", .{ pattern, match.end_line });
	}
	try emitNewVersion(allocator, file_path, writer);
}

pub fn runInsertBefore(allocator: std.mem.Allocator, file_path: []const u8, pattern: []const u8, input_text: []const u8, version: ?[]const u8, writer: *std.Io.Writer) !void {
	const result = try extractFileAndTree(allocator, file_path);
	var tree = result.tree;
	defer tree.deinit(allocator);
	defer allocator.free(result.source);

	// Version check for optimistic concurrency
	if (!try checkFileVersion(allocator, result.source, version, writer)) return;

	const match = try findFirstMatch(allocator, tree.symbols, pattern, null) orelse {
		try writer.print("error: no symbol matching '{s}' found in {s}\n", .{ pattern, file_path });
		return;
	};

	// Insert before the symbol's start byte with a newline separator
	const insert_content = try std.fmt.allocPrint(allocator, "{s}\n", .{input_text});
	defer allocator.free(insert_content);

	try spliceFile(allocator, file_path, match.start_byte, match.start_byte, insert_content);
	// The inserted content is at start_line (original content shifted down)
	if (computeHashAtLine(allocator, file_path, match.start_line)) |h| {
		try writer.print("Inserted before {s} (new content at {d}:{s})\n", .{ pattern, match.start_line, &h });
	} else {
		try writer.print("Inserted before {s} (before line {d})\n", .{ pattern, match.start_line });
	}
	try emitNewVersion(allocator, file_path, writer);
}

pub fn runReplaceLines(allocator: std.mem.Allocator, file_path: []const u8, from_str: []const u8, to_str: []const u8, input_text: []const u8, version: ?[]const u8, writer: *std.Io.Writer) !void {
	const from = parseHashlineRef(from_str) catch {
		try writer.print("error: invalid --from hashline ref '{s}' (expected format: line:hash, e.g. 45:r2p)\n", .{from_str});
		return;
	};
	const to = parseHashlineRef(to_str) catch {
		try writer.print("error: invalid --to hashline ref '{s}' (expected format: line:hash, e.g. 47:3bw)\n", .{to_str});
		return;
	};

	if (from.line > to.line) {
		try writer.print("error: --from line ({d}) must be <= --to line ({d})\n", .{ from.line, to.line });
		return;
	}

	const source = try readFileContents(allocator, file_path);
	defer allocator.free(source);

	// Version check for optimistic concurrency
	if (!try checkFileVersion(allocator, source, version, writer)) return;

	// Split into lines and compute hashes
	var lines_list = try splitLines(allocator, source);
	defer lines_list.deinit(allocator);
	const lines = lines_list.items;

	const all_hashes = try hashline.computeChainHashes(allocator, lines);
	defer allocator.free(all_hashes);

	// Verify hashes
	const from_idx = from.line - 1;
	const to_idx = to.line - 1;

	if (from_idx >= all_hashes.len) {
		try writer.print("error: line {d} is beyond end of file ({d} lines)\n", .{ from.line, all_hashes.len });
		return;
	}
	if (to_idx >= all_hashes.len) {
		try writer.print("error: line {d} is beyond end of file ({d} lines)\n", .{ to.line, all_hashes.len });
		return;
	}

	if (!std.mem.eql(u8, &all_hashes[from_idx], &from.hash)) {
		try writer.print("error: hashline mismatch at line {d} (expected {s}, got {s}) — file changed since last read\n", .{
			from.line, &from.hash, &all_hashes[from_idx],
		});
		return;
	}
	if (!std.mem.eql(u8, &all_hashes[to_idx], &to.hash)) {
		try writer.print("error: hashline mismatch at line {d} (expected {s}, got {s}) — file changed since last read\n", .{
			to.line, &to.hash, &all_hashes[to_idx],
		});
		return;
	}

	// Compute byte offsets for the line range
	const offsets = try lineByteOffsets(source, allocator);
	defer allocator.free(offsets);

	const start_byte = offsets[from_idx];
	const end_byte = if (to_idx + 1 < offsets.len) offsets[to_idx + 1] else source.len;

	try spliceFile(allocator, file_path, start_byte, end_byte, input_text);
	try writer.print("Replaced lines {d}-{d}\n", .{ from.line, to.line });
	try emitNewVersion(allocator, file_path, writer);
}

pub fn runInsertAt(allocator: std.mem.Allocator, file_path: []const u8, ref_str: []const u8, input_text: []const u8, version: ?[]const u8, writer: *std.Io.Writer) !void {
	const ref = parseHashlineRef(ref_str) catch {
		try writer.print("error: invalid hashline ref '{s}' (expected format: line:hash, e.g. 47:3bw)\n", .{ref_str});
		return;
	};

	const source = try readFileContents(allocator, file_path);
	defer allocator.free(source);

	// Version check for optimistic concurrency
	if (!try checkFileVersion(allocator, source, version, writer)) return;

	var lines_list = try splitLines(allocator, source);
	defer lines_list.deinit(allocator);
	const lines = lines_list.items;

	const all_hashes = try hashline.computeChainHashes(allocator, lines);
	defer allocator.free(all_hashes);

	const ref_idx = ref.line - 1;
	if (ref_idx >= all_hashes.len) {
		try writer.print("error: line {d} is beyond end of file ({d} lines)\n", .{ ref.line, all_hashes.len });
		return;
	}

	if (!std.mem.eql(u8, &all_hashes[ref_idx], &ref.hash)) {
		try writer.print("error: hashline mismatch at line {d} (expected {s}, got {s}) — file changed since last read\n", .{
			ref.line, &ref.hash, &all_hashes[ref_idx],
		});
		return;
	}

	// Insert after the referenced line
	const offsets = try lineByteOffsets(source, allocator);
	defer allocator.free(offsets);

	const insert_byte = if (ref_idx + 1 < offsets.len) offsets[ref_idx + 1] else source.len;

	// Ensure new content ends with newline for clean insertion
	const insert_content = if (input_text.len > 0 and input_text[input_text.len - 1] != '\n')
		try std.fmt.allocPrint(allocator, "{s}\n", .{input_text})
	else
		try allocator.dupe(u8, input_text);
	defer allocator.free(insert_content);

	try spliceFile(allocator, file_path, insert_byte, insert_byte, insert_content);
	const new_line = ref.line + 1;
	if (computeHashAtLine(allocator, file_path, new_line)) |h| {
		try writer.print("Inserted after line {d} (new content at {d}:{s})\n", .{ ref.line, new_line, &h });
	} else {
		try writer.print("Inserted after line {d}\n", .{ref.line});
	}
	try emitNewVersion(allocator, file_path, writer);
}

/// Check if the file's current version matches the expected version.
/// Returns false if version mismatch (error already printed to writer).
/// Returns true if version matches or no version provided (warning printed).
fn checkFileVersion(allocator: std.mem.Allocator, source: []const u8, expected: ?[]const u8, writer: *std.Io.Writer) !bool {
	if (expected) |ev| {
		if (hashline.computeFileVersion(allocator, source) catch null) |current| {
			if (!std.mem.eql(u8, ev, &current)) {
				try writer.print("error: file modified since last read (expected version {s}, current {s}) — re-read and retry\n", .{ ev, &current });
				return false;
			}
		}
	} else {
		try writer.print("error: --version is required. Use codescan read-file to get the current version hash.\n", .{});
		return false;
	}
	return true;
}

/// Emit the new file version after a successful write.
fn emitNewVersion(allocator: std.mem.Allocator, file_path: []const u8, writer: *std.Io.Writer) !void {
	if (hashline.computeFileVersionFromPath(allocator, file_path)) |nv| {
		try writer.print("version: {s}\n", .{&nv});
	}
}

pub fn runReplaceContentMultiFile(
	allocator: std.mem.Allocator,
	db: storage.Db,
	needle: []const u8,
	regex_mode: bool,
	replace_all_flag: bool,
	input_text: []const u8,
	path_patterns: []const []const u8,
	confirm_hash: ?[]const u8,
	root_path: []const u8,
	writer: *std.Io.Writer,
) !void {
	const repl = if (input_text.len > 0 and input_text[input_text.len - 1] == '\n')
		input_text[0 .. input_text.len - 1]
	else
		input_text;

	// Get indexed files
	const indexed_files = try storage.getAllIndexedFiles(db, allocator);
	defer {
		for (indexed_files) |f| allocator.free(f.file_path);
		allocator.free(indexed_files);
	}

	// Collect all planned changes
	const FileChange = struct {
		rel_path: []const u8,
		abs_path: []const u8,
		original: []const u8,
		modified: []const u8,
		diff_text: []const u8,
		match_count: usize,
	};
	var changes = std.ArrayListUnmanaged(FileChange){};
	defer {
		for (changes.items) |c| {
			allocator.free(c.abs_path);
			allocator.free(c.original);
			allocator.free(c.modified);
			allocator.free(c.diff_text);
		}
		changes.deinit(allocator);
	}

	var total_matches: usize = 0;

	for (indexed_files) |indexed_file| {
		const rel_path = indexed_file.file_path;

		// Apply path filters
		var any_match = false;
		for (path_patterns) |pf| {
			if (search.pathMatchesGlob(rel_path, pf)) {
				any_match = true;
				break;
			}
		}
		if (!any_match) continue;

		// Read file
		const abs_path = std.fs.path.join(allocator, &.{ root_path, rel_path }) catch continue;
		errdefer allocator.free(abs_path);
		const source = readFileContents(allocator, abs_path) catch {
			allocator.free(abs_path);
			continue;
		};
		errdefer allocator.free(source);

		// Find matches
		if (regex_mode) {
			var re = pcre2.Regex.compile(allocator, needle) catch {
				try writer.print("error: invalid regex pattern: {s}\n", .{needle});
				return;
			};
			defer re.deinit();

			var match_count: usize = 0;
			var offset: usize = 0;
			while (re.findPosition(source, offset)) |m| {
				match_count += 1;
				offset = if (m.end > m.start) m.end else m.start + 1;
			}
			if (match_count == 0) {
				allocator.free(abs_path);
				allocator.free(source);
				continue;
			}
			if (match_count > 1 and !replace_all_flag) {
				try writer.print("error: found {d} matches in {s}; use --all to replace all\n", .{ match_count, rel_path });
				allocator.free(abs_path);
				allocator.free(source);
				return;
			}
			const result = re.substituteOwned(allocator, source, repl, replace_all_flag) catch {
				allocator.free(abs_path);
				allocator.free(source);
				continue;
			};
			errdefer allocator.free(result.output);

			const diff_text = diff.generateUnifiedDiff(allocator, source, result.output, rel_path) catch {
				allocator.free(abs_path);
				allocator.free(source);
				allocator.free(result.output);
				continue;
			};
			errdefer allocator.free(diff_text);

			total_matches += match_count;
			try changes.append(allocator, .{
				.rel_path = rel_path,
				.abs_path = abs_path,
				.original = source,
				.modified = result.output,
				.diff_text = diff_text,
				.match_count = match_count,
			});
		} else {
			// Literal mode
			var match_count: usize = 0;
			var offset: usize = 0;
			while (offset <= source.len -| needle.len) {
				if (std.mem.indexOf(u8, source[offset..], needle)) |pos| {
					match_count += 1;
					offset = offset + pos + needle.len;
				} else break;
			}
			if (match_count == 0) {
				allocator.free(abs_path);
				allocator.free(source);
				continue;
			}
			if (match_count > 1 and !replace_all_flag) {
				try writer.print("error: found {d} matches in {s}; use --all to replace all\n", .{ match_count, rel_path });
				allocator.free(abs_path);
				allocator.free(source);
				return;
			}

			// Build replacement
			var result_buf = std.ArrayListUnmanaged(u8){};
			defer result_buf.deinit(allocator);
			var src_off: usize = 0;
			var replaced: usize = 0;
			while (src_off <= source.len -| needle.len) {
				if (std.mem.indexOf(u8, source[src_off..], needle)) |pos| {
					try result_buf.appendSlice(allocator, source[src_off .. src_off + pos]);
					try result_buf.appendSlice(allocator, repl);
					src_off = src_off + pos + needle.len;
					replaced += 1;
					if (!replace_all_flag) break;
				} else break;
			}
			try result_buf.appendSlice(allocator, source[src_off..]);
			const modified = try allocator.dupe(u8, result_buf.items);
			errdefer allocator.free(modified);

			const diff_text = diff.generateUnifiedDiff(allocator, source, modified, rel_path) catch {
				allocator.free(abs_path);
				allocator.free(source);
				allocator.free(modified);
				continue;
			};
			errdefer allocator.free(diff_text);

			total_matches += match_count;
			try changes.append(allocator, .{
				.rel_path = rel_path,
				.abs_path = abs_path,
				.original = source,
				.modified = modified,
				.diff_text = diff_text,
				.match_count = match_count,
			});
		}
	}

	if (changes.items.len == 0) {
		try writer.print("No matches found for '{s}' in files matching path filter.\n", .{needle});
		return;
	}

	// Compute confirmation hash from all diffs combined
	var hasher = std.hash.XxHash64.init(0);
	for (changes.items) |c| {
		hasher.update(c.diff_text);
	}
	const confirm_digest = hasher.final();
	var confirm_code: hashline.Hash = undefined;
	{
		const ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
		var v = confirm_digest;
		comptime var ci: usize = hashline.HASH_LEN;
		inline while (ci > 0) {
			ci -= 1;
			confirm_code[ci] = ALPHABET[v % 62];
			v /= 62;
		}
	}

	if (confirm_hash) |expected| {
		// Verify hash matches
		if (!std.mem.eql(u8, expected, &confirm_code)) {
			try writer.print("error: confirm hash mismatch (expected {s}, computed {s}) — changes differ from dry run, re-run without --confirm to preview\n", .{ expected, &confirm_code });
			return;
		}

		// Apply all changes
		for (changes.items) |c| {
			const file = std.fs.cwd().createFile(c.abs_path, .{}) catch {
				try writer.print("error: could not write {s}\n", .{c.rel_path});
				continue;
			};
			defer file.close();
			file.writeAll(c.modified) catch {
				try writer.print("error: could not write {s}\n", .{c.rel_path});
				continue;
			};
		}
		try writer.print("Replaced {d} occurrences across {d} files.\n", .{ total_matches, changes.items.len });
	} else {
		// Dry run — show diffs and confirm hash
		try writer.print("Would replace {d} occurrences across {d} files:\n\n", .{ total_matches, changes.items.len });
		for (changes.items) |c| {
			try writer.writeAll(c.diff_text);
			try writer.writeAll("\n");
		}
		try writer.print("Confirm hash: {s}\nRe-run with --confirm {s} to apply.\n", .{ &confirm_code, &confirm_code });
	}
}

pub fn runReplaceContent(allocator: std.mem.Allocator, file_path: []const u8, needle: []const u8, regex_mode: bool, replace_all_flag: bool, input_text: []const u8, version: ?[]const u8, writer: *std.Io.Writer) !void {
	// Strip trailing newline from replacement (stdin usually adds one)
	const repl = if (input_text.len > 0 and input_text[input_text.len - 1] == '\n')
		input_text[0 .. input_text.len - 1]
	else
		input_text;

	const source = try readFileContents(allocator, file_path);
	defer allocator.free(source);

	// Version check for optimistic concurrency
	if (!try checkFileVersion(allocator, source, version, writer)) return;

	if (regex_mode) {
		// Regex mode: use PCRE2
		var re = pcre2.Regex.compile(allocator, needle) catch {
			try writer.print("error: invalid regex pattern '{s}'\n", .{needle});
			return;
		};
		defer re.deinit();

		// Count matches for validation
		var match_count: usize = 0;
		var match_positions = std.ArrayListUnmanaged(pcre2.Match){};
		defer match_positions.deinit(allocator);
		{
			var offset: usize = 0;
			while (re.findPosition(source, offset)) |m| {
				try match_positions.append(allocator, m);
				match_count += 1;
				if (m.end > offset) {
					offset = m.end;
				} else {
					offset += 1; // avoid infinite loop on zero-length matches
				}
			}
		}

		if (match_count == 0) {
			try writer.print("error: no match found for '{s}' in {s}\n", .{ needle, file_path });
			return;
		}
		if (match_count > 1 and !replace_all_flag) {
			try writer.print("error: found {d} matches; use --all to replace all, or refine your pattern\n", .{match_count});
			return;
		}

		// Perform substitution
		const result = re.substituteOwned(allocator, source, repl, replace_all_flag) catch {
			try writer.print("error: substitution failed\n", .{});
			return;
		};
		defer allocator.free(result.output);

		const file = try std.fs.cwd().createFile(file_path, .{});
		defer file.close();
		try file.writeAll(result.output);

		// Report affected lines
		if (match_count == 1) {
			const line = byteOffsetToLine(source, match_positions.items[0].start);
			if (computeHashAtLine(allocator, file_path, line)) |h| {
				try writer.print("Replaced 1 occurrence in {s} (line {d}:{s})\n", .{ file_path, line, &h });
			} else {
				try writer.print("Replaced 1 occurrence in {s} (line {d})\n", .{ file_path, line });
			}
		} else {
			try writer.print("Replaced {d} occurrences in {s} (lines", .{ result.count, file_path });
			for (match_positions.items, 0..) |m, idx| {
				const line = byteOffsetToLine(source, m.start);
				if (idx > 0) try writer.writeAll(",");
				try writer.print(" {d}", .{line});
			}
			try writer.writeAll(")\n");
		}

		// Emit diff
		const diff_text = diff.generateUnifiedDiff(allocator, source, result.output, file_path) catch null;
		if (diff_text) |d| {
			defer allocator.free(d);
			if (d.len > 0) {
				try writer.writeAll(d);
			}
		}

		// Emit new version
		try emitNewVersion(allocator, file_path, writer);
	} else {
		// Literal mode: use std.mem.indexOf
		var match_positions = std.ArrayListUnmanaged(usize){};
		defer match_positions.deinit(allocator);
		{
			var offset: usize = 0;
			while (offset <= source.len -| needle.len) {
				if (std.mem.indexOf(u8, source[offset..], needle)) |pos| {
					try match_positions.append(allocator, offset + pos);
					offset = offset + pos + needle.len;
				} else break;
			}
		}

		const match_count = match_positions.items.len;
		if (match_count == 0) {
			try writer.print("error: no match found for '{s}' in {s}\n", .{ needle, file_path });
			return;
		}
		if (match_count > 1 and !replace_all_flag) {
			try writer.print("error: found {d} matches; use --all to replace all, or refine your pattern\n", .{match_count});
			return;
		}

		// Build result by splicing
		const positions = if (replace_all_flag) match_positions.items else match_positions.items[0..1];
		const result_len = source.len - (positions.len * needle.len) + (positions.len * repl.len);
		const result = try allocator.alloc(u8, result_len);
		defer allocator.free(result);

		var src_offset: usize = 0;
		var dst_offset: usize = 0;
		for (positions) |pos| {
			const before_len = pos - src_offset;
			@memcpy(result[dst_offset .. dst_offset + before_len], source[src_offset .. src_offset + before_len]);
			dst_offset += before_len;
			@memcpy(result[dst_offset .. dst_offset + repl.len], repl);
			dst_offset += repl.len;
			src_offset = pos + needle.len;
		}
		// Copy remainder
		const tail_len = source.len - src_offset;
		@memcpy(result[dst_offset .. dst_offset + tail_len], source[src_offset..]);

		const file = try std.fs.cwd().createFile(file_path, .{});
		defer file.close();
		try file.writeAll(result);

		// Report affected lines
		if (positions.len == 1) {
			const line = byteOffsetToLine(source, positions[0]);
			if (computeHashAtLine(allocator, file_path, line)) |h| {
				try writer.print("Replaced 1 occurrence in {s} (line {d}:{s})\n", .{ file_path, line, &h });
			} else {
				try writer.print("Replaced 1 occurrence in {s} (line {d})\n", .{ file_path, line });
			}
		} else {
			try writer.print("Replaced {d} occurrences in {s} (lines", .{ positions.len, file_path });
			for (positions, 0..) |pos, idx| {
				const line = byteOffsetToLine(source, pos);
				if (idx > 0) try writer.writeAll(",");
				try writer.print(" {d}", .{line});
			}
			try writer.writeAll(")\n");
		}

		// Emit diff
		const diff_text = diff.generateUnifiedDiff(allocator, source, result, file_path) catch null;
		if (diff_text) |d| {
			defer allocator.free(d);
			if (d.len > 0) {
				try writer.writeAll(d);
			}
		}

		// Emit new version
		try emitNewVersion(allocator, file_path, writer);
	}
}

/// Convert a byte offset in source text to a 1-based line number.
fn byteOffsetToLine(source: []const u8, byte_offset: usize) usize {
	var line: usize = 1;
	for (source[0..@min(byte_offset, source.len)]) |ch| {
		if (ch == '\n') line += 1;
	}
	return line;
}

fn resolveServer(ext: []const u8, overrides: []const config.LspOverride) ?lsp.ServerInfo {
	const lang_id = lsp.languageId(ext);
	for (overrides) |ovr| {
		if (std.mem.eql(u8, ovr.language, lang_id)) {
			return .{
				.binary = ovr.binary_path,
				.args = &[_][]const u8{},
			};
		}
	}
	return lsp.serverForExtension(ext);
}

fn printLspNotFound(writer: *std.Io.Writer, ext: []const u8, server_info: lsp.ServerInfo) !void {
	try writer.print("error: could not start language server '{s}' — is it installed and on PATH?\n", .{server_info.binary});
	if (server_info.install_hint.len > 0) {
		try writer.print("  install: {s}\n", .{server_info.install_hint});
	}
	if (server_info.install_url.len > 0) {
		try writer.print("  docs:    {s}\n", .{server_info.install_url});
	}
	try writer.print("  note:    no reindex needed — LSP operations work on-demand for '{s}' files\n", .{ext});
}

const LocateResult = struct {
	source: []u8,
	tree: ?symbol_tree.SymbolTree,
	line: u32,
	col: u32,
};

/// Locate a symbol in a file: tries tree-sitter extraction first, falls back to text search.
/// Returns null if the pattern was not found (caller should print the "not found" message).
/// On null return, all resources are cleaned up internally.
fn locateSymbol(allocator: std.mem.Allocator, file_path: []const u8, pattern: []const u8) !?LocateResult {
	if (extractFileAndTree(allocator, file_path)) |result| {
		const match = findFirstMatch(allocator, result.tree.symbols, pattern, "") catch null;
		if (match) |sym_match| {
			return .{
				.source = result.source,
				.tree = result.tree,
				.line = @intCast(sym_match.start_line - 1),
				.col = findNameCol(result.source, sym_match.start_byte, sym_match.name),
			};
		} else {
			// Symbol not in tree-sitter tree — fall back to text search (e.g. local variables)
			const pos = findPatternPosition(result.source, pattern) orelse {
				var t = result.tree;
				t.deinit(allocator);
				allocator.free(result.source);
				return null;
			};
			return .{ .source = result.source, .tree = result.tree, .line = pos.line, .col = pos.col };
		}
	} else |err| {
		if (err != error.UnsupportedFileType) return err;
		const source = try readFileContents(allocator, file_path);
		const pos = findPatternPosition(source, pattern) orelse {
			allocator.free(source);
			return null;
		};
		return .{ .source = source, .tree = null, .line = pos.line, .col = pos.col };
	}
}

pub fn runReferences(allocator: std.mem.Allocator, file_path: []const u8, pattern: []const u8, out_fmt: cli.OutputFormat, root_path: []const u8, lsp_overrides: []const config.LspOverride, writer: *std.Io.Writer) !void {
	const loc = try locateSymbol(allocator, file_path, pattern) orelse {
		try writer.print("error: '{s}' not found in '{s}'\n", .{ pattern, file_path });
		return;
	};
	const source = loc.source;
	var tree = loc.tree;
	const line = loc.line;
	const col = loc.col;
	defer allocator.free(source);
	defer if (tree) |*t| t.deinit(allocator);

	// Determine the language server binary
	const ext = std.fs.path.extension(file_path);
	const server_info = resolveServer(ext, lsp_overrides) orelse {
		try writer.print("error: no language server known for '{s}' files\n", .{ext});
		return;
	};

	// Resolve absolute path and root URI (use project root, not file parent)
	const abs_path = try std.fs.cwd().realpathAlloc(allocator, file_path);
	defer allocator.free(abs_path);

	const abs_root = std.fs.cwd().realpathAlloc(allocator, root_path) catch try allocator.dupe(u8, std.fs.path.dirname(abs_path) orelse "/");
	defer allocator.free(abs_root);

	const root_uri = try lsp.pathToUri(allocator, abs_root);
	defer allocator.free(root_uri);

	const file_uri = try lsp.pathToUri(allocator, abs_path);
	defer allocator.free(file_uri);

	// Start LSP, open file, request references
	var client = lsp.LspClient.start(allocator, server_info, root_uri) catch {
		try printLspNotFound(writer, ext, server_info);
		return;
	};
	defer client.deinit();

	const lang_id = lsp.languageId(ext);
	client.didOpen(file_uri, lang_id, source) catch {
		try writer.print("error: failed to send didOpen to language server\n", .{});
		return;
	};

	const locations = client.references(file_uri, line, col) catch {
		try writer.print("error: references request failed\n", .{});
		return;
	};
	defer {
		for (locations) |l| allocator.free(l.uri);
		allocator.free(locations);
	}

	if (locations.len == 0) {
		try writer.print("No references found for '{s}'\n", .{pattern});
		return;
	}

	// Build a cache of file path → chain hashes for hashline output
	var hash_cache = std.StringHashMap([]const hashline.Hash).init(allocator);
	defer {
		var it = hash_cache.valueIterator();
		while (it.next()) |hashes| allocator.free(hashes.*);
		hash_cache.deinit();
	}

	for (locations) |ref| {
		const path = lsp.uriToPath(ref.uri) orelse continue;
		if (hash_cache.contains(path)) continue;
		const ref_source = readFileContents(allocator, path) catch continue;
		defer allocator.free(ref_source);
		const hashes = hashline.computeSourceHashes(allocator, ref_source) catch continue;
		hash_cache.put(path, hashes) catch continue;
	}

	if (out_fmt == .json) {
		try writer.writeAll("[");
		for (locations, 0..) |ref, i| {
			if (i > 0) try writer.writeAll(",");
			const path = lsp.uriToPath(ref.uri) orelse ref.uri;
			const line_1 = ref.start_line + 1;
			const hash_str = getHashForLine(hash_cache, path, line_1);
			if (hash_str) |h| {
				try writer.print("{{\"file\":\"{s}\",\"line\":{d},\"hash\":\"{s}\",\"col\":{d}}}", .{
					path, line_1, h, ref.start_col,
				});
			} else {
				try writer.print("{{\"file\":\"{s}\",\"line\":{d},\"col\":{d}}}", .{
					path, line_1, ref.start_col,
				});
			}
		}
		try writer.writeAll("]\n");
	} else {
		try writer.print("References to '{s}' ({d} found):\n", .{ pattern, locations.len });
		for (locations) |ref| {
			const path = lsp.uriToPath(ref.uri) orelse ref.uri;
			const line_1 = ref.start_line + 1;
			const hash_str = getHashForLine(hash_cache, path, line_1);
			if (hash_str) |h| {
				try writer.print("  {s}:{d}:{s}:{d}\n", .{ path, line_1, h, ref.start_col });
			} else {
				try writer.print("  {s}:{d}:{d}\n", .{ path, line_1, ref.start_col });
			}
		}
	}
}

/// Look up the hash for a 1-indexed line in the hash cache.
fn getHashForLine(cache: std.StringHashMap([]const hashline.Hash), path: []const u8, line_1: u32) ?*const hashline.Hash {
	const hashes = cache.get(path) orelse return null;
	const idx = @as(usize, line_1) -| 1;
	if (idx >= hashes.len) return null;
	return &hashes[idx];
}

pub fn runRename(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	pattern: []const u8,
	new_name: []const u8,
	out_fmt: cli.OutputFormat,
	dry_run: bool,
	db_path: []const u8,
	root_path: []const u8,
	registry: plugin.Registry,
	lsp_overrides: []const config.LspOverride,
	embedding_dim: usize,
	writer: *std.Io.Writer,
) !void {
	const loc = try locateSymbol(allocator, file_path, pattern) orelse {
		try writer.print("error: '{s}' not found in '{s}'\n", .{ pattern, file_path });
		return;
	};
	const source = loc.source;
	var tree = loc.tree;
	const line = loc.line;
	const col = loc.col;
	defer allocator.free(source);
	defer if (tree) |*t| t.deinit(allocator);

	// Determine the language server binary
	const ext = std.fs.path.extension(file_path);
	const server_info = resolveServer(ext, lsp_overrides) orelse {
		try writer.print("error: no language server known for '{s}' files\n", .{ext});
		return;
	};

	// Resolve absolute path and root URI (use project root, not file parent)
	const abs_path = try std.fs.cwd().realpathAlloc(allocator, file_path);
	defer allocator.free(abs_path);

	const abs_root = std.fs.cwd().realpathAlloc(allocator, root_path) catch try allocator.dupe(u8, std.fs.path.dirname(abs_path) orelse "/");
	defer allocator.free(abs_root);

	const root_uri = try lsp.pathToUri(allocator, abs_root);
	defer allocator.free(root_uri);

	const file_uri = try lsp.pathToUri(allocator, abs_path);
	defer allocator.free(file_uri);

	// Start LSP, open file, request rename
	var client = lsp.LspClient.start(allocator, server_info, root_uri) catch {
		try printLspNotFound(writer, ext, server_info);
		return;
	};
	defer client.deinit();

	const lang_id = lsp.languageId(ext);
	client.didOpen(file_uri, lang_id, source) catch {
		try writer.print("error: failed to send didOpen to language server\n", .{});
		return;
	};

	const workspace_edit = client.rename(file_uri, line, col, new_name) catch {
		try writer.print("error: rename request failed\n", .{});
		return;
	};
	defer {
		for (workspace_edit.file_edits) |fe| {
			allocator.free(fe.uri);
			for (fe.edits) |edit| allocator.free(edit.new_text);
			allocator.free(fe.edits);
		}
		allocator.free(workspace_edit.file_edits);
	}

	if (workspace_edit.file_edits.len == 0) {
		try writer.print("No edits returned for rename of '{s}' to '{s}'\n", .{ pattern, new_name });
		return;
	}

	var total_edits: usize = 0;
	for (workspace_edit.file_edits) |fe| {
		total_edits += fe.edits.len;
	}

	// Build hash cache for affected files (pre-edit hashes for stale detection)
	var rename_hash_cache = std.StringHashMap([]const hashline.Hash).init(allocator);
	defer {
		var vit = rename_hash_cache.valueIterator();
		while (vit.next()) |hashes| allocator.free(hashes.*);
		rename_hash_cache.deinit();
	}
	for (workspace_edit.file_edits) |fe| {
		const path = lsp.uriToPath(fe.uri) orelse continue;
		if (rename_hash_cache.contains(path)) continue;
		const src = readFileContents(allocator, path) catch continue;
		defer allocator.free(src);
		const hashes = hashline.computeSourceHashes(allocator, src) catch continue;
		rename_hash_cache.put(path, hashes) catch continue;
	}

	if (out_fmt == .json) {
		const applied_str = if (dry_run) "false" else "true";
		try writer.print("{{\"applied\":{s},\"edits\":[", .{applied_str});
		var first = true;
		for (workspace_edit.file_edits) |fe| {
			const path = lsp.uriToPath(fe.uri) orelse fe.uri;
			for (fe.edits) |edit| {
				if (!first) try writer.writeAll(",");
				first = false;
				const start_hash = getHashForLine(rename_hash_cache, path, edit.start_line + 1);
				if (start_hash) |h| {
					try writer.print("{{\"file\":\"{s}\",\"start_line\":{d},\"start_hash\":\"{s}\",\"end_line\":{d},\"new_text\":", .{
						path, edit.start_line + 1, h, edit.end_line + 1,
					});
				} else {
					try writer.print("{{\"file\":\"{s}\",\"start_line\":{d},\"end_line\":{d},\"new_text\":", .{
						path, edit.start_line + 1, edit.end_line + 1,
					});
				}
				try writeJsonString(edit.new_text, writer);
				try writer.writeAll("}");
			}
		}
		try writer.writeAll("]}\n");
	} else {
		if (dry_run) {
			try writer.print("Rename '{s}' -> '{s}' ({d} edits across {d} files, dry run):\n", .{
				pattern, new_name, total_edits, workspace_edit.file_edits.len,
			});
		} else {
			try writer.print("Renamed '{s}' -> '{s}' ({d} edits across {d} files):\n", .{
				pattern, new_name, total_edits, workspace_edit.file_edits.len,
			});
		}
		for (workspace_edit.file_edits) |fe| {
			const path = lsp.uriToPath(fe.uri) orelse fe.uri;
			for (fe.edits) |edit| {
				const edit_hash = getHashForLine(rename_hash_cache, path, edit.start_line + 1);
				if (edit_hash) |h| {
					try writer.print("  {s}:{d}:{s}:{d} -> \"{s}\"\n", .{
						path, edit.start_line + 1, h, edit.start_col, edit.new_text,
					});
				} else {
					try writer.print("  {s}:{d}:{d} -> \"{s}\"\n", .{
						path, edit.start_line + 1, edit.start_col, edit.new_text,
					});
				}
			}
		}
	}

	// Apply edits unless dry run
	if (!dry_run) {
		for (workspace_edit.file_edits) |fe| {
			const path = lsp.uriToPath(fe.uri) orelse continue;
			applyTextEdits(allocator, path, fe.edits) catch |err| {
				try writer.print("warning: failed to apply edits to {s}: {}\n", .{ path, err });
				continue;
			};
			tryReindexFile(allocator, db_path, root_path, path, registry, embedding_dim);
		}
	}
}

/// Apply LSP text edits to a file. Edits are applied in reverse document order
/// (bottom-to-top) to avoid offset shifts.
fn applyTextEdits(allocator: std.mem.Allocator, file_path: []const u8, edits: []const lsp.TextEdit) !void {
	if (edits.len == 0) return;

	const source = try readFileContents(allocator, file_path);
	defer allocator.free(source);

	// Compute line start offsets
	const offsets = try lineByteOffsets(source, allocator);
	defer allocator.free(offsets);

	// Sort edits by position, reversed (bottom-to-top)
	const sorted = try allocator.alloc(lsp.TextEdit, edits.len);
	defer allocator.free(sorted);
	@memcpy(sorted, edits);
	std.sort.heap(lsp.TextEdit, sorted, {}, struct {
		fn lessThan(_: void, a: lsp.TextEdit, b: lsp.TextEdit) bool {
			// Reverse order: higher positions first
			if (a.start_line != b.start_line) return a.start_line > b.start_line;
			return a.start_col > b.start_col;
		}
	}.lessThan);

	// Apply edits bottom-to-top on an in-memory copy
	var buf = std.ArrayListUnmanaged(u8){};
	defer buf.deinit(allocator);
	try buf.appendSlice(allocator, source);

	for (sorted) |edit| {
		const start_byte = lineColToByte(offsets, source.len, edit.start_line, edit.start_col);
		const end_byte = lineColToByte(offsets, source.len, edit.end_line, edit.end_col);
		if (start_byte > buf.items.len or end_byte > buf.items.len or start_byte > end_byte) continue;

		// Replace the range
		buf.replaceRange(allocator, start_byte, end_byte - start_byte, edit.new_text) catch continue;
	}

	const file = try std.fs.cwd().createFile(file_path, .{});
	defer file.close();
	try file.writeAll(buf.items);
}

/// Convert 0-based line:col to byte offset using precomputed line start offsets.
fn lineColToByte(offsets: []const usize, source_len: usize, line_0: u32, col_0: u32) usize {
	const line = @as(usize, line_0);
	if (line >= offsets.len) return source_len;
	const byte = offsets[line] + @as(usize, col_0);
	return @min(byte, source_len);
}

fn matchesNamePath(pattern: []const u8, name_path: []const u8, name: []const u8) bool {
	if (pattern.len == 0) return false;
	// Absolute path: starts with "/"
	if (pattern[0] == '/') {
		return std.mem.eql(u8, pattern[1..], name_path);
	}
	// Relative path: contains "/"
	if (std.mem.indexOf(u8, pattern, "/") != null) {
		return std.mem.endsWith(u8, name_path, pattern);
	}
	// Simple name: matches the symbol's own name
	return std.mem.eql(u8, pattern, name);
}

fn formatSymbolsWithHashes(symbols: []const symbol_tree.SymbolNode, all_hashes: []const hashline.Hash, writer: *std.Io.Writer, depth: usize) !void {
	for (symbols) |*sym| {
		for (0..depth) |_| try writer.writeAll("  ");

		const start_idx = if (sym.start_line > 0) sym.start_line - 1 else 0;
		const end_idx = if (sym.end_line > 0) sym.end_line - 1 else 0;

		if (sym.start_line == sym.end_line) {
			if (start_idx < all_hashes.len) {
				try writer.print("{s} {s} ({d}:{s})\n", .{
					sym.kind.label(), sym.name, sym.start_line, &all_hashes[start_idx],
				});
			} else {
				try writer.print("{s} {s} ({d})\n", .{
					sym.kind.label(), sym.name, sym.start_line,
				});
			}
		} else {
			if (start_idx < all_hashes.len and end_idx < all_hashes.len) {
				try writer.print("{s} {s} ({d}:{s}-{d}:{s})\n", .{
					sym.kind.label(), sym.name, sym.start_line, &all_hashes[start_idx], sym.end_line, &all_hashes[end_idx],
				});
			} else {
				try writer.print("{s} {s} ({d}-{d})\n", .{
					sym.kind.label(), sym.name, sym.start_line, sym.end_line,
				});
			}
		}

		if (sym.children.len > 0) {
			try formatSymbolsWithHashes(sym.children, all_hashes, writer, depth + 1);
		}
	}
}

fn writeSymbolsJson(symbols: []const symbol_tree.SymbolNode, all_hashes: []const hashline.Hash, writer: *std.Io.Writer) !void {
	try writer.writeAll("[");
	for (symbols, 0..) |*sym, i| {
		if (i > 0) try writer.writeAll(",");
		try writeSymbolJson(sym, all_hashes, writer);
	}
	try writer.writeAll("]\n");
}

fn writeSymbolJson(sym: *const symbol_tree.SymbolNode, all_hashes: []const hashline.Hash, writer: *std.Io.Writer) !void {
	try writer.writeAll("{\"name\":");
	try writeJsonString(sym.name, writer);
	try writer.print(",\"kind\":\"{s}\",\"start_line\":{d},\"end_line\":{d}", .{
		sym.kind.label(), sym.start_line, sym.end_line,
	});
	const start_idx = if (sym.start_line > 0) sym.start_line - 1 else 0;
	const end_idx = if (sym.end_line > 0) sym.end_line - 1 else 0;
	if (start_idx < all_hashes.len) {
		try writer.print(",\"start_hash\":\"{s}\"", .{&all_hashes[start_idx]});
	}
	if (end_idx < all_hashes.len) {
		try writer.print(",\"end_hash\":\"{s}\"", .{&all_hashes[end_idx]});
	}
	if (sym.children.len > 0) {
		try writer.writeAll(",\"children\":[");
		for (sym.children, 0..) |*child, i| {
			if (i > 0) try writer.writeAll(",");
			try writeSymbolJson(child, all_hashes, writer);
		}
		try writer.writeAll("]");
	}
	try writer.writeAll("}");
}

fn writeJsonString(s: []const u8, writer: *std.Io.Writer) !void {
	try writer.writeAll("\"");
	for (s) |ch| {
		switch (ch) {
			'"' => try writer.writeAll("\\\""),
			'\\' => try writer.writeAll("\\\\"),
			'\n' => try writer.writeAll("\\n"),
			'\r' => try writer.writeAll("\\r"),
			'\t' => try writer.writeAll("\\t"),
			0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
				try writer.print("\\u{x:0>4}", .{@as(u16, ch)});
			},
			else => try writer.writeAll(&[_]u8{ch}),
		}
	}
	try writer.writeAll("\"");
}

const usage =
    \\codescan [command] [options]
    \\
    \\Commands:
    \\  search <query>            Semantic + lexical code search (default command)
    \\  symbols [pattern]         List or find symbols (functions, structs, etc.)
    \\  replace-symbol <pattern>  Replace a symbol's body (stdin)
    \\  insert-after <pattern>    Insert code after a symbol (stdin)
    \\  insert-before <pattern>   Insert code before a symbol (stdin)
    \\  replace-lines             Replace a hashline-validated line range (stdin)
    \\  insert-at <line:hash>     Insert code after a hashline (stdin)
    \\  replace-content <needle>  Find & replace text or regex (stdin)
    \\  read-file <path>          Read file with hashlines and version hash
    \\  create-file --file <path> Create a new file (stdin)
    \\  destroy-file --file <path> Move file to system trash
    \\  diff                      Show git changes with hashlines
    \\  references <pattern>      Find all references via LSP
    \\  rename <pattern>          Rename symbol across codebase via LSP
    \\  index                     Full re-index (drops & recreates DB)
    \\  update                    Incremental index (new/modified/deleted only)
    \\  watch [start|stop|status] Watch for changes and re-index continuously
    \\  config [show|edit]        Show or edit project config
    \\  serve                     Start HTTP API server
    \\  mcp-serve                 Start MCP server
    \\  status                    Show index & watcher status
    \\  clean                     Remove all codescan data
    \\
    \\Use 'codescan help <command>' for details on any command.
    \\Topics: hashlines, name-paths, languages, lsp
    \\Common: --root <path>  --json  --top <n>  --file <path>  -h/--help
    \\
;

const usage_search =
    \\Usage: codescan search <query> [options]
    \\
    \\Aliases:
    \\  query                           Alias for search
    \\  codescan <query>                If command is omitted, search is assumed
    \\
    \\Common search options:
    \\  --top <n>                       Number of hits (default 5)
    \\  --mode <vector|lexical|hybrid>  Search mode (default hybrid)
    \\  --min-score <n>                 Minimum score threshold
    \\  --scope <code|docs|comments|all>
    \\                                  Unified result scope selector
    \\  --docs, --only-docs             Only markdown/README results
    \\  --comments, --only-comments     Only doc-comment results
    \\  --include-docs                  Include markdown/README with code
    \\  --ext <csv>                     Restrict to extensions
    \\  --type <csv>                    Restrict to types: code,doc,text,log
    \\  --lang <csv>                    Restrict to language(s)
    \\  --kind <csv>                    Restrict to symbol kind(s)
    \\                                  Values: fn (function, func), struct, enum,
    \\                                  union, class, interface, trait, impl,
    \\                                  const (constant, val), var (variable, mut),
    \\                                  field, test, mod (module), type, macro
    \\                                  Meta-kinds: declaration (const+var),
    \\                                  definition (any defined symbol), let (const+var)
    \\  --path <glob>                   Filter by file path (glob, repeatable)
    \\  --file <path>                   Filter to exact file path
    \\  --regex                         Treat query as PCRE2 regex pattern
    \\  --ignore-case, -i               Case-insensitive matching (regex search)
    \\  --context <n>, -C <n>           Total lines of context around matches
    \\                                  (includes match line, e.g. -C 5 = 2 before + 1 match + 2 after)
    \\  --include-body                  Include function body text in output
    \\                                  (limits to 3 results by default)
    \\  --json                          JSON output
    \\
    \\Browse mode (no query required when filters are present):
    \\  codescan search --kind fn       List all functions
    \\  codescan search --kind struct   List all structs
    \\
    \\Examples:
    \\  codescan search "checksum"
    \\  codescan "h264 parser"
    \\  codescan search "design doc" --scope docs
    \\  codescan search "hash functions" --scope comments
    \\  codescan search "widget" --include-body
    \\  codescan search "config" --kind const,var
    \\  codescan search "init" --path "src/storage*"
    \\  codescan search "init" --file src/storage.zig
    \\  codescan search --kind definition --top 20
    \\  codescan search "pub fn \w+Init" --regex --context 5
    \\  codescan search "TODO|FIXME|HACK" --regex --top 20
    \\  codescan search "computeHash" --regex --include-body
    \\  codescan search "init" --kind fn --include-body
    \\
;

const usage_index =
    \\Usage: codescan index [options]
    \\
    \\Rebuilds the index from scratch (deletes and recreates the DB).
    \\
    \\Common index options:
    \\  --root <path>                   Project root
    \\  --db <path>                     Database path (default .codescan/index.sqlite3)
    \\  --max-file-size <n>             Max file size bytes
    \\  --type <csv>                    Index types (default code,doc)
    \\  --ext <csv>                     Restrict indexed extensions
    \\  --include-node-modules          Include node_modules
    \\  --json                          JSON output
    \\
    \\Examples:
    \\  codescan index
    \\  codescan index --root /path/to/repo
    \\
;

const usage_update =
    \\Usage: codescan update [options]
    \\
    \\Runs incremental index updates (new/modified/deleted files only).
    \\
    \\Common update options:
    \\  --root <path>                   Project root
    \\  --db <path>                     Database path
    \\  --max-file-size <n>             Max file size bytes
    \\  --type <csv>                    Indexed types (default code,doc)
    \\  --ext <csv>                     Restrict indexed extensions
    \\  --include-node-modules          Include node_modules
    \\  --json                          JSON output
    \\
    \\Examples:
    \\  codescan update
    \\  codescan update --root /path/to/repo
    \\
;

const usage_config =
    \\Usage: codescan config [show|edit]
    \\
    \\Subcommands:
    \\  show                            Print current project config
    \\  edit                            Open config in $VISUAL or $EDITOR
    \\
    \\Examples:
    \\  codescan config
    \\  codescan config edit
    \\
;

const usage_symbols =
    \\Usage: codescan symbols [pattern] [options]
    \\
    \\List or find symbols (functions, structs, types, etc.).
    \\Alias: find-symbol
    \\
    \\Options:
    \\  --file <path>            Restrict to file (repeatable)
    \\  --include-body           Include source body with hashlines
    \\  --json                   JSON output
    \\
    \\Name path patterns:
    \\  init                     Match any symbol named 'init'
    \\  MyStruct/init            Match suffix of name path
    \\  /MyStruct/init           Match exact full name path
    \\  See 'codescan help name-paths' for details.
    \\
    \\Examples:
    \\  codescan symbols --file src/main.zig
    \\  codescan symbols "parse" --file src/cli.zig --include-body
    \\  codescan symbols "Config/init"
    \\
;

const usage_replace_symbol =
    \\Usage: codescan replace-symbol <pattern> [options] < new_body.txt
    \\
    \\Replace a symbol's entire body with content from stdin.
    \\The pattern uses name path matching (see 'codescan help name-paths').
    \\
    \\Options:
    \\  --file <path>            Target file (required)
    \\
    \\Examples:
    \\  echo 'fn init() void {}' | codescan replace-symbol "init" --file src/main.zig
    \\  codescan replace-symbol "Config/validate" --file src/config.zig < new_body.zig
    \\
;

const usage_insert_after =
    \\Usage: codescan insert-after <pattern> [options] < code.txt
    \\
    \\Insert code from stdin after a matched symbol.
    \\The pattern uses name path matching (see 'codescan help name-paths').
    \\
    \\Options:
    \\  --file <path>            Target file (required)
    \\
    \\Examples:
    \\  echo 'fn newFn() void {}' | codescan insert-after "init" --file src/main.zig
    \\
;

const usage_insert_before =
    \\Usage: codescan insert-before <pattern> [options] < code.txt
    \\
    \\Insert code from stdin before a matched symbol.
    \\The pattern uses name path matching (see 'codescan help name-paths').
    \\
    \\Options:
    \\  --file <path>            Target file (required)
    \\
    \\Examples:
    \\  echo '// section header' | codescan insert-before "init" --file src/main.zig
    \\
;

const usage_replace_lines =
    \\Usage: codescan replace-lines --file <path> --from <line:hash> --to <line:hash> < new.txt
    \\
    \\Replace a range of lines with content from stdin.
    \\Lines are validated by hashlines to prevent stale edits.
    \\See 'codescan help hashlines' for hash format details.
    \\
    \\Options:
    \\  --file <path>            Target file (required)
    \\  --from <line:hash>       Start of range, inclusive (e.g. 10:r2p)
    \\  --to <line:hash>         End of range, inclusive (e.g. 25:f4x)
    \\
    \\Examples:
    \\  echo 'replacement' | codescan replace-lines --file src/main.zig --from 10:r2p --to 15:f4x
    \\
;

const usage_insert_at =
    \\Usage: codescan insert-at <line:hash> --file <path> < code.txt
    \\
    \\Insert code from stdin after the specified hashline.
    \\See 'codescan help hashlines' for hash format details.
    \\
    \\Options:
    \\  --file <path>            Target file (required)
    \\
    \\Examples:
    \\  echo 'new line' | codescan insert-at 42:r2p --file src/main.zig
    \\
;

const usage_replace_content =
    \\Usage: codescan replace-content <needle> --file <path> [options] < replacement.txt
    \\
    \\Find and replace text in a file. Replacement comes from stdin.
    \\Requires unique match (errors on multiple matches unless --all).
    \\
    \\Options:
    \\  --file <path>            Target file (required)
    \\  --regex                  Treat needle as PCRE2 regex
    \\  --all                    Replace all occurrences (default: unique match only)
    \\  --version <hash>         Version hash from read-file (prevents race conditions)
    \\
    \\Examples:
    \\  echo 'new_name' | codescan replace-content 'old_name' --file src/main.zig --all
    \\  echo 'v2' | codescan replace-content 'v[0-9]+' --file config.toml --regex
    \\  echo 'new' | codescan replace-content 'old' --file src/foo.zig --version k7m
    \\
;

const usage_read_file =
    \\Usage: codescan read-file <path> [options]
    \\
    \\Read a file with hashline annotations and a version hash.
    \\The version hash is a 3-char content checksum of the entire file —
    \\pass it to write commands via --version to prevent race conditions.
    \\
    \\Options:
    \\  --from <line>            Start line (1-indexed)
    \\  --to <line>              End line (inclusive)
    \\  --json                   JSON output
    \\
    \\Examples:
    \\  codescan read-file src/main.zig
    \\  codescan read-file src/main.zig --from 10 --to 50
    \\  codescan read-file src/main.zig --json
    \\
;

const usage_create_file =
    \\Usage: codescan create-file --file <path> < content.txt
    \\
    \\Create a new file. Errors if the file already exists.
    \\Content comes from stdin. Creates parent directories as needed.
    \\Returns the new file's version hash.
    \\
    \\Options:
    \\  --file <path>            File path to create (required)
    \\
    \\Examples:
    \\  echo 'const std = @import("std");' | codescan create-file --file src/new.zig
    \\
;

const usage_destroy_file =
    \\Usage: codescan destroy-file --file <path> [options]
    \\
    \\Move a file to the system trash (safer than rm, supports undo).
    \\macOS: moves to ~/.Trash/. Linux: uses gio trash or freedesktop spec.
    \\
    \\Options:
    \\  --file <path>            File to trash (required)
    \\  --version <hash>         Version hash from read-file (prevents race conditions)
    \\
    \\Examples:
    \\  codescan destroy-file --file src/old.zig
    \\  codescan destroy-file --file src/old.zig --version k7m
    \\
;

const usage_diff =
    \\Usage: codescan diff [options]
    \\
    \\Show uncommitted git changes with hashline annotations.
    \\Each line includes its hashline from the current file version,
    \\enabling safe edits directly from diff output.
    \\
    \\Options:
    \\  --staged, --cached       Show staged changes only
    \\  --json                   JSON output
    \\
    \\Examples:
    \\  codescan diff
    \\  codescan diff --staged
    \\  codescan diff --json
    \\
;

const usage_references =
    \\Usage: codescan references <pattern> --file <path>
    \\
    \\Find all references to a symbol via LSP.
    \\Requires the appropriate language server on PATH.
    \\See 'codescan help lsp' for server requirements.
    \\
    \\Options:
    \\  --file <path>            File containing the symbol (required)
    \\  --json                   JSON output
    \\
    \\Examples:
    \\  codescan references "parseArgs" --file src/cli.zig
    \\  codescan references "Config" --file src/config.zig --json
    \\
;

const usage_rename =
    \\Usage: codescan rename <pattern> --file <path> --to <new_name> [options]
    \\
    \\Rename a symbol across the codebase via LSP.
    \\Requires the appropriate language server on PATH.
    \\See 'codescan help lsp' for server requirements.
    \\
    \\Options:
    \\  --file <path>            File containing the symbol (required)
    \\  --to <new_name>          New name for the symbol (required)
    \\  --dry-run, -n            Preview changes without applying
    \\  --json                   JSON output
    \\
    \\Examples:
    \\  codescan rename "oldFunc" --file src/main.zig --to "newFunc"
    \\  codescan rename "Config" --file src/lib.zig --to "Settings" --dry-run
    \\
;

const usage_watch =
    \\Usage: codescan watch [subcommand] [options]
    \\
    \\Watch for file changes and re-index continuously.
    \\
    \\Subcommands:
    \\  (none)                   Run watcher in foreground
    \\  start                    Start watcher as background daemon
    \\  stop                     Stop background watcher
    \\  restart                  Restart background watcher
    \\  status                   Show watcher status
    \\  pid                      Print watcher PID
    \\
    \\Options:
    \\  --interval <ms>          Poll interval in milliseconds (default 2000)
    \\
    \\Examples:
    \\  codescan watch
    \\  codescan watch start --interval 5000
    \\  codescan watch stop
    \\
;

const usage_serve =
    \\Usage: codescan serve [options]
    \\
    \\Start the HTTP API server for programmatic access.
    \\
    \\Options:
    \\  --http-host <host>       Bind address (default 127.0.0.1)
    \\  --http-port <port>       Port number (default 8123)
    \\
    \\Examples:
    \\  codescan serve
    \\  codescan serve --http-port 9000
    \\
;

const usage_mcp_serve =
    \\Usage: codescan mcp-serve
    \\
    \\Start an MCP (Model Context Protocol) server on stdin/stdout.
    \\Used by AI editors and tools that support MCP.
    \\
;

const usage_status =
    \\Usage: codescan status
    \\
    \\Show index and watcher status: file count, index age,
    \\watcher state (running/stopped), and database location.
    \\
;

const usage_clean =
    \\Usage: codescan clean [options]
    \\
    \\Stop the watcher and remove all codescan data (.codescan/).
    \\Alias: clear
    \\
    \\Options:
    \\  --confirm, -y            Skip interactive confirmation prompt
    \\
    \\Examples:
    \\  codescan clean
    \\  codescan clean -y
    \\
;

const usage_init =
    \\Usage: codescan init [options]
    \\
    \\Initialize codescan for this project (creates .codescan/).
    \\
    \\Options:
    \\  --force, -f              Re-initialize even if already initialized
    \\
    \\Examples:
    \\  codescan init
    \\  codescan init --force
    \\
;

const usage_hashlines =
    \\Hashlines
    \\
    \\Every line reference includes a 3-char chain hash (e.g. 45:r2p).
    \\Each hash depends on the line's content AND the previous line's hash,
    \\so any edit above cascades through all subsequent hashes. This means
    \\a stale reference (from a prior read) will fail with a mismatch error
    \\rather than silently editing the wrong line. Re-read the file to get
    \\current hashes before retrying.
    \\
    \\Format:     <line>:<hash>  (e.g. 45:r2p)
    \\Alphabet:   0-9 a-z A-Z (base-62, 238328 values)
    \\Used by:    replace-lines --from/--to, insert-at, symbols --include-body
    \\
    \\Commands using hashlines:
    \\  replace-lines            --from and --to specify the line range
    \\  insert-at                positional arg specifies insertion point
    \\  symbols --include-body   output includes hashlines for each line
    \\
;

const usage_name_paths =
    \\Name Path Patterns
    \\
    \\Symbol commands (symbols, replace-symbol, insert-after, insert-before)
    \\accept a name path pattern to match symbols.
    \\
    \\Matching rules:
    \\  init                     Match any symbol named 'init'
    \\  MyStruct/init            Match suffix of name path (partial path)
    \\  /MyStruct/init           Match exact full name path (leading /)
    \\
    \\The name path is the hierarchical identifier of a symbol, using /
    \\as the separator. For example, a method 'init' inside struct 'Config'
    \\has the name path 'Config/init'.
    \\
    \\Use 'codescan symbols --file <path>' to see available name paths.
    \\
;

const usage_languages =
    \\Supported Languages
    \\
    \\Symbol extraction and LSP:
    \\  Zig, C/C++, TypeScript/JavaScript, Rust, Elixir, Bash, Lua,
    \\  Nix, Nim, Lean, Idris, Haskell, Go, Ruby, Erlang, OCaml,
    \\  Swift, LLVM IR, Clojure, Assembly
    \\
    \\Indexing and search:
    \\  Any text file (Markdown, logs, plain text, etc.)
    \\
    \\Auto-detection:
    \\  Extensionless scripts with shebangs (#!/usr/bin/env bash, etc.)
    \\  are auto-detected for bash, lua, node/deno/bun, and ruby.
    \\
    \\Language filter values (--lang):
    \\  zig, c, typescript, rust, elixir, bash, lua, nix, nim, lean,
    \\  idris, haskell, go, ruby, erlang, ocaml, swift, llvm, clojure,
    \\  assembly, markdown, text, log
    \\
;

const usage_lsp =
    \\LSP Integration
    \\
    \\The 'references' and 'rename' commands use Language Server Protocol.
    \\Codescan lazy-starts a language server for the file's language.
    \\
    \\Required servers (must be on PATH):
    \\  Zig          zls
    \\  C/C++        clangd
    \\  TypeScript   typescript-language-server
    \\  Rust         rust-analyzer
    \\  Go           gopls
    \\  Elixir       elixir-ls
    \\  Haskell      haskell-language-server
    \\  OCaml        ocamllsp
    \\  Lua          lua-language-server
    \\  Nix          nil
    \\
    \\If the server is not found, the command will error with instructions.
    \\
;

fn isUsageError(err: anyerror) bool {
	return err == error.MissingQuery or
		err == error.UnknownCommand or
		err == error.MissingValue or
        err == error.InvalidValue or
		err == error.InvalidMode or
		err == error.UnexpectedArg or
		err == error.TooManyArgs or
		err == error.InvalidNumber;
}

fn usageErrorMessage(err: anyerror) []const u8 {
	if (err == error.MissingQuery) return "missing search query";
	if (err == error.UnknownCommand) return "unknown command";
	if (err == error.MissingValue) return "missing required value";
    if (err == error.InvalidValue) return "invalid value";
	if (err == error.InvalidMode) return "invalid mode";
	if (err == error.UnexpectedArg) return "unexpected argument";
	if (err == error.TooManyArgs) return "too many arguments";
	if (err == error.InvalidNumber) return "invalid number";
	return "invalid usage";
}

const JsonEnvelopeArgs = struct {
    args: []const []const u8,
    owned: [][]u8,

    fn deinit(self: *JsonEnvelopeArgs, allocator: std.mem.Allocator) void {
        for (self.owned) |value| allocator.free(value);
        allocator.free(self.owned);
        allocator.free(self.args);
    }
};

fn shouldAttemptJsonEnvelope(args: []const []const u8, stdin_is_tty: bool) bool {
    if (stdin_is_tty) return false;
    if (args.len == 1) return true;
    if (args.len == 2 and std.mem.eql(u8, args[1], "--json")) return true;
    return false;
}

fn parseJsonEnvelopeArgs(
    allocator: std.mem.Allocator,
    payload: []const u8,
    argv0: []const u8,
) !JsonEnvelopeArgs {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |map| map,
        else => return error.InvalidJsonEnvelope,
    };
    const action = getJsonString(obj, "action") orelse return error.InvalidJsonEnvelope;

    var args_list = std.ArrayList([]const u8){};
    errdefer args_list.deinit(allocator);
    var owned_list = std.ArrayList([]u8){};
    errdefer {
        for (owned_list.items) |item| allocator.free(item);
        owned_list.deinit(allocator);
    }

    try args_list.append(allocator, argv0);
    if (std.mem.eql(u8, action, "search")) {
        try args_list.append(allocator, "search");
        const query = getJsonQuery(allocator, obj) catch return error.InvalidJsonEnvelope;
        defer if (query.owned) allocator.free(query.value);
        try appendOwnedArg(allocator, &args_list, &owned_list, query.value);
        try appendJsonStringFlag(allocator, obj, "root", "--root", &args_list, &owned_list);
        try appendJsonStringFlag(allocator, obj, "db", "--db", &args_list, &owned_list);
        try appendJsonIntegerFlag(allocator, obj, "top", "--top", &args_list, &owned_list);
        try appendJsonStringFlag(allocator, obj, "scope", "--scope", &args_list, &owned_list);
        try appendJsonStringFlag(allocator, obj, "mode", "--mode", &args_list, &owned_list);
        try appendJsonFloatFlag(allocator, obj, "min_score", "--min-score", &args_list, &owned_list);
        try appendJsonStringOrArrayFlag(allocator, obj, "ext", "--ext", &args_list, &owned_list);
        try appendJsonStringOrArrayFlag(allocator, obj, "type", "--type", &args_list, &owned_list);
        try appendJsonStringOrArrayFlag(allocator, obj, "lang", "--lang", &args_list, &owned_list);
        try appendJsonStringOrArrayFlag(allocator, obj, "kind", "--kind", &args_list, &owned_list);
        try appendJsonBoolFlag(allocator, obj, "include_docs", "--include-docs", &args_list);
        try appendJsonBoolFlag(allocator, obj, "docs_only", "--docs", &args_list);
        try appendJsonBoolFlag(allocator, obj, "comments_only", "--comments", &args_list);
    } else if (std.mem.eql(u8, action, "index")) {
        try args_list.append(allocator, "index");
        try appendJsonStringFlag(allocator, obj, "root", "--root", &args_list, &owned_list);
        try appendJsonStringFlag(allocator, obj, "db", "--db", &args_list, &owned_list);
        try appendJsonStringOrArrayFlag(allocator, obj, "ext", "--ext", &args_list, &owned_list);
        try appendJsonStringOrArrayFlag(allocator, obj, "type", "--type", &args_list, &owned_list);
    } else if (std.mem.eql(u8, action, "update") or std.mem.eql(u8, action, "reindex")) {
        try args_list.append(allocator, "update");
        try appendJsonStringFlag(allocator, obj, "root", "--root", &args_list, &owned_list);
        try appendJsonStringFlag(allocator, obj, "db", "--db", &args_list, &owned_list);
        try appendJsonStringOrArrayFlag(allocator, obj, "ext", "--ext", &args_list, &owned_list);
        try appendJsonStringOrArrayFlag(allocator, obj, "type", "--type", &args_list, &owned_list);
    } else if (std.mem.eql(u8, action, "status")) {
        try args_list.append(allocator, "status");
        try appendJsonStringFlag(allocator, obj, "root", "--root", &args_list, &owned_list);
        try appendJsonStringFlag(allocator, obj, "db", "--db", &args_list, &owned_list);
    } else {
        return error.InvalidJsonEnvelope;
    }

    try args_list.append(allocator, "--json");
    return .{
        .args = try args_list.toOwnedSlice(allocator),
        .owned = try owned_list.toOwnedSlice(allocator),
    };
}

const JsonQueryValue = struct {
    value: []const u8,
    owned: bool,
};

fn getJsonQuery(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !JsonQueryValue {
    const value = obj.get("query") orelse return error.InvalidJsonEnvelope;
    switch (value) {
        .string => |text| return .{ .value = text, .owned = false },
        .array => |arr| {
            var parts = std.ArrayList([]const u8){};
            defer parts.deinit(allocator);
            for (arr.items) |item| {
                switch (item) {
                    .string => |part| try parts.append(allocator, part),
                    else => return error.InvalidJsonEnvelope,
                }
            }
            if (parts.items.len == 0) return error.InvalidJsonEnvelope;
            return .{
                .value = try joinSpaceArgs(allocator, parts.items),
                .owned = true,
            };
        },
        else => return error.InvalidJsonEnvelope,
    }
}

fn appendOwnedArg(
    allocator: std.mem.Allocator,
    args: *std.ArrayList([]const u8),
    owned: *std.ArrayList([]u8),
    value: []const u8,
) !void {
    const duped = try allocator.dupe(u8, value);
    try owned.append(allocator, duped);
    try args.append(allocator, duped);
}

fn getJsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn appendJsonStringFlag(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
    flag: []const u8,
    args: *std.ArrayList([]const u8),
    owned: *std.ArrayList([]u8),
) !void {
    const value = getJsonString(obj, key) orelse return;
    try args.append(allocator, flag);
    try appendOwnedArg(allocator, args, owned, value);
}

fn appendJsonStringOrArrayFlag(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
    flag: []const u8,
    args: *std.ArrayList([]const u8),
    owned: *std.ArrayList([]u8),
) !void {
    const value = obj.get(key) orelse return;
    switch (value) {
        .string => |s| {
            try args.append(allocator, flag);
            try appendOwnedArg(allocator, args, owned, s);
        },
        .array => |arr| {
            if (arr.items.len == 0) return;
            var list = std.ArrayList([]const u8){};
            defer list.deinit(allocator);
            for (arr.items) |item| {
                switch (item) {
                    .string => |s| try list.append(allocator, s),
                    else => return error.InvalidJsonEnvelope,
                }
            }
            const joined = try joinCsvArgs(allocator, list.items);
            errdefer allocator.free(joined);
            try args.append(allocator, flag);
            try owned.append(allocator, joined);
            try args.append(allocator, joined);
        },
        else => return error.InvalidJsonEnvelope,
    }
}

fn joinCsvArgs(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    var total: usize = 0;
    for (parts, 0..) |part, idx| {
        total += part.len;
        if (idx + 1 < parts.len) total += 1;
    }
    const buf = try allocator.alloc(u8, total);
    var offset: usize = 0;
    for (parts, 0..) |part, idx| {
        std.mem.copyForwards(u8, buf[offset .. offset + part.len], part);
        offset += part.len;
        if (idx + 1 < parts.len) {
            buf[offset] = ',';
            offset += 1;
        }
    }
    return buf;
}

fn joinSpaceArgs(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    var total: usize = 0;
    for (parts, 0..) |part, idx| {
        total += part.len;
        if (idx + 1 < parts.len) total += 1;
    }
    const buf = try allocator.alloc(u8, total);
    var offset: usize = 0;
    for (parts, 0..) |part, idx| {
        std.mem.copyForwards(u8, buf[offset .. offset + part.len], part);
        offset += part.len;
        if (idx + 1 < parts.len) {
            buf[offset] = ' ';
            offset += 1;
        }
    }
    return buf;
}

fn appendJsonIntegerFlag(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
    flag: []const u8,
    args: *std.ArrayList([]const u8),
    owned: *std.ArrayList([]u8),
) !void {
    const value = obj.get(key) orelse return;
    const int_value = switch (value) {
        .integer => |n| n,
        else => return error.InvalidJsonEnvelope,
    };
    const text = try std.fmt.allocPrint(allocator, "{d}", .{int_value});
    errdefer allocator.free(text);
    try args.append(allocator, flag);
    try owned.append(allocator, text);
    try args.append(allocator, text);
}

fn appendJsonFloatFlag(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
    flag: []const u8,
    args: *std.ArrayList([]const u8),
    owned: *std.ArrayList([]u8),
) !void {
    const value = obj.get(key) orelse return;
    const float_value = switch (value) {
        .float => |n| n,
        .integer => |n| @as(f64, @floatFromInt(n)),
        else => return error.InvalidJsonEnvelope,
    };
    const text = try std.fmt.allocPrint(allocator, "{d}", .{float_value});
    errdefer allocator.free(text);
    try args.append(allocator, flag);
    try owned.append(allocator, text);
    try args.append(allocator, text);
}

fn appendJsonBoolFlag(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
    flag: []const u8,
    args: *std.ArrayList([]const u8),
) !void {
    const value = obj.get(key) orelse return;
    const enabled = switch (value) {
        .bool => |b| b,
        else => return error.InvalidJsonEnvelope,
    };
    if (enabled) try args.append(allocator, flag);
}

pub fn runStatus(
	allocator: std.mem.Allocator,
	db_path: []const u8,
	root_path: []const u8,
	format: cli.OutputFormat,
	writer: *std.Io.Writer,
) !void {
	const db = storage.openFileWithVec(allocator, db_path) catch {
		if (format == .json) {
			try writer.writeAll("{\"error\":\"no index found\"}\n");
		} else {
			try writer.writeAll("No codescan index found. Run `codescan init` first.\n");
		}
		return;
	};
	defer storage.close(db);

	// Gather stats
	const file_count = storage.countDistinctFiles(db, allocator) catch 0;
	const symbol_count = storage.countRows(db, allocator, "symbols") catch 0;
	const embedding_count = storage.countRows(db, allocator, "embeddings") catch 0;
	const comment_embedding_count = storage.countRows(db, allocator, "embeddings_comment") catch 0;

	var lang_stats_buf: []storage.LangStat = &.{};
	var lang_stats_owned = false;
	if (storage.languageStats(db, allocator)) |stats| {
		lang_stats_buf = stats;
		lang_stats_owned = true;
	} else |_| {}
	defer if (lang_stats_owned) {
		for (lang_stats_buf) |s| allocator.free(s.language);
		allocator.free(lang_stats_buf);
	};
	const lang_stats = lang_stats_buf;

	const last_indexed = storage.lastIndexedFile(db, allocator) catch null;
	defer if (last_indexed) |li| allocator.free(li.file_path);

	// Watcher status
	const codescan_dir = std.fs.path.dirname(db_path) orelse ".codescan";
	const watcher_pid = pidfile.readAndCheckPid(allocator, codescan_dir) catch null;

	// DB file size
	const db_size: u64 = blk: {
		const stat = std.fs.cwd().statFile(db_path) catch break :blk 0;
		break :blk stat.size;
	};

	// Read watcher progress
	const watcher_progress = progress_mod.read(allocator, codescan_dir);
	defer if (watcher_progress) |wp| allocator.free(wp);

	if (format == .json) {
		try writeStatusJson(writer, root_path, db_path, db_size, watcher_pid, file_count, symbol_count, embedding_count, comment_embedding_count, lang_stats, last_indexed);
	} else {
		try writeStatusHuman(writer, root_path, db_path, db_size, watcher_pid, watcher_progress, file_count, symbol_count, embedding_count, comment_embedding_count, lang_stats, last_indexed);
	}
}

fn writeStatusJson(
	writer: *std.Io.Writer,
	root_path: []const u8,
	db_path: []const u8,
	db_size: u64,
	watcher_pid: ?pidfile.PidType,
	file_count: i64,
	symbol_count: i64,
	embedding_count: i64,
	comment_embedding_count: i64,
	lang_stats: []const storage.LangStat,
	last_indexed: ?storage.LastIndexedResult,
) !void {
	try writer.writeAll("{");

	// Root
	try writer.writeAll("\"root\":");
	try writeJsonString(root_path, writer);
	try writer.writeAll(",");

	// DB
	try writer.writeAll("\"db_path\":");
	try writeJsonString(db_path, writer);
	try writer.print(",\"db_size_bytes\":{d},", .{db_size});

	// Watcher
	if (watcher_pid) |pid| {
		try writer.print("\"watcher\":{{\"running\":true,\"pid\":{d}}},", .{pid});
	} else {
		try writer.writeAll("\"watcher\":{\"running\":false},");
	}

	// Index stats
	try writer.print("\"index\":{{\"files\":{d},\"symbols\":{d},\"embeddings\":{d},\"comment_embeddings\":{d}}},", .{
		file_count, symbol_count, embedding_count, comment_embedding_count,
	});

	// Languages
	try writer.writeAll("\"languages\":[");
	for (lang_stats, 0..) |ls, idx| {
		if (idx > 0) try writer.writeAll(",");
		try writer.writeAll("{\"language\":");
		try writeJsonString(ls.language, writer);
		try writer.print(",\"files\":{d},\"symbols\":{d}}}", .{ ls.file_count, ls.symbol_count });
	}
	try writer.writeAll("],");

	// Last indexed
	if (last_indexed) |li| {
		try writer.writeAll("\"last_indexed\":{\"file\":");
		try writeJsonString(li.file_path, writer);
		try writer.writeAll(",\"timestamp_utc\":\"");
		try writeIso8601(writer, li.indexed_at);
		try writer.print("\",\"epoch\":{d}}}", .{li.indexed_at});
	} else {
		try writer.writeAll("\"last_indexed\":null");
	}

	try writer.writeAll("}\n");
}

fn writeStatusHuman(
	writer: *std.Io.Writer,
	root_path: []const u8,
	db_path: []const u8,
	db_size: u64,
	watcher_pid: ?pidfile.PidType,
	watcher_progress: ?[]const u8,
	file_count: i64,
	symbol_count: i64,
	embedding_count: i64,
	comment_embedding_count: i64,
	lang_stats: []const storage.LangStat,
	last_indexed: ?storage.LastIndexedResult,
) !void {
	// Root
	try writer.print("Root:       {s}\n", .{root_path});

	// DB path + size
	try writer.writeAll("DB:         ");
	try writer.writeAll(db_path);
	if (db_size > 0) {
		try writer.writeAll(" (");
		try writeHumanSize(writer, db_size);
		try writer.writeAll(")");
	}
	try writer.writeAll("\n");

	// Watcher
	if (watcher_pid) |pid| {
		if (watcher_progress) |wp| {
			const trimmed = std.mem.trim(u8, wp, &std.ascii.whitespace);
			try writer.print("Watcher:    {s} (PID {d})\n", .{ trimmed, pid });
		} else {
			try writer.print("Watcher:    running (PID {d})\n", .{pid});
		}
	} else {
		try writer.writeAll("Watcher:    stopped\n");
	}

	try writer.writeAll("\nIndex:\n");
	try writer.print("  Files:      {d}\n", .{file_count});
	try writer.print("  Symbols:    {d}\n", .{symbol_count});
	try writer.print("  Embeddings: {d} code + {d} comment\n", .{ embedding_count, comment_embedding_count });

	if (lang_stats.len > 0) {
		try writer.writeAll("\nLanguages:\n");
		for (lang_stats) |ls| {
			// Pad language name to 14 chars
			try writer.writeAll("  ");
			try writer.writeAll(ls.language);
			var pad: usize = if (ls.language.len < 14) 14 - ls.language.len else 1;
			while (pad > 0) : (pad -= 1) {
				try writer.writeAll(" ");
			}
			try writer.print("{d} files   {d} symbols\n", .{ ls.file_count, ls.symbol_count });
		}
	}

	if (last_indexed) |li| {
		try writer.print("\nLast indexed: {s}\n", .{li.file_path});
		try writer.writeAll("  ");
		try writeIso8601(writer, li.indexed_at);
		try writer.writeAll(" UTC");
		// Also show local time
		try writeLocalTime(writer, li.indexed_at);
		try writer.writeAll("\n");
	}
}

fn writeIso8601(writer: *std.Io.Writer, epoch_secs: i64) !void {
	const es = std.time.epoch.EpochSeconds{ .secs = @intCast(epoch_secs) };
	const day = es.getEpochDay();
	const yd = day.calculateYearDay();
	const md = yd.calculateMonthDay();
	const ds = es.getDaySeconds();
	try writer.print("{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
		yd.year,
		@as(u32, @intFromEnum(md.month)),
		@as(u32, md.day_index) + 1,
		ds.getHoursIntoDay(),
		ds.getMinutesIntoHour(),
		ds.getSecondsIntoMinute(),
	});
}

fn writeLocalTime(writer: *std.Io.Writer, epoch_secs: i64) !void {
	const c_time = @cImport(@cInclude("time.h"));
	const time_val: c_time.time_t = @intCast(epoch_secs);
	var local: c_time.struct_tm = undefined;
	const result = c_time.localtime_r(&time_val, &local);
	if (result == null) return;

	// Format: " (2026-02-17 12:55:00 EST)"
	try writer.writeAll(" (");
	try writer.print("{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
		@as(i32, local.tm_year) + 1900,
		@as(u32, @intCast(local.tm_mon)) + 1,
		@as(u32, @intCast(local.tm_mday)),
		@as(u32, @intCast(local.tm_hour)),
		@as(u32, @intCast(local.tm_min)),
		@as(u32, @intCast(local.tm_sec)),
	});

	// Append timezone abbreviation if available
	const tz: ?[*:0]const u8 = local.tm_zone;
	if (tz) |tz_ptr| {
		const tz_str = std.mem.span(tz_ptr);
		if (tz_str.len > 0) {
			try writer.print(" {s}", .{tz_str});
		}
	}

	try writer.writeAll(")");
}

fn writeHumanSize(writer: *std.Io.Writer, size: u64) !void {
	if (size < 1024) {
		try writer.print("{d} B", .{size});
	} else if (size < 1024 * 1024) {
		const kb = @as(f64, @floatFromInt(size)) / 1024.0;
		try writer.print("{d:.1} KB", .{kb});
	} else if (size < 1024 * 1024 * 1024) {
		const mb = @as(f64, @floatFromInt(size)) / (1024.0 * 1024.0);
		try writer.print("{d:.1} MB", .{mb});
	} else {
		const gb = @as(f64, @floatFromInt(size)) / (1024.0 * 1024.0 * 1024.0);
		try writer.print("{d:.1} GB", .{gb});
	}
}

fn usageForTopic(topic: []const u8) []const u8 {
    if (std.mem.eql(u8, topic, "search") or std.mem.eql(u8, topic, "query")) return usage_search;
    if (std.mem.eql(u8, topic, "index")) return usage_index;
    if (std.mem.eql(u8, topic, "update")) return usage_update;
    if (std.mem.eql(u8, topic, "config")) return usage_config;
    if (std.mem.eql(u8, topic, "symbols") or std.mem.eql(u8, topic, "find-symbol")) return usage_symbols;
    if (std.mem.eql(u8, topic, "replace-symbol")) return usage_replace_symbol;
    if (std.mem.eql(u8, topic, "insert-after")) return usage_insert_after;
    if (std.mem.eql(u8, topic, "insert-before")) return usage_insert_before;
    if (std.mem.eql(u8, topic, "replace-lines")) return usage_replace_lines;
    if (std.mem.eql(u8, topic, "insert-at")) return usage_insert_at;
    if (std.mem.eql(u8, topic, "replace-content")) return usage_replace_content;
    if (std.mem.eql(u8, topic, "read-file")) return usage_read_file;
    if (std.mem.eql(u8, topic, "create-file")) return usage_create_file;
    if (std.mem.eql(u8, topic, "destroy-file")) return usage_destroy_file;
    if (std.mem.eql(u8, topic, "diff")) return usage_diff;
    if (std.mem.eql(u8, topic, "references")) return usage_references;
    if (std.mem.eql(u8, topic, "rename")) return usage_rename;
    if (std.mem.eql(u8, topic, "watch")) return usage_watch;
    if (std.mem.eql(u8, topic, "serve")) return usage_serve;
    if (std.mem.eql(u8, topic, "mcp-serve")) return usage_mcp_serve;
    if (std.mem.eql(u8, topic, "status")) return usage_status;
    if (std.mem.eql(u8, topic, "clean") or std.mem.eql(u8, topic, "clear")) return usage_clean;
    if (std.mem.eql(u8, topic, "init")) return usage_init;
    if (std.mem.eql(u8, topic, "hashlines")) return usage_hashlines;
    if (std.mem.eql(u8, topic, "name-paths")) return usage_name_paths;
    if (std.mem.eql(u8, topic, "languages")) return usage_languages;
    if (std.mem.eql(u8, topic, "lsp")) return usage_lsp;
    return usage;
}

fn printUsage(writer: *std.Io.Writer, topic: ?[]const u8) !void {
    if (topic) |value| {
        try writer.writeAll(usageForTopic(value));
        return;
    }
	try writer.writeAll(usage);
}

/// Run a PCRE2 regex search across indexed files, returning matches with
/// hashline annotations and optional context lines.
pub fn runRegexSearch(
	allocator: std.mem.Allocator,
	db: storage.Db,
	pattern_str: []const u8,
	context_lines: usize,
	top_n: usize,
	path_filters: []const []const u8,
	lang_filter: ?[]const u8,
	ignore_case: bool,
	registry: plugin.Registry,
	root_path: []const u8,
	format: cli.OutputFormat,
	writer: *std.Io.Writer,
	include_body: bool,
) !void {
	// Compile the regex
	var regex = pcre2.Regex.compileEx(allocator, pattern_str, .{ .case_insensitive = ignore_case }) catch {
		if (format == .json) {
			try writer.writeAll("{\"error\":\"invalid regex pattern\"}\n");
		} else {
			try writer.print("error: invalid regex pattern: {s}\n", .{pattern_str});
		}
		return;
	};
	defer regex.deinit();

	// Get indexed files
	const indexed_files = try storage.getAllIndexedFiles(db, allocator);
	defer {
		for (indexed_files) |f| allocator.free(f.file_path);
		allocator.free(indexed_files);
	}

	const ContextLine = struct {
		line: usize,
		hash: hashline.Hash,
		content: []const u8,
		is_match: bool,
	};
	const Result = struct {
		file: []const u8,
		line: usize,
		hash: hashline.Hash,
		match_text: []const u8,
		context: []ContextLine,
		// body fields (populated when include_body=true and a containing symbol is found)
		body_name: ?[]const u8,
		body_start: usize,
		body_end: usize,
		body_lines: ?[]ContextLine,
	};

	var results = std.ArrayListUnmanaged(Result){};
	defer {
		for (results.items) |r| {
			allocator.free(r.match_text);
			for (r.context) |ctx| allocator.free(ctx.content);
			allocator.free(r.context);
			if (r.body_name) |n| allocator.free(n);
			if (r.body_lines) |bl| {
				for (bl) |ctx| allocator.free(ctx.content);
				allocator.free(bl);
			}
		}
		results.deinit(allocator);
	}

	var match_count: usize = 0;

	for (indexed_files) |indexed_file| {
		if (match_count >= top_n) break;

		const rel_path = indexed_file.file_path;

		// Apply path filters
		if (path_filters.len > 0) {
			var any_match = false;
			for (path_filters) |pf| {
				if (search.pathMatchesGlob(rel_path, pf)) {
					any_match = true;
					break;
				}
			}
			if (!any_match) continue;
		}

		// Apply language filter
		if (lang_filter) |lang| {
			const extractor = registry.find(rel_path);
			if (extractor) |ext| {
				if (!std.mem.eql(u8, ext.language, lang)) continue;
			} else {
				continue; // unknown language, skip
			}
		}

		// Read file from disk
		const abs_path = std.fs.path.join(allocator, &.{ root_path, rel_path }) catch continue;
		defer allocator.free(abs_path);

		const file = std.fs.openFileAbsolute(abs_path, .{}) catch continue;
		defer file.close();
		const source = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch continue;
		defer allocator.free(source);

		// Compute hashlines
		const hashes = hashline.computeSourceHashes(allocator, source) catch continue;
		defer allocator.free(hashes);

		// Split source into lines for context
		var lines_list = std.ArrayListUnmanaged([]const u8){};
		defer lines_list.deinit(allocator);
		{
			var start: usize = 0;
			for (source, 0..) |ch, idx| {
				if (ch == '\n') {
					try lines_list.append(allocator, source[start..idx]);
					start = idx + 1;
				}
			}
			if (start <= source.len) {
				try lines_list.append(allocator, source[start..]);
			}
		}
		const lines = lines_list.items;

		// Build line offset index (byte offset -> line number)
		var line_offsets = std.ArrayListUnmanaged(usize){};
		defer line_offsets.deinit(allocator);
		{
			var off: usize = 0;
			for (lines) |line| {
				try line_offsets.append(allocator, off);
				off += line.len + 1; // +1 for newline
			}
		}

		// Find all regex matches
		var offset: usize = 0;
		// Track which lines we already reported to avoid duplicates
		var reported_lines = std.AutoHashMapUnmanaged(usize, void){};
		defer reported_lines.deinit(allocator);

		while (match_count < top_n) {
			const m = regex.findPosition(source, offset) orelse break;

			// Find line number for match start
			var line_num: usize = 0;
			for (line_offsets.items, 0..) |lo, li| {
				if (m.start < lo) break;
				line_num = li;
			}

			// Skip if we already reported this line
			if (reported_lines.get(line_num) != null) {
				offset = m.end;
				if (offset == m.start) offset += 1; // avoid infinite loop on zero-width match
				continue;
			}
			reported_lines.put(allocator, line_num, {}) catch {};

			if (line_num >= lines.len or line_num >= hashes.len) {
				offset = m.end;
				if (offset == m.start) offset += 1;
				continue;
			}

			// Compute context range
			const before: usize = if (context_lines <= 1) 0 else (context_lines - 1) / 2;
			const after: usize = if (context_lines <= 1) 0 else context_lines - 1 - before;

			const ctx_start = if (line_num >= before) line_num - before else 0;
			const ctx_end = @min(line_num + after + 1, lines.len);

			// Build context lines
			var ctx_list = std.ArrayListUnmanaged(ContextLine){};
			errdefer {
				for (ctx_list.items) |ctx| allocator.free(ctx.content);
				ctx_list.deinit(allocator);
			}
			for (ctx_start..ctx_end) |cl| {
				if (cl >= lines.len or cl >= hashes.len) break;
				const content_dupe = try allocator.dupe(u8, lines[cl]);
				errdefer allocator.free(content_dupe);
				try ctx_list.append(allocator, .{
					.line = cl + 1, // 1-indexed
					.hash = hashes[cl],
					.content = content_dupe,
					.is_match = cl == line_num,
				});
			}

			const match_text = try allocator.dupe(u8, lines[line_num]);
			errdefer allocator.free(match_text);
			const ctx_owned = try ctx_list.toOwnedSlice(allocator);
			errdefer {
				for (ctx_owned) |ctx| allocator.free(ctx.content);
				allocator.free(ctx_owned);
			}

			// Body lookup: find the innermost symbol containing this line
			var body_name: ?[]const u8 = null;
			var body_start: usize = 0;
			var body_end: usize = 0;
			var body_lines: ?[]ContextLine = null;
			if (include_body) blk: {
				const matched_line_1indexed = line_num + 1;
				const sql: [:0]const u8 =
					"SELECT symbol_name, start_line, end_line FROM symbols " ++
					"WHERE file_path = ?1 AND start_line <= ?2 AND end_line >= ?2 " ++
					"ORDER BY (end_line - start_line) ASC LIMIT 1;\x00";
				var stmt: ?*storage.sqlite.sqlite3_stmt = null;
				if (storage.sqlite.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != storage.sqlite.SQLITE_OK) break :blk;
				defer _ = storage.sqlite.sqlite3_finalize(stmt.?);

				_ = storage.sqlite.sqlite3_bind_text(stmt.?, 1, rel_path.ptr, @intCast(rel_path.len), null);
				_ = storage.sqlite.sqlite3_bind_int64(stmt.?, 2, @intCast(matched_line_1indexed));

				if (storage.sqlite.sqlite3_step(stmt.?) == storage.sqlite.SQLITE_ROW) {
					const name_ptr = storage.sqlite.sqlite3_column_text(stmt.?, 0) orelse break :blk;
					const name_len: usize = @intCast(storage.sqlite.sqlite3_column_bytes(stmt.?, 0));
					body_name = try allocator.dupe(u8, name_ptr[0..name_len]);
					body_start = @intCast(storage.sqlite.sqlite3_column_int64(stmt.?, 1));
					body_end = @intCast(storage.sqlite.sqlite3_column_int64(stmt.?, 2));

					// Build body_lines from file source (0-indexed: body_start-1 .. body_end)
					var bl_list = std.ArrayListUnmanaged(ContextLine){};
					errdefer {
						for (bl_list.items) |ctx| allocator.free(ctx.content);
						bl_list.deinit(allocator);
					}
					const bl_start = body_start - 1; // convert to 0-indexed
					const bl_end = @min(body_end, lines.len);
					for (bl_start..bl_end) |li| {
						if (li >= lines.len or li >= hashes.len) break;
						const content_dupe = try allocator.dupe(u8, lines[li]);
						errdefer allocator.free(content_dupe);
						try bl_list.append(allocator, .{
							.line = li + 1, // 1-indexed
							.hash = hashes[li],
							.content = content_dupe,
							.is_match = li == line_num,
						});
					}
					body_lines = try bl_list.toOwnedSlice(allocator);
				}
			}

			try results.append(allocator, .{
				.file = rel_path,
				.line = line_num + 1, // 1-indexed
				.hash = hashes[line_num],
				.match_text = match_text,
				.context = ctx_owned,
				.body_name = body_name,
				.body_start = body_start,
				.body_end = body_end,
				.body_lines = body_lines,
			});
			match_count += 1;

			offset = m.end;
			if (offset == m.start) offset += 1;
		}
	}

	// Output results
	switch (format) {
		.json => {
			try writer.writeAll("{\"total_matches\":");
			try writer.print("{d}", .{results.items.len});
			try writer.writeAll(",\"showing\":");
			try writer.print("{d}", .{results.items.len});
			try writer.writeAll(",\"results\":[");
			for (results.items, 0..) |r, ri| {
				if (ri > 0) try writer.writeAll(",");
				try writer.writeAll("{\"file\":");
				try writeJsonString(r.file, writer);
				try writer.print(",\"line\":{d},\"hash\":\"{s}\",\"match\":", .{ r.line, r.hash });
				try writeJsonString(r.match_text, writer);
				if (r.context.len > 0) {
					try writer.writeAll(",\"context\":[");
					for (r.context, 0..) |ctx, ci| {
						if (ci > 0) try writer.writeAll(",");
						try writer.writeAll("{\"line\":");
						try writer.print("{d}", .{ctx.line});
						try writer.print(",\"hash\":\"{s}\",\"content\":", .{ctx.hash});
						try writeJsonString(ctx.content, writer);
						if (ctx.is_match) {
							try writer.writeAll(",\"is_match\":true");
						}
						try writer.writeAll("}");
					}
					try writer.writeAll("]");
				}
				if (r.body_name) |bname| {
					try writer.writeAll(",\"body\":{\"symbol\":");
					try writeJsonString(bname, writer);
					try writer.print(",\"start_line\":{d},\"end_line\":{d},\"lines\":[", .{ r.body_start, r.body_end });
					if (r.body_lines) |bl| {
						for (bl, 0..) |ctx, bi| {
							if (bi > 0) try writer.writeAll(",");
							try writer.writeAll("{\"line\":");
							try writer.print("{d}", .{ctx.line});
							try writer.print(",\"hash\":\"{s}\",\"content\":", .{ctx.hash});
							try writeJsonString(ctx.content, writer);
							if (ctx.is_match) {
								try writer.writeAll(",\"is_match\":true");
							}
							try writer.writeAll("}");
						}
					}
					try writer.writeAll("]}");
				}
				try writer.writeAll("}");
			}
			try writer.writeAll("]}\n");
		},
		.human => {
			if (results.items.len == 0) {
				try writer.writeAll("No regex matches found.\n");
				return;
			}
			for (results.items) |r| {
				if (r.body_name) |bname| {
					try writer.print("{s}:{d}:{s}  (in {s}, lines {d}-{d})\n", .{ r.file, r.line, r.hash, bname, r.body_start, r.body_end });
					if (r.body_lines) |bl| {
						for (bl) |ctx| {
							const prefix: []const u8 = if (ctx.is_match) "> " else "  ";
							try writer.print("{s}{d}:{s}|{s}\n", .{ prefix, ctx.line, ctx.hash, ctx.content });
						}
					}
				} else {
					try writer.print("{s}:{d}:{s}\n", .{ r.file, r.line, r.hash });
					if (r.context.len > 0) {
						for (r.context) |ctx| {
							const prefix: []const u8 = if (ctx.is_match) "> " else "  ";
							try writer.print("{s}{d}:{s}|{s}\n", .{ prefix, ctx.line, ctx.hash, ctx.content });
						}
					}
				}
			}
		},
	}
}

// writeJsonString is defined earlier in this file (takes s, writer)

// ── Test mocks for detectEmbeddingServer ─────────────────────────────────────

const OpenAIFallbackMock = struct {
    fn send(_: *anyopaque, allocator: std.mem.Allocator, req: embedding_http.HttpRequest) !embedding_http.HttpResponse {
        if (std.mem.endsWith(u8, req.url, "/v1/models")) {
            return .{ .status = 200, .body = try allocator.dupe(u8, "{\"data\":[]}") };
        }
        return error.ConnectionRefused;
    }
    fn transport(self: *OpenAIFallbackMock) embedding_http.Transport {
        return .{ .ctx = self, .send = send };
    }
};

const AllFailMock = struct {
    fn send(_: *anyopaque, _: std.mem.Allocator, _: embedding_http.HttpRequest) !embedding_http.HttpResponse {
        return error.ConnectionRefused;
    }
    fn transport(self: *AllFailMock) embedding_http.Transport {
        return .{ .ctx = self, .send = send };
    }
};

test "detectEmbeddingServer finds Ollama" {
    const allocator = std.testing.allocator;
    var mock = embedding_http.MockTransportCtx{
        .tags_body =
            \\{"models":[{"name":"bge-large:latest"}]}
        ,
        .ps_body =
            \\{"models":[]}
        ,
    };
    const result = detectEmbeddingServer(
        allocator,
        mock.transport(),
        "http://localhost:11434",
        "bge-large",
    );
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("http://localhost:11434", result.?.url);
    try std.testing.expectEqual(embedding_http.ApiDialect.ollama, result.?.dialect);
    try std.testing.expect(result.?.model_available);
}

test "detectEmbeddingServer finds oMLX when Ollama unavailable" {
    const allocator = std.testing.allocator;
    var mock = OpenAIFallbackMock{};
    const result = detectEmbeddingServer(
        allocator,
        mock.transport(),
        "http://localhost:11434",
        "bge-large",
    );
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("http://localhost:8000", result.?.url);
    try std.testing.expectEqual(embedding_http.ApiDialect.openai, result.?.dialect);
}

test "detectEmbeddingServer returns null when nothing available" {
    const allocator = std.testing.allocator;
    var mock = AllFailMock{};
    const result = detectEmbeddingServer(
        allocator,
        mock.transport(),
        "http://localhost:11434",
        "bge-large",
    );
    try std.testing.expect(result == null);
}

test "detectEmbeddingServer Ollama up but model missing" {
    const allocator = std.testing.allocator;
    var mock = embedding_http.MockTransportCtx{
        .tags_body =
            \\{"models":[{"name":"llama3:latest"}]}
        ,
        .ps_body =
            \\{"models":[]}
        ,
    };
    const result = detectEmbeddingServer(
        allocator,
        mock.transport(),
        "http://localhost:11434",
        "bge-large",
    );
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("http://localhost:11434", result.?.url);
    try std.testing.expect(!result.?.model_available);
}


test "findRepoRoot finds nearest .codescan ancestor" {
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	try tmp.dir.makePath("repo/.codescan");
	try tmp.dir.makePath("repo/sub/dir");

	const start = try tmp.dir.realpathAlloc(allocator, "repo/sub/dir");
	defer allocator.free(start);

	const expected = try tmp.dir.realpathAlloc(allocator, "repo");
	defer allocator.free(expected);

	const root = try findRepoRoot(allocator, start);
	defer if (root) |path| allocator.free(path);

	try std.testing.expect(root != null);
	try std.testing.expectEqualStrings(expected, root.?);
}

test "findRepoRoot returns null when missing" {
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	try tmp.dir.makePath("repo/sub/dir");

	const start = try tmp.dir.realpathAlloc(allocator, "repo/sub/dir");
	defer allocator.free(start);

	const stop_at = try tmp.dir.realpathAlloc(allocator, "repo");
	defer allocator.free(stop_at);

	const root = try findRepoRootUntil(allocator, start, stop_at);
	defer if (root) |path| allocator.free(path);

	try std.testing.expect(root == null);
}

test "shouldShowProgress requires tty and human output" {
	try std.testing.expect(shouldShowProgress(true, .human));
	try std.testing.expect(!shouldShowProgress(false, .human));
	try std.testing.expect(!shouldShowProgress(true, .json));
}

test "help topic search returns focused usage" {
    const text = usageForTopic("search");
    try std.testing.expect(std.mem.indexOf(u8, text, "Usage: codescan search") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Usage: codescan index") == null);
}

test "help topic unknown falls back to global usage" {
    const text = usageForTopic("does-not-exist");
    try std.testing.expectEqualStrings(usage, text);
}

test "json envelope search request converts to argv" {
    const allocator = std.testing.allocator;
    const payload = "{\"action\":\"search\",\"query\":\"checksum\",\"root\":\"/repo\",\"top\":7,\"scope\":\"docs\",\"mode\":\"hybrid\",\"min_score\":0.25}";
    var built = try parseJsonEnvelopeArgs(allocator, payload, "codescan");
    defer built.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 14), built.args.len);
    try std.testing.expectEqualStrings("codescan", built.args[0]);
    try std.testing.expectEqualStrings("search", built.args[1]);
    try std.testing.expectEqualStrings("checksum", built.args[2]);
    try std.testing.expectEqualStrings("--root", built.args[3]);
    try std.testing.expectEqualStrings("/repo", built.args[4]);
    try std.testing.expectEqualStrings("--top", built.args[5]);
    try std.testing.expectEqualStrings("7", built.args[6]);
    try std.testing.expectEqualStrings("--scope", built.args[7]);
    try std.testing.expectEqualStrings("docs", built.args[8]);
    try std.testing.expectEqualStrings("--mode", built.args[9]);
    try std.testing.expectEqualStrings("hybrid", built.args[10]);
    try std.testing.expectEqualStrings("--min-score", built.args[11]);
    const min_score = try std.fmt.parseFloat(f32, built.args[12]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), min_score, 0.0001);
    try std.testing.expectEqualStrings("--json", built.args[13]);
}

test "json envelope status request converts to argv" {
    const allocator = std.testing.allocator;
    const payload = "{\"action\":\"status\",\"root\":\"/repo\"}";
    var built = try parseJsonEnvelopeArgs(allocator, payload, "codescan");
    defer built.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 5), built.args.len);
    try std.testing.expectEqualStrings("codescan", built.args[0]);
    try std.testing.expectEqualStrings("status", built.args[1]);
    try std.testing.expectEqualStrings("--root", built.args[2]);
    try std.testing.expectEqualStrings("/repo", built.args[3]);
    try std.testing.expectEqualStrings("--json", built.args[4]);
}

test "json envelope requires action" {
    const allocator = std.testing.allocator;
    const payload = "{\"query\":\"checksum\"}";
    try std.testing.expectError(error.InvalidJsonEnvelope, parseJsonEnvelopeArgs(allocator, payload, "codescan"));
}

test "buildSearchFilters defaults to primary language" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

	var sym1 = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/a.zig"),
		.name = try allocator.dupe(u8, "a"),
		.signature = try allocator.dupe(u8, "fn a() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym1.deinit(allocator);
	var sym2 = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/b.zig"),
		.name = try allocator.dupe(u8, "b"),
		.signature = try allocator.dupe(u8, "fn b() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym2.deinit(allocator);
	var sym3 = model.Symbol{
		.language = try allocator.dupe(u8, "markdown"),
		.file_path = try allocator.dupe(u8, "README.md"),
		.name = try allocator.dupe(u8, "Title"),
		.signature = try allocator.dupe(u8, "Intro"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym3.deinit(allocator);

	_ = try storage.insertSymbol(db, sym1);
	_ = try storage.insertSymbol(db, sym2);
	_ = try storage.insertSymbol(db, sym3);

	const args = [_][]const u8{ "codescan", "search", "query" };
	var parsed = try cli.parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	var cfg = config.Config{};
	defer cfg.deinit(allocator);
	var settings = try resolveSettings(allocator, parsed, cfg, ".");
	settings.include_docs = false;

	var filter_lists = try filters.buildSearchFilters(allocator, plugin.defaultRegistry(), db, .{
		.search_ext = settings.search_ext,
		.search_type = settings.search_type,
		.search_lang = settings.search_lang,
		.primary_lang = settings.primary_lang,
		.include_docs = settings.include_docs,
		.docs_only = settings.docs_only,
	});
	defer filter_lists.deinit(allocator);

	try std.testing.expectEqual(@as(usize, 1), filter_lists.langs.items.len);
	try std.testing.expectEqualStrings("zig", filter_lists.langs.items[0]);
}

test "buildSearchFilters includes docs when requested" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

	var sym1 = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/a.zig"),
		.name = try allocator.dupe(u8, "a"),
		.signature = try allocator.dupe(u8, "fn a() void"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym1.deinit(allocator);
	var sym2 = model.Symbol{
		.language = try allocator.dupe(u8, "markdown"),
		.file_path = try allocator.dupe(u8, "README.md"),
		.name = try allocator.dupe(u8, "Title"),
		.signature = try allocator.dupe(u8, "Intro"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer sym2.deinit(allocator);

	_ = try storage.insertSymbol(db, sym1);
	_ = try storage.insertSymbol(db, sym2);

	const args = [_][]const u8{ "codescan", "search", "query" };
	var parsed = try cli.parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	var cfg = config.Config{};
	defer cfg.deinit(allocator);
	var settings = try resolveSettings(allocator, parsed, cfg, ".");
	settings.include_docs = true;

	var filter_lists = try filters.buildSearchFilters(allocator, plugin.defaultRegistry(), db, .{
		.search_ext = settings.search_ext,
		.search_type = settings.search_type,
		.search_lang = settings.search_lang,
		.primary_lang = settings.primary_lang,
		.include_docs = settings.include_docs,
		.docs_only = settings.docs_only,
	});
	defer filter_lists.deinit(allocator);

	try std.testing.expectEqual(@as(usize, 2), filter_lists.langs.items.len);
	try std.testing.expect(listContains(filter_lists.langs.items, "zig"));
	try std.testing.expect(listContains(filter_lists.langs.items, "markdown"));
}

test "resolveSettings uses discovered repo root for db path" {
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	try tmp.dir.makePath("repo/.codescan");
	try tmp.dir.makePath("repo/sub/dir");

	const start = try tmp.dir.realpathAlloc(allocator, "repo/sub/dir");
	defer allocator.free(start);

	const root = try findRepoRoot(allocator, start);
	defer if (root) |path| allocator.free(path);

	try std.testing.expect(root != null);

	const args = [_][]const u8{ "codescan", "search", "checksum" };
	var parsed = try cli.parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);

	var cfg = config.Config{};
	defer cfg.deinit(allocator);

	const settings = try resolveSettings(allocator, parsed, cfg, root.?);
	defer if (settings.db_path_owned) allocator.free(settings.db_path);

	const expected_db = try std.fs.path.join(allocator, &.{ root.?, ".codescan", "index.sqlite3" });
	defer allocator.free(expected_db);

	try std.testing.expectEqualStrings(root.?, settings.root_path);
	try std.testing.expectEqualStrings(expected_db, settings.db_path);
}

test "resolveSettings defaults index_type to code and doc" {
	const allocator = std.testing.allocator;
	const args = [_][]const u8{ "codescan", "index" };
	var parsed = try cli.parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);

	var cfg = config.Config{};
	defer cfg.deinit(allocator);

	const settings = try resolveSettings(allocator, parsed, cfg, ".");
	try std.testing.expect(settings.index_type != null);
	try std.testing.expectEqualStrings("code,doc", settings.index_type.?);
}

fn listContains(list: []const []const u8, value: []const u8) bool {
	for (list) |item| {
		if (std.mem.eql(u8, item, value)) return true;
	}
	return false;
}

test "chain hash cascade detects stale content after edits" {
	const allocator = std.testing.allocator;

	// Validates the hash cascade that runReplaceLines relies on for staleness
	// detection. When a line changes, all subsequent chain hashes must differ,
	// causing runReplaceLines to reject the edit with a "stale hashlines" error.
	const original_content = "fn foo() void {\n    return 42;\n}\n";

	var tmp_dir = std.testing.tmpDir(.{});
	defer tmp_dir.cleanup();
	try tmp_dir.dir.writeFile(.{ .sub_path = "test.zig", .data = original_content });

	// --- Step 1: Compute hashes from original content (simulates indexer) ---
	var orig_lines = try splitLines(allocator, original_content);
	defer orig_lines.deinit(allocator);

	const orig_hashes = try hashline.computeChainHashes(allocator, orig_lines.items);
	defer allocator.free(orig_hashes);

	// Store "from" and "to" hashline refs for lines 1-3
	const from_hash = orig_hashes[0]; // line 1
	const to_hash = orig_hashes[2]; // line 3

	// Verify hashes match original content
	try std.testing.expect(std.mem.eql(u8, &from_hash, &orig_hashes[0]));
	try std.testing.expect(std.mem.eql(u8, &to_hash, &orig_hashes[2]));

	// --- Step 2: Modify the file (simulates user editing between index and search) ---
	const modified_content = "fn foo() void {\n    return 99;\n}\n";
	try tmp_dir.dir.writeFile(.{ .sub_path = "test.zig", .data = modified_content });

	// --- Step 3: Re-read and compute hashes for current file content ---
	var mod_lines = try splitLines(allocator, modified_content);
	defer mod_lines.deinit(allocator);

	const new_hashes = try hashline.computeChainHashes(allocator, mod_lines.items);
	defer allocator.free(new_hashes);

	// --- Step 4: Verify stale detection ---
	// Line 1 is unchanged — hash should still match
	try std.testing.expect(std.mem.eql(u8, &from_hash, &new_hashes[0]));

	// Line 2 was edited — its hash must differ (chain breaks here)
	try std.testing.expect(!std.mem.eql(u8, &orig_hashes[1], &new_hashes[1]));

	// Line 3 content unchanged but chain input differs — hash must differ (cascade)
	try std.testing.expect(!std.mem.eql(u8, &to_hash, &new_hashes[2]));
}

test "parseHashlineRef round-trips with computed hashes" {
	const allocator = std.testing.allocator;

	const source = "line one\nline two\nline three\n";
	var lines = try splitLines(allocator, source);
	defer lines.deinit(allocator);

	const hashes = try hashline.computeChainHashes(allocator, lines.items);
	defer allocator.free(hashes);

	// Format as "2:<hash>" and parse back
	var buf: [16]u8 = undefined;
	const ref_str = try std.fmt.bufPrint(&buf, "2:{s}", .{@as([]const u8, &hashes[1])});
	const parsed_ref = try parseHashlineRef(ref_str);

	try std.testing.expectEqual(@as(usize, 2), parsed_ref.line);
	try std.testing.expectEqualStrings(&hashes[1], &parsed_ref.hash);
}

test "findNameCol locates symbol name column in source" {
	const source =
		\\const std = @import("std");
		\\pub fn writePid(allocator: std.mem.Allocator) !void {
		\\    const x = 42;
		\\}
	;
	// "pub fn writePid" — name starts at col 7 (0-indexed) on line 2
	// Line 2 starts after the first '\n' + 1
	const line2_start = std.mem.indexOfScalar(u8, source, '\n').? + 1;
	const col = findNameCol(source, line2_start, "writePid");
	try std.testing.expectEqual(@as(u32, 7), col);

	// Test with indented method
	const source2 =
		\\pub const Foo = struct {
		\\    pub fn bar(self: *Foo) void {}
		\\};
	;
	const line2_start2 = std.mem.indexOfScalar(u8, source2, '\n').? + 1;
	const col2 = findNameCol(source2, line2_start2, "bar");
	try std.testing.expectEqual(@as(u32, 11), col2);

	// Test fallback when name not found on line — should return 0
	const col3 = findNameCol(source, 0, "nonexistent");
	try std.testing.expectEqual(@as(u32, 0), col3);
}

test "findPatternPosition locates text in source" {
	const source =
		\\source_filename = "test.c"
		\\
		\\define i32 @main() {
		\\entry:
		\\  %0 = alloca i32
		\\  ret i32 0
		\\}
	;
	// @main is on line 2, col 11 ("define i32 " = 11 chars)
	const pos1 = findPatternPosition(source, "@main").?;
	try std.testing.expectEqual(@as(u32, 2), pos1.line);
	try std.testing.expectEqual(@as(u32, 11), pos1.col);

	// %0 is on line 4, col 2
	const pos2 = findPatternPosition(source, "%0").?;
	try std.testing.expectEqual(@as(u32, 4), pos2.line);
	try std.testing.expectEqual(@as(u32, 2), pos2.col);

	// entry is on line 3, col 0
	const pos3 = findPatternPosition(source, "entry").?;
	try std.testing.expectEqual(@as(u32, 3), pos3.line);
	try std.testing.expectEqual(@as(u32, 0), pos3.col);

	// Not found
	try std.testing.expect(findPatternPosition(source, "@nonexistent") == null);
}

test "findNameCol returns correct column even when byte_offset is mid-line" {
	// Simulates LLVM IR where function_header node starts mid-line
	// "define i32 @main() {\n..."
	//  ^byte 0    ^byte 11 = @main
	//        ^byte 7 = tree-sitter function_header start (at "i32")
	const source = "define i32 @main() {\nentry:\n  %needle = add i32 1, 2\n";

	// When byte_offset is mid-line (byte 7 = "i32 @main..."),
	// findNameCol must still return column 11 (from line start), not 4 (from byte_offset)
	const col = findNameCol(source, 7, "@main");
	try std.testing.expectEqual(@as(u32, 11), col);

	// When byte_offset IS the line start, should work normally
	const col2 = findNameCol(source, 0, "define");
	try std.testing.expectEqual(@as(u32, 0), col2);

	// Mid-line on second line: "  %needle" with byte_offset pointing to %
	const line3_start = std.mem.indexOf(u8, source, "  %needle").?;
	const col3 = findNameCol(source, line3_start + 2, "%needle"); // +2 points to '%'
	try std.testing.expectEqual(@as(u32, 2), col3); // column 2 from line start
}

test "runReadFile returns JSON with hashlines and version" {
	const allocator = std.testing.allocator;

	// Create a temp file with known content
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const content = "line one\nline two\nline three\n";
	try tmp.dir.writeFile(.{ .sub_path = "test.txt", .data = content });
	const abs_path = try tmp.dir.realpathAlloc(allocator, "test.txt");
	defer allocator.free(abs_path);

	// Capture output using the Allocating writer pattern (same as MCP callTool)
	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	// Call runReadFile — full file, JSON format
	try runReadFile(allocator, abs_path, null, null, .json, &out.writer);
	const json_output = try out.toOwnedSlice();
	defer allocator.free(json_output);

	// Parse the JSON output
	var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_output, .{});
	defer parsed.deinit();
	const root = parsed.value.object;

	// Verify file path
	try std.testing.expectEqualStrings(abs_path, root.get("file").?.string);

	// Verify version is 3 chars
	const version = root.get("version").?.string;
	try std.testing.expectEqual(@as(usize, 3), version.len);

	// Verify total_lines (content has 4 lines: "line one", "line two", "line three", "")
	const total_lines = @as(usize, @intCast(root.get("total_lines").?.integer));
	try std.testing.expectEqual(@as(usize, 4), total_lines);

	// Verify from/to default to full file
	try std.testing.expectEqual(@as(i64, 1), root.get("from").?.integer);
	try std.testing.expectEqual(@as(i64, 4), root.get("to").?.integer);

	// Verify content contains hashline annotations (line_num:hash|content)
	const out_content = root.get("content").?.string;
	try std.testing.expect(std.mem.indexOf(u8, out_content, "line one") != null);
	try std.testing.expect(std.mem.indexOf(u8, out_content, "line two") != null);
	// Check hashline format: digit(s) colon 3-char-hash pipe
	// Line 1 should start with "1:xxx|"
	try std.testing.expect(out_content[0] == '1');
	try std.testing.expect(out_content[1] == ':');
	try std.testing.expect(out_content[5] == '|');
}

test "runReadFile partial read with from/to" {
	const allocator = std.testing.allocator;

	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const content = "alpha\nbeta\ngamma\ndelta\nepsilon\n";
	try tmp.dir.writeFile(.{ .sub_path = "partial.txt", .data = content });
	const abs_path = try tmp.dir.realpathAlloc(allocator, "partial.txt");
	defer allocator.free(abs_path);

	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	// Read lines 2-4 only
	try runReadFile(allocator, abs_path, 2, 4, .json, &out.writer);
	const json_output = try out.toOwnedSlice();
	defer allocator.free(json_output);

	var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_output, .{});
	defer parsed.deinit();
	const root = parsed.value.object;

	// total_lines should be the FULL file line count (6 lines: alpha, beta, gamma, delta, epsilon, "")
	const total_lines = @as(usize, @intCast(root.get("total_lines").?.integer));
	try std.testing.expectEqual(@as(usize, 6), total_lines);

	// from/to should reflect the request
	try std.testing.expectEqual(@as(i64, 2), root.get("from").?.integer);
	try std.testing.expectEqual(@as(i64, 4), root.get("to").?.integer);

	// Content should contain beta, gamma, delta but NOT alpha or epsilon
	const out_content = root.get("content").?.string;
	try std.testing.expect(std.mem.indexOf(u8, out_content, "beta") != null);
	try std.testing.expect(std.mem.indexOf(u8, out_content, "gamma") != null);
	try std.testing.expect(std.mem.indexOf(u8, out_content, "delta") != null);
	try std.testing.expect(std.mem.indexOf(u8, out_content, "alpha") == null);
	try std.testing.expect(std.mem.indexOf(u8, out_content, "epsilon") == null);

	// Version should still be based on the LAST line of the entire file
	const version = root.get("version").?.string;
	try std.testing.expectEqual(@as(usize, 3), version.len);
}

test "runReplaceContent rejects stale version" {
	const allocator = std.testing.allocator;

	// Create a temp file with known content
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const content = "hello world\ngoodbye world\n";
	try tmp.dir.writeFile(.{ .sub_path = "test.txt", .data = content });
	const abs_path = try tmp.dir.realpathAlloc(allocator, "test.txt");
	defer allocator.free(abs_path);

	// Compute the current version
	const current_version = (try hashline.computeFileVersion(allocator, content)).?;

	// Modify the file externally (simulates concurrent edit)
	try tmp.dir.writeFile(.{ .sub_path = "test.txt", .data = "modified content\n" });

	// Try to replace with the old version — should be rejected
	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();
	try runReplaceContent(allocator, abs_path, "modified", false, false, "replaced", &current_version, &out.writer);
	const output_text = try out.toOwnedSlice();
	defer allocator.free(output_text);

	try std.testing.expect(std.mem.indexOf(u8, output_text, "error: file modified since last read") != null);
}

test "runReplaceContent succeeds with correct version" {
	const allocator = std.testing.allocator;

	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const content = "hello world\ngoodbye world\n";
	try tmp.dir.writeFile(.{ .sub_path = "test.txt", .data = content });
	const abs_path = try tmp.dir.realpathAlloc(allocator, "test.txt");
	defer allocator.free(abs_path);

	// Compute the current version
	const current_version = (try hashline.computeFileVersion(allocator, content)).?;

	// Replace with the correct version — should succeed
	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();
	try runReplaceContent(allocator, abs_path, "hello", false, false, "hi", &current_version, &out.writer);
	const output_text = try out.toOwnedSlice();
	defer allocator.free(output_text);

	// Should contain success message, not error
	try std.testing.expect(std.mem.indexOf(u8, output_text, "Replaced 1 occurrence") != null);
	// Should contain a new version
	try std.testing.expect(std.mem.indexOf(u8, output_text, "version: ") != null);
	// Should contain diff output
	try std.testing.expect(std.mem.indexOf(u8, output_text, "--- a/") != null);
	try std.testing.expect(std.mem.indexOf(u8, output_text, "+++ b/") != null);
}

test "runReplaceContent errors when no version provided" {
	const allocator = std.testing.allocator;

	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const content = "hello world\n";
	try tmp.dir.writeFile(.{ .sub_path = "test.txt", .data = content });
	const abs_path = try tmp.dir.realpathAlloc(allocator, "test.txt");
	defer allocator.free(abs_path);

	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();
	try runReplaceContent(allocator, abs_path, "hello", false, false, "hi", null, &out.writer);
	const output_text = try out.toOwnedSlice();
	defer allocator.free(output_text);

	// Should contain error about missing version
	try std.testing.expect(std.mem.indexOf(u8, output_text, "error: --version is required") != null);
	// File should NOT have been modified
	const after = try tmp.dir.readFileAlloc(allocator, "test.txt", 8192);
	defer allocator.free(after);
	try std.testing.expectEqualStrings(content, after);
}

test "runReplaceSymbol rejects stale version" {
	const allocator = std.testing.allocator;

	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const content = "pub fn hello() void {}\npub fn world() void {}\n";
	try tmp.dir.writeFile(.{ .sub_path = "test.zig", .data = content });
	const abs_path = try tmp.dir.realpathAlloc(allocator, "test.zig");
	defer allocator.free(abs_path);

	// Compute version from original content
	const current_version = (try hashline.computeFileVersion(allocator, content)).?;

	// Modify the file externally (simulates concurrent edit)
	try tmp.dir.writeFile(.{ .sub_path = "test.zig", .data = "pub fn hello() void { return; }\npub fn world() void {}\n" });

	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();
	try runReplaceSymbol(allocator, abs_path, "hello", "pub fn hello() void { @panic(\"new\"); }\n", &current_version, &out.writer);
	const output_text = try out.toOwnedSlice();
	defer allocator.free(output_text);

	try std.testing.expect(std.mem.indexOf(u8, output_text, "error: file modified since last read") != null);
}

test "runReplaceSymbol succeeds with correct version and emits new version" {
	const allocator = std.testing.allocator;

	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const content = "pub fn hello() void {}\npub fn world() void {}\n";
	try tmp.dir.writeFile(.{ .sub_path = "test.zig", .data = content });
	const abs_path = try tmp.dir.realpathAlloc(allocator, "test.zig");
	defer allocator.free(abs_path);

	const current_version = (try hashline.computeFileVersion(allocator, content)).?;

	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();
	try runReplaceSymbol(allocator, abs_path, "hello", "pub fn hello() void { return; }\n", &current_version, &out.writer);
	const output_text = try out.toOwnedSlice();
	defer allocator.free(output_text);

	try std.testing.expect(std.mem.indexOf(u8, output_text, "Replaced hello") != null);
	try std.testing.expect(std.mem.indexOf(u8, output_text, "version: ") != null);
}

test "runReplaceSymbol errors when no version provided" {
	const allocator = std.testing.allocator;

	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const content = "pub fn hello() void {}\npub fn world() void {}\n";
	try tmp.dir.writeFile(.{ .sub_path = "test.zig", .data = content });
	const abs_path = try tmp.dir.realpathAlloc(allocator, "test.zig");
	defer allocator.free(abs_path);

	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();
	try runReplaceSymbol(allocator, abs_path, "hello", "pub fn hello() void { return; }\n", null, &out.writer);
	const output_text = try out.toOwnedSlice();
	defer allocator.free(output_text);

	// Should contain error about missing version
	try std.testing.expect(std.mem.indexOf(u8, output_text, "error: --version is required") != null);
	// File should NOT have been modified
	const after = try tmp.dir.readFileAlloc(allocator, "test.zig", 8192);
	defer allocator.free(after);
	try std.testing.expectEqualStrings(content, after);
}

test "runInsertAt rejects stale version" {
	const allocator = std.testing.allocator;

	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const content = "line one\nline two\nline three\n";
	try tmp.dir.writeFile(.{ .sub_path = "test.txt", .data = content });
	const abs_path = try tmp.dir.realpathAlloc(allocator, "test.txt");
	defer allocator.free(abs_path);

	// Compute version and hashline ref for line 2
	const current_version = (try hashline.computeFileVersion(allocator, content)).?;
	var lines_list = try splitLines(allocator, content);
	defer lines_list.deinit(allocator);
	const all_hashes = try hashline.computeChainHashes(allocator, lines_list.items);
	defer allocator.free(all_hashes);
	const ref_str = try std.fmt.allocPrint(allocator, "2:{s}", .{&all_hashes[1]});
	defer allocator.free(ref_str);

	// Modify the file externally
	try tmp.dir.writeFile(.{ .sub_path = "test.txt", .data = "modified\nline two\nline three\n" });

	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();
	try runInsertAt(allocator, abs_path, ref_str, "inserted line\n", &current_version, &out.writer);
	const output_text = try out.toOwnedSlice();
	defer allocator.free(output_text);

	try std.testing.expect(std.mem.indexOf(u8, output_text, "error: file modified since last read") != null);
}

test "runReplaceLines rejects stale version" {
	const allocator = std.testing.allocator;

	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const content = "line one\nline two\nline three\n";
	try tmp.dir.writeFile(.{ .sub_path = "test.txt", .data = content });
	const abs_path = try tmp.dir.realpathAlloc(allocator, "test.txt");
	defer allocator.free(abs_path);

	const current_version = (try hashline.computeFileVersion(allocator, content)).?;
	var lines_list = try splitLines(allocator, content);
	defer lines_list.deinit(allocator);
	const all_hashes = try hashline.computeChainHashes(allocator, lines_list.items);
	defer allocator.free(all_hashes);
	const from_str = try std.fmt.allocPrint(allocator, "1:{s}", .{&all_hashes[0]});
	defer allocator.free(from_str);
	const to_str = try std.fmt.allocPrint(allocator, "2:{s}", .{&all_hashes[1]});
	defer allocator.free(to_str);

	// Modify the file externally
	try tmp.dir.writeFile(.{ .sub_path = "test.txt", .data = "modified\nline two\nline three\n" });

	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();
	try runReplaceLines(allocator, abs_path, from_str, to_str, "replacement\n", &current_version, &out.writer);
	const output_text = try out.toOwnedSlice();
	defer allocator.free(output_text);

	try std.testing.expect(std.mem.indexOf(u8, output_text, "error: file modified since last read") != null);
}

test "runInsertAfter rejects stale version" {
	const allocator = std.testing.allocator;

	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const content = "pub fn hello() void {}\npub fn world() void {}\n";
	try tmp.dir.writeFile(.{ .sub_path = "test.zig", .data = content });
	const abs_path = try tmp.dir.realpathAlloc(allocator, "test.zig");
	defer allocator.free(abs_path);

	const current_version = (try hashline.computeFileVersion(allocator, content)).?;

	// Modify the file externally
	try tmp.dir.writeFile(.{ .sub_path = "test.zig", .data = "pub fn hello() void { return; }\npub fn world() void {}\n" });

	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();
	try runInsertAfter(allocator, abs_path, "hello", "// inserted\n", &current_version, &out.writer);
	const output_text = try out.toOwnedSlice();
	defer allocator.free(output_text);

	try std.testing.expect(std.mem.indexOf(u8, output_text, "error: file modified since last read") != null);
}

test "runInsertBefore rejects stale version" {
	const allocator = std.testing.allocator;

	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const content = "pub fn hello() void {}\npub fn world() void {}\n";
	try tmp.dir.writeFile(.{ .sub_path = "test.zig", .data = content });
	const abs_path = try tmp.dir.realpathAlloc(allocator, "test.zig");
	defer allocator.free(abs_path);

	const current_version = (try hashline.computeFileVersion(allocator, content)).?;

	// Modify the file externally
	try tmp.dir.writeFile(.{ .sub_path = "test.zig", .data = "pub fn hello() void { return; }\npub fn world() void {}\n" });

	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();
	try runInsertBefore(allocator, abs_path, "hello", "// inserted\n", &current_version, &out.writer);
	const output_text = try out.toOwnedSlice();
	defer allocator.free(output_text);

	try std.testing.expect(std.mem.indexOf(u8, output_text, "error: file modified since last read") != null);
}

test "runCreateFile creates new file with version" {
	const allocator = std.testing.allocator;

	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const abs_dir = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(abs_dir);
	const abs_path = try std.fs.path.join(allocator, &[_][]const u8{ abs_dir, "newfile.txt" });
	defer allocator.free(abs_path);

	const body = "hello world\nline two\n";
	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();
	try runCreateFile(allocator, abs_path, body, &out.writer);
	const output_text = try out.toOwnedSlice();
	defer allocator.free(output_text);

	// Should report Created with line count and version
	try std.testing.expect(std.mem.indexOf(u8, output_text, "Created") != null);
	try std.testing.expect(std.mem.indexOf(u8, output_text, "2 lines") != null);
	try std.testing.expect(std.mem.indexOf(u8, output_text, "version:") != null);

	// File should actually exist with correct content
	const written = try tmp.dir.readFileAlloc(allocator, "newfile.txt", 1024 * 1024);
	defer allocator.free(written);
	try std.testing.expectEqualStrings(body, written);
}

test "runCreateFile errors on existing file" {
	const allocator = std.testing.allocator;

	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	try tmp.dir.writeFile(.{ .sub_path = "existing.txt", .data = "existing content\n" });
	const abs_path = try tmp.dir.realpathAlloc(allocator, "existing.txt");
	defer allocator.free(abs_path);

	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();
	try runCreateFile(allocator, abs_path, "new content\n", &out.writer);
	const output_text = try out.toOwnedSlice();
	defer allocator.free(output_text);

	// Should report error about file already existing
	try std.testing.expect(std.mem.indexOf(u8, output_text, "error: file already exists") != null);

	// Original file should be unchanged
	const content = try tmp.dir.readFileAlloc(allocator, "existing.txt", 1024 * 1024);
	defer allocator.free(content);
	try std.testing.expectEqualStrings("existing content\n", content);
}

test "runDestroyFile rejects stale version" {
	const allocator = std.testing.allocator;

	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	try tmp.dir.writeFile(.{ .sub_path = "doomed.zig", .data = "original content\n" });
	const abs_path = try tmp.dir.realpathAlloc(allocator, "doomed.zig");
	defer allocator.free(abs_path);

	// Compute the correct version of the original file
	const original_source = try readFileContents(allocator, abs_path);
	defer allocator.free(original_source);
	const correct_version = try hashline.computeFileVersion(allocator, original_source) orelse
		return error.SkipZigTest;
	_ = correct_version;

	// Now modify the file so the version is stale
	try tmp.dir.writeFile(.{ .sub_path = "doomed.zig", .data = "modified content\n" });

	// Try to destroy with the old (now stale) version
	const stale_version = "000"; // arbitrary wrong version
	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();
	try runDestroyFile(allocator, abs_path, stale_version, &out.writer);
	const output_text = try out.toOwnedSlice();
	defer allocator.free(output_text);

	// Should print a version mismatch error
	try std.testing.expect(std.mem.indexOf(u8, output_text, "error: file modified since last read") != null);

	// File should still exist (not deleted)
	tmp.dir.access("doomed.zig", .{}) catch {
		return error.FileShouldStillExist;
	};
}

test "runDestroyFile moves file to trash (file no longer accessible)" {
	const allocator = std.testing.allocator;

	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const file_content = "bye bye\n";
	try tmp.dir.writeFile(.{ .sub_path = "to_delete.txt", .data = file_content });
	const abs_path = try tmp.dir.realpathAlloc(allocator, "to_delete.txt");
	defer allocator.free(abs_path);

	// Compute version so --version requirement is satisfied
	const file_version = (try hashline.computeFileVersion(allocator, file_content)).?;

	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();
	try runDestroyFile(allocator, abs_path, &file_version, &out.writer);
	const output_text = try out.toOwnedSlice();
	defer allocator.free(output_text);

	// Should report success or warning (not an error)
	try std.testing.expect(std.mem.indexOf(u8, output_text, "error: cannot read file") == null);
	try std.testing.expect(std.mem.indexOf(u8, output_text, "Moved") != null or
		std.mem.indexOf(u8, output_text, "warning:") != null);

	// File should no longer be accessible at the original path
	const still_exists = if (std.fs.cwd().access(abs_path, .{})) |_| true else |_| false;
	try std.testing.expect(!still_exists);
}

test "runDestroyFile errors when file does not exist" {
	const allocator = std.testing.allocator;

	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const abs_path = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(abs_path);
	const nonexistent = try std.fs.path.join(allocator, &.{ abs_path, "ghost.txt" });
	defer allocator.free(nonexistent);

	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();
	try runDestroyFile(allocator, nonexistent, null, &out.writer);
	const output_text = try out.toOwnedSlice();
	defer allocator.free(output_text);

	try std.testing.expect(std.mem.indexOf(u8, output_text, "error:") != null);
}

test "runRegexSearch finds matches with correct line numbers" {
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	// Create a source file in the tmp dir
	{
		const f = try tmp.dir.createFile("hello.zig", .{});
		defer f.close();
		try f.writeAll("const std = @import(\"std\");\nfn hello() void {}\nfn world() void {}\n");
	}

	// Create DB
	try tmp.dir.makePath(".codescan");
	const root_path = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(root_path);
	const db_path = try std.fmt.allocPrint(allocator, "{s}/.codescan/index.sqlite3", .{root_path});
	defer allocator.free(db_path);

	const db = try storage.openFileWithVec(allocator, db_path);
	defer storage.close(db);
	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });
	try storage.upsertIndexedFile(db, "hello.zig", 0, 0);

	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	try runRegexSearch(
		allocator, db, "fn \\w+\\(\\)", 0, 20,
		&[_][]const u8{}, null, false,
		plugin.defaultRegistry(), root_path, .json, &out.writer, false,
	);
	const result = try out.toOwnedSlice();
	defer allocator.free(result);

	// Should find both fn declarations
	try std.testing.expect(std.mem.indexOf(u8, result, "\"total_matches\":2") != null);
	try std.testing.expect(std.mem.indexOf(u8, result, "\"line\":2") != null);
	try std.testing.expect(std.mem.indexOf(u8, result, "\"line\":3") != null);
}

test "runRegexSearch context lines shows surrounding lines" {
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	{
		const f = try tmp.dir.createFile("ctx.zig", .{});
		defer f.close();
		try f.writeAll("line1\nline2\nTARGET\nline4\nline5\n");
	}

	try tmp.dir.makePath(".codescan");
	const root_path = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(root_path);
	const db_path = try std.fmt.allocPrint(allocator, "{s}/.codescan/index.sqlite3", .{root_path});
	defer allocator.free(db_path);

	const db = try storage.openFileWithVec(allocator, db_path);
	defer storage.close(db);
	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });
	try storage.upsertIndexedFile(db, "ctx.zig", 0, 0);

	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	// context_lines=5 means 2 before + match + 2 after
	try runRegexSearch(
		allocator, db, "TARGET", 5, 20,
		&[_][]const u8{}, null, false,
		plugin.defaultRegistry(), root_path, .json, &out.writer, false,
	);
	const result = try out.toOwnedSlice();
	defer allocator.free(result);

	// Should have context lines
	try std.testing.expect(std.mem.indexOf(u8, result, "\"context\":[") != null);
	try std.testing.expect(std.mem.indexOf(u8, result, "line1") != null);
	try std.testing.expect(std.mem.indexOf(u8, result, "line2") != null);
	try std.testing.expect(std.mem.indexOf(u8, result, "TARGET") != null);
	try std.testing.expect(std.mem.indexOf(u8, result, "line4") != null);
	try std.testing.expect(std.mem.indexOf(u8, result, "line5") != null);
	try std.testing.expect(std.mem.indexOf(u8, result, "\"is_match\":true") != null);
}

test "runRegexSearch path filter restricts files" {
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	try tmp.dir.makePath("src");
	try tmp.dir.makePath("lib");

	{
		const f = try tmp.dir.createFile("src/a.zig", .{});
		defer f.close();
		try f.writeAll("fn alpha() void {}\n");
	}
	{
		const f = try tmp.dir.createFile("lib/b.zig", .{});
		defer f.close();
		try f.writeAll("fn beta() void {}\n");
	}

	try tmp.dir.makePath(".codescan");
	const root_path = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(root_path);
	const db_path = try std.fmt.allocPrint(allocator, "{s}/.codescan/index.sqlite3", .{root_path});
	defer allocator.free(db_path);

	const db = try storage.openFileWithVec(allocator, db_path);
	defer storage.close(db);
	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });
	try storage.upsertIndexedFile(db, "src/a.zig", 0, 0);
	try storage.upsertIndexedFile(db, "lib/b.zig", 0, 0);

	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	const path_filter: []const u8 = "src/*";
	try runRegexSearch(
		allocator, db, "fn \\w+", 0, 20,
		&[_][]const u8{path_filter}, null, false,
		plugin.defaultRegistry(), root_path, .json, &out.writer, false,
	);
	const result = try out.toOwnedSlice();
	defer allocator.free(result);

	// Should find alpha but not beta
	try std.testing.expect(std.mem.indexOf(u8, result, "alpha") != null);
	try std.testing.expect(std.mem.indexOf(u8, result, "beta") == null);
}

test "runRegexSearch invalid regex returns error message" {
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	try tmp.dir.makePath(".codescan");
	const root_path = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(root_path);
	const db_path = try std.fmt.allocPrint(allocator, "{s}/.codescan/index.sqlite3", .{root_path});
	defer allocator.free(db_path);

	const db = try storage.openFileWithVec(allocator, db_path);
	defer storage.close(db);
	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	try runRegexSearch(
		allocator, db, "[invalid(", 0, 20,
		&[_][]const u8{}, null, false,
		plugin.defaultRegistry(), root_path, .json, &out.writer, false,
	);
	const result = try out.toOwnedSlice();
	defer allocator.free(result);

	try std.testing.expect(std.mem.indexOf(u8, result, "error") != null);
	try std.testing.expect(std.mem.indexOf(u8, result, "invalid regex") != null);
}

test "runRegexSearch include_body shows full symbol body" {
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	// Create a source file with a clearly-delimited function
	{
		const f = try tmp.dir.createFile("body_test.zig", .{});
		defer f.close();
		try f.writeAll("// preamble\npub fn myFunc() void {\n    const x = 42;\n    _ = x;\n}\n// epilogue\n");
	}

	try tmp.dir.makePath(".codescan");
	const root_path = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(root_path);
	const db_path = try std.fmt.allocPrint(allocator, "{s}/.codescan/index.sqlite3", .{root_path});
	defer allocator.free(db_path);

	const db = try storage.openFileWithVec(allocator, db_path);
	defer storage.close(db);
	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });
	try storage.upsertIndexedFile(db, "body_test.zig", 0, 0);

	// Insert symbol spanning lines 2-5 (1-indexed)
	var sym = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "body_test.zig"),
		.name = try allocator.dupe(u8, "myFunc"),
		.signature = try allocator.dupe(u8, "pub fn myFunc() void"),
		.doc_comment = null,
		.start_line = 2,
		.end_line = 5,
	};
	defer sym.deinit(allocator);
	_ = try storage.insertSymbol(db, sym);

	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	// Search for something inside the function body with include_body = true
	try runRegexSearch(
		allocator, db, "const x = 42", 0, 20,
		&[_][]const u8{}, null, false,
		plugin.defaultRegistry(), root_path, .json, &out.writer, true,
	);
	const result = try out.toOwnedSlice();
	defer allocator.free(result);

	// Should include body object with symbol name and full body lines
	try std.testing.expect(std.mem.indexOf(u8, result, "\"body\"") != null);
	try std.testing.expect(std.mem.indexOf(u8, result, "\"myFunc\"") != null);
	// Body should include the function opener and closer
	try std.testing.expect(std.mem.indexOf(u8, result, "pub fn myFunc") != null);
	try std.testing.expect(std.mem.indexOf(u8, result, "}") != null);
}
