const std = @import("std");

pub const Outcome = enum {
	watcher_active,
	reconciled,
	stale,
};

pub const WatcherStartReason = enum {
	explicit_watch_command,
	index_completed,
	update_completed,
	search_auto_index_completed,
};

/// Keeps daemon lifecycle opt-in: indexing and searching never create watchers.
pub fn shouldStartWatcher(reason: WatcherStartReason) bool {
	return reason == .explicit_watch_command;
}

pub const WatcherAdvisory = struct {
	elapsed_seconds: f64,
};

pub const ProjectActivity = struct {
	latest_commit_age_ns: ?u64 = null,
	changed_paths: usize = 0,
};

const slow_update_ns = std.time.ns_per_s;
const recent_commit_ns = 7 * 24 * 60 * 60 * std.time.ns_per_s;

/// Recommends a watcher only when on-demand reconciliation is observably slow
/// in a repository with a recent commit or substantial current work.
pub fn watcherAdvisory(elapsed_ns: u64, activity: ProjectActivity) ?WatcherAdvisory {
	if (elapsed_ns <= slow_update_ns) return null;
	const recently_committed = if (activity.latest_commit_age_ns) |age|
		age <= recent_commit_ns
	else
		false;
	if (!recently_committed and activity.changed_paths <= 2) return null;
	return .{
		.elapsed_seconds = @as(f64, @floatFromInt(elapsed_ns)) /
			@as(f64, @floatFromInt(std.time.ns_per_s)),
	};
}

/// Converts injected Git command output into activity signals without reading
/// clocks or spawning processes, keeping boundary behavior deterministic.
pub fn parseGitActivity(now_ns: i96, commit_stdout: []const u8, status_stdout: []const u8) ProjectActivity {
	const commit_text = std.mem.trim(u8, commit_stdout, " \t\r\n");
	const commit_seconds = std.fmt.parseInt(i64, commit_text, 10) catch null;
	const commit_age_ns: ?u64 = if (commit_seconds) |seconds| age: {
		const commit_ns = @as(i96, seconds) * std.time.ns_per_s;
		if (commit_ns >= now_ns) break :age 0;
		break :age @intCast(now_ns - commit_ns);
	} else null;

	var changed_paths: usize = 0;
	var lines = std.mem.splitScalar(u8, status_stdout, '\n');
	while (lines.next()) |line| {
		if (std.mem.trim(u8, line, " \t\r").len > 0) changed_paths += 1;
	}
	return .{
		.latest_commit_age_ns = commit_age_ns,
		.changed_paths = changed_paths,
	};
}

fn commandSucceeded(term: std.process.Child.Term) bool {
	return switch (term) {
		.exited => |code| code == 0,
		else => false,
	};
}

/// Reads repository activity through Git only after a slow reconciliation has
/// made the advisory decision relevant.
pub fn detectGitActivity(
	allocator: std.mem.Allocator,
	io: std.Io,
	root_path: []const u8,
	now_ns: i96,
) ProjectActivity {
	const log_result = std.process.run(allocator, io, .{
		.argv = &.{ "git", "log", "-1", "--format=%ct" },
		.cwd = .{ .path = root_path },
		.stdout_limit = .limited(128),
		.stderr_limit = .limited(1024),
	}) catch null;
	defer if (log_result) |result| {
		allocator.free(result.stdout);
		allocator.free(result.stderr);
	};

	const status_result = std.process.run(allocator, io, .{
		.argv = &.{ "git", "status", "--porcelain=v1" },
		.cwd = .{ .path = root_path },
		.stdout_limit = .limited(4 * 1024 * 1024),
		.stderr_limit = .limited(1024),
	}) catch null;
	defer if (status_result) |result| {
		allocator.free(result.stdout);
		allocator.free(result.stderr);
	};

	const log_stdout = if (log_result) |result|
		if (commandSucceeded(result.term)) result.stdout else ""
	else
		"";
	const status_stdout = if (status_result) |result|
		if (commandSucceeded(result.term)) result.stdout else ""
	else
		"";
	return parseGitActivity(now_ns, log_stdout, status_stdout);
}

/// Coordinates pre-search index freshness without coupling the policy to a
/// particular CLI, HTTP, or MCP adapter.
pub const Adapter = struct {
	context: *anyopaque,
	watcher_running: bool,
	reconcile_fn: *const fn (context: *anyopaque) anyerror!void,
	usable_index_fn: *const fn (context: *anyopaque) bool,
};

/// Uses an active watcher as the freshness authority, otherwise reconciles.
/// A failed reconciliation may fall back only to a previously usable index.
pub fn ensureFresh(adapter: Adapter) !Outcome {
	if (adapter.watcher_running) return .watcher_active;
	adapter.reconcile_fn(adapter.context) catch |err| {
		if (adapter.usable_index_fn(adapter.context)) return .stale;
		return err;
	};
	return .reconciled;
}

const FakeAdapter = struct {
	reconcile_calls: usize = 0,
	reconcile_error: ?anyerror = null,
	usable: bool = false,

	fn adapter(self: *FakeAdapter, watcher_running: bool) Adapter {
		return .{
			.context = self,
			.watcher_running = watcher_running,
			.reconcile_fn = reconcile,
			.usable_index_fn = usableIndex,
		};
	}

	fn reconcile(context: *anyopaque) !void {
		const self: *FakeAdapter = @ptrCast(@alignCast(context));
		self.reconcile_calls += 1;
		if (self.reconcile_error) |err| return err;
	}

	fn usableIndex(context: *anyopaque) bool {
		const self: *FakeAdapter = @ptrCast(@alignCast(context));
		return self.usable;
	}
};

test "active watcher skips reconciliation" {
	var fake = FakeAdapter{};
	const outcome = try ensureFresh(fake.adapter(true));
	try std.testing.expectEqual(Outcome.watcher_active, outcome);
	try std.testing.expectEqual(@as(usize, 0), fake.reconcile_calls);
}

test "missing watcher reconciles before search" {
	var fake = FakeAdapter{};
	const outcome = try ensureFresh(fake.adapter(false));
	try std.testing.expectEqual(Outcome.reconciled, outcome);
	try std.testing.expectEqual(@as(usize, 1), fake.reconcile_calls);
}

test "failed reconciliation falls back only when an index is usable" {
	var usable = FakeAdapter{ .reconcile_error = error.EmbeddingUnavailable, .usable = true };
	try std.testing.expectEqual(Outcome.stale, try ensureFresh(usable.adapter(false)));
	try std.testing.expectEqual(@as(usize, 1), usable.reconcile_calls);

	var absent = FakeAdapter{ .reconcile_error = error.EmbeddingUnavailable, .usable = false };
	try std.testing.expectError(error.EmbeddingUnavailable, ensureFresh(absent.adapter(false)));
	try std.testing.expectEqual(@as(usize, 1), absent.reconcile_calls);
}

test "only an explicit watch command may start a watcher" {
	const cases = [_]struct {
		reason: WatcherStartReason,
		allowed: bool,
	}{
		.{ .reason = .explicit_watch_command, .allowed = true },
		.{ .reason = .index_completed, .allowed = false },
		.{ .reason = .update_completed, .allowed = false },
		.{ .reason = .search_auto_index_completed, .allowed = false },
	};
	for (cases) |case| {
		try std.testing.expectEqual(case.allowed, shouldStartWatcher(case.reason));
	}
}

test "watcher advisory requires both a slow update and a recent commit" {
	const day_ns = std.time.ns_per_s * 60 * 60 * 24;
	const cases = [_]struct {
		elapsed_ns: u64,
		commit_age_ns: ?u64,
		changed_paths: usize,
		expected: bool,
	}{
		.{ .elapsed_ns = std.time.ns_per_s, .commit_age_ns = 0, .changed_paths = 3, .expected = false },
		.{ .elapsed_ns = std.time.ns_per_s + 1, .commit_age_ns = 0, .changed_paths = 0, .expected = true },
		.{ .elapsed_ns = std.time.ns_per_s + 1, .commit_age_ns = 7 * day_ns, .changed_paths = 0, .expected = true },
		.{ .elapsed_ns = std.time.ns_per_s + 1, .commit_age_ns = 7 * day_ns + 1, .changed_paths = 2, .expected = false },
		.{ .elapsed_ns = std.time.ns_per_s + 1, .commit_age_ns = null, .changed_paths = 2, .expected = false },
		.{ .elapsed_ns = std.time.ns_per_s + 1, .commit_age_ns = null, .changed_paths = 3, .expected = true },
	};
	for (cases) |case| {
		try std.testing.expectEqual(
			case.expected,
			watcherAdvisory(case.elapsed_ns, .{
				.latest_commit_age_ns = case.commit_age_ns,
				.changed_paths = case.changed_paths,
			}) != null,
		);
	}
}

test "Git activity parser combines commit age with porcelain path count" {
	const now_ns: i96 = 2_000_000 * std.time.ns_per_s;
	const activity = parseGitActivity(
		now_ns,
		"1395200\n",
		" M src/a.zig\n?? src/b.zig\nR  old.zig -> new.zig\n",
	);
	try std.testing.expectEqual(
		@as(?u64, 7 * std.time.ns_per_day),
		activity.latest_commit_age_ns,
	);
	try std.testing.expectEqual(@as(usize, 3), activity.changed_paths);

	const future = parseGitActivity(now_ns, "2000001\n", "");
	try std.testing.expectEqual(@as(?u64, 0), future.latest_commit_age_ns);
	try std.testing.expectEqual(@as(usize, 0), future.changed_paths);
}
