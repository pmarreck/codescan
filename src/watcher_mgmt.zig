const std = @import("std");
const io_singleton = @import("io_singleton.zig");
const builtin = @import("builtin");
const pidfile = @import("pidfile.zig");

pub const WatcherInfo = struct {
	pid: std.posix.pid_t,
	cpu_pct: []const u8, // kept as string for display
	elapsed: []const u8,
	root: []const u8,
	active: bool, // has non-watcher processes with cwd under root

	pub fn deinit(self: *WatcherInfo, allocator: std.mem.Allocator) void {
		allocator.free(self.cpu_pct);
		allocator.free(self.elapsed);
		allocator.free(self.root);
	}
};

/// Parse one line of `/bin/ps -eo pid,pcpu,etime,args` output.
/// Returns null if the line doesn't match a codescan watcher.
pub fn parseWatcherLine(allocator: std.mem.Allocator, line: []const u8) !?WatcherInfo {
	// Expected format: "  PID  %CPU     ELAPSED ARGS..."
	// Example: " 66831   0.1 03-00:43:45 /path/to/codescan watch --root /some/project"
	var trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
	if (trimmed.len == 0) return null;

	// Must contain "watch --root" to be a codescan watcher
	const root_marker = std.mem.indexOf(u8, trimmed, "watch --root ");
	if (root_marker == null) return null;

	// Also skip the header line
	if (std.mem.startsWith(u8, trimmed, "PID")) return null;

	// Parse fields: PID, %CPU, ELAPSED, then args
	var it = std.mem.tokenizeAny(u8, trimmed, " \t");
	const pid_str = it.next() orelse return null;
	const cpu_str = it.next() orelse return null;
	const elapsed_str = it.next() orelse return null;

	const pid = std.fmt.parseInt(std.posix.pid_t, pid_str, 10) catch return null;

	// Extract root path: everything after "watch --root "
	const root_start = root_marker.? + "watch --root ".len;
	if (root_start >= trimmed.len) return null;
	// Root path may be followed by more flags, but --root value is next token
	const root_rest = trimmed[root_start..];
	const root_end = std.mem.indexOfAny(u8, root_rest, " \t") orelse root_rest.len;
	const root = root_rest[0..root_end];

	return WatcherInfo{
		.pid = pid,
		.cpu_pct = try allocator.dupe(u8, cpu_str),
		.elapsed = try allocator.dupe(u8, elapsed_str),
		.root = try allocator.dupe(u8, root),
		.active = false, // filled in later
	};
}

/// Parse lsof -d cwd output to extract (pid, cwd_path) pairs.
/// Returns a list of cwd paths (caller must free each + the list).
pub fn parseLsofCwds(allocator: std.mem.Allocator, output: []const u8) !std.ArrayListUnmanaged(LsofEntry) {
	var result = @as(std.ArrayListUnmanaged(LsofEntry), .empty);
	errdefer {
		for (result.items) |e| e.deinit(allocator);
		result.deinit(allocator);
	}

	var lines = std.mem.splitScalar(u8, output, '\n');
	while (lines.next()) |line| {
		if (line.len == 0) continue;
		// lsof output format: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
		// We want PID (field 1) and NAME (last field)
		var it = std.mem.tokenizeAny(u8, line, " \t");
		_ = it.next() orelse continue; // COMMAND
		const pid_str = it.next() orelse continue; // PID
		const pid = std.fmt.parseInt(std.posix.pid_t, pid_str, 10) catch continue;
		// Skip to the last field (NAME = cwd path)
		// Fields: USER, FD, TYPE, DEVICE, SIZE/OFF, NODE, NAME
		_ = it.next() orelse continue; // USER
		_ = it.next() orelse continue; // FD
		_ = it.next() orelse continue; // TYPE
		_ = it.next() orelse continue; // DEVICE
		_ = it.next() orelse continue; // SIZE/OFF
		_ = it.next() orelse continue; // NODE
		const name = it.rest();
		if (name.len == 0) continue;

		try result.append(allocator, .{
			.pid = pid,
			.path = try allocator.dupe(u8, name),
		});
	}
	return result;
}

pub const LsofEntry = struct {
	pid: std.posix.pid_t,
	path: []const u8,

	pub fn deinit(self: LsofEntry, allocator: std.mem.Allocator) void {
		allocator.free(self.path);
	}
};

/// Check if a watcher's root has any active sessions (non-watcher processes with cwd under root).
pub fn hasActiveSessions(watcher_pid: std.posix.pid_t, watcher_root: []const u8, cwds: []const LsofEntry) bool {
	for (cwds) |entry| {
		if (entry.pid == watcher_pid) continue; // skip the watcher itself
		// Check if the cwd is the root or under the root
		if (std.mem.eql(u8, entry.path, watcher_root)) return true;
		if (std.mem.startsWith(u8, entry.path, watcher_root) and
			entry.path.len > watcher_root.len and
			entry.path[watcher_root.len] == '/') return true;
	}
	return false;
}

/// Run /bin/ps and discover all running codescan watchers.
pub fn discoverWatchers(allocator: std.mem.Allocator) !std.ArrayListUnmanaged(WatcherInfo) {
	if (comptime builtin.os.tag == .windows) return error.WatcherNotSupportedOnPlatform;

	const ps_output = try runCommand(allocator, &.{ "/bin/ps", "-eo", "pid,pcpu,etime,args" });
	defer allocator.free(ps_output);

	var watchers = @as(std.ArrayListUnmanaged(WatcherInfo), .empty);
	errdefer {
		for (watchers.items) |*w| w.deinit(allocator);
		watchers.deinit(allocator);
	}

	var lines = std.mem.splitScalar(u8, ps_output, '\n');
	while (lines.next()) |line| {
		if (try parseWatcherLine(allocator, line)) |info| {
			try watchers.append(allocator, info);
		}
	}

	return watchers;
}

/// Get all process cwds via lsof.
pub fn getActiveCwds(allocator: std.mem.Allocator) !std.ArrayListUnmanaged(LsofEntry) {
	if (comptime builtin.os.tag == .windows) return error.WatcherNotSupportedOnPlatform;

	const lsof_output = try runCommand(allocator, &.{ "/usr/sbin/lsof", "-d", "cwd" });	defer allocator.free(lsof_output);

	return parseLsofCwds(allocator, lsof_output);
}

/// Populate the .active field on each watcher by cross-referencing cwds.
pub fn markActiveWatchers(watchers: []WatcherInfo, cwds: []const LsofEntry) void {
	for (watchers) |*w| {
		w.active = hasActiveSessions(w.pid, w.root, cwds);
	}
}

/// Stop a watcher by sending SIGTERM. Returns `error.WatcherNotSupportedOnPlatform`
/// on Windows and `error.SignalFailed` if `kill(2)` returned nonzero.
pub fn stopWatcher(pid: std.posix.pid_t) !void {
	if (comptime builtin.os.tag == .windows) return error.WatcherNotSupportedOnPlatform;
	if (std.c.kill(pid, std.posix.SIG.TERM) != 0) return error.SignalFailed;
}

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
	const io = io_singleton.getOrInit();
	var child = try std.process.spawn(io, .{
		.argv = argv,
		.stdout = .pipe,
		.stderr = .ignore,
	});
	const output = try io_singleton.readToEndAlloc(child.stdout.?, allocator, 10 * 1024 * 1024);
	errdefer allocator.free(output);
	const term = try child.wait(io);
	if (term.exited != 0) return error.CommandFailed;
	return output;
}
// ─── Tests ───────────────────────────────────────────────────────────────────

test "parseWatcherLine extracts watcher info" {
	const allocator = std.testing.allocator;
	const line = " 66831   0.1 03-00:43:45 /usr/local/bin/codescan watch --root /Users/pmarreck/projects/es-shell";
	var info = (try parseWatcherLine(allocator, line)).?;
	defer info.deinit(allocator);

	try std.testing.expectEqual(@as(std.posix.pid_t, 66831), info.pid);
	try std.testing.expectEqualStrings("0.1", info.cpu_pct);
	try std.testing.expectEqualStrings("03-00:43:45", info.elapsed);
	try std.testing.expectEqualStrings("/Users/pmarreck/projects/es-shell", info.root);
}

test "parseWatcherLine returns null for non-watcher lines" {
	const allocator = std.testing.allocator;
	try std.testing.expect(try parseWatcherLine(allocator, "  PID  %CPU     ELAPSED ARGS") == null);
	try std.testing.expect(try parseWatcherLine(allocator, " 1234   0.0    00:05:00 /usr/bin/vim") == null);
	try std.testing.expect(try parseWatcherLine(allocator, "") == null);
}

test "parseWatcherLine handles path with spaces in other args" {
	const allocator = std.testing.allocator;
	const line = "67649   7.6 03-00:43:18 /path/to/codescan watch --root /Users/me/my-project";
	var info = (try parseWatcherLine(allocator, line)).?;
	defer info.deinit(allocator);

	try std.testing.expectEqual(@as(std.posix.pid_t, 67649), info.pid);
	try std.testing.expectEqualStrings("/Users/me/my-project", info.root);
}

test "parseLsofCwds extracts pid and path" {
	const allocator = std.testing.allocator;
	const output =
		\\COMMAND   PID   USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
		\\zsh     12345 peter  cwd    DIR  1,18      640  123 /Users/peter/projects/foo
		\\codescan 66831 peter  cwd    DIR  1,18      640  456 /Users/peter/projects/es-shell
	;
	var entries = try parseLsofCwds(allocator, output);
	defer {
		for (entries.items) |e| e.deinit(allocator);
		entries.deinit(allocator);
	}

	// Header line is skipped (PID parse fails on "PID")
	try std.testing.expectEqual(@as(usize, 2), entries.items.len);
	try std.testing.expectEqual(@as(std.posix.pid_t, 12345), entries.items[0].pid);
	try std.testing.expectEqualStrings("/Users/peter/projects/foo", entries.items[0].path);
	try std.testing.expectEqual(@as(std.posix.pid_t, 66831), entries.items[1].pid);
	try std.testing.expectEqualStrings("/Users/peter/projects/es-shell", entries.items[1].path);
}

test "hasActiveSessions detects active cwd under root" {
	const cwds = [_]LsofEntry{
		.{ .pid = 66831, .path = "/Users/me/project" }, // watcher itself
		.{ .pid = 12345, .path = "/Users/me/project" }, // shell in project root
	};
	try std.testing.expect(hasActiveSessions(66831, "/Users/me/project", &cwds));
}

test "hasActiveSessions detects subcwd under root" {
	const cwds = [_]LsofEntry{
		.{ .pid = 66831, .path = "/Users/me/project" }, // watcher itself
		.{ .pid = 12345, .path = "/Users/me/project/src" }, // shell in subdir
	};
	try std.testing.expect(hasActiveSessions(66831, "/Users/me/project", &cwds));
}

test "hasActiveSessions returns false when only watcher has cwd" {
	const cwds = [_]LsofEntry{
		.{ .pid = 66831, .path = "/Users/me/project" }, // watcher itself only
	};
	try std.testing.expect(!hasActiveSessions(66831, "/Users/me/project", &cwds));
}

test "hasActiveSessions rejects partial prefix match" {
	// /Users/me/project-extra should NOT match /Users/me/project
	const cwds = [_]LsofEntry{
		.{ .pid = 12345, .path = "/Users/me/project-extra" },
	};
	try std.testing.expect(!hasActiveSessions(66831, "/Users/me/project", &cwds));
}

test "hasActiveSessions returns false with no cwds" {
	const cwds = [_]LsofEntry{};
	try std.testing.expect(!hasActiveSessions(66831, "/Users/me/project", &cwds));
}
