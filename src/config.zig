const std = @import("std");
const cli = @import("cli.zig");

/// Default config template written to new .codescan/config files.
/// All values are commented out; uncomment to override defaults.
pub const default_template =
    \\# codescan project configuration
    \\# https://github.com/pmarreck/codescan
    \\#
    \\# This file lives in .codescan/config at the root of an indexed project.
    \\# It is safe to commit — it contains no secrets, only search preferences.
    \\# Uncomment and modify values as needed.
    \\# Changes take effect on the next command invocation.
    \\# See: codescan --help
    \\
    \\# Output format: human or json
    \\#output=human
    \\
    \\# Number of search results to return
    \\#top=10
    \\
    \\# Embedding server (ollama_url and ollama_model are accepted as aliases)
    \\#embedding_url=http://localhost:11434
    \\#embedding_model=jina-code-embeddings-1.5b
    \\#embedding_api=ollama
    \\#embedding_api_key=
    \\#embedding_dim=1536    \\#batch_size=16
    \\
    \\# Maximum file size to index (bytes, default 5 MiB)
    \\#max_file_size=5242880
    \\
    \\# Search tuning
    \\#search_mode=hybrid
    \\#fusion=weighted_sum
    \\#rrf_k=60
    \\#fts_mode=broad
    \\#weight_vector=0.7
    \\#weight_lexical=0.3
    \\#min_score=0.0
    \\#
    \\# Language-specific overrides live in .codescan/weights.toml
    \\# (for example: [zig], [elixir], [rust] sections)
    \\
    \\# Index/search file filters (comma-separated)
    \\#index_ext=
    \\#index_type=code,doc
    \\#search_ext=
    \\#search_type=
    \\#search_lang=
    \\#primary_lang=
    \\
    \\# Include options
    \\#include_docs=false
    \\#include_node_modules=false
    \\
    \\# Ignore patterns (comma-separated globs, can be per-language)
    \\#ignore=
    \\#ignore.zig=zig-cache,zig-out
    \\
    \\# Always include patterns (comma-separated globs, overrides .gitignore)
    \\# Use this for files you want indexed even if gitignored.
    \\# Escape literal commas in patterns with \,
    \\#always_include=*.md,docs/**
    \\
    \\# LSP binary overrides (key = language ID, e.g. zig, rust, clojure)
    \\#lsp.zig=/custom/path/to/zls
    \\#lsp.rust=/custom/path/to/rust-analyzer
    \\
    \\# HTTP API server
    \\#http_host=127.0.0.1
    \\#http_port=8123
    \\
;

pub const IgnoreOverride = struct {
	language: []const u8,
	patterns: std.ArrayListUnmanaged([]const u8) = .{},

	pub fn deinit(self: *IgnoreOverride, allocator: std.mem.Allocator) void {
		for (self.patterns.items) |pattern| allocator.free(pattern);
		self.patterns.deinit(allocator);
		allocator.free(self.language);
		self.* = undefined;
	}
};

pub const LspOverride = struct {
	language: []const u8,
	binary_path: []const u8,

	pub fn deinit(self: *LspOverride, allocator: std.mem.Allocator) void {
		allocator.free(self.language);
		allocator.free(self.binary_path);
		self.* = undefined;
	}
};

pub const Config = struct {
	output: ?cli.OutputFormat = null,
	top_n: ?usize = null,
	root_path: ?[]const u8 = null,
	db_path: ?[]const u8 = null,
	embedding_url: ?[]const u8 = null,
	embedding_model: ?[]const u8 = null,
	embedding_api: ?[]const u8 = null,
	embedding_api_key: ?[]const u8 = null,
	embedding_dim: ?usize = null,
	batch_size: ?usize = null,
	max_file_size: ?usize = null,
	search_mode: ?[]const u8 = null,
	fusion: ?[]const u8 = null,
	rrf_k: ?f32 = null,
	fts_mode: ?[]const u8 = null,
	weight_vector: ?f32 = null,
	weight_lexical: ?f32 = null,
	min_score: ?f32 = null,
	index_ext: ?[]const u8 = null,
	index_type: ?[]const u8 = null,
	search_ext: ?[]const u8 = null,
	search_type: ?[]const u8 = null,
	search_lang: ?[]const u8 = null,
	search_symbol_kind: ?[]const u8 = null,
	primary_lang: ?[]const u8 = null,
	include_docs: ?bool = null,
	docs_only: ?bool = null,
	comments_only: ?bool = null,
	include_node_modules: ?bool = null,
	ignore_global: std.ArrayListUnmanaged([]const u8) = .{},
	always_include: std.ArrayListUnmanaged([]const u8) = .{},
	ignore_lang: std.ArrayListUnmanaged(IgnoreOverride) = .{},
	lsp_overrides: std.ArrayListUnmanaged(LspOverride) = .{},
	http_host: ?[]const u8 = null,
	http_port: ?u16 = null,

	pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
		if (self.root_path) |value| allocator.free(value);
		if (self.db_path) |value| allocator.free(value);
		if (self.embedding_url) |value| allocator.free(value);
		if (self.embedding_model) |value| allocator.free(value);
		if (self.embedding_api) |value| allocator.free(value);
		if (self.embedding_api_key) |value| allocator.free(value);
		if (self.search_mode) |value| allocator.free(value);
		if (self.fusion) |value| allocator.free(value);
		if (self.fts_mode) |value| allocator.free(value);
		if (self.index_ext) |value| allocator.free(value);
		if (self.index_type) |value| allocator.free(value);
		if (self.search_ext) |value| allocator.free(value);
		if (self.search_type) |value| allocator.free(value);
		if (self.search_lang) |value| allocator.free(value);
		if (self.search_symbol_kind) |value| allocator.free(value);
		if (self.primary_lang) |value| allocator.free(value);
		if (self.http_host) |value| allocator.free(value);
		for (self.ignore_global.items) |pattern| allocator.free(pattern);
		self.ignore_global.deinit(allocator);
		for (self.always_include.items) |pattern| allocator.free(pattern);
		self.always_include.deinit(allocator);
		for (self.ignore_lang.items) |*entry| entry.deinit(allocator);
		self.ignore_lang.deinit(allocator);
		for (self.lsp_overrides.items) |*entry| entry.deinit(allocator);
		self.lsp_overrides.deinit(allocator);
		self.* = .{};
	}
};

pub fn parseText(allocator: std.mem.Allocator, text: []const u8) !Config {
	var config = Config{};
	var lines = std.mem.splitScalar(u8, text, '\n');
	while (lines.next()) |line| {
		const trimmed = std.mem.trim(u8, line, " \t\r");
		if (trimmed.len == 0) continue;
		if (trimmed[0] == '#') continue;
		if (trimmed.len >= 2 and trimmed[0] == '/' and trimmed[1] == '/') continue;

		var kv = std.mem.splitScalar(u8, trimmed, '=');
		const key_raw = kv.next() orelse return error.InvalidLine;
		const value_raw = kv.next() orelse return error.InvalidLine;
		if (kv.next() != null) return error.InvalidLine;

		const key = std.mem.trim(u8, key_raw, " \t");
		const value_untrimmed = std.mem.trim(u8, value_raw, " \t");
		const value = stripQuotes(value_untrimmed);

		if (std.mem.eql(u8, key, "output")) {
			if (std.mem.eql(u8, value, "json")) {
				config.output = .json;
			} else if (std.mem.eql(u8, value, "human")) {
				config.output = .human;
			} else {
				return error.InvalidValue;
			}
			continue;
		}

		if (std.mem.eql(u8, key, "top")) {
			config.top_n = try std.fmt.parseInt(usize, value, 10);
			continue;
		}

		if (std.mem.eql(u8, key, "root")) {
			config.root_path = try allocator.dupe(u8, value);
			continue;
		}

		if (std.mem.eql(u8, key, "db")) {
			config.db_path = try allocator.dupe(u8, value);
			continue;
		}


		if (std.mem.eql(u8, key, "embedding_url") or std.mem.eql(u8, key, "ollama_url")) {
			config.embedding_url = try allocator.dupe(u8, value);
			continue;
		}

		if (std.mem.eql(u8, key, "embedding_model") or std.mem.eql(u8, key, "ollama_model")) {
			config.embedding_model = try allocator.dupe(u8, value);
			continue;
		}

		if (std.mem.eql(u8, key, "embedding_api")) {
			if (!std.mem.eql(u8, value, "ollama") and !std.mem.eql(u8, value, "openai")) {
				return error.InvalidValue;
			}
			config.embedding_api = try allocator.dupe(u8, value);
			continue;
		}

		if (std.mem.eql(u8, key, "embedding_api_key")) {
			config.embedding_api_key = try allocator.dupe(u8, value);
			continue;
		}

		if (std.mem.eql(u8, key, "embedding_dim")) {
			config.embedding_dim = try std.fmt.parseInt(usize, value, 10);
			continue;
		}

		if (std.mem.eql(u8, key, "batch_size")) {
			config.batch_size = try std.fmt.parseInt(usize, value, 10);
			continue;
		}

		if (std.mem.eql(u8, key, "max_file_size")) {
			config.max_file_size = try std.fmt.parseInt(usize, value, 10);
			continue;
		}

		if (std.mem.eql(u8, key, "search_mode")) {
			if (!validMode(value)) return error.InvalidValue;
			config.search_mode = try allocator.dupe(u8, value);
			continue;
		}

		if (std.mem.eql(u8, key, "fusion")) {
			if (!validFusion(value)) return error.InvalidValue;
			config.fusion = try allocator.dupe(u8, value);
			continue;
		}

		if (std.mem.eql(u8, key, "rrf_k")) {
			config.rrf_k = std.fmt.parseFloat(f32, value) catch return error.InvalidValue;
			continue;
		}

		if (std.mem.eql(u8, key, "fts_mode")) {
			if (!validFtsMode(value)) return error.InvalidValue;
			config.fts_mode = try allocator.dupe(u8, value);
			continue;
		}

		if (std.mem.eql(u8, key, "ignore")) {
			try appendPatterns(allocator, &config.ignore_global, value);
			continue;
		}

		if (std.mem.eql(u8, key, "always_include")) {
			try appendPatterns(allocator, &config.always_include, value);
			continue;
		}

		if (std.mem.startsWith(u8, key, "ignore.")) {
			const lang = key["ignore.".len..];
			if (lang.len == 0) return error.InvalidValue;
			var entry = try getOrCreateOverride(allocator, &config.ignore_lang, lang);
			try appendPatterns(allocator, &entry.patterns, value);
			continue;
		}

		if (std.mem.startsWith(u8, key, "lsp.")) {
			const lang = key["lsp.".len..];
			if (lang.len == 0) return error.InvalidValue;
			try config.lsp_overrides.append(allocator, .{
				.language = try allocator.dupe(u8, lang),
				.binary_path = try allocator.dupe(u8, value),
			});
			continue;
		}

		if (std.mem.eql(u8, key, "weight_vector")) {
			config.weight_vector = try std.fmt.parseFloat(f32, value);
			continue;
		}

		if (std.mem.eql(u8, key, "weight_lexical")) {
			config.weight_lexical = try std.fmt.parseFloat(f32, value);
			continue;
		}

		if (std.mem.eql(u8, key, "min_score")) {
			config.min_score = try std.fmt.parseFloat(f32, value);
			continue;
		}

		if (std.mem.eql(u8, key, "index_ext")) {
			config.index_ext = try allocator.dupe(u8, value);
			continue;
		}

		if (std.mem.eql(u8, key, "index_type")) {
			config.index_type = try allocator.dupe(u8, value);
			continue;
		}

		if (std.mem.eql(u8, key, "search_ext")) {
			config.search_ext = try allocator.dupe(u8, value);
			continue;
		}

		if (std.mem.eql(u8, key, "search_type")) {
			config.search_type = try allocator.dupe(u8, value);
			continue;
		}

		if (std.mem.eql(u8, key, "search_lang")) {
			config.search_lang = try allocator.dupe(u8, value);
			continue;
		}

		if (std.mem.eql(u8, key, "search_symbol_kind")) {
			config.search_symbol_kind = try allocator.dupe(u8, value);
			continue;
		}

		if (std.mem.eql(u8, key, "primary_lang")) {
			config.primary_lang = try allocator.dupe(u8, value);
			continue;
		}

		if (std.mem.eql(u8, key, "include_docs")) {
			if (std.mem.eql(u8, value, "true")) {
				config.include_docs = true;
			} else if (std.mem.eql(u8, value, "false")) {
				config.include_docs = false;
			} else {
				return error.InvalidValue;
			}
			continue;
		}

		if (std.mem.eql(u8, key, "docs_only")) {
			if (std.mem.eql(u8, value, "true")) {
				config.docs_only = true;
			} else if (std.mem.eql(u8, value, "false")) {
				config.docs_only = false;
			} else {
				return error.InvalidValue;
			}
			continue;
		}

		if (std.mem.eql(u8, key, "comments_only")) {
			if (std.mem.eql(u8, value, "true")) {
				config.comments_only = true;
			} else if (std.mem.eql(u8, value, "false")) {
				config.comments_only = false;
			} else {
				return error.InvalidValue;
			}
			continue;
		}

		if (std.mem.eql(u8, key, "include_node_modules")) {
			if (std.mem.eql(u8, value, "true")) {
				config.include_node_modules = true;
			} else if (std.mem.eql(u8, value, "false")) {
				config.include_node_modules = false;
			} else {
				return error.InvalidValue;
			}
			continue;
		}

		if (std.mem.eql(u8, key, "http_host")) {
			config.http_host = try allocator.dupe(u8, value);
			continue;
		}

		if (std.mem.eql(u8, key, "http_port")) {
			config.http_port = try std.fmt.parseInt(u16, value, 10);
			continue;
		}

		return error.UnknownKey;
	}

	return config;
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !Config {
	const file = try std.fs.cwd().openFile(path, .{});
	defer file.close();
	const data = try file.readToEndAlloc(allocator, 1024 * 1024);
	defer allocator.free(data);
	return parseText(allocator, data);
}

fn stripQuotes(value: []const u8) []const u8 {
	if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
		return value[1 .. value.len - 1];
	}
	return value;
}

fn appendPatterns(
	allocator: std.mem.Allocator,
	list: *std.ArrayListUnmanaged([]const u8),
	value: []const u8,
) !void {
	// Split on commas, respecting \, as an escaped literal comma
	var buf = std.ArrayListUnmanaged(u8){};
	defer buf.deinit(allocator);
	var i: usize = 0;
	while (i < value.len) : (i += 1) {
		if (value[i] == '\\' and i + 1 < value.len and value[i + 1] == ',') {
			try buf.append(allocator, ',');
			i += 1; // skip the comma
		} else if (value[i] == ',') {
			const trimmed = std.mem.trim(u8, buf.items, " \t\r");
			if (trimmed.len > 0) {
				try list.append(allocator, try allocator.dupe(u8, trimmed));
			}
			buf.clearRetainingCapacity();
		} else {
			try buf.append(allocator, value[i]);
		}
	}
	// Last segment
	const trimmed = std.mem.trim(u8, buf.items, " \t\r");
	if (trimmed.len > 0) {
		try list.append(allocator, try allocator.dupe(u8, trimmed));
	}
}

fn getOrCreateOverride(
	allocator: std.mem.Allocator,
	list: *std.ArrayListUnmanaged(IgnoreOverride),
	lang: []const u8,
) !*IgnoreOverride {
	for (list.items) |*entry| {
		if (std.mem.eql(u8, entry.language, lang)) return entry;
	}
	try list.append(allocator, .{
		.language = try allocator.dupe(u8, lang),
		.patterns = .{},
	});
	return &list.items[list.items.len - 1];
}

fn validMode(value: []const u8) bool {
	return std.mem.eql(u8, value, "vector") or std.mem.eql(u8, value, "lexical") or std.mem.eql(u8, value, "hybrid");
}

fn validFusion(value: []const u8) bool {
	return std.mem.eql(u8, value, "weighted_sum") or std.mem.eql(u8, value, "weighted-sum") or std.mem.eql(u8, value, "rrf");
}

fn validFtsMode(value: []const u8) bool {
	return std.mem.eql(u8, value, "broad") or std.mem.eql(u8, value, "balanced") or std.mem.eql(u8, value, "strict");
}

test "parseText empty yields defaults" {
	const allocator = std.testing.allocator;
	var cfg = try parseText(allocator, "\n\n# comment\n");
	defer cfg.deinit(allocator);
	try std.testing.expect(cfg.output == null);
	try std.testing.expect(cfg.top_n == null);
	try std.testing.expect(cfg.root_path == null);
	try std.testing.expect(cfg.db_path == null);
	try std.testing.expect(cfg.embedding_url == null);
	try std.testing.expect(cfg.embedding_model == null);
	try std.testing.expect(cfg.embedding_api == null);
	try std.testing.expect(cfg.embedding_api_key == null);
	try std.testing.expect(cfg.embedding_dim == null);
	try std.testing.expect(cfg.batch_size == null);
	try std.testing.expect(cfg.max_file_size == null);
	try std.testing.expect(cfg.search_mode == null);
	try std.testing.expect(cfg.weight_vector == null);
	try std.testing.expect(cfg.weight_lexical == null);
	try std.testing.expect(cfg.min_score == null);
	try std.testing.expect(cfg.docs_only == null);
	try std.testing.expect(cfg.comments_only == null);
	try std.testing.expect(cfg.include_node_modules == null);
	try std.testing.expectEqual(@as(usize, 0), cfg.ignore_global.items.len);
	try std.testing.expectEqual(@as(usize, 0), cfg.ignore_lang.items.len);
	try std.testing.expect(cfg.http_host == null);
	try std.testing.expect(cfg.http_port == null);
}

test "parseText reads values" {
	const allocator = std.testing.allocator;
	const text =
		"output=json\n" ++
		"top=7\n" ++
		"root=/repo\n" ++
		"db=.codescan/db.sqlite3\n" ++
		"ollama_url=http://127.0.0.1:11434\n" ++
		"ollama_model=bge-large\n" ++
		"embedding_dim=768\n" ++
		"batch_size=8\n" ++
		"max_file_size=2048\n" ++
		"search_mode=hybrid\n" ++
		"weight_vector=0.8\n" ++
		"weight_lexical=0.2\n" ++
		"min_score=0.55\n" ++
		"index_ext=zig,md\n" ++
		"index_type=code,doc\n" ++
		"search_ext=zig\n" ++
		"search_type=code\n" ++
		"search_lang=zig\n" ++
		"primary_lang=zig\n" ++
		"include_docs=true\n" ++
		"docs_only=false\n" ++
		"comments_only=true\n" ++
		"include_node_modules=true\n" ++
		"http_host=0.0.0.0\n" ++
		"http_port=9001\n";
	var cfg = try parseText(allocator, text);
	defer cfg.deinit(allocator);
	try std.testing.expectEqual(cli.OutputFormat.json, cfg.output.?);
	try std.testing.expectEqual(@as(usize, 7), cfg.top_n.?);
	try std.testing.expectEqualStrings("/repo", cfg.root_path.?);
	try std.testing.expectEqualStrings(".codescan/db.sqlite3", cfg.db_path.?);
	try std.testing.expectEqualStrings("http://127.0.0.1:11434", cfg.embedding_url.?);
	try std.testing.expectEqualStrings("bge-large", cfg.embedding_model.?);
	try std.testing.expectEqual(@as(usize, 768), cfg.embedding_dim.?);
	try std.testing.expectEqual(@as(usize, 8), cfg.batch_size.?);
	try std.testing.expectEqual(@as(usize, 2048), cfg.max_file_size.?);
	try std.testing.expectEqualStrings("hybrid", cfg.search_mode.?);
	try std.testing.expectApproxEqAbs(@as(f32, 0.8), cfg.weight_vector.?, 0.0001);
	try std.testing.expectApproxEqAbs(@as(f32, 0.2), cfg.weight_lexical.?, 0.0001);
	try std.testing.expectApproxEqAbs(@as(f32, 0.55), cfg.min_score.?, 0.0001);
	try std.testing.expectEqualStrings("zig,md", cfg.index_ext.?);
	try std.testing.expectEqualStrings("code,doc", cfg.index_type.?);
	try std.testing.expectEqualStrings("zig", cfg.search_ext.?);
	try std.testing.expectEqualStrings("code", cfg.search_type.?);
	try std.testing.expectEqualStrings("zig", cfg.search_lang.?);
	try std.testing.expectEqualStrings("zig", cfg.primary_lang.?);
	try std.testing.expectEqual(true, cfg.include_docs.?);
	try std.testing.expectEqual(false, cfg.docs_only.?);
	try std.testing.expectEqual(true, cfg.comments_only.?);
	try std.testing.expectEqual(true, cfg.include_node_modules.?);
	try std.testing.expectEqualStrings("0.0.0.0", cfg.http_host.?);
	try std.testing.expectEqual(@as(u16, 9001), cfg.http_port.?);
}

test "parseText reads ignore patterns" {
	const allocator = std.testing.allocator;
	const text =
		"ignore=**/.git/**, **/.codescan/**\n" ++
		"ignore.zig=**/.zig-cache/**,**/zig-out/**\n" ++
		"ignore.elixir=**/deps/**\n";
	var cfg = try parseText(allocator, text);
	defer cfg.deinit(allocator);

	try std.testing.expectEqual(@as(usize, 2), cfg.ignore_global.items.len);
	try std.testing.expectEqualStrings("**/.git/**", cfg.ignore_global.items[0]);
	try std.testing.expectEqualStrings("**/.codescan/**", cfg.ignore_global.items[1]);
	try std.testing.expectEqual(@as(usize, 2), cfg.ignore_lang.items.len);
	try std.testing.expectEqualStrings("zig", cfg.ignore_lang.items[0].language);
	try std.testing.expectEqual(@as(usize, 2), cfg.ignore_lang.items[0].patterns.items.len);
	try std.testing.expectEqualStrings("**/.zig-cache/**", cfg.ignore_lang.items[0].patterns.items[0]);
	try std.testing.expectEqualStrings("**/zig-out/**", cfg.ignore_lang.items[0].patterns.items[1]);
}

test "parseText errors on invalid line" {
	const allocator = std.testing.allocator;
	try std.testing.expectError(error.InvalidLine, parseText(allocator, "nope\n"));
}

test "parseText errors on unknown key" {
	const allocator = std.testing.allocator;
	try std.testing.expectError(error.UnknownKey, parseText(allocator, "nope=1\n"));
}

test "default_template parses without error" {
	const allocator = std.testing.allocator;
	var cfg = try parseText(allocator, default_template);
	defer cfg.deinit(allocator);
	// All values should remain null (everything is commented out)
	try std.testing.expect(cfg.output == null);
	try std.testing.expect(cfg.top_n == null);
	try std.testing.expect(cfg.max_file_size == null);
	try std.testing.expect(cfg.embedding_url == null);
	try std.testing.expect(cfg.search_mode == null);
}

test "loadFromPath reads file" {
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	try tmp.dir.writeFile(.{ .sub_path = "config", .data = "top=3\n" });
	const allocator = std.testing.allocator;
	const path = try tmp.dir.realpathAlloc(allocator, "config");
	defer allocator.free(path);
	var cfg = try loadFromPath(allocator, path);
	defer cfg.deinit(allocator);
	try std.testing.expectEqual(@as(usize, 3), cfg.top_n.?);
}

test "parseText reads embedding_api and embedding_api_key" {
	const allocator = std.testing.allocator;
	var cfg = try parseText(allocator, "embedding_api=openai\nembedding_api_key=my-secret-key\n");
	defer cfg.deinit(allocator);
	try std.testing.expectEqualStrings("openai", cfg.embedding_api.?);
	try std.testing.expectEqualStrings("my-secret-key", cfg.embedding_api_key.?);
}

test "parseText reads embedding_url and embedding_model" {
	const allocator = std.testing.allocator;
	var cfg = try parseText(allocator, "embedding_url=http://localhost:8000\nembedding_model=bge-m3\n");
	defer cfg.deinit(allocator);
	try std.testing.expectEqualStrings("http://localhost:8000", cfg.embedding_url.?);
	try std.testing.expectEqualStrings("bge-m3", cfg.embedding_model.?);
}

test "parseText ollama_url alias populates embedding_url" {
	const allocator = std.testing.allocator;
	var cfg = try parseText(allocator, "ollama_url=http://localhost:11434\nollama_model=bge-large\n");
	defer cfg.deinit(allocator);
	try std.testing.expectEqualStrings("http://localhost:11434", cfg.embedding_url.?);
	try std.testing.expectEqualStrings("bge-large", cfg.embedding_model.?);
}

test "parseText rejects invalid embedding_api" {
	const allocator = std.testing.allocator;
	try std.testing.expectError(error.InvalidValue, parseText(allocator, "embedding_api=banana\n"));
}
