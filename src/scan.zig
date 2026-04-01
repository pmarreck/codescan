const std = @import("std");
const plugin = @import("plugin.zig");
const config = @import("config.zig");
const filter = @import("filter.zig");

pub const IgnoreConfig = struct {
	global: []const []const u8,
	per_language: []const config.IgnoreOverride,
	include_node_modules: bool,
	/// Glob patterns for files to always index, even if gitignored.
	always_include: []const []const u8 = &[_][]const u8{},
};

const IgnorePattern = struct {
	pattern: filter.Pattern,
	root_anchored: bool,
};

const IgnoreSet = struct {
	language: []const u8,
	patterns: []IgnorePattern,
};

const node_modules_pattern = "**/node_modules/**";
const bin_pattern = "**/bin/**";

const default_ignore_global = &[_][]const u8{
	"**/.git/**",
	"**/.jj/**",
	"**/.hg/**",
	"**/.svn/**",
	"**/.bzr/**",
	"**/CVS/**",
	"**/.codescan/**",
	"**/.codescan-fixtures/**",
	"**/.idea/**",
	"**/.vscode/**",
	"**/.cache/**",
	"**/.pnpm-store/**",
	"**/.yarn/**",
	"**/.pnp/**",
	"**/deps/**",
	node_modules_pattern,
	"**/vendor/**",
	"**/third_party/**",
	"**/.gradle/**",
	"**/.m2/**",
	"**/.next/**",
	"**/.nuxt/**",
	"**/.svelte-kit/**",
	"**/.turbo/**",
	"**/.parcel-cache/**",
	"**/.vite/**",
	"**/build/**",
	"**/dist/**",
	"**/out/**",
	"**/target/**",
	"**/bin/**",
	"**/obj/**",
	"**/coverage/**",
	"**/Pods/**",
	"**/.pytest_cache/**",
	"**/.mypy_cache/**",
	"**/.ruff_cache/**",
	"**/.tox/**",
	"**/.nox/**",
	"**/__pycache__/**",
	"**/.venv/**",
	"**/venv/**",
	"**/.stack-work/**",
	"**/dist-newstyle/**",
	"**/nimcache/**",
	"**/result/**",
	"**/.build/**",
	"**/CMakeFiles/**",
	"**/.zig-cache/**",
	"**/zig-cache/**",
	"**/.zig-out/**",
	"**/zig-out/**",
	"**/.DS_Store",
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

	const skip_bin_ignore = isBashProject(dir);
	const ignore_sets = try buildIgnoreSets(allocator, registry, ignore_cfg, skip_bin_ignore);
	defer deinitIgnoreSets(allocator, ignore_sets);

	var git_allow = try buildGitAllowSet(allocator, root_path);
	defer if (git_allow) |*set| deinitGitAllowSet(allocator, set);

	var results = std.ArrayListUnmanaged([]const u8){};
	errdefer {
		for (results.items) |path| allocator.free(path);
		results.deinit(allocator);
	}

	while (try walker.next()) |entry| {
		const is_file = entry.kind == .file or
			(entry.kind == .sym_link and isSymlinkToFile(dir, entry.path));
		if (!is_file) continue;
		// Check if file is in always_include (overrides gitignore)
		const force_included = blk: {
			if (entry.kind == .sym_link) break :blk true; // symlinks always included
			for (ignore_cfg.always_include) |pattern| {
				if (globMatch(entry.path, pattern)) break :blk true;
			}
			break :blk false;
		};
		if (!force_included) {
			if (git_allow) |*set| {
				if (!set.contains(entry.path)) continue;
			}
		}
		var extractor = registry.find(entry.path);
		if (extractor == null) {
			if (detectShebangLanguage(dir, entry.path)) |language| {
				extractor = registry.findByLanguage(language);
			}
		}
		const chosen = extractor orelse continue;
		if (shouldIgnore(allocator, ignore_sets, chosen.language, entry.path)) continue;
		try results.append(allocator, try allocator.dupe(u8, entry.path));
	}

	return results.toOwnedSlice(allocator);
}

fn buildGitAllowSet(allocator: std.mem.Allocator, root_path: []const u8) !?std.StringHashMapUnmanaged(void) {
	// Delegate .gitignore semantics to Git directly. If unavailable or not a repo,
	// fall back to existing scanner ignore logic.
	var root_dir = std.fs.cwd().openDir(root_path, .{}) catch return null;
	defer root_dir.close();
	_ = root_dir.statFile(".git") catch return null;

	const root_abs = std.fs.cwd().realpathAlloc(allocator, root_path) catch return null;
	defer allocator.free(root_abs);
	const top_level_raw = gitCaptureStdout(
		allocator,
		&[_][]const u8{ "git", "-C", root_path, "rev-parse", "--show-toplevel" },
	) catch return null;
	defer allocator.free(top_level_raw);
	const top_level = std.mem.trimRight(u8, top_level_raw, "\r\n");
	if (!std.mem.eql(u8, top_level, root_abs)) return null;

	const stdout = gitCaptureStdout(
		allocator,
		&[_][]const u8{ "git", "-C", root_path, "ls-files", "-z", "--cached", "--others", "--exclude-standard" },
	) catch return null;
	defer allocator.free(stdout);

	var allow = std.StringHashMapUnmanaged(void){};
	errdefer deinitGitAllowSet(allocator, &allow);

	var i: usize = 0;
	while (i < stdout.len) {
		const start = i;
		while (i < stdout.len and stdout[i] != 0) : (i += 1) {}
		if (i > start) {
			const rel = stdout[start..i];
			try allow.put(allocator, try allocator.dupe(u8, rel), {});
		}
		if (i < stdout.len and stdout[i] == 0) i += 1;
	}

	return allow;
}

fn gitCaptureStdout(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
	var child = std.process.Child.init(argv, allocator);
	child.stdin_behavior = .Close;
	child.stdout_behavior = .Pipe;
	child.stderr_behavior = .Ignore;

	try child.spawn();
	const stdout = try child.stdout.?.readToEndAlloc(allocator, 256 * 1024 * 1024);
	errdefer allocator.free(stdout);

	const term = try child.wait();
	switch (term) {
		.Exited => |code| if (code != 0) return error.ChildProcessFailed,
		else => return error.ChildProcessFailed,
	}

	return stdout;
}

fn deinitGitAllowSet(allocator: std.mem.Allocator, set: *std.StringHashMapUnmanaged(void)) void {
	var it = set.keyIterator();
	while (it.next()) |key_ptr| allocator.free(key_ptr.*);
	set.deinit(allocator);
}

/// Returns true if the project root contains typical bash dotfiles,
/// indicating bin/ likely contains shell scripts rather than build artifacts.
fn isBashProject(dir: std.fs.Dir) bool {
	const markers = [_][]const u8{ ".bashrc", ".bash_profile", ".profile", ".bash_aliases" };
	for (&markers) |name| {
		if (dir.statFile(name)) |_| return true else |_| {}
	}
	return false;
}

/// Simple glob match: * matches any sequence, ? matches one char.
fn globMatch(path: []const u8, pattern: []const u8) bool {
	var pi: usize = 0;
	var gi: usize = 0;
	var star_pi: ?usize = null;
	var star_gi: ?usize = null;
	while (pi < path.len) {
		if (gi < pattern.len and (pattern[gi] == '?' or pattern[gi] == path[pi])) {
			pi += 1;
			gi += 1;
		} else if (gi < pattern.len and pattern[gi] == '*') {
			star_pi = pi;
			star_gi = gi;
			gi += 1;
		} else if (star_gi) |sg| {
			gi = sg + 1;
			star_pi = star_pi.? + 1;
			pi = star_pi.?;
		} else {
			return false;
		}
	}
	while (gi < pattern.len and pattern[gi] == '*') gi += 1;
	return gi == pattern.len;
}

fn isSymlinkToFile(dir: std.fs.Dir, rel_path: []const u8) bool {
	const stat = dir.statFile(rel_path) catch return false;
	return stat.kind == .file;
}

fn detectShebangLanguage(dir: std.fs.Dir, rel_path: []const u8) ?[]const u8 {
	var file = dir.openFile(rel_path, .{}) catch return null;
	defer file.close();

	var buf: [256]u8 = undefined;
	const n = file.read(&buf) catch return null;
	if (n < 2) return null;
	if (buf[0] != '#' or buf[1] != '!') return null;

	const slice = buf[0..n];
	const line_end = std.mem.indexOfScalar(u8, slice, '\n') orelse slice.len;
	return parseShebang(slice[0..line_end]);
}

fn parseShebang(line: []const u8) ?[]const u8 {
	if (line.len < 2 or line[0] != '#' or line[1] != '!') return null;

	var rest = std.mem.trimLeft(u8, line[2..], " \t");
	if (rest.len == 0) return null;

	var token = nextToken(rest);
	if (isEnvToken(token)) {
		rest = std.mem.trimLeft(u8, rest[token.len..], " \t");
		while (rest.len > 0) {
			token = nextToken(rest);
			if (token.len == 0) return null;
			rest = std.mem.trimLeft(u8, rest[token.len..], " \t");
			if (!std.mem.startsWith(u8, token, "-")) break;
		}
	}

	const name = basename(token);
	return shebangLanguage(name);
}

fn nextToken(text: []const u8) []const u8 {
	var idx: usize = 0;
	while (idx < text.len and !std.ascii.isWhitespace(text[idx])) : (idx += 1) {}
	return text[0..idx];
}

fn isEnvToken(token: []const u8) bool {
	return std.mem.eql(u8, basename(token), "env");
}

fn basename(path: []const u8) []const u8 {
	const pos = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
	if (pos + 1 >= path.len) return path;
	return path[pos + 1 ..];
}

fn shebangLanguage(name: []const u8) ?[]const u8 {
	if (std.mem.eql(u8, name, "bash") or std.mem.eql(u8, name, "sh")) return "bash";
	if (std.mem.eql(u8, name, "lua") or std.mem.eql(u8, name, "luajit")) return "lua";
	return null;
}

fn buildIgnoreSets(
	allocator: std.mem.Allocator,
	registry: plugin.Registry,
	ignore_cfg: IgnoreConfig,
	skip_bin_ignore: bool,
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

		try appendDefaultPatterns(allocator, &patterns, ignore_cfg.include_node_modules, skip_bin_ignore);
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
		try appendPattern(allocator, patterns, raw);
	}
}

fn appendDefaultPatterns(
	allocator: std.mem.Allocator,
	patterns: *std.ArrayListUnmanaged(IgnorePattern),
	include_node_modules: bool,
	skip_bin_ignore: bool,
) !void {
	for (default_ignore_global) |raw| {
		if (include_node_modules and std.mem.eql(u8, raw, node_modules_pattern)) continue;
		if (skip_bin_ignore and std.mem.eql(u8, raw, bin_pattern)) continue;
		try appendPattern(allocator, patterns, raw);
	}
}

fn appendPattern(
	allocator: std.mem.Allocator,
	patterns: *std.ArrayListUnmanaged(IgnorePattern),
	raw: []const u8,
) !void {
	const compiled = try filter.compile(allocator, raw);
	try patterns.append(allocator, .{
		.pattern = compiled,
		.root_anchored = std.mem.startsWith(u8, raw, "/"),
	});
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
		.include_node_modules = false,
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

test "findFiles includes shebang scripts without extension" {
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	try tmp.dir.writeFile(.{ .sub_path = "script", .data = "#!/usr/bin/env bash\nexit 0\n" });
	try tmp.dir.writeFile(.{ .sub_path = "luascript", .data = "#!/usr/bin/env luajit\nprint('ok')\n" });
	try tmp.dir.writeFile(.{ .sub_path = "pythonscript", .data = "#!/usr/bin/env python3\nprint('no')\n" });

	const allocator = std.testing.allocator;
	const root = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(root);

	const files = try findFiles(allocator, root, plugin.defaultRegistry(), .{
		.global = &[_][]const u8{},
		.per_language = &[_]config.IgnoreOverride{},
		.include_node_modules = false,
	});
	defer {
		for (files) |path| allocator.free(path);
		allocator.free(files);
	}

	try std.testing.expectEqual(@as(usize, 2), files.len);
	var found_bash = false;
	var found_lua = false;
	var found_python = false;
	for (files) |path| {
		if (std.mem.eql(u8, path, "script")) found_bash = true;
		if (std.mem.eql(u8, path, "luascript")) found_lua = true;
		if (std.mem.eql(u8, path, "pythonscript")) found_python = true;
	}
	try std.testing.expect(found_bash);
	try std.testing.expect(found_lua);
	try std.testing.expect(!found_python);
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
		.include_node_modules = false,
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
	try tmp.dir.makePath(".jj");
	try tmp.dir.makePath(".codescan");
	try tmp.dir.makePath(".codescan-fixtures/fixture");
	try tmp.dir.makePath("deps/lib");
	try tmp.dir.makePath("node_modules/pkg");
	try tmp.dir.writeFile(.{ .sub_path = "src/main.zig", .data = "" });
	try tmp.dir.writeFile(.{ .sub_path = ".git/ignored.zig", .data = "" });
	try tmp.dir.writeFile(.{ .sub_path = ".jj/ignored.zig", .data = "" });
	try tmp.dir.writeFile(.{ .sub_path = ".codescan/index.sqlite3", .data = "" });
	try tmp.dir.writeFile(.{ .sub_path = ".codescan-fixtures/fixture/ignored.zig", .data = "" });
	try tmp.dir.writeFile(.{ .sub_path = "deps/lib/ignored.zig", .data = "" });
	try tmp.dir.writeFile(.{ .sub_path = "node_modules/pkg/ignored.zig", .data = "" });

	const allocator = std.testing.allocator;
	const root = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(root);

	const files = try findFiles(allocator, root, plugin.defaultRegistry(), .{
		.global = &[_][]const u8{},
		.per_language = &[_]config.IgnoreOverride{},
		.include_node_modules = false,
	});
	defer {
		for (files) |path| allocator.free(path);
		allocator.free(files);
	}

	try std.testing.expectEqual(@as(usize, 1), files.len);
	try std.testing.expectEqualStrings("src/main.zig", files[0]);
}

test "findFiles respects .gitignore for untracked files" {
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	try tmp.dir.makePath("src");
	try tmp.dir.makePath("generated");
	try tmp.dir.writeFile(.{ .sub_path = ".gitignore", .data = "generated/\n" });
	try tmp.dir.writeFile(.{ .sub_path = "src/main.zig", .data = "" });
	try tmp.dir.writeFile(.{ .sub_path = "generated/skip.zig", .data = "" });

	const allocator = std.testing.allocator;
	const root = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(root);

	var init_child = std.process.Child.init(&[_][]const u8{ "git", "-C", root, "init", "-q" }, allocator);
	init_child.stdin_behavior = .Close;
	init_child.stdout_behavior = .Ignore;
	init_child.stderr_behavior = .Ignore;
	init_child.spawn() catch return error.SkipZigTest;
	const init_term = try init_child.wait();
	switch (init_term) {
		.Exited => |code| if (code != 0) return error.SkipZigTest,
		else => return error.SkipZigTest,
	}

	const files = try findFiles(allocator, root, plugin.defaultRegistry(), .{
		.global = &[_][]const u8{},
		.per_language = &[_]config.IgnoreOverride{},
		.include_node_modules = false,
	});
	defer {
		for (files) |path| allocator.free(path);
		allocator.free(files);
	}

	try std.testing.expectEqual(@as(usize, 1), files.len);
	try std.testing.expectEqualStrings("src/main.zig", files[0]);
}

test "findFiles still includes tracked files even if matched by .gitignore" {
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	try tmp.dir.makePath("src");
	try tmp.dir.writeFile(.{ .sub_path = ".gitignore", .data = "*.zig\n" });
	try tmp.dir.writeFile(.{ .sub_path = "src/main.zig", .data = "" });

	const allocator = std.testing.allocator;
	const root = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(root);

	var init_child = std.process.Child.init(&[_][]const u8{ "git", "-C", root, "init", "-q" }, allocator);
	init_child.stdin_behavior = .Close;
	init_child.stdout_behavior = .Ignore;
	init_child.stderr_behavior = .Ignore;
	init_child.spawn() catch return error.SkipZigTest;
	const init_term = try init_child.wait();
	switch (init_term) {
		.Exited => |code| if (code != 0) return error.SkipZigTest,
		else => return error.SkipZigTest,
	}

	var add_child = std.process.Child.init(&[_][]const u8{ "git", "-C", root, "add", ".gitignore", "src/main.zig" }, allocator);
	add_child.stdin_behavior = .Close;
	add_child.stdout_behavior = .Ignore;
	add_child.stderr_behavior = .Ignore;
	add_child.spawn() catch return error.SkipZigTest;
	const add_term = try add_child.wait();
	switch (add_term) {
		.Exited => |code| if (code != 0) return error.SkipZigTest,
		else => return error.SkipZigTest,
	}

	const files = try findFiles(allocator, root, plugin.defaultRegistry(), .{
		.global = &[_][]const u8{},
		.per_language = &[_]config.IgnoreOverride{},
		.include_node_modules = false,
	});
	defer {
		for (files) |path| allocator.free(path);
		allocator.free(files);
	}

	try std.testing.expectEqual(@as(usize, 1), files.len);
	try std.testing.expectEqualStrings("src/main.zig", files[0]);
}

test "findFiles includes node_modules when enabled" {
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	try tmp.dir.makePath("src");
	try tmp.dir.makePath("node_modules/pkg");
	try tmp.dir.writeFile(.{ .sub_path = "src/main.zig", .data = "" });
	try tmp.dir.writeFile(.{ .sub_path = "node_modules/pkg/dep.zig", .data = "" });

	const allocator = std.testing.allocator;
	const root = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(root);

	const files = try findFiles(allocator, root, plugin.defaultRegistry(), .{
		.global = &[_][]const u8{},
		.per_language = &[_]config.IgnoreOverride{},
		.include_node_modules = true,
	});
	defer {
		for (files) |path| allocator.free(path);
		allocator.free(files);
	}

	try std.testing.expectEqual(@as(usize, 2), files.len);
}

test "findFiles matches bash dotfile names" {
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	try tmp.dir.writeFile(.{ .sub_path = ".bashrc", .data = "# bash config\n" });
	try tmp.dir.writeFile(.{ .sub_path = ".bash_profile", .data = "# profile\n" });
	try tmp.dir.writeFile(.{ .sub_path = ".profile", .data = "# profile\n" });
	try tmp.dir.writeFile(.{ .sub_path = ".bash_aliases", .data = "# aliases\n" });
	try tmp.dir.writeFile(.{ .sub_path = ".vimrc", .data = "\" vim config\n" });

	const allocator = std.testing.allocator;
	const root = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(root);

	const files = try findFiles(allocator, root, plugin.defaultRegistry(), .{
		.global = &[_][]const u8{},
		.per_language = &[_]config.IgnoreOverride{},
		.include_node_modules = false,
	});
	defer {
		for (files) |path| allocator.free(path);
		allocator.free(files);
	}

	// Should find .bashrc, .bash_profile, .profile, .bash_aliases but NOT .vimrc
	try std.testing.expectEqual(@as(usize, 4), files.len);
	var found_bashrc = false;
	var found_profile = false;
	for (files) |path| {
		if (std.mem.eql(u8, path, ".bashrc")) found_bashrc = true;
		if (std.mem.eql(u8, path, ".profile")) found_profile = true;
	}
	try std.testing.expect(found_bashrc);
	try std.testing.expect(found_profile);
}

test "findFiles follows symlinks to files" {
	if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;

	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	try tmp.dir.writeFile(.{ .sub_path = "real.sh", .data = "#!/bin/bash\n" });
	try std.posix.symlinkat("real.sh", tmp.dir.fd, "link.sh");

	const allocator = std.testing.allocator;
	const root = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(root);

	const files = try findFiles(allocator, root, plugin.defaultRegistry(), .{
		.global = &[_][]const u8{},
		.per_language = &[_]config.IgnoreOverride{},
		.include_node_modules = false,
	});
	defer {
		for (files) |path| allocator.free(path);
		allocator.free(files);
	}

	// Should find both real.sh and the symlink link.sh
	try std.testing.expectEqual(@as(usize, 2), files.len);
}

test "findFiles includes bin/ in bash-heavy projects" {
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	// Create a bash-heavy project root (has .bashrc)
	try tmp.dir.writeFile(.{ .sub_path = ".bashrc", .data = "# config\n" });
	try tmp.dir.makePath("bin");
	try tmp.dir.writeFile(.{ .sub_path = "bin/my-script.sh", .data = "#!/bin/bash\n" });

	const allocator = std.testing.allocator;
	const root = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(root);

	const files = try findFiles(allocator, root, plugin.defaultRegistry(), .{
		.global = &[_][]const u8{},
		.per_language = &[_]config.IgnoreOverride{},
		.include_node_modules = false,
	});
	defer {
		for (files) |path| allocator.free(path);
		allocator.free(files);
	}

	// Should find .bashrc AND bin/my-script.sh (bin/ not ignored in bash projects)
	var found_script = false;
	var found_bashrc = false;
	for (files) |path| {
		if (std.mem.eql(u8, path, "bin/my-script.sh")) found_script = true;
		if (std.mem.eql(u8, path, ".bashrc")) found_bashrc = true;
	}
	try std.testing.expect(found_bashrc);
	try std.testing.expect(found_script);
}

test "findFiles ignores bin/ in non-bash projects" {
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	// Normal project (no bash dotfiles in root)
	try tmp.dir.makePath("src");
	try tmp.dir.makePath("bin");
	try tmp.dir.writeFile(.{ .sub_path = "src/main.zig", .data = "" });
	try tmp.dir.writeFile(.{ .sub_path = "bin/output.zig", .data = "" });

	const allocator = std.testing.allocator;
	const root = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(root);

	const files = try findFiles(allocator, root, plugin.defaultRegistry(), .{
		.global = &[_][]const u8{},
		.per_language = &[_]config.IgnoreOverride{},
		.include_node_modules = false,
	});
	defer {
		for (files) |path| allocator.free(path);
		allocator.free(files);
	}

	// Should only find src/main.zig — bin/ should be ignored
	try std.testing.expectEqual(@as(usize, 1), files.len);
	try std.testing.expectEqualStrings("src/main.zig", files[0]);
}
