const std = @import("std");
const kind = @import("kind.zig");
const model = @import("model.zig");
const plugin = @import("plugin.zig");
const storage = @import("storage.zig");

pub const FilterLists = struct {
	exts: std.ArrayListUnmanaged([]const u8) = .empty,
	langs: std.ArrayListUnmanaged([]const u8) = .empty,
	kinds: std.ArrayListUnmanaged(kind.Kind) = .empty,
	symbol_kinds: std.ArrayListUnmanaged([]const u8) = .empty,

	pub fn deinit(self: *FilterLists, allocator: std.mem.Allocator) void {
		for (self.exts.items) |item| allocator.free(item);
		self.exts.deinit(allocator);
		for (self.langs.items) |item| allocator.free(item);
		self.langs.deinit(allocator);
		self.kinds.deinit(allocator);
		for (self.symbol_kinds.items) |item| allocator.free(item);
		self.symbol_kinds.deinit(allocator);
		self.* = undefined;
	}
};

pub const SearchOptions = struct {
	search_ext: ?[]const u8 = null,
	search_type: ?[]const u8 = null,
	search_lang: ?[]const u8 = null,
	search_symbol_kind: ?[]const u8 = null,
	primary_lang: ?[]const u8 = null,
	include_docs: bool = false,
	docs_only: bool = false,
};

pub fn buildIndexFilters(
	allocator: std.mem.Allocator,
	index_ext: ?[]const u8,
	index_type: ?[]const u8,
) !FilterLists {
	var filters = FilterLists{};
	errdefer filters.deinit(allocator);

	if (index_ext) |value| {
		try parseExtList(allocator, &filters.exts, value);
	}
	if (index_type) |value| {
		try parseKindList(allocator, &filters.kinds, value);
	}
	return filters;
}

/// Resolves the extension/language/kind filter set for a search. Pure with
/// respect to the index: filters depend only on the caller's options and the
/// language registry, never on which languages happen to dominate the database.
pub fn buildSearchFilters(
	allocator: std.mem.Allocator,
	registry: plugin.Registry,
	options: SearchOptions,
) !FilterLists {
	var filters = FilterLists{};
	errdefer filters.deinit(allocator);

	if (options.search_ext) |value| {
		try parseExtList(allocator, &filters.exts, value);
	}
	if (options.search_lang) |value| {
		try parseLangList(allocator, &filters.langs, value);
	}
	if (options.search_type) |value| {
		try parseKindList(allocator, &filters.kinds, value);
	}
	if (options.search_symbol_kind) |value| {
		try parseSymbolKindList(allocator, &filters.symbol_kinds, value);
	}

	if (options.docs_only) {
		if (!containsKind(filters.kinds.items, .doc)) {
			try filters.kinds.append(allocator, .doc);
		}
	}

	const has_explicit =
		filters.exts.items.len > 0 or
		filters.langs.items.len > 0 or
		filters.kinds.items.len > 0;

	if (!has_explicit and !options.docs_only) {
		// Default search restricts to code languages so plain queries return code
		// rather than prose. It must NOT narrow further to a single language:
		// pinning the most-populous language silently hid every other language in
		// polyglot repositories, which returned zero results for well-formed
		// queries. Only an explicitly configured primary_lang narrows the default.
		if (options.primary_lang) |value| {
			const normalized = try normalizeLower(allocator, value);
			errdefer allocator.free(normalized);
			if (!containsString(filters.langs.items, normalized)) {
				try filters.langs.append(allocator, normalized);
			} else {
				allocator.free(normalized);
			}
		} else {
			const code_langs = try registry.languagesForKinds(allocator, &[_]kind.Kind{.code});
			defer {
				for (code_langs) |item| allocator.free(item);
				allocator.free(code_langs);
			}
			for (code_langs) |item| {
				if (!containsString(filters.langs.items, item)) {
					try filters.langs.append(allocator, try allocator.dupe(u8, item));
				}
			}
		}

		if (options.include_docs) {
			const doc_langs = try registry.languagesForKinds(allocator, &[_]kind.Kind{ .doc });
			defer {
				for (doc_langs) |item| allocator.free(item);
				allocator.free(doc_langs);
			}
			for (doc_langs) |item| {
				if (!containsString(filters.langs.items, item)) {
					try filters.langs.append(allocator, try allocator.dupe(u8, item));
				}
			}
		}
		return filters;
	}

	if (filters.kinds.items.len > 0) {
		const type_langs = try registry.languagesForKinds(allocator, filters.kinds.items);
		defer {
			for (type_langs) |item| allocator.free(item);
			allocator.free(type_langs);
		}
		if (filters.langs.items.len == 0) {
			for (type_langs) |item| {
				try filters.langs.append(allocator, try allocator.dupe(u8, item));
			}
		} else {
			var kept = @as(std.ArrayListUnmanaged([]const u8), .empty);
			errdefer {
				for (kept.items) |item| allocator.free(item);
				kept.deinit(allocator);
			}
			for (filters.langs.items) |item| {
				if (containsString(type_langs, item)) {
					try kept.append(allocator, item);
				} else {
					allocator.free(item);
				}
			}
			filters.langs.deinit(allocator);
			filters.langs = kept;
		}
	}

	return filters;
}

pub fn parseExtList(
	allocator: std.mem.Allocator,
	list: *std.ArrayListUnmanaged([]const u8),
	value: []const u8,
) !void {
	var it = std.mem.splitScalar(u8, value, ',');
	while (it.next()) |part| {
		const trimmed = std.mem.trim(u8, part, " \t\r");
		if (trimmed.len == 0) continue;
		const normalized = try normalizeExtension(allocator, trimmed);
		if (!containsString(list.items, normalized)) {
			try list.append(allocator, normalized);
		} else {
			allocator.free(normalized);
		}
	}
}

pub fn parseLangList(
	allocator: std.mem.Allocator,
	list: *std.ArrayListUnmanaged([]const u8),
	value: []const u8,
) !void {
	var it = std.mem.splitScalar(u8, value, ',');
	while (it.next()) |part| {
		const trimmed = std.mem.trim(u8, part, " \t\r");
		if (trimmed.len == 0) continue;
		const normalized = try normalizeLower(allocator, trimmed);
		if (!containsString(list.items, normalized)) {
			try list.append(allocator, normalized);
		} else {
			allocator.free(normalized);
		}
	}
}

pub fn parseKindList(
	allocator: std.mem.Allocator,
	list: *std.ArrayListUnmanaged(kind.Kind),
	value: []const u8,
) !void {
	var it = std.mem.splitScalar(u8, value, ',');
	while (it.next()) |part| {
		const trimmed = std.mem.trim(u8, part, " \t\r");
		if (trimmed.len == 0) continue;
		const lower = try normalizeLower(allocator, trimmed);
		defer allocator.free(lower);
		const parsed = kind.parse(lower) orelse return error.InvalidType;
		if (!containsKind(list.items, parsed)) {
			try list.append(allocator, parsed);
		}
	}
}

fn normalizeExtension(allocator: std.mem.Allocator, ext: []const u8) ![]const u8 {
	const trimmed = std.mem.trim(u8, ext, " \t\r");
	if (trimmed.len == 0) return error.InvalidExtension;
	const needs_dot = trimmed[0] != '.';
	const extra: usize = if (needs_dot) 1 else 0;
	const buf = try allocator.alloc(u8, trimmed.len + extra);
	if (needs_dot) {
		buf[0] = '.';
		@memcpy(buf[1..], trimmed);
	} else {
		@memcpy(buf, trimmed);
	}
	for (buf) |*ch| ch.* = std.ascii.toLower(ch.*);
	return buf;
}

fn normalizeLower(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
	const buf = try allocator.alloc(u8, value.len);
	@memcpy(buf, value);
	for (buf) |*ch| ch.* = std.ascii.toLower(ch.*);
	return buf;
}

fn containsString(list: []const []const u8, value: []const u8) bool {
	for (list) |item| {
		if (std.mem.eql(u8, item, value)) return true;
	}
	return false;
}

fn containsKind(list: []const kind.Kind, value: kind.Kind) bool {
	for (list) |item| {
		if (item == value) return true;
	}
	return false;
}

pub fn parseSymbolKindList(
	allocator: std.mem.Allocator,
	list: *std.ArrayListUnmanaged([]const u8),
	value: []const u8,
) !void {
	var it = std.mem.splitScalar(u8, value, ',');
	while (it.next()) |part| {
		const trimmed = std.mem.trim(u8, part, " \t\r");
		if (trimmed.len == 0) continue;
		const lower = try normalizeLower(allocator, trimmed);
		defer allocator.free(lower);
		// Check for meta-kinds that expand to multiple values
		if (expandMetaKind(lower)) |expansions| {
			for (expansions) |canonical| {
				if (!containsString(list.items, canonical)) {
					try list.append(allocator, try allocator.dupe(u8, canonical));
				}
			}
			continue;
		}
		const canonical = normalizeSymbolKind(lower) orelse return error.InvalidSymbolKind;
		if (!containsString(list.items, canonical)) {
			try list.append(allocator, try allocator.dupe(u8, canonical));
		}
	}
}

/// Meta-kinds that expand to multiple canonical values.
fn expandMetaKind(value: []const u8) ?[]const []const u8 {
	const decl = [_][]const u8{ "const", "var" };
	const defn = [_][]const u8{"*"};
	if (std.mem.eql(u8, value, "declaration")) return &decl;
	if (std.mem.eql(u8, value, "let")) return &decl;
	if (std.mem.eql(u8, value, "definition")) return &defn;
	return null;
}

/// Normalizes user-facing symbol kind aliases to the short canonical form stored in the DB.
/// Returns null for unknown kinds. For multi-value aliases (let, declaration, definition),
/// see parseSymbolKindList which handles expansion.
fn normalizeSymbolKind(value: []const u8) ?[]const u8 {
	const map = .{
		.{ "fn", "fn" },
		.{ "func", "fn" },
		.{ "function", "fn" },
		.{ "struct", "struct" },
		.{ "enum", "enum" },
		.{ "union", "union" },
		.{ "class", "class" },
		.{ "interface", "interface" },
		.{ "trait", "trait" },
		.{ "impl", "impl" },
		.{ "const", "const" },
		.{ "constant", "const" },
		.{ "val", "const" },
		.{ "var", "var" },
		.{ "variable", "var" },
		.{ "mut", "var" },
		.{ "field", "field" },
		.{ "test", "test" },
		.{ "mod", "mod" },
		.{ "module", "mod" },
		.{ "type", "type" },
		.{ "macro", "macro" },
	};
	inline for (map) |entry| {
		if (std.mem.eql(u8, value, entry[0])) return entry[1];
	}
	return null;
}

/// Inserts one minimal symbol so tests can compose a repository whose language
/// mix is known exactly, without running an extractor or an embedder.
fn insertTestSymbol(
	allocator: std.mem.Allocator,
	db: storage.Db,
	language: []const u8,
	file_path: []const u8,
	name: []const u8,
) !void {
	var symbol = model.Symbol{
		.language = try allocator.dupe(u8, language),
		.file_path = try allocator.dupe(u8, file_path),
		.name = try allocator.dupe(u8, name),
		.signature = try allocator.dupe(u8, name),
		.doc_comment = null,
		.start_line = 1,
		.end_line = 1,
	};
	defer symbol.deinit(allocator);
	_ = try storage.insertSymbol(db, symbol);
}

/// Builds the polyglot repository shape that broke default search: the language
/// holding the most distinct files (bash tooling) is NOT the language a caller
/// is usually searching for (zig/c implementation).
fn openPolyglotTestDb(allocator: std.mem.Allocator) !storage.Db {
	const db = try storage.openMemoryWithVec(allocator);
	errdefer storage.close(db);
	var schema = try storage.initSchema(allocator, db, .{ .embedding_dim = 2 });
	defer schema.deinit(allocator);

	// Most-populous code language by distinct file count.
	try insertTestSymbol(allocator, db, "bash", "scripts/build.bash", "build_all");
	try insertTestSymbol(allocator, db, "bash", "scripts/test.bash", "run_tests");
	try insertTestSymbol(allocator, db, "bash", "scripts/release.bash", "notarize");
	// Minority code languages that default search must still reach.
	try insertTestSymbol(allocator, db, "zig", "src/printable_binary.zig", "crc32");
	try insertTestSymbol(allocator, db, "c", "src/cli.c", "crc32_table");
	// Documentation, which default search must still exclude.
	try insertTestSymbol(allocator, db, "markdown", "README.md", "Usage");
	return db;
}

test "default search filters admit every code language, not just the most populous" {
	// Regression: a plain query used to be pinned to `primaryLanguage(db)`, so a
	// polyglot repo silently returned zero results whenever the caller wanted any
	// language other than the one with the most files. Classify the whole language
	// set, not one example: minority code languages IN, docs OUT.
	const allocator = std.testing.allocator;
	const db = try openPolyglotTestDb(allocator);
	defer storage.close(db);

	var filters = try buildSearchFilters(allocator, plugin.defaultRegistry(), .{});
	defer filters.deinit(allocator);

	try std.testing.expect(containsString(filters.langs.items, "bash"));
	try std.testing.expect(containsString(filters.langs.items, "zig"));
	try std.testing.expect(containsString(filters.langs.items, "c"));
	try std.testing.expect(!containsString(filters.langs.items, "markdown"));
}

test "explicit language and configured primary language still narrow default search" {
	const allocator = std.testing.allocator;
	const db = try openPolyglotTestDb(allocator);
	defer storage.close(db);

	// An explicit --lang stays authoritative.
	var explicit = try buildSearchFilters(allocator, plugin.defaultRegistry(), .{
		.search_lang = "zig",
	});
	defer explicit.deinit(allocator);
	try std.testing.expectEqual(@as(usize, 1), explicit.langs.items.len);
	try std.testing.expectEqualStrings("zig", explicit.langs.items[0]);

	// A deliberately configured primary_lang remains an opt-in narrowing.
	var configured = try buildSearchFilters(allocator, plugin.defaultRegistry(), .{
		.primary_lang = "c",
	});
	defer configured.deinit(allocator);
	try std.testing.expectEqual(@as(usize, 1), configured.langs.items.len);
	try std.testing.expectEqualStrings("c", configured.langs.items[0]);
}

test "include_docs widens default search to code and doc languages together" {
	const allocator = std.testing.allocator;
	const db = try openPolyglotTestDb(allocator);
	defer storage.close(db);

	var filters = try buildSearchFilters(allocator, plugin.defaultRegistry(), .{
		.include_docs = true,
	});
	defer filters.deinit(allocator);

	try std.testing.expect(containsString(filters.langs.items, "zig"));
	try std.testing.expect(containsString(filters.langs.items, "bash"));
	try std.testing.expect(containsString(filters.langs.items, "markdown"));
}

test "normalizeSymbolKind maps aliases to short DB canonical forms" {
	try std.testing.expectEqualStrings("fn", normalizeSymbolKind("fn").?);
	try std.testing.expectEqualStrings("fn", normalizeSymbolKind("func").?);
	try std.testing.expectEqualStrings("fn", normalizeSymbolKind("function").?);
	try std.testing.expectEqualStrings("const", normalizeSymbolKind("const").?);
	try std.testing.expectEqualStrings("const", normalizeSymbolKind("constant").?);
	try std.testing.expectEqualStrings("const", normalizeSymbolKind("val").?);
	try std.testing.expectEqualStrings("var", normalizeSymbolKind("var").?);
	try std.testing.expectEqualStrings("var", normalizeSymbolKind("variable").?);
	try std.testing.expectEqualStrings("var", normalizeSymbolKind("mut").?);
	try std.testing.expectEqualStrings("mod", normalizeSymbolKind("mod").?);
	try std.testing.expectEqualStrings("mod", normalizeSymbolKind("module").?);
	try std.testing.expectEqualStrings("macro", normalizeSymbolKind("macro").?);
	try std.testing.expectEqualStrings("struct", normalizeSymbolKind("struct").?);
	try std.testing.expectEqualStrings("test", normalizeSymbolKind("test").?);
	try std.testing.expect(normalizeSymbolKind("bogus") == null);
}

test "parseSymbolKindList expands meta-kinds" {
	const allocator = std.testing.allocator;
	var list: std.ArrayListUnmanaged([]const u8) = .empty;
	defer {
		for (list.items) |item| allocator.free(item);
		list.deinit(allocator);
	}

	// "declaration" expands to const + var
	try parseSymbolKindList(allocator, &list, "declaration");
	try std.testing.expectEqual(@as(usize, 2), list.items.len);
	try std.testing.expectEqualStrings("const", list.items[0]);
	try std.testing.expectEqualStrings("var", list.items[1]);

	// Reset
	for (list.items) |item| allocator.free(item);
	list.clearRetainingCapacity();

	// "let" expands to const + var
	try parseSymbolKindList(allocator, &list, "let");
	try std.testing.expectEqual(@as(usize, 2), list.items.len);
	try std.testing.expectEqualStrings("const", list.items[0]);
	try std.testing.expectEqualStrings("var", list.items[1]);

	// Reset
	for (list.items) |item| allocator.free(item);
	list.clearRetainingCapacity();

	// "definition" expands to sentinel "*"
	try parseSymbolKindList(allocator, &list, "definition");
	try std.testing.expectEqual(@as(usize, 1), list.items.len);
	try std.testing.expectEqualStrings("*", list.items[0]);
}
