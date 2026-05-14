const std = @import("std");
const io_singleton = @import("io_singleton.zig");

pub const default_template =
	\\# codescan language-specific search weights
	\\# This file lives in .codescan/weights.toml.
	\\# Changes take effect when codescan starts.
	\\
	\\[default]
	\\#weight_vector=0.7
	\\#weight_lexical=0.3
	\\#weight_symbol_kind=0.0
	\\#weight_symbol_visibility=0.0
	\\#weight_symbol_scope=0.0
	\\#weight_symbol_arity=0.0
	\\
	\\[zig]
	\\#weight_vector=0.55
	\\#weight_lexical=0.45
	\\#weight_symbol_kind=0.15
	\\#weight_symbol_visibility=0.1
	\\
;

pub const WeightPair = struct {
	weight_vector: f32,
	weight_lexical: f32,
	weight_symbol_kind: f32,
	weight_symbol_visibility: f32,
	weight_symbol_scope: f32,
	weight_symbol_arity: f32,
};

pub const LangWeights = struct {
	language: []const u8,
	weight_vector: ?f32 = null,
	weight_lexical: ?f32 = null,
	weight_symbol_kind: ?f32 = null,
	weight_symbol_visibility: ?f32 = null,
	weight_symbol_scope: ?f32 = null,
	weight_symbol_arity: ?f32 = null,

	pub fn deinit(self: *LangWeights, allocator: std.mem.Allocator) void {
		allocator.free(self.language);
		self.* = undefined;
	}
};

pub const Table = struct {
	default_weight_vector: ?f32 = null,
	default_weight_lexical: ?f32 = null,
	default_weight_symbol_kind: ?f32 = null,
	default_weight_symbol_visibility: ?f32 = null,
	default_weight_symbol_scope: ?f32 = null,
	default_weight_symbol_arity: ?f32 = null,
	per_language: std.ArrayListUnmanaged(LangWeights) = .empty,

	pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
		for (self.per_language.items) |*entry| entry.deinit(allocator);
		self.per_language.deinit(allocator);
		self.* = .{};
	}

	pub fn resolveForLanguages(
		self: Table,
		allowed_langs: []const []const u8,
		fallback_vector: f32,
		fallback_lexical: f32,
		fallback_symbol_kind: f32,
		fallback_symbol_visibility: f32,
		fallback_symbol_scope: f32,
		fallback_symbol_arity: f32,
	) WeightPair {
		var pair = WeightPair{
			.weight_vector = fallback_vector,
			.weight_lexical = fallback_lexical,
			.weight_symbol_kind = fallback_symbol_kind,
			.weight_symbol_visibility = fallback_symbol_visibility,
			.weight_symbol_scope = fallback_symbol_scope,
			.weight_symbol_arity = fallback_symbol_arity,
		};

		if (self.default_weight_vector) |value| pair.weight_vector = value;
		if (self.default_weight_lexical) |value| pair.weight_lexical = value;
		if (self.default_weight_symbol_kind) |value| pair.weight_symbol_kind = value;
		if (self.default_weight_symbol_visibility) |value| pair.weight_symbol_visibility = value;
		if (self.default_weight_symbol_scope) |value| pair.weight_symbol_scope = value;
		if (self.default_weight_symbol_arity) |value| pair.weight_symbol_arity = value;

		if (allowed_langs.len == 1) {
			if (self.findLanguage(allowed_langs[0])) |entry| {
				if (entry.weight_vector) |value| pair.weight_vector = value;
				if (entry.weight_lexical) |value| pair.weight_lexical = value;
				if (entry.weight_symbol_kind) |value| pair.weight_symbol_kind = value;
				if (entry.weight_symbol_visibility) |value| pair.weight_symbol_visibility = value;
				if (entry.weight_symbol_scope) |value| pair.weight_symbol_scope = value;
				if (entry.weight_symbol_arity) |value| pair.weight_symbol_arity = value;
			}
		}

		return pair;
	}

	fn findLanguage(self: Table, language: []const u8) ?LangWeights {
		for (self.per_language.items) |entry| {
			if (std.ascii.eqlIgnoreCase(entry.language, language)) return entry;
		}
		return null;
	}

	fn getOrCreateLanguage(self: *Table, allocator: std.mem.Allocator, language: []const u8) !*LangWeights {
		for (self.per_language.items) |*entry| {
			if (std.ascii.eqlIgnoreCase(entry.language, language)) return entry;
		}
		try self.per_language.append(allocator, .{
			.language = try allocator.dupe(u8, language),
		});
		return &self.per_language.items[self.per_language.items.len - 1];
	}
};

pub fn resolveSearchWeights(
	table: ?*const Table,
	allowed_langs: []const []const u8,
	base_vector: f32,
	base_lexical: f32,
	explicit_override: bool,
) WeightPair {
	const fallback = WeightPair{
		.weight_vector = base_vector,
		.weight_lexical = base_lexical,
		.weight_symbol_kind = 0.0,
		.weight_symbol_visibility = 0.0,
		.weight_symbol_scope = 0.0,
		.weight_symbol_arity = 0.0,
	};

	var resolved = if (table) |value|
		value.resolveForLanguages(
			allowed_langs,
			base_vector,
			base_lexical,
			fallback.weight_symbol_kind,
			fallback.weight_symbol_visibility,
			fallback.weight_symbol_scope,
			fallback.weight_symbol_arity,
		)
	else
		fallback;

	if (explicit_override) {
		resolved.weight_vector = base_vector;
		resolved.weight_lexical = base_lexical;
	}

	return resolved;
}

pub fn parseText(allocator: std.mem.Allocator, text: []const u8) !Table {
	var table = Table{};
	errdefer table.deinit(allocator);

	const Section = union(enum) {
		none,
		default,
		language: []const u8,
	};
	var section: Section = .none;
	defer switch (section) {
		.language => |lang| allocator.free(lang),
		else => {},
	};

	var lines = std.mem.splitScalar(u8, text, '\n');
	while (lines.next()) |line| {
		const trimmed = std.mem.trim(u8, line, " \t\r");
		if (trimmed.len == 0) continue;
		if (trimmed[0] == '#' or trimmed[0] == ';') continue;
		if (trimmed.len >= 2 and trimmed[0] == '/' and trimmed[1] == '/') continue;

		if (trimmed[0] == '[') {
			if (trimmed[trimmed.len - 1] != ']') return error.InvalidSection;
			switch (section) {
				.language => |lang| allocator.free(lang),
				else => {},
			}
			const section_value = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
			const section_name = stripQuotes(section_value);
			if (section_name.len == 0) return error.InvalidSection;
			if (std.ascii.eqlIgnoreCase(section_name, "default")) {
				section = .default;
			} else {
				section = .{ .language = try normalizeLower(allocator, section_name) };
			}
			continue;
		}

		var kv = std.mem.splitScalar(u8, trimmed, '=');
		const key_raw = kv.next() orelse return error.InvalidLine;
		const value_raw = kv.next() orelse return error.InvalidLine;
		if (kv.next() != null) return error.InvalidLine;

		const key = std.mem.trim(u8, key_raw, " \t");
		const value_untrimmed = std.mem.trim(u8, value_raw, " \t");
		const value = stripQuotes(value_untrimmed);
		const parsed = std.fmt.parseFloat(f32, value) catch return error.InvalidValue;

		const is_known =
			std.mem.eql(u8, key, "weight_vector") or
			std.mem.eql(u8, key, "weight_lexical") or
			std.mem.eql(u8, key, "weight_symbol_kind") or
			std.mem.eql(u8, key, "weight_symbol_visibility") or
			std.mem.eql(u8, key, "weight_symbol_scope") or
			std.mem.eql(u8, key, "weight_symbol_arity");
		if (!is_known) {
			return error.UnknownKey;
		}

		switch (section) {
			.none => return error.MissingSection,
			.default => {
				if (std.mem.eql(u8, key, "weight_vector")) {
					table.default_weight_vector = parsed;
				} else if (std.mem.eql(u8, key, "weight_lexical")) {
					table.default_weight_lexical = parsed;
				} else if (std.mem.eql(u8, key, "weight_symbol_kind")) {
					table.default_weight_symbol_kind = parsed;
				} else if (std.mem.eql(u8, key, "weight_symbol_visibility")) {
					table.default_weight_symbol_visibility = parsed;
				} else if (std.mem.eql(u8, key, "weight_symbol_scope")) {
					table.default_weight_symbol_scope = parsed;
				} else {
					table.default_weight_symbol_arity = parsed;
				}
			},
			.language => |lang| {
				var entry = try table.getOrCreateLanguage(allocator, lang);
				if (std.mem.eql(u8, key, "weight_vector")) {
					entry.weight_vector = parsed;
				} else if (std.mem.eql(u8, key, "weight_lexical")) {
					entry.weight_lexical = parsed;
				} else if (std.mem.eql(u8, key, "weight_symbol_kind")) {
					entry.weight_symbol_kind = parsed;
				} else if (std.mem.eql(u8, key, "weight_symbol_visibility")) {
					entry.weight_symbol_visibility = parsed;
				} else if (std.mem.eql(u8, key, "weight_symbol_scope")) {
					entry.weight_symbol_scope = parsed;
				} else {
					entry.weight_symbol_arity = parsed;
				}
			},
		}
	}

	return table;
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !Table {
	const file = try std.Io.Dir.cwd().openFile(io_singleton.getOrInit(), path, .{});
	defer file.close(io_singleton.getOrInit());
	const data = try io_singleton.readToEndAlloc(file, allocator, 1024 * 1024);
	defer allocator.free(data);
	return parseText(allocator, data);
}

fn stripQuotes(value: []const u8) []const u8 {
	if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
		return value[1 .. value.len - 1];
	}
	return value;
}

fn normalizeLower(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
	const buf = try allocator.alloc(u8, value.len);
	@memcpy(buf, value);
	for (buf) |*ch| ch.* = std.ascii.toLower(ch.*);
	return buf;
}

test "parseText reads default and per-language overrides" {
	const allocator = std.testing.allocator;
	const text =
		"[default]\n" ++
		"weight_vector=0.65\n" ++
		"weight_lexical=0.35\n" ++
		"weight_symbol_kind=0.2\n" ++
		"weight_symbol_visibility=0.1\n" ++
		"\n" ++
		"[zig]\n" ++
		"weight_vector=0.55\n" ++
		"weight_symbol_kind=0.4\n" ++
		"[elixir]\n" ++
		"weight_lexical=0.6\n" ++
		"weight_symbol_scope=0.2\n";
	var table = try parseText(allocator, text);
	defer table.deinit(allocator);

	try std.testing.expectApproxEqAbs(@as(f32, 0.65), table.default_weight_vector.?, 0.0001);
	try std.testing.expectApproxEqAbs(@as(f32, 0.35), table.default_weight_lexical.?, 0.0001);
	try std.testing.expectApproxEqAbs(@as(f32, 0.2), table.default_weight_symbol_kind.?, 0.0001);
	try std.testing.expectApproxEqAbs(@as(f32, 0.1), table.default_weight_symbol_visibility.?, 0.0001);
	try std.testing.expectEqual(@as(usize, 2), table.per_language.items.len);

	const zig_pair = table.resolveForLanguages(&[_][]const u8{"zig"}, 0.7, 0.3, 0.0, 0.0, 0.0, 0.0);
	try std.testing.expectApproxEqAbs(@as(f32, 0.55), zig_pair.weight_vector, 0.0001);
	try std.testing.expectApproxEqAbs(@as(f32, 0.35), zig_pair.weight_lexical, 0.0001);
	try std.testing.expectApproxEqAbs(@as(f32, 0.4), zig_pair.weight_symbol_kind, 0.0001);
	try std.testing.expectApproxEqAbs(@as(f32, 0.1), zig_pair.weight_symbol_visibility, 0.0001);

	const ex_pair = table.resolveForLanguages(&[_][]const u8{"elixir"}, 0.7, 0.3, 0.0, 0.0, 0.0, 0.0);
	try std.testing.expectApproxEqAbs(@as(f32, 0.65), ex_pair.weight_vector, 0.0001);
	try std.testing.expectApproxEqAbs(@as(f32, 0.6), ex_pair.weight_lexical, 0.0001);
	try std.testing.expectApproxEqAbs(@as(f32, 0.2), ex_pair.weight_symbol_kind, 0.0001);
	try std.testing.expectApproxEqAbs(@as(f32, 0.2), ex_pair.weight_symbol_scope, 0.0001);
}

test "resolveSearchWeights skips table when explicit overrides are set" {
	const allocator = std.testing.allocator;
	const text =
		"[default]\n" ++
		"weight_vector=0.2\n" ++
		"weight_lexical=0.8\n" ++
		"[zig]\n" ++
		"weight_vector=0.9\n";
	var table = try parseText(allocator, text);
	defer table.deinit(allocator);

	const pair = resolveSearchWeights(&table, &[_][]const u8{"zig"}, 0.7, 0.3, true);
	try std.testing.expectApproxEqAbs(@as(f32, 0.7), pair.weight_vector, 0.0001);
	try std.testing.expectApproxEqAbs(@as(f32, 0.3), pair.weight_lexical, 0.0001);
}

test "resolveForLanguages keeps defaults when multiple languages are active" {
	const allocator = std.testing.allocator;
	const text =
		"[default]\n" ++
		"weight_vector=0.65\n" ++
		"weight_lexical=0.35\n" ++
		"[zig]\n" ++
		"weight_vector=0.4\n";
	var table = try parseText(allocator, text);
	defer table.deinit(allocator);

	const pair = table.resolveForLanguages(&[_][]const u8{ "zig", "markdown" }, 0.7, 0.3, 0.11, 0.12, 0.13, 0.14);
	try std.testing.expectApproxEqAbs(@as(f32, 0.65), pair.weight_vector, 0.0001);
	try std.testing.expectApproxEqAbs(@as(f32, 0.35), pair.weight_lexical, 0.0001);
	try std.testing.expectApproxEqAbs(@as(f32, 0.11), pair.weight_symbol_kind, 0.0001);
	try std.testing.expectApproxEqAbs(@as(f32, 0.12), pair.weight_symbol_visibility, 0.0001);
	try std.testing.expectApproxEqAbs(@as(f32, 0.13), pair.weight_symbol_scope, 0.0001);
	try std.testing.expectApproxEqAbs(@as(f32, 0.14), pair.weight_symbol_arity, 0.0001);
}
