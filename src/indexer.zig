const std = @import("std");
const plugin = @import("plugin.zig");
const kind = @import("kind.zig");
const scan = @import("scan.zig");
const storage = @import("storage.zig");
const model = @import("model.zig");
const embedding = @import("embedding.zig");
const embedding_http = @import("embedding_http.zig");
const config = @import("config.zig");
const hashline = @import("hashline.zig");

pub const Options = struct {
	embedding_dim: usize,
	embedding_model: []const u8 = "",
	batch_size: usize = 16,
	max_file_size: usize = 1024 * 1024,
	allowed_exts: []const []const u8 = &[_][]const u8{},
	allowed_kinds: []const kind.Kind = &[_]kind.Kind{},
	ignore: scan.IgnoreConfig = .{
		.global = &[_][]const u8{},
		.per_language = &[_]config.IgnoreOverride{},
		.include_node_modules = false,
	},
	show_progress: bool = false,
};

pub const Stats = struct {
	files: usize,
	symbols: usize,
};

pub fn indexAll(
	allocator: std.mem.Allocator,
	db: storage.Db,
	root_path: []const u8,
	registry: plugin.Registry,
	embedder: embedding.Embedder,
	options: Options,
) !Stats {
	if (options.batch_size == 0) return error.InvalidBatchSize;

	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = options.embedding_dim, .embedding_model = options.embedding_model });
	try storage.resetIndex(db);

	const debug = try debugEnabled(allocator);
	const show_progress = options.show_progress and !debug;

	const files = try scan.findFiles(allocator, root_path, registry, options.ignore);
	defer {
		for (files) |path| allocator.free(path);
		allocator.free(files);
	}

	var batch_texts: std.ArrayListUnmanaged([]const u8) = .{};
	var batch_rowids: std.ArrayListUnmanaged(i64) = .{};
	var comment_texts: std.ArrayListUnmanaged([]const u8) = .{};
	var comment_rowids: std.ArrayListUnmanaged(i64) = .{};
	defer {
		for (batch_texts.items) |text| allocator.free(text);
		batch_texts.deinit(allocator);
		batch_rowids.deinit(allocator);
		for (comment_texts.items) |text| allocator.free(text);
		comment_texts.deinit(allocator);
		comment_rowids.deinit(allocator);
	}

	var stderr_buf: [4096]u8 = undefined;
	var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
	const stderr = &stderr_writer.interface;

	var stats = Stats{ .files = 0, .symbols = 0 };
	if (debug) {
		debugLog(stderr, "codescan: debug: indexing {d} files\n", .{files.len});
	}
	if (show_progress) {
		printProgress(stderr, 0, files.len, false);
	}
	var progress_last: usize = 0;
	const progress_step: usize = 1;
	for (files) |rel_path| {
		if (show_progress) {
			progress_last += 1;
			if (shouldEmitProgress(progress_last, files.len, progress_step)) {
				printProgress(stderr, progress_last, files.len, false);
			}
		}
		if (debug) {
			debugLog(stderr, "codescan: debug: scanning {s}\n", .{rel_path});
		}
		const extractor = registry.find(rel_path) orelse continue;
		if (!kindAllowed(extractor.kind, options.allowed_kinds)) continue;
		if (!extAllowed(rel_path, options.allowed_exts)) continue;
		const full_path = try std.fs.path.join(allocator, &.{ root_path, rel_path });
		defer allocator.free(full_path);

		const file = try std.fs.cwd().openFile(full_path, .{});
		defer file.close();

		const stat = try file.stat();
		const size = stat.size;
		if (options.max_file_size > 0) {
			if (show_progress) {
				const warn_threshold: u64 = @intCast(options.max_file_size / 4);
				if (warn_threshold > 0 and size > warn_threshold) {
					const skipping = size > options.max_file_size;
					warnLargeFile(stderr, rel_path, size, warn_threshold, options.max_file_size, skipping);
				}
			}
			if (size > options.max_file_size) continue;
		}

		const source = file.readToEndAlloc(allocator, options.max_file_size) catch |err| {
			if (err == error.FileTooBig) continue;
			return err;
		};
		defer allocator.free(source);

		stats.files += 1;

		const symbols = try extractor.extract(allocator, rel_path, source);
		defer {
			for (symbols) |*sym| sym.deinit(allocator);
			allocator.free(symbols);
		}
		for (symbols) |*sym| {
			try enrichSymbolMetadata(allocator, sym);
		}

		// Compute chain hashes for this file's lines
		const hashes = computeFileHashes(allocator, source) catch null;
		defer if (hashes) |h| allocator.free(h);

		for (symbols, 0..) |sym, sym_idx| {
			var sym_with_hash = sym;
			if (hashes) |h| {
				if (sym.start_line > 0 and sym.start_line <= h.len)
					sym_with_hash.start_hash = h[sym.start_line - 1];
				if (sym.end_line > 0 and sym.end_line <= h.len)
					sym_with_hash.end_hash = h[sym.end_line - 1];
			}
			const body = try extractSourceBody(allocator, source, sym.start_line, sym.end_line);
			defer if (body) |b| allocator.free(b);
			sym_with_hash.body = body;
			const rowid = try storage.insertSymbol(db, sym_with_hash);
			stats.symbols += 1;

			const text = try buildSymbolText(allocator, sym, extractor.kind);
			try batch_texts.append(allocator, text);
			try batch_rowids.append(allocator, rowid);

			if (batch_texts.items.len >= options.batch_size) {
				if (show_progress and symbols.len > options.batch_size) {
					printFileProgress(stderr, progress_last, files.len, rel_path, sym_idx + 1, symbols.len);
				}
				if (debug) {
					debugLog(stderr, "codescan: debug: embedding {d} symbols\n", .{batch_texts.items.len});
				}
				try flushBatch(allocator, db, embedder, options, &batch_texts, &batch_rowids);
			}

			if (sym.doc_comment) |doc| {
				const comment_text = try buildCommentText(allocator, doc, .doc);
				try comment_texts.append(allocator, comment_text);
				try comment_rowids.append(allocator, rowid);

				if (comment_texts.items.len >= options.batch_size) {
					if (debug) {
						debugLog(stderr, "codescan: debug: embedding {d} comments\n", .{comment_texts.items.len});
					}
					try flushCommentBatch(allocator, db, embedder, options, &comment_texts, &comment_rowids);
				}
			}
		}

		// Track indexed file so indexIncremental knows about it
		const current_mtime: i64 = @intCast(@divFloor(stat.mtime, std.time.ns_per_s));
		const current_size: i64 = @intCast(size);
		try storage.upsertIndexedFile(db, rel_path, current_mtime, current_size);
	}

	if (batch_texts.items.len > 0) {
		if (debug) {
			debugLog(stderr, "codescan: debug: embedding {d} symbols\n", .{batch_texts.items.len});
		}
		try flushBatch(allocator, db, embedder, options, &batch_texts, &batch_rowids);
	}
	if (comment_texts.items.len > 0) {
		if (debug) {
			debugLog(stderr, "codescan: debug: embedding {d} comments\n", .{comment_texts.items.len});
		}
		try flushCommentBatch(allocator, db, embedder, options, &comment_texts, &comment_rowids);
	}

	if (show_progress) {
		printProgress(stderr, progress_last, files.len, true);
	}

	return stats;
}

pub const IncrementalStats = struct {
	new_files: usize,
	modified_files: usize,
	deleted_files: usize,
	unchanged_files: usize,
	symbols: usize,
};

pub fn indexIncremental(
	allocator: std.mem.Allocator,
	db: storage.Db,
	root_path: []const u8,
	registry: plugin.Registry,
	embedder: embedding.Embedder,
	options: Options,
) !IncrementalStats {
	if (options.batch_size == 0) return error.InvalidBatchSize;

	// Ensure schema exists (including indexed_files table)
	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = options.embedding_dim, .embedding_model = options.embedding_model });

	const debug = try debugEnabled(allocator);
	const show_progress = options.show_progress and !debug;

	var stderr_buf: [4096]u8 = undefined;
	var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
	const stderr = &stderr_writer.interface;

	// 1. Scan filesystem for current files
	const files = try scan.findFiles(allocator, root_path, registry, options.ignore);
	defer {
		for (files) |path| allocator.free(path);
		allocator.free(files);
	}

	// 2. Get previously indexed files
	const indexed = try storage.getAllIndexedFiles(db, allocator);
	defer {
		for (indexed) |item| allocator.free(item.file_path);
		allocator.free(indexed);
	}

	// Build lookup map of previously indexed files (mtime + size for change detection)
	const MtimeAndSize = struct { mtime: i64, size: i64 };
	var indexed_map = std.StringHashMap(MtimeAndSize).init(allocator);
	defer indexed_map.deinit();
	for (indexed) |item| {
		try indexed_map.put(item.file_path, .{ .mtime = item.mtime_ns, .size = item.size });
	}

	// Build set of current files for deletion detection
	var current_set = std.StringHashMap(void).init(allocator);
	defer current_set.deinit();
	for (files) |path| {
		try current_set.put(path, {});
	}

	var stats = IncrementalStats{
		.new_files = 0,
		.modified_files = 0,
		.deleted_files = 0,
		.unchanged_files = 0,
		.symbols = 0,
	};

	// 3. Detect and process deleted files
	for (indexed) |item| {
		if (!current_set.contains(item.file_path)) {
			if (debug) {
				debugLog(stderr, "codescan: debug: deleted {s}\n", .{item.file_path});
			}
			try storage.deleteSymbolsByFile(db, item.file_path);
			try storage.deleteIndexedFile(db, item.file_path);
			stats.deleted_files += 1;
		}
	}

	// 4. Process new and modified files
	var batch_texts: std.ArrayListUnmanaged([]const u8) = .{};
	var batch_rowids: std.ArrayListUnmanaged(i64) = .{};
	var comment_texts: std.ArrayListUnmanaged([]const u8) = .{};
	var comment_rowids: std.ArrayListUnmanaged(i64) = .{};
	defer {
		for (batch_texts.items) |text| allocator.free(text);
		batch_texts.deinit(allocator);
		batch_rowids.deinit(allocator);
		for (comment_texts.items) |text| allocator.free(text);
		comment_texts.deinit(allocator);
		comment_rowids.deinit(allocator);
	}

	var progress_count: usize = 0;
	if (show_progress) {
		printProgress(stderr, 0, files.len, false);
	}

	for (files) |rel_path| {
		progress_count += 1;
		if (show_progress) {
			if (shouldEmitProgress(progress_count, files.len, 1)) {
				printProgress(stderr, progress_count, files.len, false);
			}
		}

		const extractor = registry.find(rel_path) orelse continue;
		if (!kindAllowed(extractor.kind, options.allowed_kinds)) continue;
		if (!extAllowed(rel_path, options.allowed_exts)) continue;

		const full_path = try std.fs.path.join(allocator, &.{ root_path, rel_path });
		defer allocator.free(full_path);

		const file = std.fs.cwd().openFile(full_path, .{}) catch continue;
		defer file.close();

		const stat = try file.stat();
		const size = stat.size;
		if (options.max_file_size > 0 and size > options.max_file_size) continue;

		const current_mtime: i64 = @intCast(@divFloor(stat.mtime, std.time.ns_per_s));
		const current_size: i64 = @intCast(size);

		// Check if file is unchanged (both mtime and size must match to catch same-second edits)
		if (indexed_map.get(rel_path)) |prev| {
			if (prev.mtime == current_mtime and prev.size == current_size) {
				stats.unchanged_files += 1;
				continue;
			}
			// Modified: remove old symbols first
			if (debug) {
				debugLog(stderr, "codescan: debug: modified {s}\n", .{rel_path});
			}
			try storage.deleteSymbolsByFile(db, rel_path);
			stats.modified_files += 1;
		} else {
			if (debug) {
				debugLog(stderr, "codescan: debug: new {s}\n", .{rel_path});
			}
			stats.new_files += 1;
		}

		// Read and index the file
		const source = file.readToEndAlloc(allocator, options.max_file_size) catch |err| {
			if (err == error.FileTooBig) continue;
			return err;
		};
		defer allocator.free(source);

		const symbols = try extractor.extract(allocator, rel_path, source);
		defer {
			for (symbols) |*sym| sym.deinit(allocator);
			allocator.free(symbols);
		}
		for (symbols) |*sym| {
			try enrichSymbolMetadata(allocator, sym);
		}

		// Compute chain hashes for this file's lines
		const hashes = computeFileHashes(allocator, source) catch null;
		defer if (hashes) |h| allocator.free(h);

		for (symbols, 0..) |sym, sym_idx| {
			var sym_with_hash = sym;
			if (hashes) |h| {
				if (sym.start_line > 0 and sym.start_line <= h.len)
					sym_with_hash.start_hash = h[sym.start_line - 1];
				if (sym.end_line > 0 and sym.end_line <= h.len)
					sym_with_hash.end_hash = h[sym.end_line - 1];
			}
			const body = try extractSourceBody(allocator, source, sym.start_line, sym.end_line);
			defer if (body) |b| allocator.free(b);
			sym_with_hash.body = body;
			const rowid = try storage.insertSymbol(db, sym_with_hash);
			stats.symbols += 1;

			const text = try buildSymbolText(allocator, sym, extractor.kind);
			try batch_texts.append(allocator, text);
			try batch_rowids.append(allocator, rowid);

			if (batch_texts.items.len >= options.batch_size) {
				if (show_progress and symbols.len > options.batch_size) {
					printFileProgress(stderr, progress_count, files.len, rel_path, sym_idx + 1, symbols.len);
				}
				try flushBatch(allocator, db, embedder, options, &batch_texts, &batch_rowids);
			}

			if (sym.doc_comment) |doc| {
				const comment_text = try buildCommentText(allocator, doc, .doc);
				try comment_texts.append(allocator, comment_text);
				try comment_rowids.append(allocator, rowid);

				if (comment_texts.items.len >= options.batch_size) {
					try flushCommentBatch(allocator, db, embedder, options, &comment_texts, &comment_rowids);
				}
			}
		}

		// Update file tracking
		try storage.upsertIndexedFile(db, rel_path, current_mtime, current_size);
	}

	// Flush remaining batches
	if (batch_texts.items.len > 0) {
		try flushBatch(allocator, db, embedder, options, &batch_texts, &batch_rowids);
	}
	if (comment_texts.items.len > 0) {
		try flushCommentBatch(allocator, db, embedder, options, &comment_texts, &comment_rowids);
	}

	if (show_progress) {
		printProgress(stderr, progress_count, files.len, true);
	}

	return stats;
}

/// Re-index a single file after an edit operation.
/// Deletes old symbols, re-extracts via tree-sitter, re-inserts symbols + FTS.
/// Skips embedding (the background daemon will catch up on vectors).
/// This is fast because it avoids any network calls.
pub fn reindexFile(
	allocator: std.mem.Allocator,
	db: storage.Db,
	rel_path: []const u8,
	root_path: []const u8,
	registry: plugin.Registry,
) !void {
	const extractor = registry.find(rel_path) orelse return;

	const full_path = try std.fs.path.join(allocator, &.{ root_path, rel_path });
	defer allocator.free(full_path);

	const file = try std.fs.cwd().openFile(full_path, .{});
	defer file.close();

	const stat = try file.stat();
	const source = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
	defer allocator.free(source);

	const symbols = try extractor.extract(allocator, rel_path, source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}
	for (symbols) |*sym| {
		try enrichSymbolMetadata(allocator, sym);
	}

	// Compute chain hashes
	const hashes = computeFileHashes(allocator, source) catch null;
	defer if (hashes) |h| allocator.free(h);

	// Delete old data for this file
	try storage.deleteSymbolsByFile(db, rel_path);

	// Re-insert symbols (insertSymbol also handles FTS)
	for (symbols) |sym| {
		var sym_with_hash = sym;
		if (hashes) |h| {
			if (sym.start_line > 0 and sym.start_line <= h.len)
				sym_with_hash.start_hash = h[sym.start_line - 1];
			if (sym.end_line > 0 and sym.end_line <= h.len)
				sym_with_hash.end_hash = h[sym.end_line - 1];
		}
		const body = try extractSourceBody(allocator, source, sym.start_line, sym.end_line);
		defer if (body) |b| allocator.free(b);
		sym_with_hash.body = body;
		_ = try storage.insertSymbol(db, sym_with_hash);
	}

	// Update file metadata
	const current_mtime: i64 = @intCast(@divFloor(stat.mtime, std.time.ns_per_s));
	const current_size: i64 = @intCast(stat.size);
	try storage.upsertIndexedFile(db, rel_path, current_mtime, current_size);
}

fn enrichSymbolMetadata(allocator: std.mem.Allocator, symbol: *model.Symbol) !void {
	if (symbol.symbol_kind == null) {
		if (inferKindFromSignature(symbol.signature, symbol.language)) |value| {
			symbol.symbol_kind = try allocator.dupe(u8, value);
		}
	}
	if (symbol.symbol_visibility == null) {
		if (inferVisibilityFromSignature(symbol.signature)) |value| {
			symbol.symbol_visibility = try allocator.dupe(u8, value);
		}
	}
	if (symbol.symbol_scope == null) {
		if (inferScope(symbol.name, symbol.signature, symbol.symbol_kind)) |value| {
			symbol.symbol_scope = try allocator.dupe(u8, value);
		}
	}
	if (symbol.symbol_arity == null) {
		symbol.symbol_arity = inferArityFromSignature(symbol.name, symbol.signature);
	}
}

fn inferKindFromSignature(signature: []const u8, language: []const u8) ?[]const u8 {
	var trimmed = std.mem.trimLeft(u8, signature, " \t");
	// Strip visibility and qualifier prefixes so "pub inline fn" / "pub const X = struct" work
	inline for ([_][]const u8{ "pub ", "export ", "inline ", "comptime ", "extern " }) |prefix| {
		if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{prefix})) {
			trimmed = std.mem.trimLeft(u8, trimmed[prefix.len..], " \t");
		}
	}
	if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{
		"fn ",
		"def ",
		"defp ",
		"func ",
		"function ",
		"proc ",
	})) return "fn";
	if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{ "class ", "class\t" })) return "class";
	if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{ "struct ", "record " })) return "struct";
	if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{ "enum " })) return "enum";
	if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{ "interface " })) return "interface";
	if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{ "trait " })) return "trait";
	if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{ "module ", "mod ", "namespace " })) return "mod";
	if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{ "macro " })) return "macro";
	if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{ "test ", "test\t", "test\"" })) return "test";
	// const/val → always immutable
	if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{ "const ", "val " })) {
		if (containsTypeAssignment(signature)) |type_kind| return type_kind;
		return "const";
	}
	// let → language-dependent mutability
	if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{"let "})) {
		if (containsTypeAssignment(signature)) |type_kind| return type_kind;
		// let is immutable in Rust and Swift
		if (std.ascii.eqlIgnoreCase(language, "rust") or std.ascii.eqlIgnoreCase(language, "swift")) {
			return "const";
		}
		return "var";
	}
	// var/mut → always mutable
	if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{ "var ", "mut " })) {
		if (containsTypeAssignment(signature)) |type_kind| return type_kind;
		return "var";
	}
	if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{ "type ", "typedef " })) return "type";
	return null;
}

/// Check if a signature contains "= struct", "= enum", or "= union" indicating a type definition.
fn containsTypeAssignment(signature: []const u8) ?[]const u8 {
	const patterns = [_]struct { needle: []const u8, kind: []const u8 }{
		.{ .needle = "= struct", .kind = "struct" },
		.{ .needle = "= enum", .kind = "enum" },
		.{ .needle = "= union", .kind = "union" },
	};
	for (patterns) |p| {
		if (std.mem.indexOf(u8, signature, p.needle) != null) return p.kind;
	}
	return null;
}

fn inferVisibilityFromSignature(signature: []const u8) ?[]const u8 {
	const trimmed = std.mem.trimLeft(u8, signature, " \t");
	if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{
		"pub ",
		"public ",
		"export ",
	})) return "public";
	if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{ "private ", "priv " })) return "private";
	if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{ "protected " })) return "protected";
	if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{ "internal " })) return "internal";
	return null;
}

fn inferScope(name: []const u8, signature: []const u8, symbol_kind: ?[]const u8) ?[]const u8 {
	const trimmed = std.mem.trimLeft(u8, signature, " \t");
	if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{ "var ", "let ", "const ", "val ", "mut " })) {
		return "local";
	}
	if (std.mem.indexOf(u8, name, ".") != null or std.mem.indexOf(u8, name, "::") != null) {
		if (symbol_kind) |kind_value| {
			if (std.ascii.eqlIgnoreCase(kind_value, "fn")) return "method";
		}
		return "member";
	}
	return "top_level";
}

fn inferArityFromSignature(name: []const u8, signature: []const u8) ?i32 {
	if (std.mem.indexOfScalar(u8, signature, '(')) |open_idx| {
		if (std.mem.indexOfScalarPos(u8, signature, open_idx + 1, ')')) |close_idx| {
			const params = signature[open_idx + 1 .. close_idx];
			if (isEmptyParams(params)) return 0;
			var count: i32 = 1;
			var paren_depth: i32 = 0;
			var bracket_depth: i32 = 0;
			var brace_depth: i32 = 0;
			var angle_depth: i32 = 0;
				for (params) |ch| {
					switch (ch) {
						'(' => paren_depth += 1,
						')' => {
							if (paren_depth > 0) paren_depth -= 1;
						},
						'[' => bracket_depth += 1,
						']' => {
							if (bracket_depth > 0) bracket_depth -= 1;
						},
						'{' => brace_depth += 1,
						'}' => {
							if (brace_depth > 0) brace_depth -= 1;
						},
						'<' => angle_depth += 1,
						'>' => {
							if (angle_depth > 0) angle_depth -= 1;
						},
						',' => if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0 and angle_depth == 0) {
							count += 1;
						},
					else => {},
				}
			}
			return count;
		}
	}
	if (std.mem.lastIndexOfScalar(u8, name, '/')) |slash_idx| {
		if (slash_idx + 1 < name.len) {
			return parseIntToken(name[slash_idx + 1 ..]);
		}
	}
	return null;
}

fn isEmptyParams(params: []const u8) bool {
	const trimmed = std.mem.trim(u8, params, " \t\r\n");
	if (trimmed.len == 0) return true;
	return std.ascii.eqlIgnoreCase(trimmed, "void");
}

fn parseIntToken(token: []const u8) ?i32 {
	if (token.len == 0) return null;
	for (token) |ch| {
		if (!std.ascii.isDigit(ch)) return null;
	}
	return std.fmt.parseInt(i32, token, 10) catch null;
}

fn hasAnyPrefixIgnoreCase(value: []const u8, prefixes: []const []const u8) bool {
	for (prefixes) |prefix| {
		if (hasPrefixIgnoreCase(value, prefix)) return true;
	}
	return false;
}

fn hasPrefixIgnoreCase(value: []const u8, prefix: []const u8) bool {
	if (value.len < prefix.len) return false;
	return std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn kindAllowed(kind_value: kind.Kind, allowed: []const kind.Kind) bool {
	if (allowed.len == 0) return true;
	for (allowed) |value| {
		if (value == kind_value) return true;
	}
	return false;
}

fn extAllowed(path: []const u8, allowed: []const []const u8) bool {
	if (allowed.len == 0) return true;
	for (allowed) |ext| {
		if (hasExtensionIgnoreCase(path, ext)) return true;
	}
	return false;
}

fn hasExtensionIgnoreCase(path: []const u8, ext: []const u8) bool {
	if (ext.len == 0) return false;
	if (path.len < ext.len) return false;
	const tail = path[path.len - ext.len ..];
	return std.ascii.eqlIgnoreCase(tail, ext);
}

/// Split source into lines and compute chain hashes.
const max_body_bytes: usize = 16 * 1024; // 16 KB cap per symbol body

/// Extract the source body for a symbol from source text, given its 1-based line range.
/// Returns an owned slice truncated to max_body_bytes, or null if the range is invalid.
fn extractSourceBody(allocator: std.mem.Allocator, source: []const u8, start_line: usize, end_line: usize) !?[]const u8 {
	if (start_line == 0 or end_line == 0 or start_line > end_line) return null;

	// Walk source to find byte offsets for the line range
	var line: usize = 1;
	var body_start: ?usize = null;
	if (start_line == 1) body_start = 0;

	for (source, 0..) |ch, i| {
		if (ch == '\n') {
			if (line == end_line) {
				// End of the last line we want (include the newline)
				const bs = body_start orelse return null;
				const raw = source[bs .. i + 1];
				const len = @min(raw.len, max_body_bytes);
				return try allocator.dupe(u8, raw[0..len]);
			}
			line += 1;
			if (line == start_line) {
				body_start = i + 1;
			}
		}
	}

	// Handle last line (no trailing newline)
	if (line >= start_line and line <= end_line) {
		const bs = body_start orelse return null;
		const raw = source[bs..];
		const len = @min(raw.len, max_body_bytes);
		return try allocator.dupe(u8, raw[0..len]);
	}

	return null;
}

fn computeFileHashes(allocator: std.mem.Allocator, source: []const u8) ![]hashline.Hash {
	// Split source into lines
	var lines = std.ArrayListUnmanaged([]const u8){};
	defer lines.deinit(allocator);

	var start: usize = 0;
	for (source, 0..) |ch, i| {
		if (ch == '\n') {
			try lines.append(allocator, source[start..i]);
			start = i + 1;
		}
	}
	// Last line (may not end with newline)
	if (start <= source.len) {
		try lines.append(allocator, source[start..]);
	}

	return hashline.computeChainHashes(allocator, lines.items);
}

pub fn buildSymbolText(
	allocator: std.mem.Allocator,
	symbol: model.Symbol,
	symbol_kind: kind.Kind,
) ![]u8 {
	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	try out.writer.writeAll(symbol.name);
	try out.writer.writeAll("\n");
	try out.writer.writeAll(symbol.signature);
	if (symbol.doc_comment) |doc| {
		try out.writer.writeAll("\n");
		try out.writer.writeAll(doc);
	}

	const text = try out.toOwnedSlice();
	return truncateOwnedText(allocator, symbol_kind, text);
}

pub fn buildCommentText(
	allocator: std.mem.Allocator,
	doc: []const u8,
	comment_kind: kind.Kind,
) ![]u8 {
	return truncateForKind(allocator, comment_kind, doc);
}

const max_embed_bytes_code: usize = 1600;
const max_embed_bytes_doc: usize = 1000;

fn maxEmbedBytes(item_kind: kind.Kind) usize {
	return switch (item_kind) {
		.code, .log => max_embed_bytes_code,
		.doc, .text => max_embed_bytes_doc,
	};
}

fn truncateOwnedText(allocator: std.mem.Allocator, item_kind: kind.Kind, text: []u8) ![]u8 {
	const limit = maxEmbedBytes(item_kind);
	if (text.len <= limit) return text;
	const trimmed = try truncateForKind(allocator, item_kind, text);
	allocator.free(text);
	return trimmed;
}

fn truncateForKind(
	allocator: std.mem.Allocator,
	item_kind: kind.Kind,
	text: []const u8,
) ![]u8 {
	const limit = maxEmbedBytes(item_kind);
	if (text.len <= limit) return allocator.dupe(u8, text);

	return switch (item_kind) {
		.code, .log => truncateCode(allocator, text, limit),
		.doc, .text => truncateText(allocator, text, limit),
	};
}

fn truncateText(allocator: std.mem.Allocator, text: []const u8, limit: usize) ![]u8 {
	const min_reasonable = limit / 2;
	const bounded = text[0..limit];

	if (findSentenceCut(bounded, min_reasonable)) |cut| {
		return allocator.dupe(u8, trimRight(text[0..cut]));
	}
	if (findWhitespaceCut(bounded, min_reasonable)) |cut| {
		return allocator.dupe(u8, trimRight(text[0..cut]));
	}
	return allocator.dupe(u8, text[0..limit]);
}

fn truncateCode(allocator: std.mem.Allocator, text: []const u8, limit: usize) ![]u8 {
	const min_reasonable = limit / 2;
	const bounded = text[0..limit];

	if (findNewlineCut(bounded, min_reasonable)) |cut| {
		return allocator.dupe(u8, trimRight(text[0..cut]));
	}
	if (findWhitespaceCut(bounded, min_reasonable)) |cut| {
		return allocator.dupe(u8, trimRight(text[0..cut]));
	}
	return allocator.dupe(u8, text[0..limit]);
}

fn findSentenceCut(text: []const u8, min_reasonable: usize) ?usize {
	if (text.len == 0) return null;
	var idx: usize = text.len;
	while (idx > min_reasonable) : (idx -= 1) {
		const ch = text[idx - 1];
		if (ch == '.' or ch == '!' or ch == '?') {
			if (idx < text.len and !isWhitespace(text[idx])) continue;
			return idx;
		}
	}
	return null;
}

fn findNewlineCut(text: []const u8, min_reasonable: usize) ?usize {
	const idx = std.mem.lastIndexOfScalar(u8, text, '\n') orelse return null;
	if (idx + 1 < min_reasonable) return null;
	return idx + 1;
}

fn findWhitespaceCut(text: []const u8, min_reasonable: usize) ?usize {
	if (text.len == 0) return null;
	var idx: usize = text.len;
	while (idx > min_reasonable) : (idx -= 1) {
		if (isWhitespace(text[idx - 1])) return idx - 1;
	}
	return null;
}

fn isWhitespace(ch: u8) bool {
	return ch == ' ' or ch == '\n' or ch == '\r' or ch == '\t';
}

fn trimRight(text: []const u8) []const u8 {
	return std.mem.trimRight(u8, text, " \t\r\n");
}

fn flushBatch(
	allocator: std.mem.Allocator,
	db: storage.Db,
	embedder: embedding.Embedder,
	options: Options,
	batch_texts: *std.ArrayListUnmanaged([]const u8),
	batch_rowids: *std.ArrayListUnmanaged(i64),
) !void {
	const embeddings = try embedder.embed(embedder.ctx, allocator, batch_texts.items);
	defer embedder.free(embedder.ctx, allocator, embeddings);

	// NullEmbedder returns empty — skip vector insertion, just clean up texts
	if (embeddings.len == 0) {
		for (batch_texts.items) |text| allocator.free(text);
		batch_texts.clearRetainingCapacity();
		batch_rowids.clearRetainingCapacity();
		return;
	}

	if (embeddings.len != batch_texts.items.len) return error.EmbeddingCountMismatch;
	for (embeddings, 0..) |vector, idx| {
		if (vector.len != options.embedding_dim) return error.EmbeddingDimMismatch;
		try storage.insertEmbedding(db, allocator, batch_rowids.items[idx], vector);
	}

	for (batch_texts.items) |text| allocator.free(text);
	batch_texts.clearRetainingCapacity();
	batch_rowids.clearRetainingCapacity();
}

fn flushCommentBatch(
	allocator: std.mem.Allocator,
	db: storage.Db,
	embedder: embedding.Embedder,
	options: Options,
	batch_texts: *std.ArrayListUnmanaged([]const u8),
	batch_rowids: *std.ArrayListUnmanaged(i64),
) !void {
	const embeddings = try embedder.embed(embedder.ctx, allocator, batch_texts.items);
	defer embedder.free(embedder.ctx, allocator, embeddings);

	// NullEmbedder returns empty — skip vector insertion, just clean up texts
	if (embeddings.len == 0) {
		for (batch_texts.items) |text| allocator.free(text);
		batch_texts.clearRetainingCapacity();
		batch_rowids.clearRetainingCapacity();
		return;
	}

	if (embeddings.len != batch_texts.items.len) return error.EmbeddingCountMismatch;
	for (embeddings, 0..) |vector, idx| {
		if (vector.len != options.embedding_dim) return error.EmbeddingDimMismatch;
		try storage.insertCommentEmbedding(db, allocator, batch_rowids.items[idx], vector);
	}

	for (batch_texts.items) |text| allocator.free(text);
	batch_texts.clearRetainingCapacity();
	batch_rowids.clearRetainingCapacity();
}

fn warnLargeFile(
	writer: *std.Io.Writer,
	file_path: []const u8,
	size: u64,
	threshold: u64,
	max_size: usize,
	skipping: bool,
) void {
	const action = if (skipping) "skipping" else "consider refactoring";
	_ = writer.print(
		"codescan: warning: {s} is {d} bytes (warn>{d}, max {d}); {s} or increase --max-file-size / .codescan/config\n",
		.{ file_path, size, threshold, max_size, action },
	) catch {};
	_ = writer.flush() catch {};
}

fn debugEnabled(allocator: std.mem.Allocator) !bool {
	const value = std.process.getEnvVarOwned(allocator, "DEBUG") catch |err| switch (err) {
		error.EnvironmentVariableNotFound => return false,
		else => return err,
	};
	defer allocator.free(value);
	return debugEnabledFromValue(value);
}

fn debugEnabledFromValue(value: []const u8) bool {
	const trimmed = std.mem.trim(u8, value, " \t\r\n");
	if (trimmed.len == 0) return false;
	if (std.ascii.eqlIgnoreCase(trimmed, "0")) return false;
	if (std.ascii.eqlIgnoreCase(trimmed, "false")) return false;
	if (std.ascii.eqlIgnoreCase(trimmed, "no")) return false;
	return true;
}

fn envOrDefault(allocator: std.mem.Allocator, key: []const u8, fallback: []const u8) ![]u8 {
	const value = std.process.getEnvVarOwned(allocator, key) catch |err| switch (err) {
		error.EnvironmentVariableNotFound => return allocator.dupe(u8, fallback),
		else => return err,
	};
	return value;
}

fn debugLog(writer: *std.Io.Writer, comptime fmt: []const u8, args: anytype) void {
	_ = writer.print(fmt, args) catch {};
	_ = writer.flush() catch {};
}

fn printProgress(writer: *std.Io.Writer, current: usize, total: usize, done: bool) void {
	if (done) {
		// Clear the line and print final count
		_ = writer.print("\r\x1b[KIndexed {d}/{d}\n", .{ current, total }) catch {};
	} else {
		_ = writer.print("\r\x1b[KIndexed {d}/{d}", .{ current, total }) catch {};
	}
	_ = writer.flush() catch {};
}

fn printFileProgress(writer: *std.Io.Writer, file_count: usize, file_total: usize, filename: []const u8, sym_current: usize, sym_total: usize) void {
	// Show: Indexed 95/173 — gtk.zig (48/312 symbols)
	const basename = std.fs.path.basename(filename);
	_ = writer.print("\r\x1b[KIndexed {d}/{d} \xe2\x80\x94 {s} ({d}/{d} symbols)", .{
		file_count, file_total, basename, sym_current, sym_total,
	}) catch {};
	_ = writer.flush() catch {};
}

fn formatProgress(allocator: std.mem.Allocator, current: usize, total: usize) ![]u8 {
	return std.fmt.allocPrint(allocator, "Indexed {d}/{d}", .{ current, total });
}

fn shouldEmitProgress(current: usize, total: usize, step: usize) bool {
	if (step == 0) return current == total;
	return current == total or current % step == 0;
}

test "buildSymbolText includes name signature and doc" {
	const allocator = std.testing.allocator;
	var symbol = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/main.zig"),
		.name = try allocator.dupe(u8, "add"),
		.signature = try allocator.dupe(u8, "pub fn add(a: i32, b: i32) i32"),
		.doc_comment = try allocator.dupe(u8, "Adds two ints"),
		.start_line = 1,
		.end_line = 2,
	};
	defer symbol.deinit(allocator);

	const text = try buildSymbolText(allocator, symbol, .code);
	defer allocator.free(text);
	try std.testing.expectEqualStrings(
		"add\npub fn add(a: i32, b: i32) i32\nAdds two ints",
		text,
	);
}

test "truncateForKind prefers sentence boundary for docs" {
	const allocator = std.testing.allocator;
	const sentence = "This is a sentence. ";
	var out = std.ArrayListUnmanaged(u8){};
	defer out.deinit(allocator);

	while (out.items.len <= max_embed_bytes_doc + 20) {
		try out.appendSlice(allocator, sentence);
	}
	const text = out.items;

	const truncated = try truncateForKind(allocator, .doc, text);
	defer allocator.free(truncated);
	try std.testing.expect(truncated.len <= max_embed_bytes_doc);
	try std.testing.expect(truncated.len >= max_embed_bytes_doc / 2);
	const last = truncated[truncated.len - 1];
	try std.testing.expect(last == '.' or last == '!' or last == '?');
}

test "truncateForKind prefers newline boundary for code" {
	const allocator = std.testing.allocator;
	var out = std.ArrayListUnmanaged(u8){};
	defer out.deinit(allocator);

	while (out.items.len <= max_embed_bytes_code + 40) {
		try out.appendSlice(allocator, "const value = 12345;\n");
	}
	const text = out.items;

	const truncated = try truncateForKind(allocator, .code, text);
	defer allocator.free(truncated);
	try std.testing.expect(truncated.len <= max_embed_bytes_code);
	try std.testing.expect(truncated.len >= max_embed_bytes_code / 2);

	const slice = text[0..max_embed_bytes_code];
	const last_newline = std.mem.lastIndexOfScalar(u8, slice, '\n') orelse 0;
	const expected = std.mem.trimRight(u8, text[0..last_newline + 1], " \t\r\n");
	try std.testing.expectEqualStrings(expected, truncated);
}

test "buildSymbolText truncates long inputs" {
	const allocator = std.testing.allocator;
	const long_doc = try allocator.alloc(u8, max_embed_bytes_doc + 10);
	defer allocator.free(long_doc);
	@memset(long_doc, 'a');

	var symbol = model.Symbol{
		.language = try allocator.dupe(u8, "markdown"),
		.file_path = try allocator.dupe(u8, "README.md"),
		.name = try allocator.dupe(u8, "Title"),
		.signature = try allocator.dupe(u8, "Intro"),
		.doc_comment = try allocator.dupe(u8, long_doc),
		.start_line = 1,
		.end_line = 2,
	};
	defer symbol.deinit(allocator);

	const text = try buildSymbolText(allocator, symbol, .doc);
	defer allocator.free(text);
	try std.testing.expect(text.len <= max_embed_bytes_doc);
}

test "doc truncation avoids Ollama context length errors" {
	const allocator = std.testing.allocator;
	try embedding_http.skipIfNoOllama(allocator);
	const doc =
		"## Images\n\n" ++
		"| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |\n" ++
		"|--------|------------|------------------|-----------------|-----------|-----|\n" ++
		"| **PNG** | .png | Signature, chunk structure, IEND terminator | CRC32 per chunk | Checksum | \u{2014} |\n" ++
		"| **JPEG** | .jpg, .jpeg | SOI/EOI markers, segment structure | Full decode via libjpeg-turbo | Full Decode | \u{2014} |\n" ++
		"| **JPEG XL** | .jxl | Codestream (FF 0A) or container signature | Full decode via libjxl | Full Decode | 1 |\n" ++
		"| **GIF** | .gif | Header (GIF87a/89a), trailer (0x3B), block structure | Full LZW decode via zigimg | Full Decode | 1 |\n" ++
		"| **BMP** | .bmp | Header, DIB header, pixel data bounds | Full pixel decode via zigimg | Full Decode | 1 |\n" ++
		"| **WebP** | .webp | RIFF container, VP8/VP8L/VP8X chunks | Full decode via libwebp | Full Decode | 1 |\n" ++
		"| **TIFF** | .tiff, .tif | Header (II/MM), IFD structure, tag validation | Full decode via zigimg | Full Decode | 1 |\n" ++
		"| **HEIC/HEIF** | .heic, .heif | ISOBMFF structure, ftyp brand validation | Full decode via libheif/libde265 | Full Decode | 1 |\n" ++
		"| **AVIF** | .avif | ISOBMFF structure, ftyp brand validation | Full decode via libheif/dav1d | Full Decode | 1 |\n" ++
		"| **SVG** | .svg | XML declaration, `<svg>` root element | Full XML parse | Integrity | \u{2014} |\n" ++
		"| **OpenEXR** | .exr | Signature (76 2F 31 01), header structure | Required attribute validation (channels, compression, windows) | Integrity | \u{2014} |\n";

	var symbol = model.Symbol{
		.language = try allocator.dupe(u8, "markdown"),
		.file_path = try allocator.dupe(u8, "FORMAT_VERIFICATIONS.md"),
		.name = try allocator.dupe(u8, "Images"),
		.signature = try allocator.dupe(
			u8,
			"| Format | Extensions | Basic Validation | Deep Validation | Max Depth | GT |",
		),
		.doc_comment = try allocator.dupe(u8, doc),
		.start_line = 1,
		.end_line = 20,
	};
	defer symbol.deinit(allocator);

	const text = try buildSymbolText(allocator, symbol, .doc);
	defer allocator.free(text);

	var transport = embedding_http.StdHttpTransport.init(allocator);
	defer transport.deinit();

	const url = try envOrDefault(allocator, "OLLAMA_URL", "http://localhost:11434");
	defer allocator.free(url);
	const model_name = try envOrDefault(allocator, "OLLAMA_MODEL", "bge-large");
	defer allocator.free(model_name);

	embedding_http.ensureModelAvailable(allocator, transport.transport(), url, model_name, .ollama) catch |err| switch (err) {
		error.ModelLoading => {}, // Model exists, embed will trigger loading
		else => return err,
	};

	var adapter = embedding.HttpEmbedder{
		.transport = transport.transport(),
		.base_url = url,
		.model = model_name,
		.dialect = .ollama,
		.auth_header = null,
	};	const embedder = adapter.embedder();

	const inputs = [_][]const u8{ text };
	const embeddings = try embedder.embed(embedder.ctx, allocator, &inputs);
	defer embedder.free(embedder.ctx, allocator, embeddings);

	try std.testing.expectEqual(@as(usize, 1), embeddings.len);
	try std.testing.expect(embeddings[0].len > 0);
}

test "debugEnabledFromValue recognizes truthy values" {
	try std.testing.expect(!debugEnabledFromValue(""));
	try std.testing.expect(!debugEnabledFromValue("0"));
	try std.testing.expect(!debugEnabledFromValue("false"));
	try std.testing.expect(!debugEnabledFromValue("no"));
	try std.testing.expect(debugEnabledFromValue("1"));
	try std.testing.expect(debugEnabledFromValue("true"));
	try std.testing.expect(debugEnabledFromValue("yes"));
}

test "formatProgress formats counters" {
	const allocator = std.testing.allocator;
	const text = try formatProgress(allocator, 3, 10);
	defer allocator.free(text);
	try std.testing.expectEqualStrings("Indexed 3/10", text);
}

test "shouldEmitProgress respects step and completion" {
	try std.testing.expect(shouldEmitProgress(1, 10, 1));
	try std.testing.expect(shouldEmitProgress(2, 10, 1));
	try std.testing.expect(!shouldEmitProgress(3, 10, 2));
	try std.testing.expect(shouldEmitProgress(4, 10, 2));
	try std.testing.expect(shouldEmitProgress(10, 10, 5));
}

test "enrichSymbolMetadata infers kind visibility scope and arity" {
	const allocator = std.testing.allocator;
	var symbol = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/main.zig"),
		.name = try allocator.dupe(u8, "add"),
		.signature = try allocator.dupe(u8, "pub fn add(a: i32, b: i32) i32"),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer symbol.deinit(allocator);

	try enrichSymbolMetadata(allocator, &symbol);

	try std.testing.expect(symbol.symbol_kind != null);
	try std.testing.expect(symbol.symbol_visibility != null);
	try std.testing.expect(symbol.symbol_scope != null);
	try std.testing.expect(symbol.symbol_arity != null);
	try std.testing.expectEqualStrings("fn", symbol.symbol_kind.?);
	try std.testing.expectEqualStrings("public", symbol.symbol_visibility.?);
	try std.testing.expectEqualStrings("top_level", symbol.symbol_scope.?);
	try std.testing.expectEqual(@as(i32, 2), symbol.symbol_arity.?);
}

test "inferKindFromSignature returns short canonical forms with const/var split" {
	// Functions → "fn"
	try std.testing.expectEqualStrings("fn", inferKindFromSignature("pub fn add(a: i32) i32", "zig").?);
	try std.testing.expectEqualStrings("fn", inferKindFromSignature("fn sub(a: i32) i32", "zig").?);
	try std.testing.expectEqualStrings("fn", inferKindFromSignature("def foo(x):", "python").?);
	try std.testing.expectEqualStrings("fn", inferKindFromSignature("inline fn vecToLower(v: Vec) Vec", "zig").?);
	try std.testing.expectEqualStrings("fn", inferKindFromSignature("pub inline fn foo() void", "zig").?);
	try std.testing.expectEqualStrings("fn", inferKindFromSignature("extern fn write() void", "zig").?);
	// Structs/enums/unions from Zig patterns
	try std.testing.expectEqualStrings("struct", inferKindFromSignature("pub const FsWatch = struct", "zig").?);
	try std.testing.expectEqualStrings("struct", inferKindFromSignature("const Config = struct", "zig").?);
	try std.testing.expectEqualStrings("enum", inferKindFromSignature("pub const Color = enum", "zig").?);
	try std.testing.expectEqualStrings("union", inferKindFromSignature("pub const Value = union", "zig").?);
	// Immutable → "const"
	try std.testing.expectEqualStrings("const", inferKindFromSignature("pub const MAX_SIZE = 100", "zig").?);
	try std.testing.expectEqualStrings("const", inferKindFromSignature("const name = \"hello\"", "zig").?);
	try std.testing.expectEqualStrings("const", inferKindFromSignature("val x = 1", "kotlin").?);
	// let in Rust/Swift → "const" (immutable)
	try std.testing.expectEqualStrings("const", inferKindFromSignature("let x = 1", "rust").?);
	try std.testing.expectEqualStrings("const", inferKindFromSignature("let x = 1", "swift").?);
	// let in JS/TS → "var" (mutable)
	try std.testing.expectEqualStrings("var", inferKindFromSignature("let x = 1", "typescript").?);
	try std.testing.expectEqualStrings("var", inferKindFromSignature("let x = 1", "javascript").?);
	// Mutable → "var"
	try std.testing.expectEqualStrings("var", inferKindFromSignature("pub var count = 0", "zig").?);
	try std.testing.expectEqualStrings("var", inferKindFromSignature("comptime var i: usize = 0", "zig").?);
	try std.testing.expectEqualStrings("var", inferKindFromSignature("mut x = 1", "rust").?);
	// Module → "mod"
	try std.testing.expectEqualStrings("mod", inferKindFromSignature("module Foo", "elixir").?);
	// Test
	try std.testing.expectEqualStrings("test", inferKindFromSignature("test \"basic addition\"", "zig").?);
	// Other kinds unchanged
	try std.testing.expectEqualStrings("struct", inferKindFromSignature("struct Foo", "c").?);
	try std.testing.expectEqualStrings("class", inferKindFromSignature("class Foo", "typescript").?);
	try std.testing.expectEqualStrings("enum", inferKindFromSignature("enum Color", "rust").?);
	try std.testing.expectEqualStrings("macro", inferKindFromSignature("macro foo", "elixir").?);
	try std.testing.expectEqualStrings("type", inferKindFromSignature("type Foo = int", "go").?);
}

test "inferArityFromSignature supports slash arity fallback" {
	try std.testing.expectEqual(@as(?i32, 2), inferArityFromSignature("decode/2", "decode/2"));
}

test "indexAll stores symbols and embeddings" {
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	try tmp.dir.makePath("src");
	const source =
		"/// Adds\n" ++
		"pub fn add(a: i32, b: i32) i32 { return a + b; }\n" ++
		"fn sub(a: i32, b: i32) i32 { return a - b; }\n";
	try tmp.dir.writeFile(.{ .sub_path = "src/math.zig", .data = source });

	const allocator = std.testing.allocator;
	const root = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(root);

	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	var fake = FakeEmbedder{};
	const stats = try indexAll(allocator, db, root, plugin.defaultRegistry(), fake.embedder(), .{
		.embedding_dim = 2,
		.batch_size = 2,
	});

	try std.testing.expectEqual(@as(usize, 1), stats.files);
	try std.testing.expectEqual(@as(usize, 2), stats.symbols);
	try std.testing.expectEqual(@as(i64, 2), try storage.countRows(db, allocator, "symbols"));
	try std.testing.expectEqual(@as(i64, 2), try storage.countRows(db, allocator, "embeddings"));
	try std.testing.expectEqual(@as(i64, 1), try storage.countRows(db, allocator, "embeddings_comment"));
}

test "indexAll skips files over max_file_size" {
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	try tmp.dir.makePath("src");
	const source =
		"/// Big\n" ++
		"pub fn big() void { return; }\n";
	try tmp.dir.writeFile(.{ .sub_path = "src/big.zig", .data = source });

	const allocator = std.testing.allocator;
	const root = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(root);

	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	var fake = FakeEmbedder{};
	const stats = try indexAll(allocator, db, root, plugin.defaultRegistry(), fake.embedder(), .{
		.embedding_dim = 2,
		.batch_size = 2,
		.max_file_size = 8,
	});

	try std.testing.expectEqual(@as(usize, 0), stats.files);
	try std.testing.expectEqual(@as(usize, 0), stats.symbols);
	try std.testing.expectEqual(@as(i64, 0), try storage.countRows(db, allocator, "symbols"));
}

test "indexAll filters by extension and kind" {
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	try tmp.dir.makePath("src");
	try tmp.dir.writeFile(.{ .sub_path = "src/main.zig", .data = "pub fn add() void {}" });
	try tmp.dir.writeFile(.{ .sub_path = "README.md", .data = "# Title\nbody\n" });

	const allocator = std.testing.allocator;
	const root = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(root);

	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	var fake = FakeEmbedder{};
	const stats = try indexAll(allocator, db, root, plugin.defaultRegistry(), fake.embedder(), .{
		.embedding_dim = 2,
		.allowed_exts = &[_][]const u8{ ".md" },
		.allowed_kinds = &[_]kind.Kind{ .doc },
	});

	try std.testing.expectEqual(@as(usize, 1), stats.files);
	try std.testing.expect(stats.symbols > 0);
	try std.testing.expectEqual(@as(i64, 1), try storage.countDistinctFiles(db, allocator));
}

test "warnLargeFile includes limits" {
	const allocator = std.testing.allocator;
	var out: std.io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	warnLargeFile(&out.writer, "src/big.zig", 600_000, 500_000, 2_000_000, false);
	const payload = try out.toOwnedSlice();
	defer allocator.free(payload);

	try std.testing.expect(std.mem.indexOf(u8, payload, "src/big.zig") != null);
	try std.testing.expect(std.mem.indexOf(u8, payload, "max 2000000") != null);
}

test "indexIncremental indexes new files and skips unchanged" {
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	try tmp.dir.makePath("src");
	try tmp.dir.writeFile(.{ .sub_path = "src/math.zig", .data = "pub fn add(a: i32, b: i32) i32 { return a + b; }\n" });

	const allocator = std.testing.allocator;
	const root = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(root);

	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	var fake = FakeEmbedder{};

	// First incremental index: everything is new
	const stats1 = try indexIncremental(allocator, db, root, plugin.defaultRegistry(), fake.embedder(), .{
		.embedding_dim = 2,
		.batch_size = 2,
	});
	try std.testing.expectEqual(@as(usize, 1), stats1.new_files);
	try std.testing.expectEqual(@as(usize, 0), stats1.modified_files);
	try std.testing.expectEqual(@as(usize, 0), stats1.unchanged_files);
	try std.testing.expect(stats1.symbols > 0);

	// Second incremental index: everything unchanged (same mtime at second resolution)
	const stats2 = try indexIncremental(allocator, db, root, plugin.defaultRegistry(), fake.embedder(), .{
		.embedding_dim = 2,
		.batch_size = 2,
	});
	try std.testing.expectEqual(@as(usize, 0), stats2.new_files);
	try std.testing.expectEqual(@as(usize, 0), stats2.modified_files);
	try std.testing.expectEqual(@as(usize, 1), stats2.unchanged_files);
}

test "indexIncremental detects deleted files" {
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	try tmp.dir.makePath("src");
	try tmp.dir.writeFile(.{ .sub_path = "src/a.zig", .data = "pub fn a() void {}\n" });
	try tmp.dir.writeFile(.{ .sub_path = "src/b.zig", .data = "pub fn b() void {}\n" });

	const allocator = std.testing.allocator;
	const root = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(root);

	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);

	var fake = FakeEmbedder{};

	// Initial index
	const stats1 = try indexIncremental(allocator, db, root, plugin.defaultRegistry(), fake.embedder(), .{
		.embedding_dim = 2,
		.batch_size = 2,
	});
	try std.testing.expectEqual(@as(usize, 2), stats1.new_files);
	try std.testing.expectEqual(@as(i64, 2), try storage.countRows(db, allocator, "symbols"));

	// Delete one file
	try tmp.dir.deleteFile("src/b.zig");

	// Re-index: should detect deletion
	const stats2 = try indexIncremental(allocator, db, root, plugin.defaultRegistry(), fake.embedder(), .{
		.embedding_dim = 2,
		.batch_size = 2,
	});
	try std.testing.expectEqual(@as(usize, 1), stats2.deleted_files);
	try std.testing.expectEqual(@as(usize, 1), stats2.unchanged_files);
	try std.testing.expectEqual(@as(i64, 1), try storage.countRows(db, allocator, "symbols"));
}

const FakeEmbedder = struct {
	pub fn embedder(self: *FakeEmbedder) embedding.Embedder {
		return .{ .ctx = self, .embed = embed, .free = free };
	}

	fn embed(ctx: *anyopaque, allocator: std.mem.Allocator, inputs: []const []const u8) ![][]f32 {
		_ = ctx;
		var rows = try allocator.alloc([]f32, inputs.len);
		errdefer {
			for (rows) |row| allocator.free(row);
			allocator.free(rows);
		}
		for (inputs, 0..) |input, idx| {
			var row = try allocator.alloc(f32, 2);
			const len: f32 = @floatFromInt(input.len);
			row[0] = len;
			row[1] = len + 0.5;
			rows[idx] = row;
		}
		return rows;
	}

	fn free(ctx: *anyopaque, allocator: std.mem.Allocator, embeddings: [][]f32) void {
		_ = ctx;
		for (embeddings) |row| allocator.free(row);
		allocator.free(embeddings);
	}
};
