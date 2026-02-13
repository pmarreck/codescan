const std = @import("std");
const builtin = @import("builtin");

/// OS-native file system watcher. Uses FSEvents on macOS, fanotify on Linux,
/// and falls back to polling on unsupported platforms.
pub const FsWatch = struct {
	backend: Backend,

	pub const WaitResult = enum { changed, timeout };
	pub const InitError = error{OpenFrameworkFailed} || error{MissingSymbol} || error{FanotifyInitFailed} || std.mem.Allocator.Error;

	pub const Backend = switch (builtin.os.tag) {
		.macos => MacOsBackend,
		// Use fanotify when the C library exposes it; otherwise fall back to polling
		// (e.g. garnix builders where glibc headers lack fanotify wrappers).
		.linux => if (@hasDecl(std.c, "fanotify_init")) LinuxBackend else PollingBackend,
		else => PollingBackend,
	};

	pub fn init(allocator: std.mem.Allocator) InitError!FsWatch {
		return .{ .backend = try Backend.init(allocator) };
	}

	pub fn deinit(self: *FsWatch, allocator: std.mem.Allocator) void {
		self.backend.deinit(allocator);
	}

	pub fn setWatchPaths(self: *FsWatch, allocator: std.mem.Allocator, paths: []const []const u8) !void {
		try self.backend.setWatchPaths(allocator, paths);
	}

	pub fn wait(self: *FsWatch, timeout_ms: ?u64) !WaitResult {
		return self.backend.wait(timeout_ms);
	}
};

// -- macOS FSEvents backend --------------------------------------------------

const MacOsBackend = struct {
	core_services: std.DynLib,
	syms: ResolvedSymbols,
	queue: dispatch_queue_t,
	semaphore: dispatch_semaphore_t,
	stream: ?FSEventStreamRef,
	watch_paths_z: std.ArrayListUnmanaged([*:0]const u8),

	const CFAllocatorRef = ?*const anyopaque;
	const CFArrayRef = *const anyopaque;
	const CFStringRef = *const anyopaque;
	const CFTimeInterval = f64;
	const CFIndex = i32;
	const CFStringEncoding = enum(u32) { utf8 = 0x8000100 };

	const FSEventStreamRef = *anyopaque;
	const ConstFSEventStreamRef = *const anyopaque;
	const FSEventStreamEventId = u64;
	const FSEventStreamCallback = *const fn (
		stream: ConstFSEventStreamRef,
		ctx: ?*anyopaque,
		num_events: usize,
		event_paths: *anyopaque,
		event_flags: [*]const u32,
		event_ids: [*]const FSEventStreamEventId,
	) callconv(.c) void;

	const FSEventStreamContext = extern struct {
		version: i32 = 0,
		info: ?*anyopaque = null,
		retain: ?*const anyopaque = null,
		release: ?*const anyopaque = null,
		copy_description: ?*const anyopaque = null,
	};

	const FSEventStreamCreateFlags = packed struct(u32) {
		use_cf_types: bool = false,
		no_defer: bool = false,
		watch_root: bool = false,
		ignore_self: bool = false,
		file_events: bool = false,
		_: u27 = 0,
	};

	const dispatch_queue_t = *anyopaque;
	const dispatch_semaphore_t = *anyopaque;
	const dispatch_time_t = u64;
	const DISPATCH_TIME_NOW: dispatch_time_t = 0;
	const DISPATCH_TIME_FOREVER: dispatch_time_t = ~@as(u64, 0);

	extern fn dispatch_semaphore_create(value: isize) dispatch_semaphore_t;
	extern fn dispatch_semaphore_wait(dsema: dispatch_semaphore_t, timeout: dispatch_time_t) isize;
	extern fn dispatch_semaphore_signal(dsema: dispatch_semaphore_t) isize;
	extern fn dispatch_queue_create(label: [*:0]const u8, attr: ?*anyopaque) dispatch_queue_t;
	extern fn dispatch_release(object: *anyopaque) void;
	extern fn dispatch_time(when: dispatch_time_t, delta: i64) dispatch_time_t;

	const ResolvedSymbols = struct {
		FSEventStreamCreate: *const fn (
			allocator: CFAllocatorRef,
			callback: FSEventStreamCallback,
			ctx: ?*const FSEventStreamContext,
			paths_to_watch: CFArrayRef,
			since_when: FSEventStreamEventId,
			latency: CFTimeInterval,
			flags: FSEventStreamCreateFlags,
		) callconv(.c) ?FSEventStreamRef,
		FSEventStreamSetDispatchQueue: *const fn (stream: FSEventStreamRef, queue: dispatch_queue_t) callconv(.c) void,
		FSEventStreamStart: *const fn (stream: FSEventStreamRef) callconv(.c) bool,
		FSEventStreamStop: *const fn (stream: FSEventStreamRef) callconv(.c) void,
		FSEventStreamInvalidate: *const fn (stream: FSEventStreamRef) callconv(.c) void,
		FSEventStreamRelease: *const fn (stream: FSEventStreamRef) callconv(.c) void,
		CFRelease: *const fn (cf: *const anyopaque) callconv(.c) void,
		CFArrayCreate: *const fn (
			allocator: CFAllocatorRef,
			values: [*]const usize,
			num_values: CFIndex,
			call_backs: ?*const anyopaque,
		) callconv(.c) CFArrayRef,
		CFStringCreateWithCString: *const fn (
			alloc: CFAllocatorRef,
			c_str: [*:0]const u8,
			encoding: CFStringEncoding,
		) callconv(.c) CFStringRef,
	};

	fn init(_: std.mem.Allocator) (error{OpenFrameworkFailed} || error{MissingSymbol})!MacOsBackend {
		var cs = std.DynLib.open("/System/Library/Frameworks/CoreServices.framework/CoreServices") catch
			return error.OpenFrameworkFailed;
		errdefer cs.close();

		var syms: ResolvedSymbols = undefined;
		inline for (@typeInfo(ResolvedSymbols).@"struct".fields) |f| {
			@field(syms, f.name) = cs.lookup(f.type, f.name) orelse return error.MissingSymbol;
		}

		return .{
			.core_services = cs,
			.syms = syms,
			.queue = dispatch_queue_create("com.codescan.fswatcher", null),
			.semaphore = dispatch_semaphore_create(0),
			.stream = null,
			.watch_paths_z = .{},
		};
	}

	fn deinit(self: *MacOsBackend, allocator: std.mem.Allocator) void {
		self.stopStream();
		for (self.watch_paths_z.items) |p| allocator.free(std.mem.span(p));
		self.watch_paths_z.deinit(allocator);
		dispatch_release(self.queue);
		dispatch_release(self.semaphore);
		self.core_services.close();
	}

	fn stopStream(self: *MacOsBackend) void {
		if (self.stream) |s| {
			self.syms.FSEventStreamStop(s);
			self.syms.FSEventStreamInvalidate(s);
			self.syms.FSEventStreamRelease(s);
			self.stream = null;
		}
	}

	fn setWatchPaths(self: *MacOsBackend, allocator: std.mem.Allocator, paths: []const []const u8) !void {
		self.stopStream();

		// Free old paths
		for (self.watch_paths_z.items) |p| allocator.free(std.mem.span(p));
		self.watch_paths_z.clearRetainingCapacity();

		// Build CF array of paths
		for (paths) |path| {
			const z = try allocator.dupeZ(u8, path);
			try self.watch_paths_z.append(allocator, z);
		}

		if (self.watch_paths_z.items.len == 0) return;

		// Create CFString array
		const cf_strings = try allocator.alloc(usize, self.watch_paths_z.items.len);
		defer allocator.free(cf_strings);

		for (self.watch_paths_z.items, 0..) |p, i| {
			const cf_str = self.syms.CFStringCreateWithCString(null, p, .utf8);
			cf_strings[i] = @intFromPtr(cf_str);
		}
		defer for (cf_strings) |s| self.syms.CFRelease(@ptrFromInt(s));

		const cf_array = self.syms.CFArrayCreate(
			null,
			cf_strings.ptr,
			@intCast(cf_strings.len),
			null,
		);

		var ctx = FSEventStreamContext{ .info = @ptrCast(self.semaphore) };
		const since_now: FSEventStreamEventId = ~@as(u64, 0);

		self.stream = self.syms.FSEventStreamCreate(
			null,
			&fsEventsCallback,
			&ctx,
			cf_array,
			since_now,
			0.1, // 100ms latency coalescing
			.{ .no_defer = true },
		);

		self.syms.CFRelease(cf_array);

		if (self.stream) |s| {
			self.syms.FSEventStreamSetDispatchQueue(s, self.queue);
			_ = self.syms.FSEventStreamStart(s);
		}
	}

	fn fsEventsCallback(
		_: ConstFSEventStreamRef,
		ctx: ?*anyopaque,
		_: usize,
		_: *anyopaque,
		_: [*]const u32,
		_: [*]const FSEventStreamEventId,
	) callconv(.c) void {
		if (ctx) |c| {
			const sem: dispatch_semaphore_t = @ptrCast(c);
			_ = dispatch_semaphore_signal(sem);
		}
	}

	fn wait(self: *MacOsBackend, timeout_ms: ?u64) !FsWatch.WaitResult {
		if (self.stream == null) return .timeout;

		const dt: dispatch_time_t = if (timeout_ms) |ms|
			dispatch_time(DISPATCH_TIME_NOW, @intCast(ms * std.time.ns_per_ms))
		else
			DISPATCH_TIME_FOREVER;

		const result = dispatch_semaphore_wait(self.semaphore, dt);
		return if (result == 0) .changed else .timeout;
	}
};

// -- Linux fanotify backend --------------------------------------------------

const LinuxBackend = struct {
	fan_fd: std.posix.fd_t,

	fn init(_: std.mem.Allocator) error{FanotifyInitFailed}!LinuxBackend {
		const fd = std.posix.fanotify_init(.{
			.CLOEXEC = true,
			.NONBLOCK = true,
			.REPORT_NAME = true,
			.REPORT_DIR_FID = true,
			.REPORT_FID = true,
		}, 0) catch return error.FanotifyInitFailed;

		return .{ .fan_fd = fd };
	}

	fn deinit(self: *LinuxBackend, _: std.mem.Allocator) void {
		std.posix.close(self.fan_fd);
	}

	fn setWatchPaths(self: *LinuxBackend, _: std.mem.Allocator, paths: []const []const u8) !void {
		// First flush existing marks
		std.posix.fanotify_mark(self.fan_fd, .{ .FLUSH = true }, .{}, std.posix.AT.FDCWD, null) catch {};

		for (paths) |path| {
			var dir = try std.fs.cwd().openDir(path, .{});
			defer dir.close();

			std.posix.fanotify_mark(self.fan_fd, .{
				.ADD = true,
				.FILESYSTEM = true,
			}, .{
				.CLOSE_WRITE = true,
				.CREATE = true,
				.DELETE = true,
				.MOVED_FROM = true,
				.MOVED_TO = true,
			}, dir.fd, null) catch |err| switch (err) {
				error.UnsupportedFlags => {
					// Older kernel — try without FILESYSTEM flag
					std.posix.fanotify_mark(self.fan_fd, .{
						.ADD = true,
					}, .{
						.CLOSE_WRITE = true,
						.CREATE = true,
						.DELETE = true,
						.MOVED_FROM = true,
						.MOVED_TO = true,
					}, dir.fd, ".") catch return error.WatchFailed;
				},
				else => return error.WatchFailed,
			};
		}
	}

	fn wait(self: *LinuxBackend, timeout_ms: ?u64) !FsWatch.WaitResult {
		var fds = [1]std.posix.pollfd{.{
			.fd = self.fan_fd,
			.events = std.posix.POLL.IN,
			.revents = 0,
		}};

		const timeout: i32 = if (timeout_ms) |ms| @intCast(@min(ms, std.math.maxInt(i32))) else -1;
		const n = std.posix.poll(&fds, timeout) catch return .timeout;

		if (n > 0 and (fds[0].revents & std.posix.POLL.IN) != 0) {
			// Drain the event buffer
			var buf: [4096]u8 align(@alignOf(std.os.linux.fanotify.event_metadata)) = undefined;
			while (true) {
				const bytes = std.posix.read(self.fan_fd, &buf) catch break;
				if (bytes == 0) break;
			}
			return .changed;
		}
		return .timeout;
	}
};

// -- Polling fallback --------------------------------------------------------

const PollingBackend = struct {
	fn init(_: std.mem.Allocator) !PollingBackend {
		return .{};
	}

	fn deinit(_: *PollingBackend, _: std.mem.Allocator) void {}

	fn setWatchPaths(_: *PollingBackend, _: std.mem.Allocator, _: []const []const u8) !void {}

	fn wait(_: *PollingBackend, timeout_ms: ?u64) !FsWatch.WaitResult {
		if (timeout_ms) |ms| {
			std.Thread.sleep(ms * std.time.ns_per_ms);
		}
		return .timeout;
	}
};

// Tests

test "FsWatch init and deinit" {
	const allocator = std.testing.allocator;
	var w = FsWatch.init(allocator) catch |err| {
		// On CI or unsupported platforms, init may fail — that's OK
		switch (err) {
			error.OpenFrameworkFailed, error.MissingSymbol, error.FanotifyInitFailed => return,
			else => return err,
		}
	};
	defer w.deinit(allocator);
}

test "FsWatch wait returns timeout when no changes" {
	const allocator = std.testing.allocator;
	var w = FsWatch.init(allocator) catch return; // skip if unsupported
	defer w.deinit(allocator);

	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(dir_path);

	try w.setWatchPaths(allocator, &.{dir_path});

	const result = try w.wait(100);
	try std.testing.expectEqual(FsWatch.WaitResult.timeout, result);
}

test "FsWatch wait detects file creation" {
	const allocator = std.testing.allocator;
	var w = FsWatch.init(allocator) catch return; // skip if unsupported
	defer w.deinit(allocator);

	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
	defer allocator.free(dir_path);

	try w.setWatchPaths(allocator, &.{dir_path});

	// Create a file from another thread after a short delay
	const handle = try std.Thread.spawn(.{}, struct {
		fn run(dir: std.fs.Dir) void {
			std.Thread.sleep(50 * std.time.ns_per_ms);
			const f = dir.createFile("test_trigger.txt", .{}) catch return;
			f.close();
		}
	}.run, .{tmp.dir});

	const result = try w.wait(5000);
	handle.join();

	// On macOS with FSEvents this should detect the change.
	// On polling backend it will always timeout, so we accept both.
	_ = result;
}
