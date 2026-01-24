const std = @import("std");
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

const Defaults = struct {
	output: cli.OutputFormat = .human,
	top_n: usize = 10,
	root_path: []const u8 = ".",
	db_path: []const u8 = ".codescan/index.sqlite3",
	ollama_url: []const u8 = "http://localhost:11434",
	ollama_model: []const u8 = "bge-large",
	embedding_dim: usize = 1024,
	batch_size: usize = 16,
	max_file_size: usize = 2 * 1024 * 1024,
	search_mode: search.SearchMode = .hybrid,
	weight_vector: f32 = 0.7,
	weight_lexical: f32 = 0.3,
	min_score: f32 = 0.0,
	http_host: []const u8 = "127.0.0.1",
	http_port: u16 = 8123,
	include_docs: bool = false,
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
	weight_vector: f32,
	weight_lexical: f32,
	min_score: f32,
	include_docs: bool,
	docs_only: bool,
	comments_only: bool,
	index_ext: ?[]const u8,
	index_type: ?[]const u8,
	search_ext: ?[]const u8,
	search_type: ?[]const u8,
	search_lang: ?[]const u8,
	primary_lang: ?[]const u8,
	ignore_global: []const []const u8,
	ignore_lang: []const config.IgnoreOverride,
	http_host: []const u8,
	http_port: u16,
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

	const parsed = cli.parse(args) catch |err| {
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

	if (parsed.command == .help) {
		try printUsage(stdout);
		try stdout.flush();
		return;
	}

	var discovered_root: ?[]u8 = null;
	defer if (discovered_root) |path| allocator.free(path);

	var config_root = parsed.root_path;
	if (!parsed.seen.root_path) {
		discovered_root = try findRepoRoot(allocator, parsed.root_path);
		if (discovered_root) |root| {
			config_root = root;
		}
	}

	var cfg = try loadConfig(allocator, config_root);
	defer cfg.deinit(allocator);

	const settings = try resolveSettings(allocator, parsed, cfg, config_root);
	defer if (settings.db_path_owned) allocator.free(settings.db_path);
	defer if (settings.ollama_model_owned) allocator.free(settings.ollama_model);

	const registry = plugin.defaultRegistry();

	switch (parsed.command) {
		.index, .update => {
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
					},
				},
			);

			if (settings.output == .json) {
				try stdout.print("{{\"status\":\"ok\",\"files\":{d},\"symbols\":{d}}}\n", .{ stats.files, stats.symbols });
			} else {
				try stdout.print("Indexed {d} files, {d} symbols\n", .{ stats.files, stats.symbols });
			}
			try stdout.flush();
		},
		.search => {
			const query = parsed.query orelse return error.MissingQuery;
			try ensureParentDir(settings.db_path);
			const db = try storage.openFileWithVec(allocator, settings.db_path);
			defer storage.close(db);

			var http_client = ollama.StdHttpTransport.init(allocator);
			defer http_client.deinit();
			if (settings.search_mode != .lexical) {
				try ensureModelAvailableOrExit(allocator, http_client.transport(), settings.ollama_url, settings.ollama_model);
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

			const results = try search.search(
				allocator,
				db,
				embedder_adapter.embedder(),
				query,
				.{
					.top_n = settings.top_n,
					.mode = settings.search_mode,
					.weight_vector = settings.weight_vector,
					.weight_lexical = settings.weight_lexical,
					.min_score = settings.min_score,
					.allowed_langs = search_filters.langs.items,
					.allowed_exts = search_filters.exts.items,
					.comments_only = settings.comments_only,
				},
			);
			defer search.freeResults(allocator, results);

			const use_color = settings.output == .human and !std.process.hasEnvVarConstant("NO_COLOR");
			try output.writeResults(allocator, stdout, settings.output, results, .{
				.show_comments = settings.show_comments,
				.use_color = use_color,
			});
			try stdout.flush();
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
				.search_weight_vector = settings.weight_vector,
				.search_weight_lexical = settings.weight_lexical,
				.search_min_score = settings.min_score,
				.ignore_global = settings.ignore_global,
				.ignore_lang = settings.ignore_lang,
				.http_host = settings.http_host,
				.http_port = settings.http_port,
			});
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
		.weight_vector = defaults.weight_vector,
		.weight_lexical = defaults.weight_lexical,
		.min_score = defaults.min_score,
		.include_docs = defaults.include_docs,
		.docs_only = false,
		.comments_only = false,
		.index_ext = null,
		.index_type = null,
		.search_ext = null,
		.search_type = null,
		.search_lang = null,
		.primary_lang = null,
		.ignore_global = &[_][]const u8{},
		.ignore_lang = &[_]config.IgnoreOverride{},
		.http_host = defaults.http_host,
		.http_port = defaults.http_port,
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
	if (cfg.search_mode) |value| settings.search_mode = try parseMode(value);
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
	settings.ignore_global = cfg.ignore_global.items;
	settings.ignore_lang = cfg.ignore_lang.items;
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
	if (parsed.seen.weight_vector) settings.weight_vector = parsed.weight_vector;
	if (parsed.seen.weight_lexical) settings.weight_lexical = parsed.weight_lexical;
	if (parsed.seen.min_score) settings.min_score = parsed.min_score;
	if (parsed.seen.include_docs) settings.include_docs = parsed.include_docs;
	if (parsed.seen.docs_only) settings.docs_only = parsed.docs_only;
	if (parsed.seen.comments_only) settings.comments_only = parsed.comments_only;
	if (parsed.seen.ext_filter) {
		if (parsed.command == .index or parsed.command == .update) {
			settings.index_ext = parsed.ext_filter;
		} else if (parsed.command == .search) {
			settings.search_ext = parsed.ext_filter;
		}
	}
	if (parsed.seen.type_filter) {
		if (parsed.command == .index or parsed.command == .update) {
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
	const path = try std.fs.path.join(allocator, &.{ root_path, ".codescan", "config" });
	defer allocator.free(path);

	return config.loadFromPath(allocator, path) catch |err| switch (err) {
		error.FileNotFound => config.Config{},
		error.NotDir => config.Config{},
		else => err,
	};
}

fn ensureParentDir(path: []const u8) !void {
	const dir = std.fs.path.dirname(path) orelse return;
	try std.fs.cwd().makePath(dir);
}

fn parseMode(value: []const u8) !search.SearchMode {
	if (std.mem.eql(u8, value, "vector")) return .vector;
	if (std.mem.eql(u8, value, "lexical")) return .lexical;
	if (std.mem.eql(u8, value, "hybrid")) return .hybrid;
	return error.InvalidMode;
}


const usage =
	\\codescan <command> [options]
	\\
	\\Commands:
	\\  index             Index codebase
	\\  update            Rebuild index (currently full reindex)
	\\  search <query>    Search indexed codebase
	\\  serve             Start HTTP API server
	\\
	\\Options:
	\\  --root <path>           Root path (default: nearest .codescan ancestor or .)
	\\  --db <path>             DB path (default .codescan/index.sqlite3)
	\\  --ollama-url <url>      Ollama base URL (default http://localhost:11434)
	\\  --ollama-model <name>   Embedding model (default bge-large or $OLLAMA_MODEL)
	\\  --embedding-dim <n>     Embedding dimension (default 1024)
	\\  --batch <n>             Embedding batch size (default 16)
	\\  --max-file-size <n>     Max file size bytes (default 2097152)
	\\  --top <n>               Search top N (default 10)
	\\  --mode <vector|lexical|hybrid>  Search mode (default hybrid)
	\\  --weight-vector <n>     Hybrid weight for vector score (default 0.7)
	\\  --weight-lexical <n>    Hybrid weight for lexical score (default 0.3)
	\\  --min-score <n>         Minimum score threshold (default 0.0)
	\\  --ext <csv>             Restrict to extensions (comma-separated)
	\\  --type <csv>            Restrict to types: code,doc,text,log
	\\  --lang <csv>            Restrict search to languages
	\\  --include-docs          Include markdown/README when defaulting to primary language
	\\  --docs, --only-docs     Only return markdown/README results
	\\  --comments, --only-comments  Only return doc-comment results
	\\  --http-host <host>      HTTP host (default 127.0.0.1)
	\\  --http-port <port>      HTTP port (default 8123)
	\\  --show-comments, --verbose   Show doc comments in human output (default: hidden)
	\\  --json                  JSON output for CLI search/index
	\\  -h, --help              Show help
	\\
;

fn isUsageError(err: anyerror) bool {
	return err == error.MissingQuery or
		err == error.UnknownCommand or
		err == error.MissingValue or
		err == error.InvalidMode or
		err == error.UnexpectedArg or
		err == error.TooManyArgs;
}

fn usageErrorMessage(err: anyerror) []const u8 {
	if (err == error.MissingQuery) return "missing search query";
	if (err == error.UnknownCommand) return "unknown command";
	if (err == error.MissingValue) return "missing required value";
	if (err == error.InvalidMode) return "invalid mode";
	if (err == error.UnexpectedArg) return "unexpected argument";
	if (err == error.TooManyArgs) return "too many arguments";
	return "invalid usage";
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

test "buildSearchFilters defaults to primary language" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

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
	const parsed = try cli.parse(&args);
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

	try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });

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
	const parsed = try cli.parse(&args);
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
	const parsed = try cli.parse(&args);

	var cfg = config.Config{};
	defer cfg.deinit(allocator);

	const settings = try resolveSettings(allocator, parsed, cfg, root.?);
	defer if (settings.db_path_owned) allocator.free(settings.db_path);

	const expected_db = try std.fs.path.join(allocator, &.{ root.?, ".codescan", "index.sqlite3" });
	defer allocator.free(expected_db);

	try std.testing.expectEqualStrings(root.?, settings.root_path);
	try std.testing.expectEqualStrings(expected_db, settings.db_path);
}

fn listContains(list: []const []const u8, value: []const u8) bool {
	for (list) |item| {
		if (std.mem.eql(u8, item, value)) return true;
	}
	return false;
}
