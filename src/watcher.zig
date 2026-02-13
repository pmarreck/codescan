const std = @import("std");
const indexer = @import("indexer.zig");
const plugin = @import("plugin.zig");
const storage = @import("storage.zig");
const embedding = @import("embedding.zig");
const pidfile = @import("pidfile.zig");
const fs_watch = @import("fs_watch.zig");

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
	var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
	const stderr = &stderr_writer.interface;

	// Write PID file if codescan dir is provided
	if (options.codescan_dir) |dir| {
		pidfile.writePid(allocator, dir) catch {};
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

	// Initial full incremental pass
	const initial = try indexer.indexIncremental(
		allocator,
		db,
		root_path,
		registry,
		embedder,
		options.index_options,
	);
	printChangeSummary(stderr, initial);

	while (!stop.load(.acquire)) {
		const result = native_watcher.wait(options.interval_ms) catch .timeout;
		if (stop.load(.acquire)) break;

		// Run incremental index on change or periodic timeout
		const stats = indexer.indexIncremental(
			allocator,
			db,
			root_path,
			registry,
			embedder,
			options.index_options,
		) catch |err| {
			_ = stderr.print("watcher: index error: {s}\n", .{@errorName(err)}) catch {};
			_ = stderr.flush() catch {};
			continue;
		};

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

	// Initial full incremental pass
	const initial = try indexer.indexIncremental(
		allocator,
		db,
		root_path,
		registry,
		embedder,
		options.index_options,
	);
	printChangeSummary(stderr, initial);

	while (!stop.load(.acquire)) {
		std.Thread.sleep(options.interval_ms * std.time.ns_per_ms);
		if (stop.load(.acquire)) break;

		const stats = indexer.indexIncremental(
			allocator,
			db,
			root_path,
			registry,
			embedder,
			options.index_options,
		) catch |err| {
			_ = stderr.print("watcher: index error: {s}\n", .{@errorName(err)}) catch {};
			_ = stderr.flush() catch {};
			continue;
		};

		if (stats.new_files > 0 or stats.modified_files > 0 or stats.deleted_files > 0) {
			printChangeSummary(stderr, stats);
		}
	}
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
	var out: std.io.Writer.Allocating = .init(allocator);
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
	var out: std.io.Writer.Allocating = .init(allocator);
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
