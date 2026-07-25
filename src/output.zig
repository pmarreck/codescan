const std = @import("std");
const cli = @import("cli.zig");
const search = @import("search.zig");
const freshness_mod = @import("freshness.zig");
const hashline = @import("hashline.zig");
const model = @import("model.zig");

pub const OutputOptions = struct {
	show_comments: bool = false,
	show_body: bool = false,
	use_color: bool = true,
	total_relevant: usize = 0,
	top_n: usize = 10,
	freshness: ?FreshnessMetadata = null,
};

pub const FreshnessMetadata = struct {
	outcome: freshness_mod.Outcome,
	update_seconds: ?f64 = null,
	watcher_recommended: bool = false,
};

pub fn writeResults(
	allocator: std.mem.Allocator,
	writer: *std.Io.Writer,
	format: cli.OutputFormat,
	results: []const search.Result,
	options: OutputOptions,
) !void {
	switch (format) {
		.human => try writeHuman(writer, results, options),
		.json => try writeJson(allocator, writer, results, options),
	}
}

fn writeHuman(writer: *std.Io.Writer, results: []const search.Result, options: OutputOptions) !void {
	if (options.total_relevant > results.len) {
		try writer.print("Showing {d} of {d} results (use --top {d} to see all)\n", .{
			results.len, options.total_relevant, options.total_relevant,
		});
	}
	const idx_width = countDigits(results.len);
	var path_width: usize = 0;
	var range_width: usize = 0;
	for (results) |res| {
		path_width = @max(path_width, res.symbol.file_path.len);
		var tmp_buf: [128]u8 = undefined;
		const tmp_range = formatRange(&tmp_buf, res.symbol);
		range_width = @max(range_width, tmp_range.len);
	}

	for (results, 0..) |res, idx| {
		try writeIndex(writer, idx + 1, idx_width);
		try writer.writeAll(". ");
		try writeColored(writer, options.use_color, "\x1b[36m", res.symbol.file_path);
		try writePadding(writer, path_width - res.symbol.file_path.len);
		try writer.writeAll(" ");

		var range_buf: [128]u8 = undefined;
		const range = formatRange(&range_buf, res.symbol);
		try writeColored(writer, options.use_color, "\x1b[33m", range);
		try writePadding(writer, range_width - range.len);
		try writer.writeAll("  ");

		try writeColored(writer, options.use_color, "\x1b[1m", res.symbol.signature);
		try writer.writeAll("\n");

		if (options.use_color) try writer.writeAll("\x1b[2m");
		try writer.print(
			"   score {d:.3}  vec {d:.3}  lex {d:.3}  evidence {s}",
			.{ res.score, vectorScore(res), res.lexical, @tagName(search.evidenceFor(res)) },
		);
		if (res.lexical_sources.any()) {
			try writer.writeAll("  match ");
			try writeLexicalSources(writer, res.lexical_sources);
		}
		try writer.writeAll("\n");
		if (options.use_color) try writer.writeAll("\x1b[0m");

		if (options.show_comments) {
			if (res.symbol.doc_comment) |doc| {
				try writer.print("   doc: {s}\n", .{doc});
			}
		}

		if (options.show_body) {
			if (res.symbol.body) |body| {
				try writer.writeAll("   --- body ---\n");
				var line_iter = std.mem.splitScalar(u8, body, '\n');
				while (line_iter.next()) |line| {
					try writer.print("   {s}\n", .{line});
				}
			}
		}
	}
}

fn writeJson(allocator: std.mem.Allocator, writer: *std.Io.Writer, results: []const search.Result, options: OutputOptions) !void {
	const JsonResult = struct {
		language: []const u8,
		file_path: []const u8,
		start_line: usize,
		start_hash: ?[]const u8,
		end_line: usize,
		end_hash: ?[]const u8,
		name: []const u8,
		signature: []const u8,
		doc_comment: ?[]const u8,
		body: ?[]const u8,
		symbol_kind: ?[]const u8,
		symbol_visibility: ?[]const u8,
		symbol_scope: ?[]const u8,
		symbol_arity: ?i32,
		score: f32,
		distance: ?f32,
		vector: f32,
		lexical: f32,
		bm25: f32,
		evidence: search.Evidence,
		lexical_sources: search.LexicalSources,
	};

	const Payload = struct {
		total_relevant: usize,
		showing: usize,
		confidence: search.ResultSetConfidence,
		freshness: ?freshness_mod.Outcome,
		update_seconds: ?f64,
		watcher_recommended: bool,
		watcher_help: ?[]const u8,
		results: []const JsonResult,
	};

	var rows = try allocator.alloc(JsonResult, results.len);
	defer allocator.free(rows);

	for (results, 0..) |res, idx| {
		rows[idx] = .{
			.language = res.symbol.language,
			.file_path = res.symbol.file_path,
			.start_line = res.symbol.start_line,
			.start_hash = if (res.symbol.start_hash) |*h| @as([]const u8, h) else null,
			.end_line = res.symbol.end_line,
			.end_hash = if (res.symbol.end_hash) |*h| @as([]const u8, h) else null,
			.name = res.symbol.name,
			.signature = res.symbol.signature,
			.doc_comment = res.symbol.doc_comment,
			.body = if (options.show_body) res.symbol.body else null,
			.symbol_kind = res.symbol.symbol_kind,
			.symbol_visibility = res.symbol.symbol_visibility,
			.symbol_scope = res.symbol.symbol_scope,
			.symbol_arity = res.symbol.symbol_arity,
			.score = res.score,
			.distance = if (std.math.isInf(res.distance)) null else res.distance,
			.vector = vectorScore(res),
			.lexical = res.lexical,
			.bm25 = res.bm25,
			.evidence = search.evidenceFor(res),
			.lexical_sources = res.lexical_sources,
		};
	}

	var stream: std.json.Stringify = .{ .writer = writer, .options = .{} };
	try stream.write(Payload{
		.total_relevant = options.total_relevant,
		.showing = results.len,
		.confidence = search.confidenceFor(results),
		.freshness = if (options.freshness) |value| value.outcome else null,
		.update_seconds = if (options.freshness) |value| value.update_seconds else null,
		.watcher_recommended = if (options.freshness) |value| value.watcher_recommended else false,
		.watcher_help = if (options.freshness) |value|
			if (value.watcher_recommended) "codescan help watch" else null
		else
			null,
		.results = rows,
	});
}

/// Writes a concise result-set warning while retaining every weak hit; callers
/// route this metadata to stderr so stdout remains composable.
pub fn writeConfidenceNote(writer: *std.Io.Writer, results: []const search.Result) !void {
	switch (search.confidenceFor(results)) {
		.mixed => try writer.writeAll(
			"note: mixed-confidence results: the top hit is weak, but stronger evidence appears below it; all hits are retained. Lexical matches may come from undisplayed comments (use --show-comments).\n",
		),
		.weak => try writer.writeAll(
			"note: Weak evidence; showing best-effort results.\n",
		),
		.none, .strong => {},
	}
}

/// Renders the discovery phase from explicit state so timing and I/O remain
/// outside the visual formatter.
pub fn writeDiscoveryProgress(writer: *std.Io.Writer, eligible_files: usize, done: bool) !void {
	try writer.print("\rJust a moment... scanning files: {d}", .{eligible_files});
	if (done) try writer.writeAll("\n");
}

fn vectorScore(result: search.Result) f32 {
	return if (std.math.isInf(result.distance)) 0 else 1.0 / (1.0 + result.distance);
}

fn writeLexicalSources(writer: *std.Io.Writer, sources: search.LexicalSources) !void {
	var wrote_one = false;
	inline for (.{
		.{ "name", sources.name },
		.{ "signature", sources.signature },
		.{ "comment", sources.comment },
		.{ "body", sources.body },
		.{ "path", sources.path },
        .{ "frontmatter-description", sources.frontmatter_description },
        .{ "frontmatter-tags", sources.frontmatter_tags },
	}) |entry| {
		if (entry[1]) {
			if (wrote_one) try writer.writeAll(",");
			try writer.writeAll(entry[0]);
			wrote_one = true;
		}
	}
}

test "writeResults emits json payload" {
	const allocator = std.testing.allocator;

	var res = search.Result{
		.id = 1,
		.symbol = .{
			.language = try allocator.dupe(u8, "zig"),
			.file_path = try allocator.dupe(u8, "src/a.zig"),
			.name = try allocator.dupe(u8, "add"),
			.signature = try allocator.dupe(u8, "fn add() void"),
			.doc_comment = null,
			.start_line = 1,
			.end_line = 2,
		},
		.score = 0.9,
		.distance = 0.1,
		.lexical = 1.0,
		.bm25 = 0,
	};
	defer res.deinit(allocator);

	var out: std.Io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	try writeResults(allocator, &out.writer, .json, &[_]search.Result{res}, .{});
	const payload = try out.toOwnedSlice();
	defer allocator.free(payload);

	var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
	defer parsed.deinit();

	const obj = parsed.value.object;
	const results = obj.get("results") orelse return error.TestExpectedEqual;
	try std.testing.expect(results.array.items.len == 1);
	const first = results.array.items[0].object;
	try std.testing.expectEqualStrings("src/a.zig", first.get("file_path").?.string);
}

test "writeResults emits human output" {
	const allocator = std.testing.allocator;

	var res = search.Result{
		.id = 1,
		.symbol = .{
			.language = try allocator.dupe(u8, "zig"),
			.file_path = try allocator.dupe(u8, "src/a.zig"),
			.name = try allocator.dupe(u8, "add"),
			.signature = try allocator.dupe(u8, "fn add() void"),
			.doc_comment = null,
			.start_line = 1,
			.end_line = 2,
		},
		.score = 0.9,
		.distance = 0.1,
		.lexical = 1.0,
		.bm25 = 0,
	};
	defer res.deinit(allocator);

	var out: std.Io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	try writeResults(allocator, &out.writer, .human, &[_]search.Result{res}, .{ .use_color = false });
	const payload = try out.toOwnedSlice();
	defer allocator.free(payload);

	try std.testing.expect(std.mem.indexOf(u8, payload, "src/a.zig") != null);
	try std.testing.expect(std.mem.indexOf(u8, payload, "1-2") != null);
}

test "writeResults hides doc comments by default" {
	const allocator = std.testing.allocator;

	var res = search.Result{
		.id = 1,
		.symbol = .{
			.language = try allocator.dupe(u8, "zig"),
			.file_path = try allocator.dupe(u8, "src/a.zig"),
			.name = try allocator.dupe(u8, "add"),
			.signature = try allocator.dupe(u8, "fn add() void"),
			.doc_comment = try allocator.dupe(u8, "adds"),
			.start_line = 1,
			.end_line = 2,
		},
		.score = 0.9,
		.distance = 0.1,
		.lexical = 1.0,
		.bm25 = 0,
	};
	defer res.deinit(allocator);

	var out: std.Io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	try writeResults(allocator, &out.writer, .human, &[_]search.Result{res}, .{ .use_color = false });
	const payload = try out.toOwnedSlice();
	defer allocator.free(payload);

	try std.testing.expect(std.mem.indexOf(u8, payload, "doc:") == null);
}

test "writeResults includes doc comments when enabled" {
	const allocator = std.testing.allocator;

	var res = search.Result{
		.id = 1,
		.symbol = .{
			.language = try allocator.dupe(u8, "zig"),
			.file_path = try allocator.dupe(u8, "src/a.zig"),
			.name = try allocator.dupe(u8, "add"),
			.signature = try allocator.dupe(u8, "fn add() void"),
			.doc_comment = try allocator.dupe(u8, "adds"),
			.start_line = 1,
			.end_line = 2,
		},
		.score = 0.9,
		.distance = 0.1,
		.lexical = 1.0,
		.bm25 = 0,
	};
	defer res.deinit(allocator);

	var out: std.Io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	try writeResults(allocator, &out.writer, .human, &[_]search.Result{res}, .{
		.show_comments = true,
		.use_color = false,
	});
	const payload = try out.toOwnedSlice();
	defer allocator.free(payload);

	try std.testing.expect(std.mem.indexOf(u8, payload, "doc: adds") != null);
}

fn countDigits(value: usize) usize {
	var n = value;
	var digits: usize = 1;
	while (n >= 10) : (n /= 10) digits += 1;
	return digits;
}

/// Formats a line range as "start:hash-end:hash" when hashes present, or "start-end" without.
fn formatRange(buf: []u8, sym: model.Symbol) []const u8 {
	if (sym.start_hash) |sh| {
		if (sym.end_hash) |eh| {
			return std.fmt.bufPrint(buf, "{d}:{s}-{d}:{s}", .{
				sym.start_line, &sh, sym.end_line, &eh,
			}) catch "?-?";
		}
	}
	return std.fmt.bufPrint(buf, "{d}-{d}", .{ sym.start_line, sym.end_line }) catch "?-?";
}

fn writeIndex(writer: *std.Io.Writer, value: usize, width: usize) !void {
	var buf: [32]u8 = undefined;
	const rendered = try std.fmt.bufPrint(&buf, "{d}", .{value});
	try writePadding(writer, width - rendered.len);
	try writer.writeAll(rendered);
}

fn writePadding(writer: *std.Io.Writer, count: usize) !void {
	var i: usize = 0;
	while (i < count) : (i += 1) {
		try writer.writeAll(" ");
	}
}

/// Decides whether human output may carry ANSI styling. Pure so the policy is
/// testable without a terminal: machine-readable output, a set `NO_COLOR`, and a
/// non-TTY destination (a pipe, a file, or an agent reading our stdout) each
/// independently suppress color.
pub fn shouldUseColor(human_output: bool, no_color_env_set: bool, stdout_is_tty: bool) bool {
	return human_output and !no_color_env_set and stdout_is_tty;
}

test "shouldUseColor suppresses ANSI for every non-interactive destination" {
	// Classify the whole input space, not one example.
	for ([_]bool{ true, false }) |human| {
		for ([_]bool{ true, false }) |no_color| {
			for ([_]bool{ true, false }) |is_tty| {
				const expected = human and !no_color and is_tty;
				try std.testing.expectEqual(expected, shouldUseColor(human, no_color, is_tty));
			}
		}
	}

	// The regression that mattered: piped human output must be plain, so agents
	// and shell pipelines never receive escape codes.
	try std.testing.expect(!shouldUseColor(true, false, false));
	// An interactive terminal still gets full styling.
	try std.testing.expect(shouldUseColor(true, false, true));
}

fn writeColored(writer: *std.Io.Writer, use_color: bool, code: []const u8, text: []const u8) !void {
	if (use_color) try writer.writeAll(code);
	try writer.writeAll(text);
	if (use_color) try writer.writeAll("\x1b[0m");
}

test "human output includes hashlines when hashes present" {
	const allocator = std.testing.allocator;

	var res = search.Result{
		.id = 1,
		.symbol = .{
			.language = try allocator.dupe(u8, "zig"),
			.file_path = try allocator.dupe(u8, "src/a.zig"),
			.name = try allocator.dupe(u8, "add"),
			.signature = try allocator.dupe(u8, "fn add() void"),
			.doc_comment = null,
			.start_line = 10,
			.end_line = 20,
			.start_hash = .{ 'k', '7', 'm' },
			.end_hash = .{ 'x', '9', 'a' },
		},
		.score = 0.9,
		.distance = 0.1,
		.lexical = 1.0,
		.bm25 = 0,
	};
	defer res.deinit(allocator);

	var out: std.Io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	try writeResults(allocator, &out.writer, .human, &[_]search.Result{res}, .{ .use_color = false });
	const payload = try out.toOwnedSlice();
	defer allocator.free(payload);

	// Line ranges must include hashline format: "10:k7m-20:x9a"
	try std.testing.expect(std.mem.indexOf(u8, payload, "10:k7m-20:x9a") != null);
}

test "json output includes hashlines when hashes present" {
	const allocator = std.testing.allocator;

	var res = search.Result{
		.id = 1,
		.symbol = .{
			.language = try allocator.dupe(u8, "zig"),
			.file_path = try allocator.dupe(u8, "src/a.zig"),
			.name = try allocator.dupe(u8, "add"),
			.signature = try allocator.dupe(u8, "fn add() void"),
			.doc_comment = null,
			.start_line = 10,
			.end_line = 20,
			.start_hash = .{ 'k', '7', 'm' },
			.end_hash = .{ 'x', '9', 'a' },
		},
		.score = 0.9,
		.distance = 0.1,
		.lexical = 1.0,
		.bm25 = 0,
	};
	defer res.deinit(allocator);

	var out: std.Io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	try writeResults(allocator, &out.writer, .json, &[_]search.Result{res}, .{});
	const payload = try out.toOwnedSlice();
	defer allocator.free(payload);

	// JSON should include start_hash and end_hash fields
	try std.testing.expect(std.mem.indexOf(u8, payload, "\"start_hash\":\"k7m\"") != null);
	try std.testing.expect(std.mem.indexOf(u8, payload, "\"end_hash\":\"x9a\"") != null);
}

test "human output shows plain line range when hashes absent" {
	const allocator = std.testing.allocator;

	var res = search.Result{
		.id = 1,
		.symbol = .{
			.language = try allocator.dupe(u8, "zig"),
			.file_path = try allocator.dupe(u8, "src/a.zig"),
			.name = try allocator.dupe(u8, "add"),
			.signature = try allocator.dupe(u8, "fn add() void"),
			.doc_comment = null,
			.start_line = 10,
			.end_line = 20,
		},
		.score = 0.9,
		.distance = 0.1,
		.lexical = 1.0,
		.bm25 = 0,
	};
	defer res.deinit(allocator);

	var out: std.Io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	try writeResults(allocator, &out.writer, .human, &[_]search.Result{res}, .{ .use_color = false });
	const payload = try out.toOwnedSlice();
	defer allocator.free(payload);

	// Without hashes, plain range format
	try std.testing.expect(std.mem.indexOf(u8, payload, "10-20") != null);
}

test "human output labels evidence and undisplayed comment match provenance" {
	const allocator = std.testing.allocator;
	var res = search.Result{
		.id = 1,
		.symbol = .{
			.language = try allocator.dupe(u8, "go"),
			.file_path = try allocator.dupe(u8, "internal/audio/stream.go"),
			.name = try allocator.dupe(u8, "chooseCandidate"),
			.signature = try allocator.dupe(u8, "func chooseCandidate()"),
			.doc_comment = try allocator.dupe(u8, "Excludes DRM-only variants."),
			.start_line = 1,
			.end_line = 2,
		},
		.score = 0.24,
		.distance = std.math.inf(f32),
		.lexical = 1.0,
		.bm25 = -7.8,
		.lexical_sources = .{ .comment = true },
	};
	defer res.deinit(allocator);

	var out: std.Io.Writer.Allocating = .init(allocator);
	defer out.deinit();
	try writeResults(allocator, &out.writer, .human, &.{res}, .{ .use_color = false });
	const payload = try out.toOwnedSlice();
	defer allocator.free(payload);

	try std.testing.expect(std.mem.indexOf(u8, payload, "evidence strong") != null);
	try std.testing.expect(std.mem.indexOf(u8, payload, "match comment") != null);
	try std.testing.expect(std.mem.indexOf(u8, payload, "doc:") == null);
}

test "human output labels frontmatter field provenance" {
    const allocator = std.testing.allocator;
    var res = search.Result{
        .id = 1,
        .symbol = .{
            .language = try allocator.dupe(u8, "markdown"),
            .file_path = try allocator.dupe(u8, "MEMORIES/nix.frontmatter.md"),
            .name = try allocator.dupe(u8, "nix.frontmatter.md"),
            .signature = try allocator.dupe(u8, "Git-backed Nix flakes exclude untracked inputs."),
            .doc_comment = try allocator.dupe(u8, "nix flakes untracked-files"),
            .symbol_kind = try allocator.dupe(u8, "frontmatter"),
            .start_line = 1,
            .end_line = 5,
        },
        .score = 0.8,
        .distance = std.math.inf(f32),
        .lexical = 1.0,
        .bm25 = -9.0,
        .lexical_sources = .{
            .frontmatter_description = true,
            .frontmatter_tags = true,
        },
    };
    defer res.deinit(allocator);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeResults(allocator, &out.writer, .human, &.{res}, .{ .use_color = false });
    const payload = try out.toOwnedSlice();
    defer allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(
        u8,
        payload,
        "match frontmatter-description,frontmatter-tags",
    ) != null);
}

test "json output exposes result-set confidence evidence and lexical sources" {
	const allocator = std.testing.allocator;
	var weak = search.Result{
		.id = 1,
		.symbol = .{
			.language = try allocator.dupe(u8, "go"),
			.file_path = try allocator.dupe(u8, "cmd/main.go"),
			.name = try allocator.dupe(u8, "min"),
			.signature = try allocator.dupe(u8, "func min(a, b int) int"),
			.doc_comment = null,
			.start_line = 1,
			.end_line = 2,
		},
		.score = 0.30,
		.distance = 1.335,
		.lexical = 0,
		.bm25 = 0,
	};
	defer weak.deinit(allocator);
	var comment = search.Result{
		.id = 2,
		.symbol = .{
			.language = try allocator.dupe(u8, "go"),
			.file_path = try allocator.dupe(u8, "internal/audio/stream.go"),
			.name = try allocator.dupe(u8, "chooseCandidate"),
			.signature = try allocator.dupe(u8, "func chooseCandidate()"),
			.doc_comment = try allocator.dupe(u8, "Excludes DRM-only variants."),
			.start_line = 3,
			.end_line = 4,
		},
		.score = 0.24,
		.distance = std.math.inf(f32),
		.lexical = 1.0,
		.bm25 = -7.8,
		.lexical_sources = .{ .comment = true },
	};
	defer comment.deinit(allocator);

	var out: std.Io.Writer.Allocating = .init(allocator);
	defer out.deinit();
	try writeResults(allocator, &out.writer, .json, &.{ weak, comment }, .{
		.freshness = .{
			.outcome = .reconciled,
			.update_seconds = 1.25,
			.watcher_recommended = true,
		},
	});
	const payload = try out.toOwnedSlice();
	defer allocator.free(payload);

	var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
	defer parsed.deinit();
	const root = parsed.value.object;
	try std.testing.expectEqualStrings("mixed", root.get("confidence").?.string);
	try std.testing.expectEqualStrings("reconciled", root.get("freshness").?.string);
	try std.testing.expectApproxEqAbs(@as(f64, 1.25), root.get("update_seconds").?.float, 0.001);
	try std.testing.expect(root.get("watcher_recommended").?.bool);
	try std.testing.expectEqualStrings("codescan help watch", root.get("watcher_help").?.string);
	const results = root.get("results").?.array.items;
	try std.testing.expectEqualStrings("weak", results[0].object.get("evidence").?.string);
	try std.testing.expectEqualStrings("strong", results[1].object.get("evidence").?.string);
	try std.testing.expect(results[1].object.get("lexical_sources").?.object.get("comment").?.bool);
}

test "confidence note warns for mixed and weak result sets without hiding hits" {
	const weak = search.Result{
		.id = 1,
		.symbol = undefined,
		.score = 0.30,
		.distance = 1.335,
		.lexical = 0,
		.bm25 = 0,
	};
	const strong = search.Result{
		.id = 2,
		.symbol = undefined,
		.score = 0.24,
		.distance = std.math.inf(f32),
		.lexical = 1.0,
		.bm25 = -7.8,
		.lexical_sources = .{ .comment = true },
	};

	var mixed_out: std.Io.Writer.Allocating = .init(std.testing.allocator);
	defer mixed_out.deinit();
	try writeConfidenceNote(&mixed_out.writer, &.{ weak, strong });
	const mixed_payload = try mixed_out.toOwnedSlice();
	defer std.testing.allocator.free(mixed_payload);
	try std.testing.expect(std.mem.indexOf(u8, mixed_payload, "mixed-confidence") != null);
	try std.testing.expect(std.mem.indexOf(u8, mixed_payload, "retained") != null);
	try std.testing.expect(std.mem.indexOf(u8, mixed_payload, "--show-comments") != null);

	var weak_out: std.Io.Writer.Allocating = .init(std.testing.allocator);
	defer weak_out.deinit();
	try writeConfidenceNote(&weak_out.writer, &.{weak});
	const weak_payload = try weak_out.toOwnedSlice();
	defer std.testing.allocator.free(weak_payload);
	try std.testing.expectEqualStrings(
		"note: Weak evidence; showing best-effort results.\n",
		weak_payload,
	);

	var strong_out: std.Io.Writer.Allocating = .init(std.testing.allocator);
	defer strong_out.deinit();
	try writeConfidenceNote(&strong_out.writer, &.{strong});
	const strong_payload = try strong_out.toOwnedSlice();
	defer std.testing.allocator.free(strong_payload);
	try std.testing.expectEqual(@as(usize, 0), strong_payload.len);
}
