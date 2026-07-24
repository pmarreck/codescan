const std = @import("std");
const io_singleton = @import("io_singleton.zig");
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
const max_shebang_line_bytes = 256;

pub const FileProgress = struct {
    context: *anyopaque,
    observe_fn: *const fn (context: *anyopaque, eligible_files: usize) void,
    finish_fn: *const fn (context: *anyopaque) void,

    pub fn observe(self: FileProgress, eligible_files: usize) void {
        self.observe_fn(self.context, eligible_files);
    }

    pub fn finish(self: FileProgress) void {
        self.finish_fn(self.context);
    }
};

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
    return findFilesWithProgress(allocator, root_path, registry, ignore_cfg, null);
}

pub fn findFilesWithProgress(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    registry: plugin.Registry,
    ignore_cfg: IgnoreConfig,
    progress: ?FileProgress,
) ![]const []const u8 {
    defer if (progress) |value| value.finish();
    var dir = try std.Io.Dir.cwd().openDir(io_singleton.getOrInit(), root_path, .{ .iterate = true });
    defer dir.close(io_singleton.getOrInit());

    const skip_bin_ignore = isBashProject(dir);
    const ignore_sets = try buildIgnoreSets(allocator, registry, ignore_cfg, skip_bin_ignore);
    defer deinitIgnoreSets(allocator, ignore_sets);

    var results = @as(std.ArrayListUnmanaged([]const u8), .empty);
    errdefer {
        for (results.items) |path| allocator.free(path);
        results.deinit(allocator);
    }

    const git_files = try captureGitFileList(allocator, root_path);
    defer if (git_files) |files| allocator.free(files);

    // Git already computed the exact tracked-plus-eligible-untracked candidate
    // set. Iterating it directly avoids walking large ignored build/cache trees.
    if (git_files != null and ignore_cfg.always_include.len == 0) {
        var paths = std.mem.splitScalar(u8, git_files.?, 0);
        while (paths.next()) |path| {
            if (path.len == 0) continue;
            const stat = dir.statFile(io_singleton.getOrInit(), path, .{}) catch continue;
            if (stat.kind != .file) continue;
            try appendEligibleFile(allocator, dir, registry, ignore_sets, path, &results, progress);
        }
        return results.toOwnedSlice(allocator);
    }

    var git_allow = if (git_files) |files|
        try buildGitAllowSetFromList(allocator, files)
    else
        null;
    defer if (git_allow) |*set| deinitGitAllowSet(allocator, set);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io_singleton.getOrInit())) |entry| {
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
        try appendEligibleFile(allocator, dir, registry, ignore_sets, entry.path, &results, progress);
    }

    return results.toOwnedSlice(allocator);
}

fn appendEligibleFile(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    registry: plugin.Registry,
    ignore_sets: []IgnoreSet,
    path: []const u8,
    results: *std.ArrayListUnmanaged([]const u8),
    progress: ?FileProgress,
) !void {
    const chosen = findExtractor(dir, registry, path) orelse return;
    if (shouldIgnore(allocator, ignore_sets, chosen.language, path)) return;
    try results.append(allocator, try allocator.dupe(u8, path));
    if (progress) |value| value.observe(results.items.len);
}

/// Resolves an extractor by filename first, then by an extensionless script's
/// shebang so discovery, updates, and watcher reindexing classify identically.
pub fn findExtractor(dir: std.Io.Dir, registry: plugin.Registry, path: []const u8) ?*const plugin.Extractor {
    if (registry.find(path)) |extractor| return extractor;
    if (std.fs.path.extension(path).len != 0) return null;
    const language = detectShebangLanguage(dir, path) orelse return null;
    return registry.findByLanguage(language);
}

fn captureGitFileList(allocator: std.mem.Allocator, root_path: []const u8) !?[]u8 {
    // Delegate .gitignore semantics to Git directly. If unavailable or not a repo,
    // fall back to existing scanner ignore logic.
    var root_dir = std.Io.Dir.cwd().openDir(io_singleton.getOrInit(), root_path, .{}) catch return null;
    defer root_dir.close(io_singleton.getOrInit());
    _ = root_dir.statFile(io_singleton.getOrInit(), ".git", .{}) catch return null;

    const stdout = gitCaptureStdout(
        allocator,
        &[_][]const u8{ "git", "-C", root_path, "ls-files", "-z", "--cached", "--others", "--exclude-standard" },
    ) catch return null;
    return stdout;
}

fn buildGitAllowSetFromList(allocator: std.mem.Allocator, stdout: []const u8) !std.StringHashMapUnmanaged(void) {
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
    const io = io_singleton.getOrInit();
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .close,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    const stdout = try io_singleton.readToEndAlloc(child.stdout.?, allocator, 256 * 1024 * 1024);
    errdefer allocator.free(stdout);

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.ChildProcessFailed,
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
fn isBashProject(dir: std.Io.Dir) bool {
    const markers = [_][]const u8{ ".bashrc", ".bash_profile", ".profile", ".bash_aliases" };
    for (&markers) |name| {
        if (dir.statFile(io_singleton.getOrInit(), name, .{})) |_| return true else |_| {}
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

fn isSymlinkToFile(dir: std.Io.Dir, rel_path: []const u8) bool {
    const stat = dir.statFile(io_singleton.getOrInit(), rel_path, .{}) catch return false;
    return stat.kind == .file;
}

fn detectShebangLanguage(dir: std.Io.Dir, rel_path: []const u8) ?[]const u8 {
    const io = io_singleton.getOrInit();
    const stat = dir.statFile(io, rel_path, .{}) catch return null;
    if (stat.kind != .file) return null;
    if (comptime std.Io.File.Permissions.has_executable_bit) {
        if (stat.permissions.toMode() & 0o111 == 0) return null;
    } else {
        return null;
    }

    var file = dir.openFile(io_singleton.getOrInit(), rel_path, .{}) catch return null;
    defer file.close(io);

    var chunk: [4096]u8 = undefined;
    var first_line: [max_shebang_line_bytes]u8 = undefined;
    var first_line_len: usize = 0;
    var language: ?[]const u8 = null;
    var first_line_complete = false;

    while (true) {
        const n = file.readStreaming(io, &.{&chunk}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return null,
        };
        if (n == 0) return null;

        for (chunk[0..n]) |byte| {
            // NUL is not valid shell source and is the conventional binary-file
            // discriminator. Continue through the entire candidate after parsing
            // its shebang so a binary payload cannot masquerade as a script.
            if (byte == 0) return null;
            if (first_line_complete) continue;
            if (byte == '\n') {
                language = parseShebang(first_line[0..first_line_len]) orelse return null;
                first_line_complete = true;
                continue;
            }
            if (first_line_len == first_line.len) return null;
            first_line[first_line_len] = byte;
            first_line_len += 1;
        }
    }

    if (!first_line_complete) {
        language = parseShebang(first_line[0..first_line_len]) orelse return null;
    }
    return language;
}

fn parseShebang(line: []const u8) ?[]const u8 {
    if (line.len < 2 or line[0] != '#' or line[1] != '!') return null;

    var rest = std.mem.trimStart(u8, line[2..], " \t");
    if (rest.len == 0) return null;

    var token = nextToken(rest);
    if (isEnvToken(token)) {
        rest = std.mem.trimStart(u8, rest[token.len..], " \t");
        while (rest.len > 0) {
            token = nextToken(rest);
            if (token.len == 0) return null;
            rest = std.mem.trimStart(u8, rest[token.len..], " \t");
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
    if (matchesInterpreter(name, &.{ "bash", "sh", "zsh", "dash", "ash", "ksh" })) return "bash";
    if (std.mem.eql(u8, name, "lua") or std.mem.eql(u8, name, "luajit")) return "lua";
    if (matchesInterpreter(name, &.{ "ruby", "irb" })) return "ruby";
    if (std.mem.eql(u8, name, "fish")) return "fish";
    if (matchesInterpreter(name, &.{ "nu", "nushell" })) return "nushell";
    if (matchesInterpreter(name, &.{ "pwsh", "powershell" })) return "powershell";
    if (matchesInterpreter(name, &.{ "tclsh", "wish" })) return "tcl";
    if (matchesInterpreter(name, &.{ "osh", "ysh" })) return "oil";
    if (matchesInterpreter(name, &.{ "fsi", "dotnet-fsi" })) return "fsharp";
    if (matchesInterpreter(name, &.{ "racket", "raco" })) return "racket";
    if (matchesInterpreter(name, &.{ "guile", "scheme", "chez", "petite", "csi", "gosh" })) return "scheme";
    if (matchesInterpreter(name, &.{ "sbcl", "clisp", "ecl" })) return "common-lisp";
    if (matchesInterpreter(name, &.{ "sml", "poly", "polyml" })) return "sml";
    if (matchesInterpreter(name, &.{ "bb", "babashka", "clojure", "clj" })) return "clojure";
    if (matchesInterpreter(name, &.{ "node", "nodejs", "deno", "bun" })) return "typescript";
    if (matchesInterpreter(name, &.{ "elixir", "iex" })) return "elixir";
    if (matchesInterpreter(name, &.{ "runghc", "runhaskell" })) return "haskell";
    if (std.mem.eql(u8, name, "swift")) return "swift";
    if (std.mem.eql(u8, name, "nim")) return "nim";
    if (std.mem.eql(u8, name, "escript")) return "erlang";
    if (std.mem.eql(u8, name, "ocaml")) return "ocaml";
    return null;
}

fn matchesInterpreter(name: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

test "shebang classifier covers supported executable script runtimes as a set" {
    const cases = .{
        .{ "#!/usr/bin/env -S fish --no-config", "fish" },
        .{ "#!/usr/bin/nu", "nushell" },
        .{ "#!/usr/bin/env pwsh", "powershell" },
        .{ "#!/usr/bin/tclsh", "tcl" },
        .{ "#!/usr/bin/env ysh", "oil" },
        .{ "#!/usr/bin/env fsi", "fsharp" },
        .{ "#!/usr/bin/env racket", "racket" },
        .{ "#!/usr/bin/guile", "scheme" },
        .{ "#!/usr/bin/env sbcl", "common-lisp" },
        .{ "#!/usr/bin/env sml", "sml" },
        .{ "#!/usr/bin/env bb", "clojure" },
        .{ "#!/usr/bin/env node", "typescript" },
        .{ "#!/usr/bin/env elixir", "elixir" },
        .{ "#!/usr/bin/env runghc", "haskell" },
        .{ "#!/usr/bin/env swift", "swift" },
        .{ "#!/usr/bin/env nim", "nim" },
        .{ "#!/usr/bin/env escript", "erlang" },
        .{ "#!/usr/bin/env ocaml", "ocaml" },
        .{ "#!/usr/bin/env irb", "ruby" },
        .{ "#!/bin/zsh", "bash" },
    };
    inline for (cases) |case| {
        const actual = parseShebang(case[0]) orelse {
            std.debug.print("unclassified shebang: {s}\n", .{case[0]});
            return error.TestExpectedEqual;
        };
        try std.testing.expectEqualStrings(case[1], actual);
    }
}

fn buildIgnoreSets(
    allocator: std.mem.Allocator,
    registry: plugin.Registry,
    ignore_cfg: IgnoreConfig,
    skip_bin_ignore: bool,
) ![]IgnoreSet {
    var sets = @as(std.ArrayListUnmanaged(IgnoreSet), .empty);
    errdefer {
        for (sets.items) |*set| {
            for (set.patterns) |*pat| pat.pattern.deinit();
            allocator.free(set.patterns);
        }
        sets.deinit(allocator);
    }

    for (registry.extractors) |extractor| {
        var patterns = @as(std.ArrayListUnmanaged(IgnorePattern), .empty);
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

    try tmp.dir.createDirPath(io_singleton.getOrInit(), "src");
    try tmp.dir.createDirPath(io_singleton.getOrInit(), "lib");
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = "src/main.zig", .data = "" });
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = "lib/demo.ex", .data = "" });
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = "README.md", .data = "" });

    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
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

test "findFiles classifies extensionless scripts from text executable shebangs" {
    if (comptime !std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const executable = std.Io.Dir.CreateFileOptions{ .permissions = .executable_file };
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{
        .sub_path = "script",
        .data = "#!/usr/bin/env bash\nexit 0\n",
        .flags = executable,
    });
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{
        .sub_path = "luascript",
        .data = "#!/usr/bin/env luajit\nprint('ok')\n",
        .flags = executable,
    });
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{
        .sub_path = "rubyscript",
        .data = "#!/usr/bin/env ruby\ndef ok = true\n",
        .flags = executable,
    });
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{
        .sub_path = "non_executable",
        .data = "#!/usr/bin/env bash\nexit 0\n",
    });
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{
        .sub_path = "missing_shebang",
        .data = "echo no\n",
        .flags = executable,
    });
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{
        .sub_path = "unsupported_shebang",
        .data = "#!/usr/bin/env python3\nprint('no')\n",
        .flags = executable,
    });
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{
        .sub_path = "binary_impostor",
        .data = "#!/usr/bin/env bash\nprintf ok\n\x00binary\n",
        .flags = executable,
    });

    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
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
    var found_bash = false;
    var found_lua = false;
    var found_ruby = false;
    var found_false_positive = false;
    for (files) |path| {
        if (std.mem.eql(u8, path, "script")) found_bash = true;
        if (std.mem.eql(u8, path, "luascript")) found_lua = true;
        if (std.mem.eql(u8, path, "rubyscript")) found_ruby = true;
        if (std.mem.eql(u8, path, "non_executable") or
            std.mem.eql(u8, path, "missing_shebang") or
            std.mem.eql(u8, path, "unsupported_shebang") or
            std.mem.eql(u8, path, "binary_impostor")) found_false_positive = true;
    }
    try std.testing.expect(found_bash);
    try std.testing.expect(found_lua);
    try std.testing.expect(found_ruby);
    try std.testing.expect(!found_false_positive);
}

test "findFiles respects ignores" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_singleton.getOrInit(), "src");
    try tmp.dir.createDirPath(io_singleton.getOrInit(), "lib");
    try tmp.dir.createDirPath(io_singleton.getOrInit(), ".zig-cache");
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = "src/main.zig", .data = "" });
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = ".zig-cache/cache.zig", .data = "" });
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = "lib/demo.ex", .data = "" });
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = "lib/skip.ex", .data = "" });

    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
    defer allocator.free(root);

    var patterns = @as(std.ArrayListUnmanaged([]const u8), .empty);
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

    try tmp.dir.createDirPath(io_singleton.getOrInit(), "src");
    try tmp.dir.createDirPath(io_singleton.getOrInit(), ".git");
    try tmp.dir.createDirPath(io_singleton.getOrInit(), ".jj");
    try tmp.dir.createDirPath(io_singleton.getOrInit(), ".codescan");
    try tmp.dir.createDirPath(io_singleton.getOrInit(), ".codescan-fixtures/fixture");
    try tmp.dir.createDirPath(io_singleton.getOrInit(), "deps/lib");
    try tmp.dir.createDirPath(io_singleton.getOrInit(), "node_modules/pkg");
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = "src/main.zig", .data = "" });
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = ".git/ignored.zig", .data = "" });
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = ".jj/ignored.zig", .data = "" });
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = ".codescan/index.sqlite3", .data = "" });
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = ".codescan-fixtures/fixture/ignored.zig", .data = "" });
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = "deps/lib/ignored.zig", .data = "" });
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = "node_modules/pkg/ignored.zig", .data = "" });

    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
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

    try tmp.dir.createDirPath(io_singleton.getOrInit(), "src");
    try tmp.dir.createDirPath(io_singleton.getOrInit(), "generated");
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = ".gitignore", .data = "generated/\n" });
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = "src/main.zig", .data = "" });
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = "generated/skip.zig", .data = "" });

    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
    defer allocator.free(root);

    const io_t1 = io_singleton.getOrInit();
    var init_child = std.process.spawn(io_t1, .{
        .argv = &[_][]const u8{ "git", "-C", root, "init", "-q" },
        .stdin = .close,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.SkipZigTest;
    const init_term = try init_child.wait(io_t1);
    switch (init_term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
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

test "findFiles classifies gitignored symlinks with the full candidate set" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_singleton.getOrInit(), "src");
    try tmp.dir.createDirPath(io_singleton.getOrInit(), "generated");
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = ".gitignore", .data = "generated/\n" });
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = "src/real.sh", .data = "#!/usr/bin/env bash\n" });
    try tmp.dir.symLink(io_singleton.getOrInit(), "../src/real.sh", "generated/alias.sh", .{});

    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
    defer allocator.free(root);

    const io = io_singleton.getOrInit();
    var init_child = std.process.spawn(io, .{
        .argv = &[_][]const u8{ "git", "-C", root, "init", "-q" },
        .stdin = .close,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.SkipZigTest;
    const init_term = try init_child.wait(io);
    switch (init_term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
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
    try std.testing.expectEqualStrings("src/real.sh", files[0]);
}

test "findFiles still includes tracked files even if matched by .gitignore" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io_singleton.getOrInit(), "src");
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = ".gitignore", .data = "*.zig\n" });
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = "src/main.zig", .data = "" });

    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
    defer allocator.free(root);

    const io_t2 = io_singleton.getOrInit();
    var init_child = std.process.spawn(io_t2, .{
        .argv = &[_][]const u8{ "git", "-C", root, "init", "-q" },
        .stdin = .close,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.SkipZigTest;
    const init_term = try init_child.wait(io_t2);
    switch (init_term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }

    var add_child = std.process.spawn(io_t2, .{
        .argv = &[_][]const u8{ "git", "-C", root, "add", ".gitignore", "src/main.zig" },
        .stdin = .close,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.SkipZigTest;
    const add_term = try add_child.wait(io_t2);
    switch (add_term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
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

    try tmp.dir.createDirPath(io_singleton.getOrInit(), "src");
    try tmp.dir.createDirPath(io_singleton.getOrInit(), "node_modules/pkg");
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = "src/main.zig", .data = "" });
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = "node_modules/pkg/dep.zig", .data = "" });

    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
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

    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = ".bashrc", .data = "# bash config\n" });
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = ".bash_profile", .data = "# profile\n" });
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = ".profile", .data = "# profile\n" });
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = ".bash_aliases", .data = "# aliases\n" });
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = ".vimrc", .data = "\" vim config\n" });

    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
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

    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = "real.sh", .data = "#!/bin/bash\n" });
    try tmp.dir.symLink(io_singleton.getOrInit(), "real.sh", "link.sh", .{});

    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
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
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = ".bashrc", .data = "# config\n" });
    try tmp.dir.createDirPath(io_singleton.getOrInit(), "bin");
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = "bin/my-script.sh", .data = "#!/bin/bash\n" });

    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
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
    try tmp.dir.createDirPath(io_singleton.getOrInit(), "src");
    try tmp.dir.createDirPath(io_singleton.getOrInit(), "bin");
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = "src/main.zig", .data = "" });
    try tmp.dir.writeFile(io_singleton.getOrInit(), .{ .sub_path = "bin/output.zig", .data = "" });

    const allocator = std.testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
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
