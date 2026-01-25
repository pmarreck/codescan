const std = @import("std");
const search = @import("search.zig");

pub const OutputFormat = enum {
	human,
	json,
};

pub const CommandTag = enum {
	help,
	config,
	index,
	update,
	search,
	serve,
};

pub const ConfigAction = enum {
	show,
	edit,
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
	weight_vector: bool = false,
	weight_lexical: bool = false,
	min_score: bool = false,
	ext_filter: bool = false,
	type_filter: bool = false,
	lang_filter: bool = false,
};

pub const Parsed = struct {
	command: CommandTag,
	config_action: ConfigAction,
	assumed_search: bool,
	query_owned: bool,
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
	weight_vector: f32,
	weight_lexical: f32,
	min_score: f32,
	ext_filter: ?[]const u8,
	type_filter: ?[]const u8,
	lang_filter: ?[]const u8,
	seen: Seen,

	pub fn deinit(self: *Parsed, allocator: std.mem.Allocator) void {
		if (self.query_owned and self.query != null) {
			allocator.free(self.query.?);
		}
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
		.output = .human,
		.show_comments = false,
		.include_docs = false,
		.docs_only = false,
		.comments_only = false,
		.include_node_modules = false,
		.query = null,
		.top_n = 10,
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
		.weight_vector = 0.7,
		.weight_lexical = 0.3,
		.min_score = 0.0,
		.ext_filter = null,
		.type_filter = null,
		.lang_filter = null,
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
	if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
		parsed.command = .help;
		return parsed;
	} else if (std.mem.eql(u8, cmd, "config")) {
		parsed.command = .config;
		i += 1;
	} else if (std.mem.eql(u8, cmd, "index")) {
		parsed.command = .index;
		i += 1;
	} else if (std.mem.eql(u8, cmd, "update")) {
		parsed.command = .update;
		i += 1;
	} else if (std.mem.eql(u8, cmd, "search")) {
		parsed.command = .search;
		i += 1;
	} else if (std.mem.eql(u8, cmd, "serve")) {
		parsed.command = .serve;
		i += 1;
	} else {
		parsed.command = .search;
		parsed.assumed_search = true;
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
		if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "--show-comments")) {
			parsed.show_comments = true;
			parsed.seen.show_comments = true;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--comments") or std.mem.eql(u8, arg, "--only-comments")) {
			parsed.comments_only = true;
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
			parsed.seen.docs_only = true;
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
			parsed.search_mode = try parseMode(args[i]);
			parsed.seen.search_mode = true;
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
		if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
			parsed.command = .help;
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

		return error.UnexpectedArg;
	}

	if (parsed.command == .search) {
		if (!query_parts_inited or query_parts.items.len == 0) {
			return error.MissingQuery;
		}
		if (query_parts.items.len == 1) {
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

fn parseMode(value: []const u8) !search.SearchMode {
	if (std.mem.eql(u8, value, "vector")) return .vector;
	if (std.mem.eql(u8, value, "lexical")) return .lexical;
	if (std.mem.eql(u8, value, "hybrid")) return .hybrid;
	return error.InvalidMode;
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
	try std.testing.expectEqual(@as(usize, 10), parsed.top_n);
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

test "parse search missing query errors" {
	const args = [_][]const u8{ "codescan", "search" };
	try std.testing.expectError(error.MissingQuery, parse(std.testing.allocator, &args));
}
