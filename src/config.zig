const std = @import("std");
const io_singleton = @import("io_singleton.zig");
const cli = @import("cli.zig");
const env_expand = @import("env_expand.zig");

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
    \\#embedding_model=bge-large
    \\#embedding_api=ollama
    \\#embedding_api_key=
    \\#embedding_dim=1024
    \\#batch_size=16
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
	patterns: std.ArrayListUnmanaged([]const u8) = .empty,

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
	/// Pre-expansion verbatim string when `embedding_api_key` was loaded from a
	/// reference-containing literal (e.g. `${OMLX_API_KEY}`). Used for
	/// write-back to avoid baking the resolved secret into the file.
	/// Null if the config value contained no references.
	embedding_api_key_raw: ?[]const u8 = null,
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
	ignore_global: std.ArrayListUnmanaged([]const u8) = .empty,
	always_include: std.ArrayListUnmanaged([]const u8) = .empty,
	ignore_lang: std.ArrayListUnmanaged(IgnoreOverride) = .empty,
	lsp_overrides: std.ArrayListUnmanaged(LspOverride) = .empty,
	http_host: ?[]const u8 = null,
	http_port: ?u16 = null,
	/// How long a watcher may sit idle before retiring, as written in the
	/// config (e.g. "1d", "12h", "never"). Kept verbatim so an invalid value
	/// fails loudly where it is used rather than silently defaulting.
	watcher_idle_timeout: ?[]const u8 = null,

	pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
		if (self.root_path) |value| allocator.free(value);
		if (self.db_path) |value| allocator.free(value);
		if (self.embedding_url) |value| allocator.free(value);
		if (self.embedding_model) |value| allocator.free(value);
		if (self.embedding_api) |value| allocator.free(value);
		if (self.embedding_api_key) |value| allocator.free(value);
		if (self.embedding_api_key_raw) |value| allocator.free(value);
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
		if (self.watcher_idle_timeout) |value| allocator.free(value);
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

	/// Returns the value to write to disk for `key`. For `embedding_api_key`
	/// with a raw placeholder, returns the placeholder. For the explicitly
	/// enumerated write-back keys, returns the stored (expanded) value.
	///
	/// Supported keys: `embedding_api_key`, `embedding_url`, `embedding_model`,
	/// `embedding_api`, `http_host`. Callers passing other keys get `""` —
	/// add the key here before wiring a new write-back call site.
	pub fn writeValueFor(self: *const Config, key: []const u8) []const u8 {
		if (std.mem.eql(u8, key, "embedding_api_key")) {
			if (self.embedding_api_key_raw) |raw| return raw;
			if (self.embedding_api_key) |v| return v;
			return "";
		}
		if (std.mem.eql(u8, key, "embedding_url")) return self.embedding_url orelse "";
		if (std.mem.eql(u8, key, "embedding_model")) return self.embedding_model orelse "";
		if (std.mem.eql(u8, key, "embedding_api")) return self.embedding_api orelse "";
		if (std.mem.eql(u8, key, "http_host")) return self.http_host orelse "";
		return "";
	}

	/// Replace `embedding_api_key` with an explicit literal value, clearing any
	/// raw placeholder that was tracked. Use when code writes a NEW literal
	/// (e.g. first-time auto-detection) that should be persisted as-is.
	pub fn setApiKeyLiteral(self: *Config, allocator: std.mem.Allocator, new_value: []const u8) !void {
		if (self.embedding_api_key) |old| allocator.free(old);
		if (self.embedding_api_key_raw) |raw| {
			allocator.free(raw);
			self.embedding_api_key_raw = null;
		}
		self.embedding_api_key = try allocator.dupe(u8, new_value);
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
			config.root_path = try env_expand.expand(allocator, value);
			continue;
		}

		if (std.mem.eql(u8, key, "db")) {
			config.db_path = try env_expand.expand(allocator, value);
			continue;
		}


		if (std.mem.eql(u8, key, "embedding_url") or std.mem.eql(u8, key, "ollama_url")) {
			config.embedding_url = try env_expand.expand(allocator, value);
			continue;
		}

		if (std.mem.eql(u8, key, "embedding_model") or std.mem.eql(u8, key, "ollama_model")) {
			config.embedding_model = try env_expand.expand(allocator, value);
			continue;
		}

		if (std.mem.eql(u8, key, "embedding_api")) {
			const expanded = try env_expand.expand(allocator, value);
			errdefer allocator.free(expanded);
			if (!std.mem.eql(u8, expanded, "ollama") and !std.mem.eql(u8, expanded, "openai")) {
				return error.InvalidValue;
			}
			config.embedding_api = expanded;
			continue;
		}

		if (std.mem.eql(u8, key, "embedding_api_key")) {
			if (env_expand.hasRef(value)) {
				const raw_dup = try allocator.dupe(u8, value);
				errdefer allocator.free(raw_dup);
				config.embedding_api_key = try env_expand.expand(allocator, value);
				config.embedding_api_key_raw = raw_dup;
			} else {
				config.embedding_api_key = try allocator.dupe(u8, value);
			}
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
			const expanded = try env_expand.expand(allocator, value);
			errdefer allocator.free(expanded);
			if (!validMode(expanded)) return error.InvalidValue;
			config.search_mode = expanded;
			continue;
		}

		if (std.mem.eql(u8, key, "fusion")) {
			const expanded = try env_expand.expand(allocator, value);
			errdefer allocator.free(expanded);
			if (!validFusion(expanded)) return error.InvalidValue;
			config.fusion = expanded;
			continue;
		}

		if (std.mem.eql(u8, key, "rrf_k")) {
			config.rrf_k = std.fmt.parseFloat(f32, value) catch return error.InvalidValue;
			continue;
		}

		if (std.mem.eql(u8, key, "fts_mode")) {
			const expanded = try env_expand.expand(allocator, value);
			errdefer allocator.free(expanded);
			if (!validFtsMode(expanded)) return error.InvalidValue;
			config.fts_mode = expanded;
			continue;
		}

		if (std.mem.eql(u8, key, "ignore")) {
			const expanded = try env_expand.expand(allocator, value);
			defer allocator.free(expanded);
			try appendPatterns(allocator, &config.ignore_global, expanded);
			continue;
		}

		if (std.mem.eql(u8, key, "always_include")) {
			const expanded = try env_expand.expand(allocator, value);
			defer allocator.free(expanded);
			try appendPatterns(allocator, &config.always_include, expanded);
			continue;
		}

		if (std.mem.startsWith(u8, key, "ignore.")) {
			const lang = key["ignore.".len..];
			if (lang.len == 0) return error.InvalidValue;
			var entry = try getOrCreateOverride(allocator, &config.ignore_lang, lang);
			const expanded = try env_expand.expand(allocator, value);
			defer allocator.free(expanded);
			try appendPatterns(allocator, &entry.patterns, expanded);
			continue;
		}

		if (std.mem.startsWith(u8, key, "lsp.")) {
			const lang = key["lsp.".len..];
			if (lang.len == 0) return error.InvalidValue;
			try config.lsp_overrides.append(allocator, .{
				.language = try allocator.dupe(u8, lang),
				.binary_path = try env_expand.expand(allocator, value),
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
			config.index_ext = try env_expand.expand(allocator, value);
			continue;
		}

		if (std.mem.eql(u8, key, "index_type")) {
			config.index_type = try env_expand.expand(allocator, value);
			continue;
		}

		if (std.mem.eql(u8, key, "search_ext")) {
			config.search_ext = try env_expand.expand(allocator, value);
			continue;
		}

		if (std.mem.eql(u8, key, "search_type")) {
			config.search_type = try env_expand.expand(allocator, value);
			continue;
		}

		if (std.mem.eql(u8, key, "search_lang")) {
			config.search_lang = try env_expand.expand(allocator, value);
			continue;
		}

		if (std.mem.eql(u8, key, "search_symbol_kind")) {
			config.search_symbol_kind = try env_expand.expand(allocator, value);
			continue;
		}

		if (std.mem.eql(u8, key, "primary_lang")) {
			config.primary_lang = try env_expand.expand(allocator, value);
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

		if (std.mem.eql(u8, key, "watcher_idle_timeout")) {
			config.watcher_idle_timeout = try allocator.dupe(u8, value);
			continue;
		}

		if (std.mem.eql(u8, key, "http_host")) {
			config.http_host = try env_expand.expand(allocator, value);
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
	const io = io_singleton.getOrInit();
	const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
	defer allocator.free(data);
	return parseText(allocator, data);
}

pub fn stripQuotes(value: []const u8) []const u8 {
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
	var buf = @as(std.ArrayListUnmanaged(u8), .empty);
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
		.patterns = .empty,
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

pub const KV = struct {
    key: []const u8,
    value: []const u8,
};

/// Rewrites config content, uncommenting and updating keys that match `kvs`.
/// Keys not found in the original content are appended at the end.
/// Returns a new allocated string with the updated content.
pub fn writeConfigValues(allocator: std.mem.Allocator, content: []const u8, kvs: []const KV) ![]u8 {
    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);

    // Track which kvs were matched
    var matched = try allocator.alloc(bool, kvs.len);
    defer allocator.free(matched);
    @memset(matched, false);

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    var first_line = true;
    while (line_iter.next()) |line| {
        if (!first_line) try output.append(allocator, '\n');
        first_line = false;

        // Check if this line matches any key (commented or uncommented)
        var was_matched = false;
        for (kvs, 0..) |kv, idx| {
            // Match "#key=..." or "# key=..." or "key=..."
            const trimmed = std.mem.trimStart(u8, line, " \t");
            const after_hash = if (std.mem.startsWith(u8, trimmed, "#"))
                std.mem.trimStart(u8, trimmed[1..], " \t")
            else
                trimmed;

            if (std.mem.startsWith(u8, after_hash, kv.key)) {
                const rest = after_hash[kv.key.len..];
                if (rest.len > 0 and rest[0] == '=') {
                    // This line matches — write the uncommented updated value
                    try output.appendSlice(allocator, kv.key);
                    try output.append(allocator, '=');
                    try output.appendSlice(allocator, kv.value);
                    matched[idx] = true;
                    was_matched = true;
                    break;
                }
            }
        }

        if (!was_matched) {
            try output.appendSlice(allocator, line);
        }
    }

    // Append any unmatched keys at the end
    for (kvs, 0..) |kv, idx| {
        if (!matched[idx]) {
            try output.append(allocator, '\n');
            try output.appendSlice(allocator, kv.key);
            try output.append(allocator, '=');
            try output.appendSlice(allocator, kv.value);
        }
    }

    return try output.toOwnedSlice(allocator);
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
	try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = "config", .data = "top=3\n" });
	const allocator = std.testing.allocator;
	const path = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), "config", allocator);
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

test "writeConfigValues updates commented keys" {
    const allocator = std.testing.allocator;
    const input =
        \\# codescan config
        \\#embedding_url=http://localhost:11434
        \\#embedding_api=ollama
        \\#embedding_model=bge-large
        \\#search_mode=hybrid
        \\
    ;
    const kvs = [_]KV{
        .{ .key = "embedding_url", .value = "http://localhost:8000" },
        .{ .key = "embedding_api", .value = "openai" },
        .{ .key = "embedding_model", .value = "jina-code" },
    };
    const result = try writeConfigValues(allocator, input, &kvs);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "embedding_url=http://localhost:8000") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "embedding_api=openai") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "embedding_model=jina-code") != null);
    // search_mode should remain commented
    try std.testing.expect(std.mem.indexOf(u8, result, "#search_mode=hybrid") != null);
}

test "writeConfigValues updates uncommented keys" {
    const allocator = std.testing.allocator;
    const input =
        \\embedding_url=http://localhost:11434
        \\embedding_model=bge-large
        \\
    ;
    const kvs = [_]KV{
        .{ .key = "embedding_url", .value = "http://localhost:8000" },
    };
    const result = try writeConfigValues(allocator, input, &kvs);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "embedding_url=http://localhost:8000") != null);
    // embedding_model should be unchanged
    try std.testing.expect(std.mem.indexOf(u8, result, "embedding_model=bge-large") != null);
}

test "writeConfigValues appends missing keys" {
    const allocator = std.testing.allocator;
    const input =
        \\# codescan config
        \\#embedding_url=http://localhost:11434
        \\
    ;
    const kvs = [_]KV{
        .{ .key = "embedding_url", .value = "http://localhost:8000" },
        .{ .key = "search_mode", .value = "lexical" },
    };
    const result = try writeConfigValues(allocator, input, &kvs);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "embedding_url=http://localhost:8000") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "search_mode=lexical") != null);
}

test "parseText expands ${VAR} in embedding_api_key when set via env" {
    const allocator = std.testing.allocator;
    // PATH is universally set in unix envs, including the nix dev shell.
    var cfg = try parseText(allocator, "embedding_api_key=${PATH}\n");
    defer cfg.deinit(allocator);
    try std.testing.expect(cfg.embedding_api_key != null);
    try std.testing.expect(cfg.embedding_api_key.?.len > 0);
    try std.testing.expect(!std.mem.eql(u8, cfg.embedding_api_key.?, "${PATH}"));
}

test "parseText expands ${UNSET:-default} to default when unset" {
    const allocator = std.testing.allocator;
    var cfg = try parseText(allocator, "embedding_model=${CODESCAN_DEFINITELY_UNSET_123XYZ:-fallback-model}\n");
    defer cfg.deinit(allocator);
    try std.testing.expectEqualStrings("fallback-model", cfg.embedding_model.?);
}

test "parseText passes plain values through unchanged" {
    const allocator = std.testing.allocator;
    var cfg = try parseText(allocator, "embedding_model=bge-large\n");
    defer cfg.deinit(allocator);
    try std.testing.expectEqualStrings("bge-large", cfg.embedding_model.?);
}

test "parseText preserves raw ${VAR} for embedding_api_key when reference present" {
    const allocator = std.testing.allocator;
    var cfg = try parseText(allocator, "embedding_api_key=${PATH}\n");
    defer cfg.deinit(allocator);
    // _raw is set verbatim to the pre-expansion string.
    try std.testing.expect(cfg.embedding_api_key_raw != null);
    try std.testing.expectEqualStrings("${PATH}", cfg.embedding_api_key_raw.?);
    // expanded value is distinct from the placeholder.
    try std.testing.expect(!std.mem.eql(u8, cfg.embedding_api_key.?, "${PATH}"));
}

test "parseText leaves _raw null for plain embedding_api_key value" {
    const allocator = std.testing.allocator;
    var cfg = try parseText(allocator, "embedding_api_key=plain-literal-key\n");
    defer cfg.deinit(allocator);
    try std.testing.expect(cfg.embedding_api_key_raw == null);
    try std.testing.expectEqualStrings("plain-literal-key", cfg.embedding_api_key.?);
}

test "writeValueFor returns raw placeholder for embedding_api_key when _raw is set" {
    const allocator = std.testing.allocator;
    var cfg = try parseText(allocator, "embedding_api_key=${PATH}\n");
    defer cfg.deinit(allocator);
    const v = cfg.writeValueFor("embedding_api_key");
    try std.testing.expectEqualStrings("${PATH}", v);
}

test "writeValueFor returns expanded value for embedding_api_key when _raw is null" {
    const allocator = std.testing.allocator;
    var cfg = try parseText(allocator, "embedding_api_key=plain-key\n");
    defer cfg.deinit(allocator);
    const v = cfg.writeValueFor("embedding_api_key");
    try std.testing.expectEqualStrings("plain-key", v);
}

test "writeValueFor returns expanded value for non-secret fields" {
    const allocator = std.testing.allocator;
    var cfg = try parseText(allocator, "embedding_url=http://host\n");
    defer cfg.deinit(allocator);
    const v = cfg.writeValueFor("embedding_url");
    try std.testing.expectEqualStrings("http://host", v);
}

test "writeValueFor returns empty string for unset fields" {
    const allocator = std.testing.allocator;
    var cfg = try parseText(allocator, "\n");
    defer cfg.deinit(allocator);
    try std.testing.expectEqualStrings("", cfg.writeValueFor("embedding_api_key"));
    try std.testing.expectEqualStrings("", cfg.writeValueFor("embedding_url"));
}

test "setApiKeyLiteral clears _raw and replaces expanded with new literal" {
    const allocator = std.testing.allocator;
    var cfg = try parseText(allocator, "embedding_api_key=${PATH}\n");
    defer cfg.deinit(allocator);
    try std.testing.expect(cfg.embedding_api_key_raw != null);
    try cfg.setApiKeyLiteral(allocator, "new-literal");
    try std.testing.expect(cfg.embedding_api_key_raw == null);
    try std.testing.expectEqualStrings("new-literal", cfg.embedding_api_key.?);
    // Subsequent writeValueFor returns the new literal.
    try std.testing.expectEqualStrings("new-literal", cfg.writeValueFor("embedding_api_key"));
}

test "writeConfigValues roundtrip preserves ${VAR} placeholder via writeValueFor" {
    const allocator = std.testing.allocator;
    const original =
        \\#embedding_url=http://localhost:11434
        \\embedding_api_key=${PATH}
        \\
    ;
    var cfg = try parseText(allocator, original);
    defer cfg.deinit(allocator);

    const kvs = [_]KV{
        .{ .key = "embedding_api_key", .value = cfg.writeValueFor("embedding_api_key") },
    };
    const updated = try writeConfigValues(allocator, original, &kvs);
    defer allocator.free(updated);

    try std.testing.expect(std.mem.indexOf(u8, updated, "embedding_api_key=${PATH}") != null);
    // Must NOT contain the resolved PATH value:
    try std.testing.expect(std.mem.indexOf(u8, updated, cfg.embedding_api_key.?) == null);
}

/// Merges a higher-precedence config over a lower-precedence one, key by key,
/// taking ownership of the overlay's values and leaving it safe to deinit.
///
/// Per-key rather than whole-file is the entire point: a project that sets only
/// `top=5` must still inherit a global `embedding_url`. A whole-file override
/// would mean any project with a config at all stops inheriting anything.
///
/// The field sweep is comptime over `Config`'s fields, so a newly added setting
/// participates automatically. A hand-written merge is exactly the kind of list
/// that silently falls out of date, and the failure mode — one setting quietly
/// not inheriting — is invisible until someone debugs it by hand.
pub fn applyOver(allocator: std.mem.Allocator, base: *Config, overlay: *Config) !void {
	inline for (@typeInfo(Config).@"struct".fields) |field| {
		const info = @typeInfo(field.type);
		if (comptime info == .optional) {
			if (@field(overlay, field.name)) |value| {
				// Owned strings must not leak when displaced; scalars and enums
				// are copied.
				if (comptime info.optional.child == []const u8) {
					if (@field(base, field.name)) |old| allocator.free(old);
				}
				@field(base, field.name) = value;
				@field(overlay, field.name) = null;
			}
		} else {
			// List-valued settings accumulate rather than replace, so a project
			// adds to the global ignore set instead of discarding it. Ownership
			// of each element transfers; clearing prevents a double free.
			try @field(base, field.name).appendSlice(allocator, @field(overlay, field.name).items);
			@field(overlay, field.name).clearRetainingCapacity();
		}
	}
}

test "applyOver merges per key rather than per file" {
	const allocator = std.testing.allocator;

	// Global: a URL and a model, plus one ignore pattern.
	var global = try parseText(allocator,
		\\embedding_url=http://global:11434
		\\embedding_model=jina-code-embeddings:1.5b
		\\embedding_dim=1536
		\\ignore=vendor/
		\\
	);
	defer global.deinit(allocator);

	// Project: overrides only the model and adds an ignore. Everything else
	// must survive from the global — this is the case that makes one embedding
	// URL across many projects actually work.
	var project = try parseText(allocator,
		\\embedding_model=bge-large
		\\top=5
		\\ignore=build/
		\\
	);
	defer project.deinit(allocator);

	try applyOver(allocator, &global, &project);

	// Set only globally: inherited.
	try std.testing.expectEqualStrings("http://global:11434", global.embedding_url.?);
	try std.testing.expectEqual(@as(?usize, 1536), global.embedding_dim);
	// Set in both: project wins.
	try std.testing.expectEqualStrings("bge-large", global.embedding_model.?);
	// Set only in the project: adopted.
	try std.testing.expectEqual(@as(?usize, 5), global.top_n);
	// Set in neither: still absent.
	try std.testing.expect(global.search_lang == null);
	// Lists accumulate, global first.
	try std.testing.expectEqual(@as(usize, 2), global.ignore_global.items.len);
	try std.testing.expectEqualStrings("vendor/", global.ignore_global.items[0]);
	try std.testing.expectEqualStrings("build/", global.ignore_global.items[1]);
}

test "applyOver leaves the base untouched when the overlay is empty" {
	const allocator = std.testing.allocator;

	var base = try parseText(allocator,
		\\embedding_url=http://global:11434
		\\ignore=vendor/
		\\
	);
	defer base.deinit(allocator);

	// An empty config carries no opinion, so merging it must change nothing.
	// This is what makes a project without a config inherit the global one
	// wholesale.
	var empty = Config{};
	defer empty.deinit(allocator);

	try applyOver(allocator, &base, &empty);

	try std.testing.expectEqualStrings("http://global:11434", base.embedding_url.?);
	try std.testing.expectEqual(@as(usize, 1), base.ignore_global.items.len);
}

test "applyOver covers every Config field, including ones added later" {
	// A merge that silently skips a field is invisible in normal use, so assert
	// mechanically that the sweep reaches all of them rather than trusting that
	// the two tests above happen to cover the interesting ones.
	comptime {
		var optional_fields = 0;
		var list_fields = 0;
		for (@typeInfo(Config).@"struct".fields) |field| {
			switch (@typeInfo(field.type)) {
				.optional => optional_fields += 1,
				.@"struct" => list_fields += 1,
				else => @compileError("Config field '" ++ field.name ++
					"' is neither optional nor a list, so applyOver has no rule for it"),
			}
		}
		if (optional_fields == 0 or list_fields == 0) @compileError("Config shape changed unexpectedly");
	}
}

/// Path to the machine-wide config, honouring `XDG_CONFIG_HOME` and falling
/// back to `~/.config`. Returns null when neither variable is set, in which
/// case there is simply no global tier rather than a guessed location.
pub fn globalPath(allocator: std.mem.Allocator) !?[]u8 {
	const env_map = io_singleton.getEnvMapOrInit(allocator);
	if (env_map.get("XDG_CONFIG_HOME")) |xdg| {
		if (xdg.len > 0) return try std.fs.path.join(allocator, &.{ xdg, "codescan", "config.ini" });
	}
	const home = env_map.get("HOME") orelse return null;
	if (home.len == 0) return null;
	return try std.fs.path.join(allocator, &.{ home, ".config", "codescan", "config.ini" });
}

test "globalPath prefers XDG_CONFIG_HOME and falls back to HOME" {
	const allocator = std.testing.allocator;

	var env = std.process.Environ.Map.init(allocator);
	defer env.deinit();
	io_singleton.setEnvMap(&env);
	defer io_singleton.setEnvMap(null);

	// Neither set: no global tier, rather than a guessed path.
	try std.testing.expect((try globalPath(allocator)) == null);

	try env.put("HOME", "/home/someone");
	{
		const path = (try globalPath(allocator)).?;
		defer allocator.free(path);
		try std.testing.expectEqualStrings("/home/someone/.config/codescan/config.ini", path);
	}

	try env.put("XDG_CONFIG_HOME", "/xdg");
	{
		const path = (try globalPath(allocator)).?;
		defer allocator.free(path);
		try std.testing.expectEqualStrings("/xdg/codescan/config.ini", path);
	}

	// An empty XDG value must not produce a path rooted at "/", which would
	// silently read someone else's file.
	try env.put("XDG_CONFIG_HOME", "");
	{
		const path = (try globalPath(allocator)).?;
		defer allocator.free(path);
		try std.testing.expectEqualStrings("/home/someone/.config/codescan/config.ini", path);
	}
}
