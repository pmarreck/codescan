const std = @import("std");
const search = @import("search.zig");

pub const OutputFormat = enum {
	human,
	json,
};

pub const CommandTag = enum {
	help,
	index,
	update,
	search,
	serve,
};

pub const Seen = struct {
	output: bool = false,
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
};

pub const Parsed = struct {
	command: CommandTag,
	output: OutputFormat,
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
	seen: Seen,
};

pub fn parse(args: []const []const u8) !Parsed {
	if (args.len <= 1) {
		return Parsed{
			.command = .help,
			.output = .human,
			.query = null,
			.top_n = 10,
			.root_path = ".",
			.db_path = ".codescan/index.sqlite3",
			.ollama_url = "http://localhost:11434",
			.ollama_model = "bge-large",
			.embedding_dim = 1024,
			.batch_size = 16,
			.max_file_size = 1024 * 1024,
			.http_host = "127.0.0.1",
			.http_port = 8123,
			.search_mode = .hybrid,
			.weight_vector = 0.7,
			.weight_lexical = 0.3,
			.seen = .{},
		};
	}
	var parsed = Parsed{
		.command = .help,
		.output = .human,
		.query = null,
		.top_n = 10,
		.root_path = ".",
		.db_path = ".codescan/index.sqlite3",
		.ollama_url = "http://localhost:11434",
		.ollama_model = "bge-large",
		.embedding_dim = 1024,
		.batch_size = 16,
		.max_file_size = 1024 * 1024,
		.http_host = "127.0.0.1",
		.http_port = 8123,
		.search_mode = .hybrid,
		.weight_vector = 0.7,
		.weight_lexical = 0.3,
		.seen = .{},
	};

	var i: usize = 1;
	if (i >= args.len) {
		return parsed;
	}

	const cmd = args[i];
	i += 1;
	if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
		parsed.command = .help;
		return parsed;
	} else if (std.mem.eql(u8, cmd, "index")) {
		parsed.command = .index;
	} else if (std.mem.eql(u8, cmd, "update")) {
		parsed.command = .update;
	} else if (std.mem.eql(u8, cmd, "search")) {
		parsed.command = .search;
	} else if (std.mem.eql(u8, cmd, "serve")) {
		parsed.command = .serve;
	} else {
		return error.UnknownCommand;
	}

	while (i < args.len) {
		const arg = args[i];
		if (std.mem.eql(u8, arg, "--json")) {
			parsed.output = .json;
			parsed.seen.output = true;
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
		if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
			parsed.command = .help;
			return parsed;
		}

		if (parsed.command == .search) {
			if (parsed.query == null) {
				parsed.query = arg;
				i += 1;
				continue;
			}
			return error.TooManyArgs;
		}

		return error.UnexpectedArg;
	}

	if (parsed.command == .search and parsed.query == null) {
		return error.MissingQuery;
	}

	return parsed;
}

fn parseMode(value: []const u8) !search.SearchMode {
	if (std.mem.eql(u8, value, "vector")) return .vector;
	if (std.mem.eql(u8, value, "lexical")) return .lexical;
	if (std.mem.eql(u8, value, "hybrid")) return .hybrid;
	return error.InvalidMode;
}

test "parse with no args defaults to help" {
	const args = [_][]const u8{ "codescan" };
	const parsed = try parse(&args);
	try std.testing.expectEqual(CommandTag.help, parsed.command);
	try std.testing.expectEqual(OutputFormat.human, parsed.output);
	try std.testing.expectEqualStrings("bge-large", parsed.ollama_model);
	try std.testing.expectEqual(@as(usize, 1024), parsed.embedding_dim);
	try std.testing.expectEqual(@as(u16, 8123), parsed.http_port);
	try std.testing.expect(parsed.seen.output == false);
}

test "parse search with query defaults" {
	const args = [_][]const u8{ "codescan", "search", "hash functions" };
	const parsed = try parse(&args);
	try std.testing.expectEqual(CommandTag.search, parsed.command);
	try std.testing.expectEqual(OutputFormat.human, parsed.output);
	try std.testing.expectEqualStrings("hash functions", parsed.query.?);
	try std.testing.expectEqual(@as(usize, 10), parsed.top_n);
	try std.testing.expectEqualStrings(".", parsed.root_path);
	try std.testing.expectEqualStrings(".codescan/index.sqlite3", parsed.db_path);
	try std.testing.expectEqualStrings("http://localhost:11434", parsed.ollama_url);
	try std.testing.expect(parsed.search_mode == .hybrid);
	try std.testing.expect(parsed.seen.top_n == false);
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
	};
	const parsed = try parse(&args);
	try std.testing.expectEqual(CommandTag.search, parsed.command);
	try std.testing.expectEqualStrings("checksum", parsed.query.?);
	try std.testing.expectApproxEqAbs(@as(f32, 0.8), parsed.weight_vector, 0.0001);
	try std.testing.expectApproxEqAbs(@as(f32, 0.2), parsed.weight_lexical, 0.0001);
	try std.testing.expect(parsed.seen.weight_vector);
	try std.testing.expect(parsed.seen.weight_lexical);
}

test "parse search with flags" {
	const args = [_][]const u8{
		"codescan",
		"search",
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
		"hash functions",
	};
	const parsed = try parse(&args);
	try std.testing.expectEqual(CommandTag.search, parsed.command);
	try std.testing.expectEqual(OutputFormat.json, parsed.output);
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
	try std.testing.expect(parsed.seen.http_port);
}

test "parse search missing query errors" {
	const args = [_][]const u8{ "codescan", "search" };
	try std.testing.expectError(error.MissingQuery, parse(&args));
}
