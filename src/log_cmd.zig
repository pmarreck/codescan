const std = @import("std");
const builtin = @import("builtin");
const io_singleton = @import("io_singleton.zig");

pub const Options = struct {
    root: ?[]const u8 = null,
    since: []const u8 = "1h",
    follow: bool = false,
    all: bool = false,
    limit: ?usize = null,
};

pub const Platform = enum { macos, linux, unsupported };

pub fn currentPlatform() Platform {
    return switch (builtin.os.tag) {
        .macos => .macos,
        .linux => .linux,
        else => .unsupported,
    };
}

/// Build argv for the platform log tool. Caller owns the outer slice; inner
/// slices are either literals or borrowed from `opts`.
pub fn buildArgv(
    allocator: std.mem.Allocator,
    platform: Platform,
    opts: Options,
) ![]const []const u8 {
    var list = @as(std.ArrayListUnmanaged([]const u8), .empty);
    errdefer list.deinit(allocator);

    switch (platform) {
        .macos => {
            if (opts.follow) {
                try list.append(allocator, "log");
                try list.append(allocator, "stream");
                try list.append(allocator, "--predicate");
                try list.append(allocator, "process == \"codescan\"");
            } else {
                try list.append(allocator, "log");
                try list.append(allocator, "show");
                try list.append(allocator, "--predicate");
                try list.append(allocator, "process == \"codescan\"");
                try list.append(allocator, "--last");
                try list.append(allocator, opts.since);
                try list.append(allocator, "--style");
                try list.append(allocator, "compact");
            }
        },
        .linux => {
            try list.append(allocator, "journalctl");
            try list.append(allocator, "-t");
            try list.append(allocator, "codescan");
            try list.append(allocator, "--since");
            try list.append(allocator, opts.since);
            try list.append(allocator, "--no-pager");
            if (opts.follow) try list.append(allocator, "--follow");
        },
        .unsupported => return error.UnsupportedPlatform,
    }

    return list.toOwnedSlice(allocator);
}

/// Filter raw log output: if `root` is set, keep only lines whose content
/// contains "<root>: " (the separator added by syslog.logWithRoot).
/// If `limit` is set, keep only the last `limit` matching lines.
/// Returns an owned slice (caller frees).
pub fn filterOutput(
    allocator: std.mem.Allocator,
    output: []const u8,
    root: ?[]const u8,
    limit: ?usize,
) ![]u8 {
    var kept = @as(std.ArrayListUnmanaged([]const u8), .empty);
    defer kept.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, output, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        if (root) |r| {
            var marker_buf: [1024]u8 = undefined;
            if (r.len + 2 > marker_buf.len) continue;
            @memcpy(marker_buf[0..r.len], r);
            marker_buf[r.len] = ':';
            marker_buf[r.len + 1] = ' ';
            const marker = marker_buf[0 .. r.len + 2];
            if (std.mem.indexOf(u8, line, marker) == null) continue;
        }
        try kept.append(allocator, line);
    }

    const start: usize = if (limit) |n| (if (kept.items.len > n) kept.items.len - n else 0) else 0;

    var out = @as(std.ArrayListUnmanaged(u8), .empty);
    errdefer out.deinit(allocator);
    for (kept.items[start..]) |line| {
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

// ---- Tests ----

test "buildArgv macos without follow" {
    const allocator = std.testing.allocator;
    const argv = try buildArgv(allocator, .macos, .{ .since = "30m" });
    defer allocator.free(argv);
    try std.testing.expectEqualStrings("log", argv[0]);
    try std.testing.expectEqualStrings("show", argv[1]);
    try std.testing.expectEqualStrings("--predicate", argv[2]);
    try std.testing.expect(std.mem.indexOf(u8, argv[3], "codescan") != null);
    try std.testing.expectEqualStrings("--last", argv[4]);
    try std.testing.expectEqualStrings("30m", argv[5]);
}

test "buildArgv macos with follow uses stream" {
    const allocator = std.testing.allocator;
    const argv = try buildArgv(allocator, .macos, .{ .follow = true });
    defer allocator.free(argv);
    try std.testing.expectEqualStrings("stream", argv[1]);
}

test "buildArgv linux uses journalctl -t codescan" {
    const allocator = std.testing.allocator;
    const argv = try buildArgv(allocator, .linux, .{ .since = "10m" });
    defer allocator.free(argv);
    try std.testing.expectEqualStrings("journalctl", argv[0]);
    try std.testing.expectEqualStrings("-t", argv[1]);
    try std.testing.expectEqualStrings("codescan", argv[2]);
    try std.testing.expectEqualStrings("--since", argv[3]);
    try std.testing.expectEqualStrings("10m", argv[4]);
}

test "buildArgv returns error for unsupported platform" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedPlatform, buildArgv(allocator, .unsupported, .{}));
}

test "filterOutput retains lines matching root marker" {
    const allocator = std.testing.allocator;
    const input =
        \\2026-04-18 10:00:00 codescan[123]: /a: watcher started
        \\2026-04-18 10:01:00 codescan[124]: /b: watcher started
        \\2026-04-18 10:02:00 codescan[125]: /a: index error: Foo (1/5)
    ;
    const filtered = try filterOutput(allocator, input, "/a", null);
    defer allocator.free(filtered);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "/a: watcher started") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "/a: index error") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "/b:") == null);
}

test "filterOutput without root returns all non-empty lines" {
    const allocator = std.testing.allocator;
    const input = "alpha\n\nbravo\n";
    const filtered = try filterOutput(allocator, input, null, null);
    defer allocator.free(filtered);
    try std.testing.expectEqualStrings("alpha\nbravo\n", filtered);
}

test "filterOutput applies limit to keep the last N lines" {
    const allocator = std.testing.allocator;
    const input = "a\nb\nc\nd\ne\n";
    const filtered = try filterOutput(allocator, input, null, 2);
    defer allocator.free(filtered);
    try std.testing.expectEqualStrings("d\ne\n", filtered);
}

// Seam for tests: allows injecting a fake command runner.
pub const CommandRunner = *const fn (
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) anyerror![]u8;

fn realRunner(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) anyerror![]u8 {
    const io = io_singleton.getOrInit();
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .close,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    errdefer _ = child.wait(io) catch {};

    const out = try io_singleton.readToEndAlloc(child.stdout.?, allocator, std.math.maxInt(usize));
    errdefer allocator.free(out);

    _ = try child.wait(io);
    return out;
}

/// Run the log retrieval pipeline and return the filtered output.
/// Caller owns the returned slice.
pub fn run(
    allocator: std.mem.Allocator,
    opts: Options,
    runner: ?CommandRunner,
) ![]u8 {
    const platform = currentPlatform();
    if (platform == .unsupported) return error.UnsupportedPlatform;

    const argv = try buildArgv(allocator, platform, opts);
    defer allocator.free(argv);

    const raw = try (runner orelse realRunner)(allocator, argv);
    defer allocator.free(raw);

    const effective_root: ?[]const u8 = if (opts.all) null else opts.root;
    return filterOutput(allocator, raw, effective_root, opts.limit);
}

// --- Test fakes ---

var fake_output: []const u8 = "";

fn fakeRunner(allocator: std.mem.Allocator, argv: []const []const u8) anyerror![]u8 {
    _ = argv;
    return allocator.dupe(u8, fake_output);
}

test "run applies root filter and honors --all" {
    const allocator = std.testing.allocator;
    fake_output =
        \\2026-04-18 codescan[1]: /proj-a: watcher started
        \\2026-04-18 codescan[2]: /proj-b: watcher started
    ;

    const filtered = try run(allocator, .{ .root = "/proj-a" }, fakeRunner);
    defer allocator.free(filtered);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "/proj-a") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "/proj-b") == null);

    const all = try run(allocator, .{ .root = "/proj-a", .all = true }, fakeRunner);
    defer allocator.free(all);
    try std.testing.expect(std.mem.indexOf(u8, all, "/proj-a") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "/proj-b") != null);
}
