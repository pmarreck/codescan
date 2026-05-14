const std = @import("std");
const io_singleton = @import("io_singleton.zig");
const indexer = @import("indexer.zig");
const plugin = @import("plugin.zig");
const storage = @import("storage.zig");
const embedding = @import("embedding.zig");
const pidfile = @import("pidfile.zig");
const fs_watch = @import("fs_watch.zig");
const progress = @import("progress.zig");
const syslog = @import("syslog.zig");

pub const WatchOptions = struct {
	interval_ms: u64 = 2000,
	codescan_dir: ?[]const u8 = null,
	index_options: indexer.Options,
};

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
	var stderr_writer = std.Io.File.stderr().writer(io_singleton.getOrInit(), &stderr_buf);
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
	}
	defer if (options.codescan_dir) |dir| pidfile.removePid(allocator, dir);

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
	syslog.logWithRoot(syslog.LOG_NOTICE, root_path, "watcher started (native events)");

	// Set up progress file (symlink to TMPDIR)
	const progress_path = progress.setup(allocator, options.codescan_dir orelse ".");
	defer progress.clear(allocator, progress_path, options.codescan_dir);

	// Snapshot config mtime so we can detect edits
	const config_path = configPathFromDir(allocator, options.codescan_dir);
	defer if (config_path) |p| allocator.free(p);
	var config_mtime = getFileMtime(config_path);

	// Initial full incremental pass
	progress.write(progress_path, "indexing...");
	const initial = try indexer.indexIncremental(
		allocator,
		db,
		root_path,
		registry,
		embedder,
		options.index_options,
	);
	progress.write(progress_path, "idle");
	printChangeSummary(stderr, initial);

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
		const stats = indexer.indexIncremental(
			allocator,
			db,
			root_path,
			registry,
			embedder,
			options.index_options,
		) catch |err| {
			consecutive_errors += 1;
			_ = stderr.print("watcher: index error: {s} ({d}/{d})\n", .{ @errorName(err), consecutive_errors, max_consecutive_errors }) catch {};
			_ = stderr.flush() catch {};
			var msg_buf_w: [256]u8 = undefined;
			const msg_w = std.fmt.bufPrint(&msg_buf_w, "index error: {s} ({d}/{d})", .{ @errorName(err), consecutive_errors, max_consecutive_errors }) catch "index error (format failed)";
			syslog.logWithRoot(syslog.LOG_WARNING, root_path, msg_w);
			if (consecutive_errors >= max_consecutive_errors) {
				_ = stderr.print("watcher: too many consecutive errors, stopping\n", .{}) catch {};
				_ = stderr.flush() catch {};
				syslog.logWithRoot(syslog.LOG_ERR, root_path, "watcher stopping: too many consecutive errors");
				return;
			}
			continue;
		};
		consecutive_errors = 0;
		progress.write(progress_path, "idle");

		if (stats.new_files > 0 or stats.modified_files > 0 or stats.deleted_files > 0) {
			printChangeSummary(stderr, stats);
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
	syslog.logWithRoot(syslog.LOG_NOTICE, root_path, "watcher started (polling)");

	// Set up progress file (symlink to TMPDIR)
	const progress_path_poll = progress.setup(allocator, options.codescan_dir orelse ".");
	defer progress.clear(allocator, progress_path_poll, options.codescan_dir);

	// Snapshot config mtime so we can detect edits
	const config_path = configPathFromDir(allocator, options.codescan_dir);
	defer if (config_path) |p| allocator.free(p);
	var config_mtime = getFileMtime(config_path);

	// Initial full incremental pass
	progress.write(progress_path_poll, "indexing...");
	const initial = try indexer.indexIncremental(
		allocator,
		db,
		root_path,
		registry,
		embedder,
		options.index_options,
	);
	progress.write(progress_path_poll, "idle");
	printChangeSummary(stderr, initial);

	const max_consecutive_errors = 5;
	var consecutive_errors: u32 = 0;

	while (!stop.load(.acquire)) {
		std.Thread.sleep(options.interval_ms * std.time.ns_per_ms);
		if (stop.load(.acquire)) break;

		// Check if config file was edited
		if (configChanged(config_path, &config_mtime)) {
			_ = stderr.print("watcher: config changed, stopping (restart to apply new settings)\n", .{}) catch {};
			_ = stderr.flush() catch {};
			syslog.logWithRoot(syslog.LOG_NOTICE, root_path, "watcher stopping: config changed");
			return;
		}

		progress.write(progress_path_poll, "indexing...");
		const stats = indexer.indexIncremental(
			allocator,
			db,
			root_path,
			registry,
			embedder,
			options.index_options,
		) catch |err| {
			consecutive_errors += 1;
			progress.write(progress_path_poll, "error");
			_ = stderr.print("watcher: index error: {s} ({d}/{d})\n", .{ @errorName(err), consecutive_errors, max_consecutive_errors }) catch {};
			_ = stderr.flush() catch {};
			var msg_buf_p: [256]u8 = undefined;
			const msg_p = std.fmt.bufPrint(&msg_buf_p, "index error: {s} ({d}/{d})", .{ @errorName(err), consecutive_errors, max_consecutive_errors }) catch "index error (format failed)";
			syslog.logWithRoot(syslog.LOG_WARNING, root_path, msg_p);
			if (consecutive_errors >= max_consecutive_errors) {
				_ = stderr.print("watcher: too many consecutive errors, stopping\n", .{}) catch {};
				_ = stderr.flush() catch {};
				syslog.logWithRoot(syslog.LOG_ERR, root_path, "watcher stopping: too many consecutive errors");
				return;
			}
			continue;
		};
		consecutive_errors = 0;
		progress.write(progress_path_poll, "idle");

		if (stats.new_files > 0 or stats.modified_files > 0 or stats.deleted_files > 0) {
			printChangeSummary(stderr, stats);
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
	return stat.mtime;
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
	const total_changed = stats.new_files + stats.modified_files + stats.deleted_files;
	if (total_changed == 0 and stats.unchanged_files > 0) {
		_ = writer.print("Up to date ({d} files, {d} symbols)\n", .{
			stats.unchanged_files,
			stats.symbols,
		}) catch {};
	} else {
		_ = writer.print("+{d} new, ~{d} modified, -{d} deleted, ={d} unchanged ({d} symbols)\n", .{
			stats.new_files,
			stats.modified_files,
			stats.deleted_files,
			stats.unchanged_files,
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
		.symbols = 0,
	});

	const text = try out.toOwnedSlice();
	defer allocator.free(text);

	try std.testing.expect(std.mem.indexOf(u8, text, "Up to date") != null);
}

test "watcher source contains syslog calls at all error paths" {
    const src = @embedFile("watcher.zig");
    var count: usize = 0;
    var i: usize = 0;
    const needle = "syslog." ++ "logWithRoot(";
    while (std.mem.indexOfPos(u8, src, i, needle)) |pos| : (i = pos + 1) {
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 8), count);
}
