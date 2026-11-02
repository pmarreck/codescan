const std = @import("std");
const embedding_http = @import("embedding_http.zig");
const freshness = @import("freshness.zig");
const io_singleton = @import("io_singleton.zig");
const output = @import("output.zig");
const pidfile = @import("pidfile.zig");
const update_service = @import("update_service.zig");

pub const Request = struct {
	root_path: []const u8,
	db_path: []const u8,
	embedding_url: []const u8,
	embedding_model: []const u8,
	embedding_dialect: embedding_http.ApiDialect,
	lexical_only: bool,
};

/// Borrowed only for the synchronous ensure call. The callback must not retain
/// the diagnostic slot, whose lifetime ends when reconciliation returns.
pub const Reconciler = struct {
	context: *anyopaque,
	run_fn: *const fn (context: *anyopaque, embedding_failure: *?anyerror) anyerror!void,
};

const SearchFreshnessContext = struct {
	allocator: std.mem.Allocator,
	request: Request,
	update: Reconciler,
	inference_unavailable: bool = false,

	fn adapter(self: *SearchFreshnessContext, watcher_running: bool) freshness.Adapter {
		return .{
			.context = self,
			.watcher_running = watcher_running,
			.reconcile_fn = reconcile,
			.usable_index_fn = usableIndex,
		};
	}

	fn reconcile(context: *anyopaque) !void {
		const self: *SearchFreshnessContext = @ptrCast(@alignCast(context));
		self.inference_unavailable = false;
		if (!self.request.lexical_only) {
			var http_client = embedding_http.StdHttpTransport.init(self.allocator);
			defer http_client.deinit();
			if (!embedding_http.inferenceAvailable(
				self.allocator,
				http_client.transport(),
				self.request.embedding_url,
				self.request.embedding_model,
				self.request.embedding_dialect,
			)) {
				self.inference_unavailable = true;
				return error.EmbeddingUnavailable;
			}
		}
		var embedding_failure: ?anyerror = null;
		defer if (embedding_failure) |err| {
			if (err != error.OutOfMemory) self.inference_unavailable = true;
		};
		self.update.run_fn(self.update.context, &embedding_failure) catch |err| {
			if (err == error.EmbeddingDimMismatch) self.inference_unavailable = true;
			return err;
		};
	}

	fn usableIndex(context: *anyopaque) bool {
		const self: *SearchFreshnessContext = @ptrCast(@alignCast(context));
		return update_service.indexUsable(self.allocator, self.request.db_path);
	}
};

pub const Result = struct {
	outcome: freshness.Outcome,
	elapsed_ns: u64,
	watcher_advisory: ?freshness.WatcherAdvisory,
	semantic_index_pending_paths: ?usize = null,
	inference_unavailable: bool = false,
	inference_url: ?[]const u8 = null,

	pub fn outputMetadata(self: Result) output.FreshnessMetadata {
		return .{
			.outcome = self.outcome,
			.update_seconds = if (self.outcome == .watcher_active)
				null
			else
				@as(f64, @floatFromInt(self.elapsed_ns)) /
					@as(f64, @floatFromInt(std.time.ns_per_s)),
			.watcher_recommended = self.watcher_advisory != null,
			.semantic_index_pending_paths = self.semantic_index_pending_paths,
			.inference_unavailable = self.inference_unavailable,
			.inference_url = self.inference_url,
		};
	}
};

/// Reconciles on demand when no watcher owns freshness for this project.
pub fn ensure(allocator: std.mem.Allocator, request: Request, update: Reconciler) !Result {
	const codescan_dir = std.fs.path.dirname(request.db_path) orelse ".codescan";
	var context = SearchFreshnessContext{
		.allocator = allocator,
		.request = request,
		.update = update,
	};
	const io = io_singleton.getOrInit();
	const started = std.Io.Clock.awake.now(io);
	const outcome = try freshness.ensureFresh(context.adapter(
		pidfile.isWatcherRunning(allocator, codescan_dir),
	));
	const duration = started.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
	const elapsed_ns: u64 = if (duration > 0) @intCast(duration) else 0;
	const watcher_advisory = if (outcome == .reconciled and elapsed_ns > std.time.ns_per_s) advice: {
		const activity = freshness.detectGitActivity(
			allocator,
			io,
			request.root_path,
			std.Io.Clock.real.now(io).nanoseconds,
		);
		break :advice freshness.watcherAdvisory(elapsed_ns, activity);
	} else null;
	return .{
		.outcome = outcome,
		.elapsed_ns = elapsed_ns,
		.watcher_advisory = watcher_advisory,
		.inference_unavailable = context.inference_unavailable,
		.inference_url = if (context.inference_unavailable) request.embedding_url else null,
	};
}

const FakeReconciler = struct {
	calls: usize = 0,
	initial_failure: ?anyerror = error.NotCalled,

	fn port(self: *FakeReconciler) Reconciler {
		return .{ .context = self, .run_fn = run };
	}

	fn run(context: *anyopaque, embedding_failure: *?anyerror) !void {
		const self: *FakeReconciler = @ptrCast(@alignCast(context));
		self.calls += 1;
		self.initial_failure = embedding_failure.*;
	}
};

fn testRequest(root: []const u8, db_path: []const u8, lexical_only: bool) Request {
	return .{
		.root_path = root,
		.db_path = db_path,
		.embedding_url = "not an inference endpoint",
		.embedding_model = "fixture-model",
		.embedding_dialect = .ollama,
		.lexical_only = lexical_only,
	};
}

test "freshness service keeps an active watcher authoritative without invoking its update port" {
	if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const root = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
	defer allocator.free(root);
	const db_path = try std.fs.path.join(allocator, &.{ root, "index.sqlite3" });
	defer allocator.free(db_path);
	try pidfile.writePid(allocator, root);

	var update = FakeReconciler{};
	const result = try ensure(allocator, testRequest(root, db_path, false), update.port());
	try std.testing.expectEqual(freshness.Outcome.watcher_active, result.outcome);
	try std.testing.expectEqual(@as(usize, 0), update.calls);
	try std.testing.expectEqual(@as(?anyerror, error.NotCalled), update.initial_failure);
	const metadata = result.outputMetadata();
	try std.testing.expectEqual(@as(?f64, null), metadata.update_seconds);
	try std.testing.expect(!metadata.inference_unavailable);
	try std.testing.expect(metadata.inference_url == null);
}

test "freshness service invokes its update port once for a lexical reconciliation" {
	const allocator = std.testing.allocator;
	var tmp = std.testing.tmpDir(.{});
	defer tmp.cleanup();
	const root = try tmp.dir.realPathFileAlloc(io_singleton.getOrInit(), ".", allocator);
	defer allocator.free(root);
	const db_path = try std.fs.path.join(allocator, &.{ root, "index.sqlite3" });
	defer allocator.free(db_path);

	var update = FakeReconciler{};
	const result = try ensure(allocator, testRequest(root, db_path, true), update.port());
	try std.testing.expectEqual(freshness.Outcome.reconciled, result.outcome);
	try std.testing.expectEqual(@as(usize, 1), update.calls);
	try std.testing.expectEqual(@as(?anyerror, null), update.initial_failure);
	const metadata = result.outputMetadata();
	try std.testing.expect(metadata.update_seconds != null);
	try std.testing.expect(!metadata.inference_unavailable);
	try std.testing.expect(metadata.inference_url == null);
}
