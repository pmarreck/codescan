const std = @import("std");
const cli = @import("cli.zig");
const io_singleton = @import("io_singleton.zig");
const pidfile = @import("pidfile.zig");
const root_report = @import("root_report.zig");

pub fn run(
	allocator: std.mem.Allocator,
	format: cli.OutputFormat,
	writer: *std.Io.Writer,
	find_info: anytype,
) !void {
	const cwd_path = try std.Io.Dir.cwd().realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
	defer allocator.free(cwd_path);

	const info_opt = find_info(allocator, cwd_path) catch |err| {
		if (format == .json) {
			try writer.print("{{\"error\":\"{s}\"}}\n", .{@errorName(err)});
		} else {
			try writer.print("error: {s}\n", .{@errorName(err)});
		}
		return err;
	};

	const info = info_opt orelse {
		if (format == .json) {
			const rendered = try root_report.missing(allocator, cwd_path);
			defer allocator.free(rendered);
			try writer.writeAll(rendered);
			try writer.writeAll("\n");
		} else {
			try writer.print("error: no .codescan/ directory found walking up from {s}\n", .{cwd_path});
		}
		try writer.flush();
		std.process.exit(1);
	};
	defer {
		allocator.free(info.project_root);
		allocator.free(info.codescan_dir);
	}

	if (format == .human) {
		try writer.print("{s}\n", .{info.project_root});
		return;
	}

	// JSON output: include codescan_dir, db_path, watcher pid/status, walk_up_steps
	const db_path = try std.fs.path.join(allocator, &.{ info.codescan_dir, "index.sqlite3" });
	defer allocator.free(db_path);

	const pid_opt = pidfile.readAndCheckPid(allocator, info.codescan_dir) catch null;
	const watcher_status: []const u8 = if (pidfile.isWatcherRunning(allocator, info.codescan_dir))
		"running"
	else if (pid_opt != null)
		"stale"
	else
		"stopped";

	const rendered = try root_report.found(allocator, .{
		.project_root = info.project_root, .root = info.codescan_dir, .db_path = db_path,
		.watcher_pid = if (pid_opt) |pid| @intCast(pid) else null,
		.watcher_status = watcher_status, .walk_up_steps = info.walk_up_steps,
	});
	defer allocator.free(rendered);
	try writer.writeAll(rendered);
	try writer.writeAll("\n");
}
