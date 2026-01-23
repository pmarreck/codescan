const std = @import("std");

pub const OutputFormat = enum {
	human,
	json,
};

pub const CommandTag = enum {
	help,
	index,
	update,
	search,
};

pub const Parsed = struct {
	command: CommandTag,
	output: OutputFormat,
	query: ?[]const u8,
	top_n: usize,
	root_path: []const u8,
	db_path: []const u8,
	ollama_url: []const u8,
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
	} else {
		return error.UnknownCommand;
	}

	while (i < args.len) {
		const arg = args[i];
		if (std.mem.eql(u8, arg, "--json")) {
			parsed.output = .json;
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--top")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			parsed.top_n = try std.fmt.parseInt(usize, args[i], 10);
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--root")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			parsed.root_path = args[i];
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--db")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			parsed.db_path = args[i];
			i += 1;
			continue;
		}
		if (std.mem.eql(u8, arg, "--ollama-url")) {
			i += 1;
			if (i >= args.len) return error.MissingValue;
			parsed.ollama_url = args[i];
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

test "parse with no args defaults to help" {
	const args = [_][]const u8{ "codescan" };
	const parsed = try parse(&args);
	try std.testing.expectEqual(CommandTag.help, parsed.command);
	try std.testing.expectEqual(OutputFormat.human, parsed.output);
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
}

test "parse search missing query errors" {
	const args = [_][]const u8{ "codescan", "search" };
	try std.testing.expectError(error.MissingQuery, parse(&args));
}
