const std = @import("std");
const search = @import("search.zig");

pub const OutputFormat = enum {
	human,
	json,
};

pub const CommandTag = enum {
	help,
	config,
	init,
	index,
	update,
	search,
	serve,
	symbols,
	replace_symbol,
	insert_after,
	insert_before,
	replace_lines,
	insert_at,
	replace_content,
	create_file,
	read_file,
	destroy_file,
	diff,
	references,
	rename,
	watch,
	mcp_serve,
	clean,
	status,
};

pub const ConfigAction = enum {
	show,
	edit,
};

pub const WatchAction = enum {
	run, // default: foreground watcher
	stop,
	start, // background daemon
	restart,
	status,
	pid,
};

pub const Seen = struct {
	output: bool = false,
	show_comments: bool = false,
	include_docs: bool = false,
	docs_only: bool = false,
	comments_only: bool = false,
	include_node_modules: bool = false,
	top_n: bool = false,
	root_path: bool = false,
	db_path: bool = false,
	ollama_url: bool = false,
	ollama_model: bool = false,
	embedding_dim: bool = false,
	batch_size: bool = false,
	max_file_size: bool = false,
	http_host: bool = false,
	http_port: bool = false,
	search_mode: bool = false,
	fusion: bool = false,
	rrf_k: bool = false,
	fts_mode: bool = false,
	weight_vector: bool = false,
	weight_lexical: bool = false,
	min_score: bool = false,
	ext_filter: bool = false,
	type_filter: bool = false,
	lang_filter: bool = false,
	kind_filter: bool = false,
    scope: bool = false,
	force: bool = false,
	dry_run: bool = false,
	confirm: bool = false,
};

pub const Parsed = struct {
	command: CommandTag,
	config_action: ConfigAction,
	assumed_search: bool,
	query_owned: bool,
    help_topic: ?[]const u8,
	output: OutputFormat,
	show_comments: bool,
	include_docs: bool,
	docs_only: bool,
	comments_only: bool,
	include_node_modules: bool,
	query: ?[]const u8,
	top_n: usize,
	root_path: []const u8,
	db_path: []const u8,
	ollama_url: []const u8,
	ollama_model: []const u8,
	embedding_dim: usize,
	batch_size: usize,
	max_file_size: usize,
	http_host: []const u8,
	http_port: u16,
	search_mode: search.SearchMode,
	fusion: search.FusionMode,
	rrf_k: f32,
	fts_mode: search.FtsMode,
	weight_vector: f32,
	weight_lexical: f32,
	min_score: f32,
	ext_filter: ?[]const u8,
	type_filter: ?[]const u8,
	lang_filter: ?[]const u8,
	kind_filter: ?[]const u8,
	path_filters: std.ArrayListUnmanaged([]const u8),
	file_filter: ?[]const u8,
	symbols_files: std.ArrayListUnmanaged([]const u8),
	pattern: ?[]const u8,
	include_body: bool,
	from_ref: ?[]const u8,
	to_ref: ?[]const u8,
	from_line: ?usize,
	to_line: ?usize,
	hashline_ref: ?[]const u8,
	rename_to: ?[]const u8,
	regex_mode: bool,
	regex_search: bool,
	ignore_case: bool,
	context_lines: usize,
	replace_all: bool,
	version_hash: ?[]const u8,
	confirm_hash: ?[]const u8,
	staged: bool,
	watch_interval: u64,
	watch_action: WatchAction,
	force: bool,
	dry_run: bool,
	confirm: bool,
	seen: Seen,

	pub fn deinit(self: *Parsed, allocator: std.mem.Allocator) void {
		if (self.query_owned and self.query != null) {
			allocator.free(self.query.?);
		}
		self.path_filters.deinit(allocator);
		self.symbols_files.deinit(allocator);
	}
};

pub fn parse(allocator: std.mem.Allocator, args: []const []const u8) !Parsed {
	if (args.len <= 1) {
		return error.MissingQuery;
	}
	var parsed = Parsed{
		.command = .help,
		.config_action = .show,
		.assumed_search = false,
		.query_owned = false,
        .help_topic = null,
		.output = .human,
		.show_comments = false,
		.include_docs = false,
		.docs_only = false,
		.comments_only = false,
		.include_node_modules = false,
		.query = null,
		.top_n = 5,
		.root_path = ".",
		.db_path = ".codescan/index.sqlite3",
		.ollama_url = "http://localhost:11434",
		.ollama_model = "bge-large",
		.embedding_dim = 1024,
		.batch_size = 16,
		.max_file_size = 2 * 1024 * 1024,
		.http_host = "127.0.0.1",
		.http_port = 8123,
		.search_mode = .hybrid,
		.fusion = .weighted_sum,
		.rrf_k = 60,
		.fts_mode = .broad,
		.weight_vector = 0.7,
		.weight_lexical = 0.3,
		.min_score = 0.0,
		.ext_filter = null,
		.type_filter = null,
		.lang_filter = null,
		.kind_filter = null,
		.path_filters = .{},
		.file_filter = null,
		.symbols_files = .{},
		.pattern = null,
		.include_body = false,
		.from_ref = null,
		.to_ref = null,
		.from_line = null,
		.to_line = null,
		.hashline_ref = null,
		.rename_to = null,
		.regex_mode = false,
		.regex_search = false,
		.ignore_case = false,
		.context_lines = 0,
		.replace_all = false,
		.version_hash = null,
		.confirm_hash = null,
		.staged = false,
		.watch_interval = 2000,
		.watch_action = .run,
		.force = false,
		.dry_run = false,
		.confirm = false,
		.seen = .{},
	};

	var query_parts: std.ArrayList([]const u8) = undefined;
	var query_parts_inited = false;
	defer if (query_parts_inited) query_parts.deinit(allocator);

	var i: usize = 1;
	if (i >= args.len) {
		return parsed;
	}

	const cmd = args[i];
    var help_topic_default: ?[]const u8 = null;
	if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
		parsed.command = .help;
        i += 1;
        if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
            parsed.help_topic = args[i];
        }
		return parsed;
	} else if (std.mem.eql(u8, cmd, "config")) {
		parsed.command = .config;
        help_topic_default = "config";
		i += 1;
	} else if (std.mem.eql(u8, cmd, "init")) {
		parsed.command = .init;
        help_topic_default = "init";
		i += 1;
	} else if (std.mem.eql(u8, cmd, "index")) {
		parsed.command = .index;
        help_topic_default = "index";
		i += 1;
	} else if (std.mem.eql(u8, cmd, "update")) {
		parsed.command = .update;
        help_topic_default = "update";
		i += 1;
	} else if (std.mem.eql(u8, cmd, "search") or std.mem.eql(u8, cmd, "query")) {
		parsed.command = .search;
        help_topic_default = "search";
		i += 1;
	} else if (std.mem.eql(u8, cmd, "serve")) {
		parsed.command = .serve;
        help_topic_default = "serve";
		i += 1;
	} else if (std.mem.eql(u8, cmd, "symbols") or std.mem.eql(u8, cmd, "find-symbol")) {
		parsed.command = .symbols;
        help_topic_default = "symbols";
		i += 1;
		// Next non-flag arg is the pattern (optional)
		if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
			parsed.pattern = args[i];
			i += 1;
		}
	} else if (std.mem.eql(u8, cmd, "replace-symbol")) {
		parsed.command = .replace_symbol;
        help_topic_default = "replace-symbol";
		i += 1;
		if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
			parsed.pattern = args[i];
			i += 1;
		}
	} else if (std.mem.eql(u8, cmd, "insert-after")) {
		parsed.command = .insert_after;
        help_topic_default = "insert-after";
		i += 1;
		if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
			parsed.pattern = args[i];
			i += 1;
		}
	} else if (std.mem.eql(u8, cmd, "insert-before")) {
		parsed.command = .insert_before;
        help_topic_default = "insert-before";
		i += 1;
		if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
			parsed.pattern = args[i];
			i += 1;
		}
	} else if (std.mem.eql(u8, cmd, "replace-lines")) {
		parsed.command = .replace_lines;
        help_topic_default = "replace-lines";
		i += 1;
	} else if (std.mem.eql(u8, cmd, "insert-at")) {
		parsed.command = .insert_at;
        help_topic_default = "insert-at";
		i += 1;
		if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
			parsed.hashline_ref = args[i];
			i += 1;
		}
	} else if (std.mem.eql(u8, cmd, "replace-content")) {
		parsed.command = .replace_content;
        help_topic_default = "replace-content";
		i += 1;
		if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
			parsed.pattern = args[i];
			i += 1;
		}
	} else if (std.mem.eql(u8, cmd, "create-file")) {
		parsed.command = .create_file;
        help_topic_default = "create-file";
		i += 1;
	} else if (std.mem.eql(u8, cmd, "read-file")) {
		parsed.command = .read_file;
        help_topic_default = "read-file";
		i += 1;
		if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
			parsed.pattern = args[i]; // reuse pattern for file path
			i += 1;
		}
	} else if (std.mem.eql(u8, cmd, "destroy-file")) {
		parsed.command = .destroy_file;
        help_topic_default = "destroy-file";
		i += 1;
	} else if (std.mem.eql(u8, cmd, "diff")) {
		parsed.command = .diff;
        help_topic_default = "diff";
		i += 1;
	} else if (std.mem.eql(u8, cmd, "references")) {
		parsed.command = .references;
        help_topic_default = "references";
		i += 1;
		if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
			parsed.pattern = args[i];
			i += 1;
		}
	} else if (std.mem.eql(u8, cmd, "rename")) {
		parsed.command = .rename;
        help_topic_default = "rename";
		i += 1;
		if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
			parsed.pattern = args[i];
			i += 1;
		}
	} else if (std.mem.eql(u8, cmd, "mcp-serve")) {
		parsed.command = .mcp_serve;
        help_topic_default = "mcp-serve";
		i += 1;
	} else if (std.mem.eql(u8, cmd, "watch") or std.mem.eql(u8, cmd, "watcher")) {
		parsed.command = .watch;
        help_topic_default = "watch";
		i += 1;
		// Parse optional watch subcommand
		if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
			const sub = args[i];
			if (std.mem.eql(u8, sub, "stop")) {
				parsed.watch_action = .stop;
				i += 1;
			} else if (std.mem.eql(u8, sub, "start")) {
				parsed.watch_action = .start;
				i += 1;
			} else if (std.mem.eql(u8, sub, "restart")) {
				parsed.watch_action = .restart;
				i += 1;
			} else if (std.mem.eql(u8, sub, "status")) {
				parsed.watch_action = .status;
				i += 1;
			} else if (std.mem.eql(u8, sub, "pid")) {
				parsed.watch_action = .pid;
				i += 1;
			}
		}
	} else if (std.mem.eql(u8, cmd, "status")) {
		parsed.command = .status;
        help_topic_default = "status";
		i += 1;
	} else if (std.mem.eql(u8, cmd, "clean") or std.mem.eql(u8, cmd, "clear")) {
		parsed.command = .clean;
        help_topic_default = "clean";
		i += 1;
	} else {
		parsed.command = .search;
		parsed.assumed_search = true;
        help_topic_default = "search";
	}

	while (i < args.len) {
		const arg = args[i];
		if (parsed.command == .config) {
			if (std.mem.eql(u8, arg, "show")) {
				parsed.config_action = .show;
				i += 1;
				continue;
			}
			if (std.mem.eql(u8, arg, "edit")) {
				parsed.config_action = .edit;
				i += 1;
				continue;
			}
		}
		if (std.mem.eql(u8, arg, "--json")) {
			parsed.output = .json;
			parsed.seen.output = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--format")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			if (std.mem.eql(u8, args[i], "json")) {
				parsed.output = .json;
			} else if (std.mem.eql(u8, args[i], "human")) {
				parsed.output = .human;
			} else {
				return error.InvalidValue;
			}
			parsed.seen.output = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "--show-comments")) {
			parsed.show_comments = true;
			parsed.seen.show_comments = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--comments") or std.mem.eql(u8, arg, "--only-comments")) {
			parsed.comments_only = true;
            parsed.docs_only = false;
			parsed.seen.comments_only = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--include-node-modules")) {
			parsed.include_node_modules = true;
			parsed.seen.include_node_modules = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--include-docs")) {
			parsed.include_docs = true;
			parsed.seen.include_docs = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--docs") or std.mem.eql(u8, arg, "--only-docs")) {
			parsed.docs_only = true;
            parsed.include_docs = true;
            parsed.comments_only = false;
			parsed.seen.docs_only = true;
			i += 1;
			continue;
		}
        if (std.mem.eql(u8, arg, "--scope")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            const scope_value = args[i];
            if (std.mem.eql(u8, scope_value, "code")) {
                parsed.include_docs = false;
                parsed.docs_only = false;
                parsed.comments_only = false;
            } else if (std.mem.eql(u8, scope_value, "docs")) {
                parsed.include_docs = true;
                parsed.docs_only = true;
                parsed.comments_only = false;
            } else if (std.mem.eql(u8, scope_value, "comments")) {
                parsed.include_docs = false;
                parsed.docs_only = false;
                parsed.comments_only = true;
            } else if (std.mem.eql(u8, scope_value, "all")) {
                parsed.include_docs = true;
                parsed.docs_only = false;
                parsed.comments_only = false;
            } else {
                return error.InvalidValue;
            }
            parsed.seen.include_docs = true;
            parsed.seen.docs_only = true;
            parsed.seen.comments_only = true;
            parsed.seen.scope = true;
            i += 1;
            continue;
        }
		if (std.mem.eql(u8, arg, "--top")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			parsed.top_n = try std.fmt.parseInt(usize, args[i], 10);
			parsed.seen.top_n = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--root")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			parsed.root_path = args[i];
			parsed.seen.root_path = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--db")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			parsed.db_path = args[i];
			parsed.seen.db_path = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--ollama-url")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			parsed.ollama_url = args[i];
			parsed.seen.ollama_url = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--ollama-model")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			parsed.ollama_model = args[i];
			parsed.seen.ollama_model = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--embedding-dim")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			parsed.embedding_dim = try std.fmt.parseInt(usize, args[i], 10);
			parsed.seen.embedding_dim = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--batch")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			parsed.batch_size = try std.fmt.parseInt(usize, args[i], 10);
			parsed.seen.batch_size = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--max-file-size")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			parsed.max_file_size = try std.fmt.parseInt(usize, args[i], 10);
			parsed.seen.max_file_size = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--http-host")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			parsed.http_host = args[i];
			parsed.seen.http_host = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--http-port")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			parsed.http_port = try std.fmt.parseInt(u16, args[i], 10);
			parsed.seen.http_port = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--mode")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			parsed.search_mode = try search.SearchMode.parse(args[i]);
			parsed.seen.search_mode = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--fusion")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			parsed.fusion = try search.FusionMode.parse(args[i]);
			parsed.seen.fusion = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--rrf-k")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			parsed.rrf_k = try std.fmt.parseFloat(f32, args[i]);
			parsed.seen.rrf_k = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--fts-mode")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			parsed.fts_mode = try search.FtsMode.parse(args[i]);
			parsed.seen.fts_mode = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--weight-vector")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			parsed.weight_vector = try std.fmt.parseFloat(f32, args[i]);
			parsed.seen.weight_vector = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--weight-lexical")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			parsed.weight_lexical = try std.fmt.parseFloat(f32, args[i]);
			parsed.seen.weight_lexical = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--min-score")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			parsed.min_score = try std.fmt.parseFloat(f32, args[i]);
			parsed.seen.min_score = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--ext")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			parsed.ext_filter = args[i];
			parsed.seen.ext_filter = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--type")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			parsed.type_filter = args[i];
			parsed.seen.type_filter = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--lang")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			parsed.lang_filter = args[i];
			parsed.seen.lang_filter = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--kind")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			parsed.kind_filter = args[i];
			parsed.seen.kind_filter = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--path")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			try parsed.path_filters.append(allocator, args[i]);
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--include-body")) {
			parsed.include_body = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--from")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			if (parsed.command == .read_file) {
				parsed.from_line = std.fmt.parseInt(usize, args[i], 10) catch return error.InvalidValue;
			} else {
				parsed.from_ref = args[i];
			}
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--to")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			if (parsed.command == .read_file) {
				parsed.to_line = std.fmt.parseInt(usize, args[i], 10) catch return error.InvalidValue;
			} else if (parsed.command == .rename) {
				parsed.rename_to = args[i];
			} else {
				parsed.to_ref = args[i];
			}
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--interval")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			parsed.watch_interval = std.fmt.parseInt(u64, args[i], 10) catch return error.InvalidNumber;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--file")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			if (parsed.command == .search) {
				const val = args[i];
				if (std.mem.indexOfAny(u8, val, "*?[{") != null) return error.InvalidFileFilter;
				parsed.file_filter = val;
			} else {
				try parsed.symbols_files.append(allocator, args[i]);
			}
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
			parsed.force = true;
			parsed.seen.force = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--confirm") or std.mem.eql(u8, arg, "-y")) {
			parsed.confirm = true;
			parsed.seen.confirm = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--dry-run") or std.mem.eql(u8, arg, "-n")) {
			parsed.dry_run = true;
			parsed.seen.dry_run = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--regex")) {
			if (parsed.command == .search) {
				parsed.regex_search = true;
			} else {
				parsed.regex_mode = true;
			}
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--staged") or std.mem.eql(u8, arg, "--cached")) {
			parsed.staged = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--ignore-case") or std.mem.eql(u8, arg, "-i")) {
			parsed.ignore_case = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--context") or std.mem.eql(u8, arg, "-C")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			parsed.context_lines = std.fmt.parseInt(usize, args[i], 10) catch return error.InvalidValue;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--version")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			parsed.version_hash = args[i];
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--confirm")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			parsed.confirm_hash = args[i];
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--all")) {
			parsed.replace_all = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
			parsed.command = .help;
            parsed.help_topic = help_topic_default;
			return parsed;
		}

		if (parsed.command == .search) {
			if (!query_parts_inited) {
				query_parts = .{};
				query_parts_inited = true;
			}
			try query_parts.append(allocator, arg);
			i += 1;
			continue;
		}

		// Collect positional args for commands that expect them
		switch (parsed.command) {
			.symbols, .replace_symbol, .insert_after, .insert_before, .replace_content, .references, .rename => {
				if (parsed.pattern == null) {
					parsed.pattern = arg;
					i += 1;
					continue;
				}
			},
			.insert_at => {
				if (parsed.hashline_ref == null) {
					parsed.hashline_ref = arg;
					i += 1;
					continue;
				}
			},
			else => {},
		}

		return error.UnexpectedArg;
	}

	if (parsed.command == .search) {
		if (!query_parts_inited or query_parts.items.len == 0) {
			// Allow empty query when filters are present (browse mode)
			if (parsed.kind_filter == null and parsed.lang_filter == null and parsed.ext_filter == null and
				parsed.path_filters.items.len == 0 and parsed.file_filter == null) {
				return error.MissingQuery;
			}
			// query stays null — search.zig will handle browse mode
		} else if (query_parts.items.len == 1) {
			parsed.query = query_parts.items[0];
		} else {
			parsed.query = try joinArgs(allocator, query_parts.items);
			parsed.query_owned = true;
		}
	}

	return parsed;
}

fn joinArgs(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
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

test "parse with no args requires query" {
	const args = [_][]const u8{ "codescan" };
	try std.testing.expectError(error.MissingQuery, parse(std.testing.allocator, &args));
}

test "parse defaults to search when first arg is query" {
	const args = [_][]const u8{ "codescan", "checksum" };
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.search, parsed.command);
	try std.testing.expect(parsed.assumed_search);
	try std.testing.expectEqualStrings("checksum", parsed.query.?);
}

test "parse help with topic" {
    const args = [_][]const u8{ "codescan", "help", "search" };
    var parsed = try parse(std.testing.allocator, &args);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(CommandTag.help, parsed.command);
    try std.testing.expect(parsed.help_topic != null);
    try std.testing.expectEqualStrings("search", parsed.help_topic.?);
}

test "parse command --help sets help topic" {
    const args = [_][]const u8{ "codescan", "index", "--help" };
    var parsed = try parse(std.testing.allocator, &args);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(CommandTag.help, parsed.command);
    try std.testing.expect(parsed.help_topic != null);
    try std.testing.expectEqualStrings("index", parsed.help_topic.?);
}

test "parse defaults to search when first arg is flag" {
	const args = [_][]const u8{
		"codescan",
		"--docs",
		"design doc",
	};
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.search, parsed.command);
	try std.testing.expect(parsed.assumed_search);
	try std.testing.expect(parsed.docs_only);
	try std.testing.expectEqualStrings("design doc", parsed.query.?);
}

test "parse defaults to search with multi word query" {
	const args = [_][]const u8{ "codescan", "memory", "allocation" };
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.search, parsed.command);
	try std.testing.expect(parsed.assumed_search);
	try std.testing.expectEqualStrings("memory allocation", parsed.query.?);
}

test "parse search with query defaults" {
	const args = [_][]const u8{ "codescan", "search", "hash functions" };
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.search, parsed.command);
	try std.testing.expectEqual(OutputFormat.human, parsed.output);
	try std.testing.expect(parsed.show_comments == false);
	try std.testing.expect(parsed.comments_only == false);
	try std.testing.expectEqualStrings("hash functions", parsed.query.?);
	try std.testing.expectEqual(@as(usize, 5), parsed.top_n);
	try std.testing.expectEqualStrings(".", parsed.root_path);
	try std.testing.expectEqualStrings(".codescan/index.sqlite3", parsed.db_path);
	try std.testing.expectEqualStrings("http://localhost:11434", parsed.ollama_url);
	try std.testing.expect(parsed.search_mode == .hybrid);
	try std.testing.expect(parsed.seen.top_n == false);
}

test "parse search joins multi word args" {
	const args = [_][]const u8{ "codescan", "search", "memory", "allocation" };
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.search, parsed.command);
	try std.testing.expectEqualStrings("memory allocation", parsed.query.?);
}

test "parse search with weights" {
	const args = [_][]const u8{
		"codescan",
		"search",
		"checksum",
		"--weight-vector",
		"0.8",
		"--weight-lexical",
		"0.2",
		"--min-score",
		"0.4",
	};
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.search, parsed.command);
	try std.testing.expectEqualStrings("checksum", parsed.query.?);
	try std.testing.expect(parsed.show_comments == false);
	try std.testing.expect(parsed.comments_only == false);
	try std.testing.expectApproxEqAbs(@as(f32, 0.8), parsed.weight_vector, 0.0001);
	try std.testing.expectApproxEqAbs(@as(f32, 0.2), parsed.weight_lexical, 0.0001);
	try std.testing.expectApproxEqAbs(@as(f32, 0.4), parsed.min_score, 0.0001);
	try std.testing.expect(parsed.seen.weight_vector);
	try std.testing.expect(parsed.seen.weight_lexical);
	try std.testing.expect(parsed.seen.min_score);
}

test "parse search with flags" {
	const args = [_][]const u8{
		"codescan",
		"search",
		"--show-comments",
		"--include-docs",
		"--ext",
		"zig,md",
		"--type",
		"code,doc",
		"--lang",
		"zig",
		"--include-node-modules",
		"--json",
		"--top",
		"5",
		"--root",
		"/repo",
		"--db",
		"/repo/.codescan/db.sqlite3",
		"--ollama-url",
		"http://127.0.0.1:11434",
		"--ollama-model",
		"bge-large",
		"--embedding-dim",
		"768",
		"--batch",
		"8",
		"--max-file-size",
		"2048",
		"--http-host",
		"0.0.0.0",
		"--http-port",
		"9001",
		"--mode",
		"vector",
		"--min-score",
		"0.6",
		"hash functions",
	};
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.search, parsed.command);
	try std.testing.expectEqual(OutputFormat.json, parsed.output);
	try std.testing.expect(parsed.show_comments);
	try std.testing.expect(parsed.include_docs);
	try std.testing.expect(parsed.docs_only == false);
	try std.testing.expect(parsed.comments_only == false);
	try std.testing.expect(parsed.include_node_modules);
	try std.testing.expectEqualStrings("zig,md", parsed.ext_filter.?);
	try std.testing.expectEqualStrings("code,doc", parsed.type_filter.?);
	try std.testing.expectEqualStrings("zig", parsed.lang_filter.?);
	try std.testing.expectEqualStrings("hash functions", parsed.query.?);
	try std.testing.expectEqual(@as(usize, 5), parsed.top_n);
	try std.testing.expectEqualStrings("/repo", parsed.root_path);
	try std.testing.expectEqualStrings("/repo/.codescan/db.sqlite3", parsed.db_path);
	try std.testing.expectEqualStrings("http://127.0.0.1:11434", parsed.ollama_url);
	try std.testing.expectEqualStrings("bge-large", parsed.ollama_model);
	try std.testing.expectEqual(@as(usize, 768), parsed.embedding_dim);
	try std.testing.expectEqual(@as(usize, 8), parsed.batch_size);
	try std.testing.expectEqual(@as(usize, 2048), parsed.max_file_size);
	try std.testing.expectEqualStrings("0.0.0.0", parsed.http_host);
	try std.testing.expectEqual(@as(u16, 9001), parsed.http_port);
	try std.testing.expect(parsed.search_mode == .vector);
	try std.testing.expectApproxEqAbs(@as(f32, 0.6), parsed.min_score, 0.0001);
	try std.testing.expect(parsed.seen.http_port);
}

test "parse config defaults to show" {
	const args = [_][]const u8{ "codescan", "config" };
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.config, parsed.command);
	try std.testing.expectEqual(ConfigAction.show, parsed.config_action);
}

test "parse config edit" {
	const args = [_][]const u8{ "codescan", "config", "edit" };
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.config, parsed.command);
	try std.testing.expectEqual(ConfigAction.edit, parsed.config_action);
}

test "parse search with verbose alias" {
	const args = [_][]const u8{
		"codescan",
		"search",
		"--verbose",
		"hash",
	};
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.search, parsed.command);
	try std.testing.expect(parsed.show_comments);
	try std.testing.expect(parsed.seen.show_comments);
}

test "parse search with docs flag" {
	const args = [_][]const u8{
		"codescan",
		"search",
		"--docs",
		"design doc",
	};
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.search, parsed.command);
	try std.testing.expect(parsed.docs_only);
	try std.testing.expect(parsed.seen.docs_only);
	try std.testing.expectEqualStrings("design doc", parsed.query.?);
}

test "parse search with comments flag" {
	const args = [_][]const u8{
		"codescan",
		"search",
		"--only-comments",
		"doc query",
	};
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.search, parsed.command);
	try std.testing.expect(parsed.comments_only);
	try std.testing.expect(parsed.seen.comments_only);
	try std.testing.expectEqualStrings("doc query", parsed.query.?);
}

test "parse search with --scope docs" {
    const args = [_][]const u8{
        "codescan",
        "search",
        "--scope",
        "docs",
        "design",
    };
    var parsed = try parse(std.testing.allocator, &args);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(parsed.docs_only);
    try std.testing.expect(!parsed.comments_only);
}

test "parse search with --scope comments" {
    const args = [_][]const u8{
        "codescan",
        "search",
        "--scope",
        "comments",
        "hash",
    };
    var parsed = try parse(std.testing.allocator, &args);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(parsed.comments_only);
    try std.testing.expect(!parsed.docs_only);
}

test "parse search with --scope all" {
    const args = [_][]const u8{
        "codescan",
        "search",
        "--scope",
        "all",
        "hash",
    };
    var parsed = try parse(std.testing.allocator, &args);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(parsed.include_docs);
    try std.testing.expect(!parsed.docs_only);
    try std.testing.expect(!parsed.comments_only);
}

test "parse search with repeated --scope uses last value" {
    const args = [_][]const u8{
        "codescan",
        "search",
        "--scope",
        "docs",
        "--scope",
        "code",
        "hash",
    };
    var parsed = try parse(std.testing.allocator, &args);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(!parsed.include_docs);
    try std.testing.expect(!parsed.docs_only);
    try std.testing.expect(!parsed.comments_only);
}

test "parse search with invalid --scope value errors" {
    const args = [_][]const u8{
        "codescan",
        "search",
        "--scope",
        "everything",
        "hash",
    };
    try std.testing.expectError(error.InvalidValue, parse(std.testing.allocator, &args));
}

test "parse recognizes --format json" {
	const args = [_][]const u8{ "codescan", "search", "--format", "json", "query" };
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(OutputFormat.json, parsed.output);
	try std.testing.expect(parsed.seen.output);
}

test "parse recognizes --format human" {
	const args = [_][]const u8{ "codescan", "search", "--format", "human", "query" };
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(OutputFormat.human, parsed.output);
	try std.testing.expect(parsed.seen.output);
}

test "parse --format invalid value errors" {
	const args = [_][]const u8{ "codescan", "search", "--format", "xml", "query" };
	try std.testing.expectError(error.InvalidValue, parse(std.testing.allocator, &args));
}

test "parse search missing query errors" {
	const args = [_][]const u8{ "codescan", "search" };
	try std.testing.expectError(error.MissingQuery, parse(std.testing.allocator, &args));
}

test "parse search with --kind but no query allows browse mode" {
	const args = [_][]const u8{ "codescan", "search", "--kind", "fn" };
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.search, parsed.command);
	try std.testing.expect(parsed.query == null);
	try std.testing.expectEqualStrings("fn", parsed.kind_filter.?);
}

test "parse init command" {
	const args = [_][]const u8{ "codescan", "init" };
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.init, parsed.command);
	try std.testing.expect(!parsed.force);
}

test "parse init --force" {
	const args = [_][]const u8{ "codescan", "init", "--force" };
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.init, parsed.command);
	try std.testing.expect(parsed.force);
	try std.testing.expect(parsed.seen.force);
}

test "parse init -f shorthand" {
	const args = [_][]const u8{ "codescan", "init", "-f" };
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.init, parsed.command);
	try std.testing.expect(parsed.force);
}

test "parse status command" {
	const args = [_][]const u8{ "codescan", "status" };
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.status, parsed.command);
}

test "parse status --json" {
	const args = [_][]const u8{ "codescan", "status", "--json" };
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.status, parsed.command);
	try std.testing.expectEqual(OutputFormat.json, parsed.output);
}

test "parse clean command" {
	const args = [_][]const u8{ "codescan", "clean" };
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.clean, parsed.command);
	try std.testing.expect(!parsed.confirm);
}

test "parse clear as alias for clean" {
	const args = [_][]const u8{ "codescan", "clear" };
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.clean, parsed.command);
}

test "parse clean --confirm" {
	const args = [_][]const u8{ "codescan", "clean", "--confirm" };
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.clean, parsed.command);
	try std.testing.expect(parsed.confirm);
	try std.testing.expect(parsed.seen.confirm);
}

test "parse clear -y" {
	const args = [_][]const u8{ "codescan", "clear", "-y" };
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.clean, parsed.command);
	try std.testing.expect(parsed.confirm);
}

test "parse find-symbol with --file before pattern" {
	const args = [_][]const u8{ "codescan", "find-symbol", "--file", "src/main.zig", "_git_show" };
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.symbols, parsed.command);
	try std.testing.expect(parsed.symbols_files.items.len == 1);
	try std.testing.expectEqualStrings("src/main.zig", parsed.symbols_files.items[0]);
	try std.testing.expectEqualStrings("_git_show", parsed.pattern.?);
}

test "parse symbols with pattern and multiple --file args" {
	const args = [_][]const u8{ "codescan", "symbols", "init", "--file", "src/main.zig", "--file", "src/cli.zig" };
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.symbols, parsed.command);
	try std.testing.expect(parsed.symbols_files.items.len == 2);
	try std.testing.expectEqualStrings("src/main.zig", parsed.symbols_files.items[0]);
	try std.testing.expectEqualStrings("src/cli.zig", parsed.symbols_files.items[1]);
	try std.testing.expectEqualStrings("init", parsed.pattern.?);
}

test "parse symbols with pattern but no --file" {
	const args = [_][]const u8{ "codescan", "symbols", "init" };
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.symbols, parsed.command);
	try std.testing.expect(parsed.symbols_files.items.len == 0);
	try std.testing.expectEqualStrings("init", parsed.pattern.?);
}

test "parse symbols with no args (list all from CWD)" {
	const args = [_][]const u8{ "codescan", "symbols" };
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.symbols, parsed.command);
	try std.testing.expect(parsed.symbols_files.items.len == 0);
	try std.testing.expect(parsed.pattern == null);
}

test "parse find-symbol alias still works" {
	const args = [_][]const u8{ "codescan", "find-symbol", "myFunc", "--file", "src/main.zig" };
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.symbols, parsed.command);
	try std.testing.expectEqualStrings("myFunc", parsed.pattern.?);
	try std.testing.expect(parsed.symbols_files.items.len == 1);
	try std.testing.expectEqualStrings("src/main.zig", parsed.symbols_files.items[0]);
}

test "parse query as alias for search" {
	const args = [_][]const u8{ "codescan", "query", "hash functions" };
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.search, parsed.command);
	try std.testing.expectEqualStrings("hash functions", parsed.query.?);
}

test "parse search with --path flag" {
	const args = [_][]const u8{ "codescan", "search", "init", "--path", "src/storage*" };
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.search, parsed.command);
	try std.testing.expectEqual(@as(usize, 1), parsed.path_filters.items.len);
	try std.testing.expectEqualStrings("src/storage*", parsed.path_filters.items[0]);
}

test "parse search with --file flag for search command" {
	const args = [_][]const u8{ "codescan", "search", "init", "--file", "src/storage.zig" };
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.search, parsed.command);
	try std.testing.expectEqualStrings("src/storage.zig", parsed.file_filter.?);
}

test "parse search --file rejects globs" {
	const args = [_][]const u8{ "codescan", "search", "init", "--file", "src/*.zig" };
	const result = parse(std.testing.allocator, &args);
	try std.testing.expectError(error.InvalidFileFilter, result);
}

test "parse search with --path allows browse mode (no query)" {
	const args = [_][]const u8{ "codescan", "search", "--path", "src/storage*" };
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.search, parsed.command);
	try std.testing.expectEqual(@as(?[]const u8, null), parsed.query);
	try std.testing.expectEqual(@as(usize, 1), parsed.path_filters.items.len);
}

test "parse search with --file allows browse mode (no query)" {
	const args = [_][]const u8{ "codescan", "search", "--file", "src/storage.zig" };
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.search, parsed.command);
	try std.testing.expectEqual(@as(?[]const u8, null), parsed.query);
	try std.testing.expectEqualStrings("src/storage.zig", parsed.file_filter.?);
}

test "parse search --regex sets regex_search flag" {
	const args = [_][]const u8{ "codescan", "search", "fn \\w+", "--regex" };
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.search, parsed.command);
	try std.testing.expect(parsed.regex_search);
	try std.testing.expect(!parsed.regex_mode); // regex_mode is for replace_content
	try std.testing.expectEqualStrings("fn \\w+", parsed.query.?);
}

test "parse search --context sets context_lines" {
	const args = [_][]const u8{ "codescan", "search", "hello", "--context", "5" };
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(CommandTag.search, parsed.command);
	try std.testing.expectEqual(@as(usize, 5), parsed.context_lines);
}

test "parse search -C shorthand for context" {
	const args = [_][]const u8{ "codescan", "search", "hello", "-C", "3" };
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expectEqual(@as(usize, 3), parsed.context_lines);
}

test "parse --regex on non-search command sets regex_mode not regex_search" {
	const args = [_][]const u8{ "codescan", "replace-content", "pattern", "--regex" };
	var parsed = try parse(std.testing.allocator, &args);
	defer parsed.deinit(std.testing.allocator);
	try std.testing.expect(parsed.regex_mode);
	try std.testing.expect(!parsed.regex_search);
}
