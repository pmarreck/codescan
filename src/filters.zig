const std = @import("std");
const kind = @import("kind.zig");
const plugin = @import("plugin.zig");
const storage = @import("storage.zig");

pub const FilterLists = struct {
	exts: std.ArrayListUnmanaged([]const u8) = .{},
	langs: std.ArrayListUnmanaged([]const u8) = .{},
	kinds: std.ArrayListUnmanaged(kind.Kind) = .{},

	pub fn deinit(self: *FilterLists, allocator: std.mem.Allocator) void {
		for (self.exts.items) |item| allocator.free(item);
		self.exts.deinit(allocator);
		for (self.langs.items) |item| allocator.free(item);
		self.langs.deinit(allocator);
		self.kinds.deinit(allocator);
		self.* = undefined;
	}
};

pub const SearchOptions = struct {
	search_ext: ?[]const u8 = null,
	search_type: ?[]const u8 = null,
	search_lang: ?[]const u8 = null,
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

pub fn buildSearchFilters(
	allocator: std.mem.Allocator,
	registry: plugin.Registry,
	db: storage.Db,
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
		var primary_lang: ?[]const u8 = null;
		var primary_owned = false;
		if (options.primary_lang) |value| {
			primary_lang = value;
		} else {
			const code_langs = try registry.languagesForKinds(allocator, &[_]kind.Kind{ .code });
			defer {
				for (code_langs) |item| allocator.free(item);
				allocator.free(code_langs);
			}
			primary_lang = try storage.primaryLanguage(db, allocator, code_langs);
			if (primary_lang != null) primary_owned = true;
		}
		defer if (primary_owned) allocator.free(primary_lang.?);

		if (primary_lang) |value| {
			const normalized = try normalizeLower(allocator, value);
			errdefer allocator.free(normalized);
			if (!containsString(filters.langs.items, normalized)) {
				try filters.langs.append(allocator, normalized);
			} else {
				allocator.free(normalized);
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
			var kept = std.ArrayListUnmanaged([]const u8){};
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
