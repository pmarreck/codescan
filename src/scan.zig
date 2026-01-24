const std = @import("std");
const plugin = @import("plugin.zig");
const config = @import("config.zig");
const filter = @import("filter.zig");

pub const IgnoreConfig = struct {
	global: []const []const u8,
	per_language: []const config.IgnoreOverride,
};

const IgnorePattern = struct {
	pattern: filter.Pattern,
	root_anchored: bool,
};

const IgnoreSet = struct {
	language: []const u8,
	patterns: []IgnorePattern,
};

const default_ignore_global = &[_][]const u8{
	"**/.git/**",
	"**/.codescan/**",
	"**/.codescan-fixtures/**",
	"**/deps/**",
	"**/.zig-cache/**",
	"**/zig-cache/**",
	"**/.zig-out/**",
	"**/zig-out/**",
};

pub fn findFiles(
	allocator: std.mem.Allocator,
	root_path: []const u8,
	registry: plugin.Registry,
	ignore_cfg: IgnoreConfig,
) ![]const []const u8 {
	var dir = try std.fs.cwd().openDir(root_path, .{ .iterate = true });
	defer dir.close();

	var walker = try dir.walk(allocator);
	defer walker.deinit();

	const ignore_sets = try buildIgnoreSets(allocator, registry, ignore_cfg);
	defer deinitIgnoreSets(allocator, ignore_sets);

	var results = std.ArrayListUnmanaged([]const u8){};
	errdefer {
		for (results.items) |path| allocator.free(path);
		results.deinit(allocator);
	}

	while (try walker.next()) |entry| {
		if (entry.kind != .file) continue;
		const extractor = registry.find(entry.path) orelse continue;
		if (shouldIgnore(allocator, ignore_sets, extractor.language, entry.path)) continue;
		try results.append(allocator, try allocator.dupe(u8, entry.path));
	}

	return results.toOwnedSlice(allocator);
}

fn buildIgnoreSets(
	allocator: std.mem.Allocator,
	registry: plugin.Registry,
	ignore_cfg: IgnoreConfig,
) ![]IgnoreSet {
	var sets = std.ArrayListUnmanaged(IgnoreSet){};
	errdefer {
		for (sets.items) |*set| {
			for (set.patterns) |*pat| pat.pattern.deinit();
			allocator.free(set.patterns);
		}
		sets.deinit(allocator);
	}

	for (registry.extractors) |extractor| {
		var patterns = std.ArrayListUnmanaged(IgnorePattern){};
		errdefer {
			for (patterns.items) |*pat| pat.pattern.deinit();
			patterns.deinit(allocator);
		}

		try appendPatterns(allocator, &patterns, default_ignore_global);
		try appendPatterns(allocator, &patterns, ignore_cfg.global);
		try appendPatterns(allocator, &patterns, extractor.ignore_patterns);
		if (findOverrides(ignore_cfg.per_language, extractor.language)) |override| {
			try appendPatterns(allocator, &patterns, override.patterns.items);
		}

		try sets.append(allocator, .{
			.language = extractor.language,
			.patterns = try patterns.toOwnedSlice(allocator),
		});
	}

	return sets.toOwnedSlice(allocator);
}

fn appendPatterns(
	allocator: std.mem.Allocator,
	patterns: *std.ArrayListUnmanaged(IgnorePattern),
	list: []const []const u8,
) !void {
	for (list) |raw| {
		const compiled = try filter.compile(allocator, raw);
		try patterns.append(allocator, .{
			.pattern = compiled,
			.root_anchored = std.mem.startsWith(u8, raw, "/"),
		});
	}
}

fn findOverrides(
	overrides: []const config.IgnoreOverride,
	language: []const u8,
) ?*const config.IgnoreOverride {
	for (overrides) |*entry| {
		if (std.mem.eql(u8, entry.language, language)) return entry;
	}
	return null;
}

fn shouldIgnore(
	allocator: std.mem.Allocator,
	ignore_sets: []IgnoreSet,
	language: []const u8,
	rel_path: []const u8,
) bool {
	const set = findIgnoreSet(ignore_sets, language) orelse return false;
	if (set.patterns.len == 0) return false;

	var root_rel: ?[]u8 = null;
	defer if (root_rel) |value| allocator.free(value);

	for (set.patterns) |*pat| {
		const candidate = if (pat.root_anchored) blk: {
			if (root_rel == null) {
				root_rel = std.fmt.allocPrint(allocator, "/{s}", .{rel_path}) catch return false;
			}
			break :blk root_rel.?;
		} else rel_path;
		if (pat.pattern.matches(candidate)) return true;
	}

	return false;
}

fn findIgnoreSet(ignore_sets: []IgnoreSet, language: []const u8) ?*IgnoreSet {
	for (ignore_sets) |*set| {
		if (std.mem.eql(u8, set.language, language)) return set;
	}
	return null;
}

fn deinitIgnoreSets(allocator: std.mem.Allocator, ignore_sets: []IgnoreSet) void {
	for (ignore_sets) |*set| {
		for (set.patterns) |*pat| pat.pattern.deinit();
		allocator.free(set.patterns);
	}
	allocator.free(ignore_sets);
}

test "findFiles finds supported extensions" {
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	try tmp.dir.makePath("src");
	try tmp.dir.makePath("lib");
	try tmp.dir.writeFile(.{ .sub_path = "src/main.zig", .data = "" });
	try tmp.dir.writeFile(.{ .sub_path = "lib/demo.ex", .data = "" });
	try tmp.dir.writeFile(.{ .sub_path = "README.md", .data = "" });

	const allocator = std.testing.allocator;
	const root = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(root);

	const files = try findFiles(allocator, root, plugin.defaultRegistry(), .{
		.global = &[_][]const u8{},
		.per_language = &[_]config.IgnoreOverride{},
	});
	defer {
		for (files) |path| allocator.free(path);
		allocator.free(files);
	}

	try std.testing.expectEqual(@as(usize, 3), files.len);
	var found_zig = false;
	var found_ex = false;
	var found_readme = false;
	for (files) |path| {
		if (std.mem.eql(u8, path, "src/main.zig")) found_zig = true;
		if (std.mem.eql(u8, path, "lib/demo.ex")) found_ex = true;
		if (std.mem.eql(u8, path, "README.md")) found_readme = true;
	}
	try std.testing.expect(found_zig);
	try std.testing.expect(found_ex);
	try std.testing.expect(found_readme);
}

test "findFiles respects ignores" {
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	try tmp.dir.makePath("src");
	try tmp.dir.makePath("lib");
	try tmp.dir.makePath(".zig-cache");
	try tmp.dir.writeFile(.{ .sub_path = "src/main.zig", .data = "" });
	try tmp.dir.writeFile(.{ .sub_path = ".zig-cache/cache.zig", .data = "" });
	try tmp.dir.writeFile(.{ .sub_path = "lib/demo.ex", .data = "" });
	try tmp.dir.writeFile(.{ .sub_path = "lib/skip.ex", .data = "" });

	const allocator = std.testing.allocator;
	const root = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(root);

	var patterns = std.ArrayListUnmanaged([]const u8){};
	try patterns.append(allocator, try allocator.dupe(u8, "lib/skip.ex"));
	var overrides = [_]config.IgnoreOverride{
		.{ .language = try allocator.dupe(u8, "elixir"), .patterns = patterns },
	};
	defer {
		for (overrides[0..]) |*entry| entry.deinit(allocator);
	}

	const ignore = IgnoreConfig{
		.global = &[_][]const u8{},
		.per_language = overrides[0..],
	};
	const files = try findFiles(allocator, root, plugin.defaultRegistry(), ignore);
	defer {
		for (files) |path| allocator.free(path);
		allocator.free(files);
	}

	try std.testing.expectEqual(@as(usize, 2), files.len);
	var found_zig = false;
	var found_ex = false;
	for (files) |path| {
		if (std.mem.eql(u8, path, "src/main.zig")) found_zig = true;
		if (std.mem.eql(u8, path, "lib/demo.ex")) found_ex = true;
	}
	try std.testing.expect(found_zig);
	try std.testing.expect(found_ex);
}

test "findFiles ignores built-in paths" {
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	try tmp.dir.makePath("src");
	try tmp.dir.makePath(".git");
	try tmp.dir.makePath(".codescan");
	try tmp.dir.makePath(".codescan-fixtures/fixture");
	try tmp.dir.makePath("deps/lib");
	try tmp.dir.writeFile(.{ .sub_path = "src/main.zig", .data = "" });
	try tmp.dir.writeFile(.{ .sub_path = ".git/ignored.zig", .data = "" });
	try tmp.dir.writeFile(.{ .sub_path = ".codescan/index.sqlite3", .data = "" });
	try tmp.dir.writeFile(.{ .sub_path = ".codescan-fixtures/fixture/ignored.zig", .data = "" });
	try tmp.dir.writeFile(.{ .sub_path = "deps/lib/ignored.zig", .data = "" });

	const allocator = std.testing.allocator;
	const root = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(root);

	const files = try findFiles(allocator, root, plugin.defaultRegistry(), .{
		.global = &[_][]const u8{},
		.per_language = &[_]config.IgnoreOverride{},
	});
	defer {
		for (files) |path| allocator.free(path);
		allocator.free(files);
	}

	try std.testing.expectEqual(@as(usize, 1), files.len);
	try std.testing.expectEqualStrings("src/main.zig", files[0]);
}
