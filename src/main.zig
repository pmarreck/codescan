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
};

const Settings = struct {
	output: cli.OutputFormat,
	top_n: usize,
	root_path: []const u8,
	db_path: []const u8,
	db_path_owned: bool,
	ollama_url: []const u8,
	ollama_model: []const u8,
	embedding_dim: usize,
	batch_size: usize,
	max_file_size: usize,
	search_mode: search.SearchMode,
	weight_vector: f32,
	weight_lexical: f32,
	min_score: f32,
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

	const parsed = try cli.parse(args);

	var stdout_buf: [4096]u8 = undefined;
	var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
	const stdout = &stdout_writer.interface;

	if (parsed.command == .help) {
		try stdout.writeAll(usage);
		try stdout.flush();
		return;
	}

	var cfg = try loadConfig(allocator, parsed.root_path);
	defer cfg.deinit(allocator);

	const settings = try resolveSettings(allocator, parsed, cfg);
	defer if (settings.db_path_owned) allocator.free(settings.db_path);

	switch (parsed.command) {
		.index, .update => {
			try ensureParentDir(settings.db_path);
			const db = try storage.openFileWithVec(allocator, settings.db_path);
			defer storage.close(db);

			var http_client = ollama.StdHttpTransport.init(allocator);
			defer http_client.deinit();
			var embedder_adapter = embedding.OllamaEmbedder{
				.transport = http_client.transport(),
				.base_url = settings.ollama_url,
				.model = settings.ollama_model,
			};

			const stats = try indexer.indexAll(
				allocator,
				db,
				settings.root_path,
				plugin.defaultRegistry(),
				embedder_adapter.embedder(),
				.{
					.embedding_dim = settings.embedding_dim,
					.batch_size = settings.batch_size,
					.max_file_size = settings.max_file_size,
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
			var embedder_adapter = embedding.OllamaEmbedder{
				.transport = http_client.transport(),
				.base_url = settings.ollama_url,
				.model = settings.ollama_model,
			};

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
				},
			);
			defer search.freeResults(allocator, results);

			try output.writeResults(allocator, stdout, settings.output, results);
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

fn resolveSettings(allocator: std.mem.Allocator, parsed: cli.Parsed, cfg: config.Config) !Settings {
	const defaults = Defaults{};
	var settings = Settings{
		.output = defaults.output,
		.top_n = defaults.top_n,
		.root_path = defaults.root_path,
		.db_path = defaults.db_path,
		.db_path_owned = false,
		.ollama_url = defaults.ollama_url,
		.ollama_model = defaults.ollama_model,
		.embedding_dim = defaults.embedding_dim,
		.batch_size = defaults.batch_size,
		.max_file_size = defaults.max_file_size,
		.search_mode = defaults.search_mode,
		.weight_vector = defaults.weight_vector,
		.weight_lexical = defaults.weight_lexical,
		.min_score = defaults.min_score,
		.ignore_global = &[_][]const u8{},
		.ignore_lang = &[_]config.IgnoreOverride{},
		.http_host = defaults.http_host,
		.http_port = defaults.http_port,
	};

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
	settings.ignore_global = cfg.ignore_global.items;
	settings.ignore_lang = cfg.ignore_lang.items;
	if (cfg.http_host) |value| settings.http_host = value;
	if (cfg.http_port) |value| settings.http_port = value;

	if (parsed.seen.output) settings.output = parsed.output;
	if (parsed.seen.top_n) settings.top_n = parsed.top_n;
	if (parsed.seen.root_path) settings.root_path = parsed.root_path;
	if (parsed.seen.db_path) settings.db_path = parsed.db_path;
	if (parsed.seen.ollama_url) settings.ollama_url = parsed.ollama_url;
	if (parsed.seen.ollama_model) settings.ollama_model = parsed.ollama_model;
	if (parsed.seen.embedding_dim) settings.embedding_dim = parsed.embedding_dim;
	if (parsed.seen.batch_size) settings.batch_size = parsed.batch_size;
	if (parsed.seen.max_file_size) settings.max_file_size = parsed.max_file_size;
	if (parsed.seen.search_mode) settings.search_mode = parsed.search_mode;
	if (parsed.seen.weight_vector) settings.weight_vector = parsed.weight_vector;
	if (parsed.seen.weight_lexical) settings.weight_lexical = parsed.weight_lexical;
	if (parsed.seen.min_score) settings.min_score = parsed.min_score;
	if (parsed.seen.http_host) settings.http_host = parsed.http_host;
	if (parsed.seen.http_port) settings.http_port = parsed.http_port;

	if (!std.fs.path.isAbsolute(settings.db_path) and !std.mem.eql(u8, settings.root_path, ".")) {
		settings.db_path = try std.fs.path.join(allocator, &.{ settings.root_path, settings.db_path });
		settings.db_path_owned = true;
	}

	return settings;
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
	\\  --root <path>           Root path (default .)
	\\  --db <path>             DB path (default .codescan/index.sqlite3)
	\\  --ollama-url <url>      Ollama base URL (default http://localhost:11434)
	\\  --ollama-model <name>   Embedding model (default bge-large)
	\\  --embedding-dim <n>     Embedding dimension (default 1024)
	\\  --batch <n>             Embedding batch size (default 16)
	\\  --max-file-size <n>     Max file size bytes (default 2097152)
	\\  --top <n>               Search top N (default 10)
	\\  --mode <vector|lexical|hybrid>  Search mode (default hybrid)
	\\  --weight-vector <n>     Hybrid weight for vector score (default 0.7)
	\\  --weight-lexical <n>    Hybrid weight for lexical score (default 0.3)
	\\  --min-score <n>         Minimum score threshold (default 0.0)
	\\  --http-host <host>      HTTP host (default 127.0.0.1)
	\\  --http-port <port>      HTTP port (default 8123)
	\\  --json                  JSON output for CLI search/index
	\\  -h, --help              Show help
	\\
;
