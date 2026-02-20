const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const config = @import("config.zig");
const storage = @import("storage.zig");
const embedding = @import("embedding.zig");
const ollama = @import("ollama.zig");
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
const lsp = @import("lsp.zig");
const pcre2 = @import("pcre2.zig");
const watcher = @import("watcher.zig");
const pidfile = @import("pidfile.zig");
const fs_watch = @import("fs_watch.zig");
const weights = @import("weights.zig");

/// File-scope atomic flag for POSIX signal handlers (which cannot capture closures).
var g_stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

const Defaults = struct {
	output: cli.OutputFormat = .human,
	top_n: usize = 5,
	root_path: []const u8 = ".",
	db_path: []const u8 = ".codescan/index.sqlite3",
	ollama_url: []const u8 = "http://localhost:11434",
	ollama_model: []const u8 = "bge-large",
	embedding_dim: usize = 1024,
	batch_size: usize = 16,
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
	ollama_url: []const u8,
	ollama_model: []const u8,
	ollama_model_owned: bool,
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
	primary_lang: ?[]const u8,
	ignore_global: []const []const u8,
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

	var stdout_buf: [4096]u8 = undefined;
	var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
	const stdout = &stdout_writer.interface;

	var parsed = cli.parse(allocator, args) catch |err| {
		if (isUsageError(err)) {
			var stderr_buf: [4096]u8 = undefined;
			var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
			const stderr = &stderr_writer.interface;
			_ = stderr.print("error: {s}\n\n", .{usageErrorMessage(err)}) catch {};
			_ = printUsage(stderr) catch {};
			_ = stderr.flush() catch {};
			std.process.exit(64);
		}
		return err;
	};
	defer parsed.deinit(allocator);

	if (parsed.command == .help) {
		try printUsage(stdout);
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
	defer if (settings.ollama_model_owned) allocator.free(settings.ollama_model);

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

			// Open DB and init schema
			const db = try storage.openFileWithVec(allocator, settings.db_path);
			defer storage.close(db);
			_ = try storage.initSchema(allocator, db, .{ .embedding_dim = settings.embedding_dim });

			// Try Ollama; fall back to lexical-only if unavailable
			var http_client = ollama.StdHttpTransport.init(allocator);
			defer http_client.deinit();
			const ollama_ok = tryInitOllama(allocator, &http_client, settings.ollama_url, settings.ollama_model, stderr);

			var embedder_adapter = embedding.OllamaEmbedder{
				.transport = http_client.transport(),
				.base_url = settings.ollama_url,
				.model = settings.ollama_model,
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
			try ensureParentDir(settings.db_path);
			const db = try storage.openFileWithVecRecreate(allocator, settings.db_path);
			defer storage.close(db);

			var http_client = ollama.StdHttpTransport.init(allocator);
			defer http_client.deinit();
			try ensureModelAvailableOrExit(allocator, http_client.transport(), settings.ollama_url, settings.ollama_model);
			var embedder_adapter = embedding.OllamaEmbedder{
				.transport = http_client.transport(),
				.base_url = settings.ollama_url,
				.model = settings.ollama_model,
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
					.batch_size = settings.batch_size,
					.max_file_size = settings.max_file_size,
					.allowed_exts = index_filters.exts.items,
					.allowed_kinds = index_filters.kinds.items,
					.ignore = .{
						.global = settings.ignore_global,
						.per_language = settings.ignore_lang,
						.include_node_modules = settings.include_node_modules,
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
			try ensureParentDir(settings.db_path);
			const db = try storage.openFileWithVec(allocator, settings.db_path);
			defer storage.close(db);

			var http_client = ollama.StdHttpTransport.init(allocator);
			defer http_client.deinit();
			try ensureModelAvailableOrExit(allocator, http_client.transport(), settings.ollama_url, settings.ollama_model);
			var embedder_adapter = embedding.OllamaEmbedder{
				.transport = http_client.transport(),
				.base_url = settings.ollama_url,
				.model = settings.ollama_model,
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
					.batch_size = settings.batch_size,
					.max_file_size = settings.max_file_size,
					.allowed_exts = index_filters.exts.items,
					.allowed_kinds = index_filters.kinds.items,
					.ignore = .{
						.global = settings.ignore_global,
						.per_language = settings.ignore_lang,
						.include_node_modules = settings.include_node_modules,
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
			const query = parsed.query orelse return error.MissingQuery;
			try ensureParentDir(settings.db_path);
			const db = try storage.openFileWithVec(allocator, settings.db_path);
			defer storage.close(db);

			var stderr_buf: [4096]u8 = undefined;
			var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
			const stderr = &stderr_writer.interface;

			var http_client = ollama.StdHttpTransport.init(allocator);
			defer http_client.deinit();

			// Track whether we should use lexical-only (Ollama unavailable)
			var effective_search_mode = settings.search_mode;
			var did_auto_index = false;

			// Auto-index if DB is empty
			if (!storage.isIndexPopulated(db)) {
				_ = stderr.print("note: No index found. Setting up codescan for this project...\n", .{}) catch {};
				_ = stderr.flush() catch {};

				// Try Ollama; fall back to lexical if unavailable
				const ollama_ok = tryInitOllama(allocator, &http_client, settings.ollama_url, settings.ollama_model, stderr);
				if (!ollama_ok) {
					effective_search_mode = .lexical;
				}

				var embedder_adapter = embedding.OllamaEmbedder{
					.transport = http_client.transport(),
					.base_url = settings.ollama_url,
					.model = settings.ollama_model,
				};

				// Need to init schema before indexing into a fresh DB
				_ = try storage.initSchema(allocator, db, .{ .embedding_dim = settings.embedding_dim });

				_ = try performFullIndex(
					allocator,
					db,
					settings,
					registry,
					embedder_adapter.embedder(),
					stderr,
					shouldShowProgress(std.fs.File.stderr().isTty(), settings.output),
				);
				did_auto_index = true;
			} else {
				// Normal path: ensure Ollama if needed
				if (effective_search_mode != .lexical) {
					try ensureModelAvailableOrExit(allocator, http_client.transport(), settings.ollama_url, settings.ollama_model);
				}
			}

			var embedder_adapter = embedding.OllamaEmbedder{
				.transport = http_client.transport(),
				.base_url = settings.ollama_url,
				.model = settings.ollama_model,
			};

			var search_filters = try filters.buildSearchFilters(allocator, registry, db, .{
				.search_ext = settings.search_ext,
				.search_type = settings.search_type,
				.search_lang = settings.search_lang,
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

			const sr = try search.search(
				allocator,
				db,
				embedder_adapter.embedder(),
				query,
				.{
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
					.comments_only = settings.comments_only,
				},
			);
			defer search.freeResults(allocator, sr.results);

			if (sr.results.len == 0) {
				const codescan_dir = std.fs.path.dirname(settings.db_path) orelse ".codescan";
				if (pidfile.isWatcherRunning(allocator, codescan_dir)) {
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

			const use_color = settings.output == .human and !std.process.hasEnvVarConstant("NO_COLOR");
			try output.writeResults(allocator, stdout, settings.output, sr.results, .{
				.show_comments = settings.show_comments,
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
				.ollama_url = settings.ollama_url,
				.ollama_model = settings.ollama_model,
				.index_ext = settings.index_ext,
				.index_type = settings.index_type,
				.search_ext = settings.search_ext,
				.search_type = settings.search_type,
				.search_lang = settings.search_lang,
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
			const file_path = if (parsed.symbols_files.items.len > 0) parsed.symbols_files.items[0] else
				exitWithError("error: replace-symbol requires --file <path>\n");
			const input_text = try readStdin(allocator);
			defer allocator.free(input_text);
			try runReplaceSymbol(allocator, file_path, pattern, input_text, stdout);
			tryReindexFile(allocator, settings.db_path, settings.root_path, file_path, registry);
			try stdout.flush();
		},
		.insert_after => {
			const pattern = parsed.pattern orelse
				exitWithError("error: insert-after requires a name path\nusage: echo 'code' | codescan insert-after <name_path> --file <path>\n");
			const file_path = if (parsed.symbols_files.items.len > 0) parsed.symbols_files.items[0] else
				exitWithError("error: insert-after requires --file <path>\n");
			const input_text = try readStdin(allocator);
			defer allocator.free(input_text);
			try runInsertAfter(allocator, file_path, pattern, input_text, stdout);
			tryReindexFile(allocator, settings.db_path, settings.root_path, file_path, registry);
			try stdout.flush();
		},
		.insert_before => {
			const pattern = parsed.pattern orelse
				exitWithError("error: insert-before requires a name path\nusage: echo 'code' | codescan insert-before <name_path> --file <path>\n");
			const file_path = if (parsed.symbols_files.items.len > 0) parsed.symbols_files.items[0] else
				exitWithError("error: insert-before requires --file <path>\n");
			const input_text = try readStdin(allocator);
			defer allocator.free(input_text);
			try runInsertBefore(allocator, file_path, pattern, input_text, stdout);
			tryReindexFile(allocator, settings.db_path, settings.root_path, file_path, registry);
			try stdout.flush();
		},
		.replace_lines => {
			const file_path = if (parsed.symbols_files.items.len > 0) parsed.symbols_files.items[0] else
				exitWithError("error: replace-lines requires --file <path>\n");
			const from_ref = parsed.from_ref orelse
				exitWithError("error: replace-lines requires --from <line:hash>\n");
			const to_ref = parsed.to_ref orelse
				exitWithError("error: replace-lines requires --to <line:hash>\n");
			const input_text = try readStdin(allocator);
			defer allocator.free(input_text);
			try runReplaceLines(allocator, file_path, from_ref, to_ref, input_text, stdout);
			tryReindexFile(allocator, settings.db_path, settings.root_path, file_path, registry);
			try stdout.flush();
		},
		.insert_at => {
			const file_path = if (parsed.symbols_files.items.len > 0) parsed.symbols_files.items[0] else
				exitWithError("error: insert-at requires --file <path>\n");
			const ref = parsed.hashline_ref orelse
				exitWithError("error: insert-at requires a hashline ref\nusage: echo 'code' | codescan insert-at <line:hash> --file <path>\n");
			const input_text = try readStdin(allocator);
			defer allocator.free(input_text);
			try runInsertAt(allocator, file_path, ref, input_text, stdout);
			tryReindexFile(allocator, settings.db_path, settings.root_path, file_path, registry);
			try stdout.flush();
		},
		.replace_content => {
			const needle = parsed.pattern orelse
				exitWithError("error: replace-content requires a pattern\n" ++
					"usage: echo 'replacement' | codescan replace-content '<needle>' --file <path> [--regex] [--all]\n");
			const file_path = if (parsed.symbols_files.items.len > 0) parsed.symbols_files.items[0] else
				exitWithError("error: replace-content requires --file <path>\n");
			const input_text = try readStdin(allocator);
			defer allocator.free(input_text);
			try runReplaceContent(allocator, file_path, needle, parsed.regex_mode, parsed.replace_all, input_text, stdout);
			tryReindexFile(allocator, settings.db_path, settings.root_path, file_path, registry);
			try stdout.flush();
		},
		.references => {
			const pattern = parsed.pattern orelse
				exitWithError("error: references requires a name path pattern\nusage: codescan references <pattern> --file <path>\n");
			const file_path = if (parsed.symbols_files.items.len > 0) parsed.symbols_files.items[0] else
				exitWithError("error: references requires --file <path>\n");
			try runReferences(allocator, file_path, pattern, parsed.output, settings.root_path, settings.lsp_overrides, stdout);
			try stdout.flush();
		},
		.rename => {
			const pattern = parsed.pattern orelse
				exitWithError("error: rename requires a name path pattern\nusage: codescan rename <pattern> --file <path> --to <new_name>\n");
			const file_path = if (parsed.symbols_files.items.len > 0) parsed.symbols_files.items[0] else
				exitWithError("error: rename requires --file <path>\n");
			const new_name = parsed.rename_to orelse
				exitWithError("error: rename requires --to <new_name>\n");
			try runRename(allocator, file_path, pattern, new_name, parsed.output, parsed.dry_run, settings.db_path, settings.root_path, registry, settings.lsp_overrides, stdout);
			try stdout.flush();
		},
		.mcp_serve => {
			const mcp = @import("mcp.zig");
			try mcp.serve(allocator, .{
				.root_path = settings.root_path,
				.db_path = settings.db_path,
				.lsp_overrides = settings.lsp_overrides,
				.ollama_url = settings.ollama_url,
				.ollama_model = settings.ollama_model,
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
				.primary_lang = settings.primary_lang,
				.include_docs = settings.include_docs,
				.docs_only = settings.docs_only,
				.comments_only = settings.comments_only,
				.ignore_global = settings.ignore_global,
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
				.run => {
					try ensureParentDir(settings.db_path);
					// Open existing DB or create new one (don't destroy existing index)
					const db = try storage.openFileWithVec(allocator, settings.db_path);
					defer storage.close(db);

					var http_client = ollama.StdHttpTransport.init(allocator);
					defer http_client.deinit();
					try ensureModelAvailableOrExit(allocator, http_client.transport(), settings.ollama_url, settings.ollama_model);
					var embedder_adapter = embedding.OllamaEmbedder{
						.transport = http_client.transport(),
						.base_url = settings.ollama_url,
						.model = settings.ollama_model,
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
								.batch_size = settings.batch_size,
								.max_file_size = settings.max_file_size,
								.allowed_exts = index_filters.exts.items,
								.allowed_kinds = index_filters.kinds.items,
								.ignore = .{
									.global = settings.ignore_global,
									.per_language = settings.ignore_lang,
									.include_node_modules = settings.include_node_modules,
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
		.clean => {
			const codescan_dir = std.fs.path.dirname(settings.db_path) orelse ".codescan";

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
		.ollama_url = defaults.ollama_url,
		.ollama_model = defaults.ollama_model,
		.ollama_model_owned = false,
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
		.primary_lang = null,
		.ignore_global = &[_][]const u8{},
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
	if (cfg.ollama_url) |value| settings.ollama_url = value;
	if (cfg.ollama_model) |value| settings.ollama_model = value;
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
	if (cfg.primary_lang) |value| settings.primary_lang = value;
	if (cfg.include_docs) |value| settings.include_docs = value;
	if (cfg.docs_only) |value| settings.docs_only = value;
	if (cfg.comments_only) |value| settings.comments_only = value;
	if (cfg.include_node_modules) |value| settings.include_node_modules = value;
	settings.ignore_global = cfg.ignore_global.items;
	settings.ignore_lang = cfg.ignore_lang.items;
	settings.lsp_overrides = cfg.lsp_overrides.items;
	if (cfg.http_host) |value| settings.http_host = value;
	if (cfg.http_port) |value| settings.http_port = value;

	if (env_model) |value| {
		settings.ollama_model = value;
		settings.ollama_model_owned = true;
	}

	if (parsed.seen.output) settings.output = parsed.output;
	if (parsed.seen.show_comments) settings.show_comments = parsed.show_comments;
	if (parsed.seen.top_n) settings.top_n = parsed.top_n;
	if (parsed.seen.root_path) settings.root_path = parsed.root_path;
	if (parsed.seen.db_path) settings.db_path = parsed.db_path;
	if (parsed.seen.ollama_url) settings.ollama_url = parsed.ollama_url;
	if (parsed.seen.ollama_model) {
		if (settings.ollama_model_owned) {
			allocator.free(settings.ollama_model);
			settings.ollama_model_owned = false;
		}
		settings.ollama_model = parsed.ollama_model;
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
	if (parsed.seen.http_host) settings.http_host = parsed.http_host;
	if (parsed.seen.http_port) settings.http_port = parsed.http_port;

	// --comments / --only-comments implies --show-comments
	if (settings.comments_only) settings.show_comments = true;

	if (!std.fs.path.isAbsolute(settings.db_path) and !std.mem.eql(u8, settings.root_path, ".")) {
		settings.db_path = try std.fs.path.join(allocator, &.{ settings.root_path, settings.db_path });
		settings.db_path_owned = true;
	}

	return settings;
}

fn ensureModelAvailableOrExit(
	allocator: std.mem.Allocator,
	transport: ollama.Transport,
	base_url: []const u8,
	model_name: []const u8,
) !void {
	ollama.ensureModelAvailable(allocator, transport, base_url, model_name) catch |err| switch (err) {
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
		else => return err,
	};
}

fn shouldShowProgress(is_tty: bool, out_format: cli.OutputFormat) bool {
	return is_tty and out_format == .human;
}

/// Tries to connect to Ollama and ensure the model is available.
/// Returns whether Ollama is available. On failure, prints a warning to stderr.
fn tryInitOllama(
	allocator: std.mem.Allocator,
	http_client: *ollama.StdHttpTransport,
	ollama_url: []const u8,
	ollama_model: []const u8,
	stderr: *std.Io.Writer,
) bool {
	ollama.ensureModelAvailable(
		allocator,
		http_client.transport(),
		ollama_url,
		ollama_model,
	) catch |err| {
		switch (err) {
			error.ModelNotFound => {
				_ = stderr.print(
					"  note: Ollama model '{s}' not found. Using lexical-only search.\n" ++
						"  Run 'ollama pull {s}' then 'codescan update' for semantic search.\n",
					.{ ollama_model, ollama_model },
				) catch {};
			},
			else => {
				_ = stderr.print(
					"  note: Ollama not available. Using lexical-only search.\n" ++
						"  Run 'codescan update' after starting Ollama for semantic search.\n",
					.{},
				) catch {};
			},
		}
		_ = stderr.flush() catch {};
		return false;
	};
	return true;
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
			.batch_size = settings.batch_size,
			.max_file_size = settings.max_file_size,
			.allowed_exts = index_filters.exts.items,
			.allowed_kinds = index_filters.kinds.items,
			.ignore = .{
				.global = settings.ignore_global,
				.per_language = settings.ignore_lang,
				.include_node_modules = settings.include_node_modules,
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
	if (pidfile.isWatcherRunning(allocator, codescan_dir)) return;

	// Find our own binary
	const self_exe = std.fs.selfExePathAlloc(allocator) catch return;
	defer allocator.free(self_exe);

	// Spawn: codescan watch --root <path>
	var child = std.process.Child.init(
		&.{ self_exe, "watch", "--root", settings.root_path },
		allocator,
	);
	child.stdin_behavior = .Close;
	child.stdout_behavior = .Close;
	child.stderr_behavior = .Close;

	child.spawn() catch return;

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
	return std.fs.path.join(allocator, &.{ root_path, ".codescan", "config" });
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
fn tryReindexFile(allocator: std.mem.Allocator, db_path: []const u8, root_path: []const u8, file_path: []const u8, registry: plugin.Registry) void {
	var stderr_buf: [4096]u8 = undefined;
	var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
	const stderr = &stderr_writer.interface;

	const db = storage.openFileWithVec(allocator, db_path) catch |err| {
		_ = stderr.print("warning: reindex skipped (could not open index): {}\n", .{err}) catch {};
		_ = stderr.flush() catch {};
		return;
	};
	defer storage.close(db);
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

// ─── Editing Command Implementations ─────────────────────────────────

pub fn runReplaceSymbol(allocator: std.mem.Allocator, file_path: []const u8, pattern: []const u8, input_text: []const u8, writer: *std.Io.Writer) !void {
	const result = try extractFileAndTree(allocator, file_path);
	var tree = result.tree;
	defer tree.deinit(allocator);
	defer allocator.free(result.source);

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
}

pub fn runInsertAfter(allocator: std.mem.Allocator, file_path: []const u8, pattern: []const u8, input_text: []const u8, writer: *std.Io.Writer) !void {
	const result = try extractFileAndTree(allocator, file_path);
	var tree = result.tree;
	defer tree.deinit(allocator);
	defer allocator.free(result.source);

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
}

pub fn runInsertBefore(allocator: std.mem.Allocator, file_path: []const u8, pattern: []const u8, input_text: []const u8, writer: *std.Io.Writer) !void {
	const result = try extractFileAndTree(allocator, file_path);
	var tree = result.tree;
	defer tree.deinit(allocator);
	defer allocator.free(result.source);

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
}

pub fn runReplaceLines(allocator: std.mem.Allocator, file_path: []const u8, from_str: []const u8, to_str: []const u8, input_text: []const u8, writer: *std.Io.Writer) !void {
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
}

pub fn runInsertAt(allocator: std.mem.Allocator, file_path: []const u8, ref_str: []const u8, input_text: []const u8, writer: *std.Io.Writer) !void {
	const ref = parseHashlineRef(ref_str) catch {
		try writer.print("error: invalid hashline ref '{s}' (expected format: line:hash, e.g. 47:3bw)\n", .{ref_str});
		return;
	};

	const source = try readFileContents(allocator, file_path);
	defer allocator.free(source);

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
}

pub fn runReplaceContent(allocator: std.mem.Allocator, file_path: []const u8, needle: []const u8, regex_mode: bool, replace_all: bool, input_text: []const u8, writer: *std.Io.Writer) !void {
	// Strip trailing newline from replacement (stdin usually adds one)
	const repl = if (input_text.len > 0 and input_text[input_text.len - 1] == '\n')
		input_text[0 .. input_text.len - 1]
	else
		input_text;

	const source = try readFileContents(allocator, file_path);
	defer allocator.free(source);

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
		if (match_count > 1 and !replace_all) {
			try writer.print("error: found {d} matches; use --all to replace all, or refine your pattern\n", .{match_count});
			return;
		}

		// Perform substitution
		const result = re.substituteOwned(allocator, source, repl, replace_all) catch {
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
		if (match_count > 1 and !replace_all) {
			try writer.print("error: found {d} matches; use --all to replace all, or refine your pattern\n", .{match_count});
			return;
		}

		// Build result by splicing
		const positions = if (replace_all) match_positions.items else match_positions.items[0..1];
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
			tryReindexFile(allocator, db_path, root_path, path, registry);
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
	\\  init [--force]           Initialize codescan for this project
	\\  config [show|edit]       Show or edit project config
	\\  index                    Index codebase
	\\  update                   Incremental index (only new/modified/deleted)
	\\  watch                    Watch for changes and re-index continuously
	\\    watch start            Start watcher as background daemon
	\\    watch stop             Stop background watcher
	\\    watch restart          Restart background watcher
	\\    watch status           Show watcher status
	\\    watch pid              Print watcher PID
	\\  search <query>           Search indexed codebase (query is an alias)
	\\  symbols [pattern]         List or find symbols (across files, or all if no --file)
	\\                           find-symbol is an alias for symbols
	\\  replace-symbol <pattern> Replace a symbol's body (from stdin)
	\\  insert-after <pattern>   Insert code after a symbol (from stdin)
	\\  insert-before <pattern>  Insert code before a symbol (from stdin)
	\\  replace-lines            Replace a range of lines (from stdin)
	\\  insert-at <line:hash>    Insert code after a line (from stdin)
	\\  replace-content <needle> Replace matching content (from stdin)
	\\  references <pattern>    Find all references via LSP
	\\  rename <pattern>        Rename symbol across codebase via LSP
	\\  serve                    Start HTTP API server
	\\  mcp-serve                Start MCP (Model Context Protocol) server
	\\  status                   Show index and watcher status
	\\  clean, clear              Stop watcher and remove all codescan data (.codescan/)
	\\                           Requires confirmation (interactive prompt or --confirm)
	\\
	\\If no command is specified, codescan assumes `search`.
	\\
	\\Name path patterns (for symbols, replace-symbol, insert-*):
	\\  init                     Match any symbol named 'init'
	\\  MyStruct/init            Match suffix of name path
	\\  /MyStruct/init           Match exact full name path
	\\
	\\Hashlines:
	\\  Every line reference includes a 3-char chain hash (e.g. 45:r2p).
	\\  Each hash depends on the line's content AND the previous line's hash,
	\\  so any edit above cascades through all subsequent hashes. This means
	\\  a stale reference (from a prior read) will fail with a mismatch error
	\\  rather than silently editing the wrong line. Re-read the file to get
	\\  current hashes before retrying.
	\\
	\\  Hashline format:  <line>:<hash>  (e.g. 45:r2p)
	\\  Hash alphabet:    0-9 a-z (base-36, 46656 values, no case ambiguity)
	\\  Used by:          replace-lines --from/--to, insert-at, symbols output
	\\
	\\Editing options:
	\\  --file <path>            Target file (repeatable for symbols; editing/LSP commands)
	\\  --from <line:hash>       Start of line range (replace-lines)
	\\  --to <line:hash>         End of line range (replace-lines) / new name (rename)
	\\  --include-body           Include source body with hashlines
	\\  --regex                  Treat needle as PCRE2 regex (replace-content)
	\\  --all                    Replace all occurrences (replace-content)
	\\
	\\Supported languages:
	\\  Symbol extraction: Zig, C/C++, TypeScript/JavaScript, Rust, Elixir,
	\\    Bash, Lua, Nix, Nim, Lean, Idris, Haskell, Go, Ruby, Erlang,
	\\    OCaml, Swift, LLVM IR, Clojure, Assembly
	\\  LSP (references, rename): all of the above
	\\  Indexing/search: any text file (Markdown, logs, plain text, etc.)
	\\  Extensionless scripts with shebangs (#!/usr/bin/env bash, etc.)
	\\  are auto-detected for bash, lua, node/deno/bun, and ruby.
	\\
	\\LSP commands (references, rename):
	\\  Lazy-start a language server for the file's language.
	\\  Requires the appropriate server on PATH (zls, rust-analyzer,
	\\  clangd, typescript-language-server, gopls, elixir-ls, etc.)
	\\
	\\Options:
	\\  --root <path>                   Root path (default: nearest .codescan ancestor or .)
	\\  --db <path>                     DB path (default .codescan/index.sqlite3)
	\\  --ollama-url <url>              Ollama base URL (default http://localhost:11434)
	\\  --ollama-model <name>           Embedding model (default bge-large or $OLLAMA_MODEL)
	\\  --embedding-dim <n>             Embedding dimension (default 1024)
	\\  --batch <n>                     Embedding batch size (default 16)
	\\  --max-file-size <n>             Max file size bytes (default 5242880)
	\\  --top <n>                       Search top N (default 5)
	\\  --mode <vector|lexical|hybrid>  Search mode (default hybrid)
	\\  --fusion <weighted_sum|rrf>     Hybrid fusion method (default weighted_sum)
	\\  --rrf-k <n>                     RRF smoothing constant (default 60)
	\\  --fts-mode <broad|balanced|strict>  FTS query mode (default broad)
	\\  --weight-vector <n>             Hybrid weight for vector score (default 0.7)
	\\  --weight-lexical <n>            Hybrid weight for lexical score (default 0.3)
	\\  --min-score <n>                 Minimum score threshold (default 0.0)
	\\  --ext <csv>                     Restrict to extensions (comma-separated)
	\\  --type <csv>                    Restrict to types: code,doc,text,log
	\\  --lang <csv>                    Restrict search to languages:
	\\                                    zig, c, typescript, rust, elixir, bash, lua,
	\\                                    nix, nim, lean, idris, haskell, go, ruby,
	\\                                    erlang, ocaml, swift, llvm, clojure, assembly,
	\\                                    markdown, text, log
	\\  --include-docs                  Include markdown/README when defaulting to primary language
	\\  --docs, --only-docs             Only return markdown/README results
	\\  --comments, --only-comments     Only return doc-comment results
	\\  --include-node-modules          Include node_modules during indexing
	\\  --http-host <host>              HTTP host (default 127.0.0.1)
	\\  --http-port <port>              HTTP port (default 8123)
	\\  --show-comments, --verbose      Show doc comments in human output (default: hidden)
	\\  --interval <ms>                 Watch poll interval milliseconds (default 2000)
	\\  --json                          JSON output for CLI search/index
	\\  --confirm, -y                   Skip confirmation prompt (for clean/clear)
	\\  -h, --help                      Show help
	\\
;

fn isUsageError(err: anyerror) bool {
	return err == error.MissingQuery or
		err == error.UnknownCommand or
		err == error.MissingValue or
		err == error.InvalidMode or
		err == error.UnexpectedArg or
		err == error.TooManyArgs or
		err == error.InvalidNumber;
}

fn usageErrorMessage(err: anyerror) []const u8 {
	if (err == error.MissingQuery) return "missing search query";
	if (err == error.UnknownCommand) return "unknown command";
	if (err == error.MissingValue) return "missing required value";
	if (err == error.InvalidMode) return "invalid mode";
	if (err == error.UnexpectedArg) return "unexpected argument";
	if (err == error.TooManyArgs) return "too many arguments";
	if (err == error.InvalidNumber) return "invalid number";
	return "invalid usage";
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

	if (format == .json) {
		try writeStatusJson(writer, root_path, db_path, db_size, watcher_pid, file_count, symbol_count, embedding_count, comment_embedding_count, lang_stats, last_indexed);
	} else {
		try writeStatusHuman(writer, root_path, db_path, db_size, watcher_pid, file_count, symbol_count, embedding_count, comment_embedding_count, lang_stats, last_indexed);
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
		try writer.print("Watcher:    running (PID {d})\n", .{pid});
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
		@as(u32, @intFromEnum(md.month)) + 1,
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

fn printUsage(writer: *std.Io.Writer) !void {
	try writer.writeAll(usage);
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
