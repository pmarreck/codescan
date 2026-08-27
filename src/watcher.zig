const std = @import("std");
const builtin = @import("builtin");
const io_singleton = @import("io_singleton.zig");
const indexer = @import("indexer.zig");
const index_service = @import("index_service.zig");
const plugin = @import("plugin.zig");
const storage = @import("storage.zig");
const embedding = @import("embedding.zig");
const pidfile = @import("pidfile.zig");
const fs_watch = @import("fs_watch.zig");
const progress = @import("progress.zig");
const syslog = @import("syslog.zig");
const retirement = @import("retirement.zig");

pub const failure_log_filename = "watcher-error.log";
pub const startup_ready_filename = "watcher-ready";

/// A watcher owns its PID before it has completed its first incremental pass.
/// The launcher must wait for this state, rather than confusing a claimed PID
/// with an initialized watcher.
pub const StartupState = enum {
	pending,
	ready,
	failed,
};

pub fn startupState(pid_claimed: bool, ready_marker: bool, failure_record: bool) StartupState {
	if (failure_record) return .failed;
	// Windows watchers intentionally have no PID file. A marker is written only
	// after initialization succeeds, and the launcher clears stale markers before
	// it spawns, so it is the portable readiness authority.
	if (ready_marker) return .ready;
	_ = pid_claimed;
	return .pending;
}

/// Returns the project-local path that contains the most recent daemon failure.
pub fn failureLogPath(allocator: std.mem.Allocator, codescan_dir: []const u8) ![]u8 {
	return std.fs.path.join(allocator, &.{ codescan_dir, failure_log_filename });
}

/// Reports whether the project has a retained daemon-failure record.
pub fn failureRecordExists(allocator: std.mem.Allocator, codescan_dir: []const u8) bool {
	const log_path = failureLogPath(allocator, codescan_dir) catch return false;
	defer allocator.free(log_path);
	std.Io.Dir.cwd().access(io_singleton.getOrInit(), log_path, .{}) catch return false;
	return true;
}

/// Removes a previous daemon failure before a new watcher attempt. A stale
/// record must not be reported as the new child's startup result.
pub fn removeFailureRecord(allocator: std.mem.Allocator, codescan_dir: []const u8) void {
	const log_path = failureLogPath(allocator, codescan_dir) catch return;
	defer allocator.free(log_path);
	std.Io.Dir.cwd().deleteFile(io_singleton.getOrInit(), log_path) catch {};
}

fn startupReadyPath(allocator: std.mem.Allocator, codescan_dir: []const u8) ![]u8 {
	return std.fs.path.join(allocator, &.{ codescan_dir, startup_ready_filename });
}

/// Reports whether this watcher completed initialization after claiming its PID.
pub fn startupReadyExists(allocator: std.mem.Allocator, codescan_dir: []const u8) bool {
	const path = startupReadyPath(allocator, codescan_dir) catch return false;
	defer allocator.free(path);
	std.Io.Dir.cwd().access(io_singleton.getOrInit(), path, .{}) catch return false;
	return true;
}

/// Marks a watcher ready only after its first incremental pass succeeded.
pub fn writeStartupReady(allocator: std.mem.Allocator, codescan_dir: []const u8) !void {
	const path = try startupReadyPath(allocator, codescan_dir);
	defer allocator.free(path);
	const file = try std.Io.Dir.cwd().createFile(io_singleton.getOrInit(), path, .{ .truncate = true });
	defer file.close(io_singleton.getOrInit());
	try file.writeStreamingAll(io_singleton.getOrInit(), "ready\n");
}

/// Removes the ready signal when a watcher exits or before a new attempt.
pub fn removeStartupReady(allocator: std.mem.Allocator, codescan_dir: []const u8) void {
	const path = startupReadyPath(allocator, codescan_dir) catch return;
	defer allocator.free(path);
	std.Io.Dir.cwd().deleteFile(io_singleton.getOrInit(), path) catch {};
}

/// Replaces the project's last daemon-failure record with a bounded message.
/// A separate single-record file keeps a stopped background watcher diagnosable
/// without letting repeated failures grow project state without limit.
pub fn writeFailureRecord(
	allocator: std.mem.Allocator,
	codescan_dir: []const u8,
	root_path: []const u8,
	reason: []const u8,
) !void {
	const log_path = try failureLogPath(allocator, codescan_dir);
	defer allocator.free(log_path);

	var record_buf: [4096]u8 = undefined;
	const project = root_path[0..@min(root_path.len, 1024)];
	const detail = reason[0..@min(reason.len, 2800)];
	const record = try std.fmt.bufPrint(
		&record_buf,
		"watcher failure\nproject: {s}\nreason: {s}\n",
		.{ project, detail },
	);
	const file = try std.Io.Dir.cwd().createFile(io_singleton.getOrInit(), log_path, .{ .truncate = true });
	defer file.close(io_singleton.getOrInit());
	try file.writeStreamingAll(io_singleton.getOrInit(), record);
}

/// Formats a system-log startup event with the process identifier that owns
/// the watcher, allowing the event to be matched to status and a PID file.
fn startedMessage(buf: []u8, backend: []const u8) []const u8 {
	const pid: i64 = if (comptime builtin.os.tag == .windows)
		@intCast(std.os.windows.GetCurrentProcessId())
	else
		@intCast(std.c.getpid());
	return std.fmt.bufPrint(buf, "watcher started ({s}, PID {d})", .{ backend, pid }) catch "watcher started";
}

pub const WatchOptions = struct {
	interval_ms: u64 = 2000,
	codescan_dir: ?[]const u8 = null,
	/// Resolved by the caller through the application service, so a watcher
	/// pass applies exactly the filters and ignores an explicit update would.
	index_request: index_service.Request,
	/// How long the watcher may sit idle before standing down. Null never
	/// retires, which a supervised service unit requires.
	idle_limit_ns: ?u64 = null,
	/// Injected wall clock, so retirement logic is exercised without waiting.
	now_fn: *const fn () i128 = systemNowNs,
};

/// Default clock for `WatchOptions.now_fn`.
pub fn systemNowNs() i128 {
	return std.Io.Clock.real.now(io_singleton.getOrInit()).nanoseconds;
}

/// Shared retirement bookkeeping for both watch loops. Owns the idle origin and
/// the in-progress flag, so the two loops cannot drift on the race that matters:
/// a retirement decision must never land while an index pass is running.
const RetirementTracker = struct {
	options: WatchOptions,
	started_ns: i128,
	last_activity_ns: ?i128 = null,
	index_in_progress: bool = false,

	fn init(options: WatchOptions) RetirementTracker {
		return .{ .options = options, .started_ns = options.now_fn() };
	}

	fn beginIndex(self: *RetirementTracker) void {
		self.index_in_progress = true;
	}

	/// Records the outcome of a pass. Only a pass that actually changed the
	/// index resets the countdown — counting no-op polls would make the idle
	/// limit unreachable.
	fn endIndex(self: *RetirementTracker, stats: indexer.IncrementalStats) void {
		self.index_in_progress = false;
		if (retirement.countsAsActivity(.{
			.new_files = stats.new_files,
			.modified_files = stats.modified_files,
			.deleted_files = stats.deleted_files,
			.recovered_files = stats.recovered_files,
		})) {
			self.last_activity_ns = self.options.now_fn();
		}
	}

	fn abandonIndex(self: *RetirementTracker) void {
		self.index_in_progress = false;
	}

	fn decide(self: *const RetirementTracker) retirement.Decision {
		return retirement.shouldRetire(.{
			.now_ns = self.options.now_fn(),
			.last_index_ns = self.last_activity_ns,
			.started_ns = self.started_ns,
			.idle_limit_ns = self.options.idle_limit_ns,
			.index_in_progress = self.index_in_progress,
		});
	}
};

const initial_retry_base_delay_ns: u64 = 250 * std.time.ns_per_ms;

/// Returns the next bounded exponential delay after a transient first-pass
/// failure. Null means the error is terminal or the retry budget is spent.
fn initialRetryDelay(err: anyerror, failed_attempts: usize) ?u64 {
	const transient = switch (err) {
		error.HttpStatus,
		error.ConnectionRefused,
		error.ConnectionResetByPeer,
		error.Timeout,
		=> true,
		else => false,
	};
	if (!transient) return null;
	return switch (failed_attempts) {
		0 => initial_retry_base_delay_ns,
		1 => 2 * initial_retry_base_delay_ns,
		else => null,
	};
}

/// Gives a transiently busy embedding server two chances to recover before a
/// watcher declares startup failure. The retry policy stays here, separate from
/// the index service's pure application operation.
fn executeInitialIncrementalWithRetry(
	allocator: std.mem.Allocator,
	db: storage.Db,
	root_path: []const u8,
	registry: plugin.Registry,
	embedder: embedding.Embedder,
	options: WatchOptions,
	tracker: *RetirementTracker,
	stderr: *std.Io.Writer,
) !indexer.IncrementalStats {
	var failed_attempts: usize = 0;
	while (true) {
		tracker.beginIndex();
		const stats = (index_service.execute(
			allocator,
			db,
			registry,
			embedder,
			options.index_request,
		) catch |err| {
			tracker.abandonIndex();
			const delay_ns = initialRetryDelay(err, failed_attempts) orelse return err;
			failed_attempts += 1;
			const delay_ms = delay_ns / std.time.ns_per_ms;
			_ = stderr.print(
				"watcher: initial index error: {s}; retrying in {d}ms ({d}/2)\n",
				.{ @errorName(err), delay_ms, failed_attempts },
			) catch {};
			_ = stderr.flush() catch {};
			var message_buf: [256]u8 = undefined;
			const message = std.fmt.bufPrint(
				&message_buf,
				"initial index error: {s}; retrying in {d}ms ({d}/2)",
				.{ @errorName(err), delay_ms, failed_attempts },
			) catch "initial index error; retrying";
			syslog.logWithRoot(syslog.LOG_WARNING, root_path, message);
			io_singleton.getOrInit().sleep(std.Io.Duration.fromNanoseconds(delay_ns), .awake) catch {};
			continue;
		}).incremental;
		tracker.endIndex(stats);
		return stats;
	}
}

/// Announces retirement on both the terminal and the system log. A watcher that
/// simply vanished would be indistinguishable from one that crashed, which is
/// the same false-success shape as a daemon that dies with its stdio closed.
fn announceRetirement(stderr: *std.Io.Writer, root_path: []const u8, idle_limit_ns: u64) void {
	var limit_buf: [64]u8 = undefined;
	const limit = retirement.formatIdleLimit(&limit_buf, idle_limit_ns);
	_ = stderr.print(
		"watcher: retiring after {s} with no index activity (set watcher_idle_timeout=never to disable)\n",
		.{limit},
	) catch {};
	_ = stderr.flush() catch {};
	var buf: [256]u8 = undefined;
	const msg = std.fmt.bufPrint(
		&buf,
		"watcher retiring: idle {s} with no index activity",
		.{limit},
	) catch "watcher retiring: idle";
	syslog.logWithRoot(syslog.LOG_NOTICE, root_path, msg);
}


/// Runs the incremental indexer using OS-native file watching (FSEvents/fanotify),
/// falling back to polling on unsupported platforms or init failure.
/// Blocks until interrupted via stop flag.
pub fn watchLoop(
	allocator: std.mem.Allocator,
	db: storage.Db,
	root_path: []const u8,
	registry: plugin.Registry,
	embedder: embedding.Embedder,
	options: WatchOptions,
	stop: *const std.atomic.Value(bool),
) !void {
	var stderr_buf: [4096]u8 = undefined;
	var stderr_writer = io_singleton.stderrWriter(&stderr_buf);
	const stderr = &stderr_writer.interface;

	// Acquire PID file — reject if another watcher is already running
	if (options.codescan_dir) |dir| {
		pidfile.tryAcquirePid(allocator, dir) catch |err| switch (err) {
			error.WatcherAlreadyRunning => {
				if (pidfile.readAndCheckPid(allocator, dir) catch null) |existing_pid| {
					_ = stderr.print("error: watcher already running for this directory (PID {d})\n", .{existing_pid}) catch {};
				} else {
					_ = stderr.print("error: watcher already running for this directory\n", .{}) catch {};
				}
				_ = stderr.flush() catch {};
				return error.WatcherAlreadyRunning;
			},
			else => {}, // Non-critical: proceed without pidfile
		};
		removeStartupReady(allocator, dir);
	}
	defer if (options.codescan_dir) |dir| pidfile.removePid(allocator, dir);
	defer if (options.codescan_dir) |dir| removeStartupReady(allocator, dir);

	// Try native watcher; fall back to polling on failure
	var native_watcher = fs_watch.FsWatch.init(allocator) catch {
		return watchLoopPolling(allocator, db, root_path, registry, embedder, options, stop, stderr);
	};
	defer native_watcher.deinit(allocator);

	native_watcher.setWatchPaths(allocator, &.{root_path}) catch {
		return watchLoopPolling(allocator, db, root_path, registry, embedder, options, stop, stderr);
	};

	_ = stderr.print("Watching {s} (native events, Ctrl-C to stop)\n", .{root_path}) catch {};
	_ = stderr.flush() catch {};
	var start_buf: [128]u8 = undefined;
	syslog.logWithRoot(syslog.LOG_NOTICE, root_path, startedMessage(&start_buf, "native events"));

	// Set up progress file (symlink to TMPDIR)
	const progress_path = progress.setup(allocator, options.codescan_dir orelse ".");
	defer progress.clear(allocator, progress_path, options.codescan_dir);

	// Snapshot config mtime so we can detect edits
	const config_path = configPathFromDir(allocator, options.codescan_dir);
	defer if (config_path) |p| allocator.free(p);
	var config_mtime = getFileMtime(config_path);

	// Initial full incremental pass
	var tracker = RetirementTracker.init(options);
	progress.write(progress_path, "indexing...");
	const initial = try executeInitialIncrementalWithRetry(
		allocator,
		db,
		root_path,
		registry,
		embedder,
		options,
		&tracker,
		stderr,
	);
	progress.write(progress_path, "idle");
	printChangeSummary(stderr, initial);
	if (options.codescan_dir) |dir| try writeStartupReady(allocator, dir);

	const max_consecutive_errors = 5;
	var consecutive_errors: u32 = 0;

	while (!stop.load(.acquire)) {
		const result = native_watcher.wait(options.interval_ms) catch .timeout;
		if (stop.load(.acquire)) break;

		// Check if config file was edited
		if (configChanged(config_path, &config_mtime)) {
			_ = stderr.print("watcher: config changed, stopping (restart to apply new settings)\n", .{}) catch {};
			_ = stderr.flush() catch {};
			syslog.logWithRoot(syslog.LOG_NOTICE, root_path, "watcher stopping: config changed");
			return;
		}

		// Run incremental index on change or periodic timeout
		progress.write(progress_path, "indexing...");
		tracker.beginIndex();
		const stats = (index_service.execute(
			allocator,
			db,
			registry,
			embedder,
			options.index_request,
		) catch |err| {
			tracker.abandonIndex();
			consecutive_errors += 1;
			_ = stderr.print("watcher: index error: {s} ({d}/{d})\n", .{ @errorName(err), consecutive_errors, max_consecutive_errors }) catch {};
			_ = stderr.flush() catch {};
			var msg_buf_w: [256]u8 = undefined;
			const msg_w = std.fmt.bufPrint(&msg_buf_w, "index error: {s} ({d}/{d})", .{ @errorName(err), consecutive_errors, max_consecutive_errors }) catch "index error (format failed)";
			if (options.codescan_dir) |dir| {
				writeFailureRecord(allocator, dir, root_path, msg_w) catch {};
			}
			syslog.logWithRoot(syslog.LOG_WARNING, root_path, msg_w);
			if (consecutive_errors >= max_consecutive_errors) {
				_ = stderr.print("watcher: too many consecutive errors, stopping\n", .{}) catch {};
				_ = stderr.flush() catch {};
				syslog.logWithRoot(syslog.LOG_ERR, root_path, "watcher stopping: too many consecutive errors");
				return;
			}
			continue;
		}).incremental;
		tracker.endIndex(stats);
		consecutive_errors = 0;
		progress.write(progress_path, "idle");

		if (stats.new_files > 0 or stats.modified_files > 0 or stats.deleted_files > 0) {
			printChangeSummary(stderr, stats);
		}

		// Retirement is decided only here, outside the index call, so the
		// in-progress flag can never be observed mid-pass.
		if (tracker.decide() == .retire) {
			announceRetirement(stderr, root_path, options.idle_limit_ns.?);
			return;
		}

		// Suppress unused variable warning
		_ = result;
	}
}

/// Polling fallback: uses Thread.sleep between incremental index passes.
fn watchLoopPolling(
	allocator: std.mem.Allocator,
	db: storage.Db,
	root_path: []const u8,
	registry: plugin.Registry,
	embedder: embedding.Embedder,
	options: WatchOptions,
	stop: *const std.atomic.Value(bool),
	stderr: *std.Io.Writer,
) !void {
	_ = stderr.print("Watching {s} (poll every {d}ms, Ctrl-C to stop)\n", .{
		root_path,
		options.interval_ms,
	}) catch {};
	_ = stderr.flush() catch {};
	var start_buf: [128]u8 = undefined;
	syslog.logWithRoot(syslog.LOG_NOTICE, root_path, startedMessage(&start_buf, "polling"));

	// Set up progress file (symlink to TMPDIR)
	const progress_path_poll = progress.setup(allocator, options.codescan_dir orelse ".");
	defer progress.clear(allocator, progress_path_poll, options.codescan_dir);

	// Snapshot config mtime so we can detect edits
	const config_path = configPathFromDir(allocator, options.codescan_dir);
	defer if (config_path) |p| allocator.free(p);
	var config_mtime = getFileMtime(config_path);

	// Initial full incremental pass
	var tracker = RetirementTracker.init(options);
	progress.write(progress_path_poll, "indexing...");
	const initial = try executeInitialIncrementalWithRetry(
		allocator,
		db,
		root_path,
		registry,
		embedder,
		options,
		&tracker,
		stderr,
	);
	progress.write(progress_path_poll, "idle");
	printChangeSummary(stderr, initial);
	if (options.codescan_dir) |dir| try writeStartupReady(allocator, dir);

	const max_consecutive_errors = 5;
	var consecutive_errors: u32 = 0;

	while (!stop.load(.acquire)) {
		io_singleton.getOrInit().sleep(std.Io.Duration.fromNanoseconds((options.interval_ms * std.time.ns_per_ms)), .awake) catch {};
		if (stop.load(.acquire)) break;

		// Check if config file was edited
		if (configChanged(config_path, &config_mtime)) {
			_ = stderr.print("watcher: config changed, stopping (restart to apply new settings)\n", .{}) catch {};
			_ = stderr.flush() catch {};
			syslog.logWithRoot(syslog.LOG_NOTICE, root_path, "watcher stopping: config changed");
			return;
		}

		progress.write(progress_path_poll, "indexing...");
		tracker.beginIndex();
		const stats = (index_service.execute(
			allocator,
			db,
			registry,
			embedder,
			options.index_request,
		) catch |err| {
			tracker.abandonIndex();
			consecutive_errors += 1;
			progress.write(progress_path_poll, "error");
			_ = stderr.print("watcher: index error: {s} ({d}/{d})\n", .{ @errorName(err), consecutive_errors, max_consecutive_errors }) catch {};
			_ = stderr.flush() catch {};
			var msg_buf_p: [256]u8 = undefined;
			const msg_p = std.fmt.bufPrint(&msg_buf_p, "index error: {s} ({d}/{d})", .{ @errorName(err), consecutive_errors, max_consecutive_errors }) catch "index error (format failed)";
			if (options.codescan_dir) |dir| {
				writeFailureRecord(allocator, dir, root_path, msg_p) catch {};
			}
			syslog.logWithRoot(syslog.LOG_WARNING, root_path, msg_p);
			if (consecutive_errors >= max_consecutive_errors) {
				_ = stderr.print("watcher: too many consecutive errors, stopping\n", .{}) catch {};
				_ = stderr.flush() catch {};
				syslog.logWithRoot(syslog.LOG_ERR, root_path, "watcher stopping: too many consecutive errors");
				return;
			}
			continue;
		}).incremental;
		tracker.endIndex(stats);
		consecutive_errors = 0;
		progress.write(progress_path_poll, "idle");

		if (stats.new_files > 0 or stats.modified_files > 0 or stats.deleted_files > 0) {
			printChangeSummary(stderr, stats);
		}

		// Decided outside the index call, so the in-progress flag can never be
		// observed mid-pass.
		if (tracker.decide() == .retire) {
			announceRetirement(stderr, root_path, options.idle_limit_ns.?);
			return;
		}
	}
}

/// Build the config file path from the .codescan directory, or null if unavailable.
fn configPathFromDir(allocator: std.mem.Allocator, codescan_dir: ?[]const u8) ?[]u8 {
	const dir = codescan_dir orelse return null;
	return std.fs.path.join(allocator, &.{ dir, "config" }) catch return null;
}

/// Get a file's mtime (nanoseconds), or null if the file doesn't exist / can't be stat'd.
fn getFileMtime(path: ?[]const u8) ?i128 {
	const p = path orelse return null;
	const file = std.Io.Dir.cwd().openFile(io_singleton.getOrInit(), p, .{}) catch return null;
	defer file.close(io_singleton.getOrInit());
	const stat = file.stat(io_singleton.getOrInit()) catch return null;
	return stat.mtime.nanoseconds;
}

/// Returns true if the config file's mtime differs from the stored value, updating it in place.
fn configChanged(config_path: ?[]const u8, stored_mtime: *?i128) bool {
	const current = getFileMtime(config_path);
	if (stored_mtime.* == null and current == null) return false;
	if (stored_mtime.* == null and current != null) {
		// Config file was created
		stored_mtime.* = current;
		return true;
	}
	if (stored_mtime.* != null and current == null) {
		// Config file was deleted — not a "change" worth restarting for
		return false;
	}
	if (stored_mtime.*.? != current.?) {
		stored_mtime.* = current;
		return true;
	}
	return false;
}

fn printChangeSummary(writer: *std.Io.Writer, stats: indexer.IncrementalStats) void {
	const total_changed = stats.new_files + stats.modified_files + stats.deleted_files + stats.recovered_files;
	if (total_changed == 0 and stats.unchanged_files > 0) {
		_ = writer.print("Up to date ({d} files, {d} symbols)\n", .{
			stats.unchanged_files,
			stats.symbols,
		}) catch {};
	} else {
		_ = writer.print("+{d} new, ~{d} modified, -{d} deleted, ={d} unchanged, !{d} recovered ({d} symbols)\n", .{
			stats.new_files,
			stats.modified_files,
			stats.deleted_files,
			stats.unchanged_files,
			stats.recovered_files,
			stats.symbols,
		}) catch {};
	}
	_ = writer.flush() catch {};
}

test "printChangeSummary formats correctly" {
	const allocator = std.testing.allocator;
	var out: std.Io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	printChangeSummary(&out.writer, .{
		.new_files = 2,
		.modified_files = 1,
		.deleted_files = 0,
		.unchanged_files = 10,
		.recovered_files = 0,
		.symbols = 5,
	});

	const text = try out.toOwnedSlice();
	defer allocator.free(text);

	try std.testing.expect(std.mem.indexOf(u8, text, "+2 new") != null);
	try std.testing.expect(std.mem.indexOf(u8, text, "~1 modified") != null);
	try std.testing.expect(std.mem.indexOf(u8, text, "5 symbols") != null);
}

test "printChangeSummary shows up to date" {
	const allocator = std.testing.allocator;
	var out: std.Io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	printChangeSummary(&out.writer, .{
		.new_files = 0,
		.modified_files = 0,
		.deleted_files = 0,
		.unchanged_files = 10,
		.recovered_files = 0,
		.symbols = 0,
	});

	const text = try out.toOwnedSlice();
	defer allocator.free(text);

	try std.testing.expect(std.mem.indexOf(u8, text, "Up to date") != null);
}

test "writeFailureRecord replaces the prior daemon failure in the project state" {
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();

	try tmp.dir.createDirPath(io_singleton.getOrInit(), ".codescan");
	const codescan_dir = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".codescan", allocator);
	defer allocator.free(codescan_dir);

	try writeFailureRecord(allocator, codescan_dir, "/project", "first failure");
	try writeFailureRecord(allocator, codescan_dir, "/project", "second failure");

	const saved = try tmp.dir.readFileAlloc(io_singleton.getOrInit(), ".codescan/watcher-error.log", allocator, .limited(1024));
	defer allocator.free(saved);
	try std.testing.expect(std.mem.indexOf(u8, saved, "second failure") != null);
	try std.testing.expect(std.mem.indexOf(u8, saved, "first failure") == null);
	try std.testing.expect(std.mem.indexOf(u8, saved, "project: /project") != null);
	try std.testing.expect(failureRecordExists(allocator, codescan_dir));
}

test "startupState does not mistake a claimed PID for a ready watcher" {
	const cases = [_]struct {
		pid_claimed: bool,
		ready_marker: bool,
		failure_record: bool,
		want: StartupState,
	}{
		.{ .pid_claimed = false, .ready_marker = false, .failure_record = false, .want = .pending },
		.{ .pid_claimed = true, .ready_marker = false, .failure_record = false, .want = .pending },
		.{ .pid_claimed = false, .ready_marker = true, .failure_record = false, .want = .ready },
		.{ .pid_claimed = true, .ready_marker = true, .failure_record = false, .want = .ready },
		.{ .pid_claimed = true, .ready_marker = false, .failure_record = true, .want = .failed },
		.{ .pid_claimed = true, .ready_marker = true, .failure_record = true, .want = .failed },
	};

	for (cases) |case| {
		try std.testing.expectEqual(case.want, startupState(case.pid_claimed, case.ready_marker, case.failure_record));
	}
}

test "initialRetryDelay backs off only transient startup failures" {
	const cases = [_]struct {
		err: anyerror,
		failed_attempts: usize,
		want: ?u64,
	}{
		.{ .err = error.HttpStatus, .failed_attempts = 0, .want = 250 * std.time.ns_per_ms },
		.{ .err = error.ConnectionRefused, .failed_attempts = 1, .want = 500 * std.time.ns_per_ms },
		.{ .err = error.Timeout, .failed_attempts = 2, .want = null },
		.{ .err = error.OutOfMemory, .failed_attempts = 0, .want = null },
	};

	for (cases) |case| {
		try std.testing.expectEqual(case.want, initialRetryDelay(case.err, case.failed_attempts));
	}
}

test "startedMessage reports the watcher PID" {
	var buf: [256]u8 = undefined;
	const message = startedMessage(&buf, "native events");
	try std.testing.expect(std.mem.indexOf(u8, message, "watcher started") != null);
	try std.testing.expect(std.mem.indexOf(u8, message, "PID ") != null);
}

test "watcher source contains syslog calls at all error paths" {
    // An exact count, deliberately: adding or removing a log call should
    // require saying so out loud rather than passing unnoticed. A watcher that
    // stops without leaving a reason in the system log is indistinguishable
    // from one that crashed.
    //
	// 10 = start (native, polling), initial retry, config-changed stop (x2),
	// index error (x2), too-many-errors stop (x2), and retirement (shared by
	// both loops).
    const src = @embedFile("watcher.zig");
    var count: usize = 0;
    var i: usize = 0;
    const needle = "syslog." ++ "logWithRoot(";
    while (std.mem.indexOfPos(u8, src, i, needle)) |pos| : (i = pos + 1) {
        count += 1;
    }
	try std.testing.expectEqual(@as(usize, 10), count);
}
