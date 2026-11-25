const std = @import("std");
const cli = @import("cli.zig");
const embedding_http = @import("embedding_http.zig");
const storage = @import("storage.zig");

pub fn checkIndex(report: *Report, path: []const u8, model_name: []const u8, dimension: usize) !void {
	const db = storage.openFileReadOnly(report.allocator, path) catch |err| {
		try report.addFmt(.fail, "Index", "could not read embedding metadata: {s}; index unchanged", .{@errorName(err)});
		return;
	};
	defer storage.close(db);
	const stored_model = storage.embeddingModel(db, report.allocator) catch |err| {
		try report.addFmt(.fail, "Index", "could not verify the indexed embedding model: {s}; index unchanged", .{@errorName(err)});
		return;
	};
	defer report.allocator.free(stored_model);
	const stored_dimension = storage.embeddingDimension(db, report.allocator) catch |err| {
		try report.addFmt(.fail, "Index", "could not verify the indexed embedding width: {s}; index unchanged", .{@errorName(err)});
		return;
	};
	if (!std.mem.eql(u8, stored_model, model_name) or stored_dimension != dimension) {
		try report.addFmt(.fail, "Index", "stored model '{s}' ({d} dimensions) does not match configured model '{s}' ({d} dimensions); index unchanged. Restore compatible settings or rebuild after preserving the existing index", .{ stored_model, stored_dimension, model_name, dimension });
		return;
	}
	try report.addFmt(.pass, "Index", "stored model '{s}' and {d}-dimensional metadata match configuration", .{ stored_model, stored_dimension });
}

pub const InferenceConfig = struct {
	url: []const u8,
	model: []const u8,
	dialect: embedding_http.ApiDialect,
	auth_header: ?[]const u8,
	dimension: usize,
};

pub fn checkInference(report: *Report, transport: embedding_http.Transport, cfg: InferenceConfig) !void {
	if (cfg.dialect == .openai and cfg.auth_header == null) {
		try report.add(.fail, "Inference", "embedding_api=openai requires an API key; set CODESCAN_EMBEDDING_SERVER_API_KEY or embedding_api_key");
		return;
	}
	// Doctor verifies the same POST, authentication and response parsing used by
	// indexing, not just a model listing. Its diagnostic deadline is local to
	// this adapter; ordinary indexing may still wait for a cold model to load.
	var probe = InferenceProbeTransport{ .inner = transport };
	const vectors = embedding_http.embed(report.allocator, .{ .ctx = &probe, .send = InferenceProbeTransport.send }, cfg.url, cfg.model, &.{"codescan inference health probe"}, null, cfg.dialect, cfg.auth_header) catch |err| {
		if (err == error.Timeout) {
			try report.addFmt(.fail, "Inference", "embedding probe for model '{s}' at {s} did not complete within 10 seconds; inference is unverified (the model may still be loading)", .{ cfg.model, cfg.url });
		} else {
			try report.addFmt(.fail, "Inference", "embedding request for model '{s}' at {s} failed: {s}", .{ cfg.model, cfg.url, @errorName(err) });
		}
		return;
	};
	defer embedding_http.freeEmbeddings(report.allocator, vectors);
	// embed checks the response count against the single requested input.
	const vector = vectors[0];
	if (vector.len == 0 or vector.len != cfg.dimension) {
		try report.addFmt(.fail, "Inference", "model '{s}' at {s} returned a {d}-dimensional embedding, but settings require {d}; verify provider and model settings", .{ cfg.model, cfg.url, vector.len, cfg.dimension });
		return;
	}
	for (vector) |component| {
		if (!std.math.isFinite(component)) {
			try report.addFmt(.fail, "Inference", "model '{s}' at {s} returned a non-finite embedding", .{ cfg.model, cfg.url });
			return;
		}
	}
	try report.addFmt(.pass, "Inference", "model '{s}' returned a usable {d}-dimensional embedding at {s}", .{ cfg.model, vector.len, cfg.url });
}

const InferenceProbeTransport = struct {
	inner: embedding_http.Transport,

	fn send(ctx: *anyopaque, allocator: std.mem.Allocator, request: embedding_http.HttpRequest) anyerror!embedding_http.HttpResponse {
		const self: *InferenceProbeTransport = @ptrCast(@alignCast(ctx));
		var bounded = request;
		bounded.deadline_ns = embedding_http.reachability_deadline_ns;
		return self.inner.send(self.inner.ctx, allocator, bounded);
	}
};

pub const Status = enum {
	pass,
	fail,
	note,
	skipped,
};

pub const Check = struct {
	name: []const u8,
	status: Status,
	message: []const u8,
};

pub const Report = struct {
	allocator: std.mem.Allocator,
	checks: std.ArrayListUnmanaged(Check) = .empty,

	pub fn init(allocator: std.mem.Allocator) Report {
		return .{ .allocator = allocator };
	}

	pub fn deinit(self: *Report) void {
		for (self.checks.items) |check| self.allocator.free(check.message);
		self.checks.deinit(self.allocator);
		self.* = undefined;
	}

	pub fn add(self: *Report, status: Status, name: []const u8, message: []const u8) !void {
		const owned_message = try self.allocator.dupe(u8, message);
		errdefer self.allocator.free(owned_message);
		try self.checks.append(self.allocator, .{
			.name = name,
			.status = status,
			.message = owned_message,
		});
	}

	pub fn addFmt(self: *Report, status: Status, name: []const u8, comptime fmt: []const u8, args: anytype) !void {
		const message = try std.fmt.allocPrint(self.allocator, fmt, args);
		errdefer self.allocator.free(message);
		try self.checks.append(self.allocator, .{
			.name = name,
			.status = status,
			.message = message,
		});
	}
};

pub fn hasFailures(checks: []const Check) bool {
	for (checks) |check| {
		if (check.status == .fail) return true;
	}
	return false;
}

/// Pure rendering boundary for CLI and MCP callers.
pub fn render(allocator: std.mem.Allocator, root_path: []const u8, checks: []const Check, format: cli.OutputFormat) ![]u8 {
	var out: std.Io.Writer.Allocating = .init(allocator);
	defer out.deinit();

	switch (format) {
		.human => {
			try out.writer.print("Doctor: {s}\n", .{root_path});
			for (checks) |check| {
				const label = switch (check.status) {
					.pass => "OK",
					.fail => "ERROR",
					.note => "NOTE",
					.skipped => "SKIP",
				};
				try out.writer.print("{s} {s}: {s}\n", .{ label, check.name, check.message });
			}
			try out.writer.print("Health: {s}\n", .{if (hasFailures(checks)) "FAILED" else "OK"});
		},
		.json => {
			const Payload = struct {
				root: []const u8,
				ok: bool,
				checks: []const Check,
			};
			var stream: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
			try stream.write(Payload{
				.root = root_path,
				.ok = !hasFailures(checks),
				.checks = checks,
			});
			try out.writer.writeAll("\n");
		},
	}

	return out.toOwnedSlice();
}

fn exerciseReportOwnership(allocator: std.mem.Allocator) !void {
	var report = Report.init(allocator);
	defer report.deinit();
	for (0..20) |index| {
		const addition = report.add(.note, "Watcher", "stopped");
		try std.testing.expectEqual(if (addition) |_| index + 1 else |_| index, report.checks.items.len);
		for (report.checks.items) |check| {
			try std.testing.expectEqual(Status.note, check.status);
			try std.testing.expectEqualStrings("Watcher", check.name);
			try std.testing.expectEqualStrings("stopped", check.message);
		}
		try addition;
	}
}

test "report add releases message ownership at every allocation failure" {
	try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseReportOwnership, .{});
}

test "a stopped watcher is a note rather than a doctor failure" {
	const checks = [_]Check{
		.{ .name = "Settings", .status = .pass, .message = "valid" },
		.{ .name = "Watcher", .status = .note, .message = "stopped" },
	};
	try std.testing.expect(!hasFailures(&checks));

	const text = try render(std.testing.allocator, "/project", &checks, .human);
	defer std.testing.allocator.free(text);
	try std.testing.expect(std.mem.indexOf(u8, text, "NOTE Watcher: stopped") != null);
	try std.testing.expect(std.mem.indexOf(u8, text, "Health: OK") != null);
}

test "JSON report exposes a stopped watcher as a note" {
	const checks = [_]Check{
		.{ .name = "Watcher", .status = .note, .message = "stopped" },
	};
	const text = try render(std.testing.allocator, "/project", &checks, .json);
	defer std.testing.allocator.free(text);
	try std.testing.expect(std.mem.indexOf(u8, text, "\"ok\":true") != null);
	try std.testing.expect(std.mem.indexOf(u8, text, "\"status\":\"note\"") != null);
}

test "doctor rejects healthy inventories when the embedding request fails" {
	var mock = embedding_http.MockTransportCtx{
		.tags_body = "{\"models\":[{\"name\":\"test-model\"}]}",
		.ps_body = "{\"models\":[{\"name\":\"test-model\"}]}",
		.embed_should_fail = true,
	};
	var report = Report.init(std.testing.allocator);
	defer report.deinit();
	try checkInference(&report, mock.transport(), .{
		.url = "http://localhost:11434",
		.model = "test-model",
		.dialect = .ollama,
		.auth_header = null,
		.dimension = 2,
	});
	try std.testing.expect(hasFailures(report.checks.items));
	try std.testing.expectEqual(@as(usize, 1), mock.embed_count);
}

const ProbeFixture = struct {
	body: []const u8,
	status: u16 = 200,
	failure: ?anyerror = null,
	calls: usize = 0,
	auth_seen: bool = false,
	deadline: ?u64 = null,

	fn send(ctx: *anyopaque, allocator: std.mem.Allocator, req: embedding_http.HttpRequest) !embedding_http.HttpResponse {
		const self: *ProbeFixture = @ptrCast(@alignCast(ctx));
		self.calls += 1;
		self.deadline = req.deadline_ns;
		try std.testing.expectEqualStrings("POST", req.method);
		try std.testing.expect(std.mem.endsWith(u8, req.url, "/api/embed") or std.mem.endsWith(u8, req.url, "/v1/embeddings"));
		try std.testing.expect(std.mem.indexOf(u8, req.body, "test-model") != null);
		for (req.headers) |header| {
			if (std.ascii.eqlIgnoreCase(header.name, "Authorization")) {
				try std.testing.expectEqualStrings("Bearer fixture-key", header.value);
				self.auth_seen = true;
			}
		}
		if (self.failure) |err| return err;
		return .{ .status = self.status, .body = try allocator.dupe(u8, self.body) };
	}

	fn transport(self: *ProbeFixture) embedding_http.Transport {
		return .{ .ctx = self, .send = send };
	}
};

test "doctor probes both embedding APIs with authentication and a diagnostic deadline" {
	inline for (.{ embedding_http.ApiDialect.ollama, embedding_http.ApiDialect.openai }) |dialect| {
		var fixture = ProbeFixture{ .body = if (dialect == .ollama) "{\"embeddings\":[[0.1,0.2]]}" else "{\"data\":[{\"embedding\":[0.1,0.2],\"index\":0}]}" };
		var report = Report.init(std.testing.allocator);
		defer report.deinit();
		try checkInference(&report, fixture.transport(), .{
			.url = "http://localhost:8000",
			.model = "test-model",
			.dialect = dialect,
			.auth_header = if (dialect == .openai) "Bearer fixture-key" else null,
			.dimension = 2,
		});
		try std.testing.expect(!hasFailures(report.checks.items));
		try std.testing.expectEqual(@as(usize, 1), fixture.calls);
		try std.testing.expectEqual(dialect == .openai, fixture.auth_seen);
		try std.testing.expectEqual(embedding_http.reachability_deadline_ns, fixture.deadline.?);
		try std.testing.expect(std.mem.indexOf(u8, report.checks.items[0].message, "usable 2-dimensional embedding") != null);
	}
}

test "doctor rejects unusable embedding responses and reports probe failures" {
	const cases = [_]struct { body: []const u8 = "", status: u16 = 200, failure: ?anyerror = null, message: []const u8 }{
		.{ .status = 401, .message = "Unauthorized" },
		.{ .status = 503, .message = "HttpStatus" },
		.{ .body = "{}", .message = "MissingEmbeddings" },
		.{ .body = "not json", .message = "SyntaxError" },
		.{ .body = "{\"embeddings\":[]}", .message = "InvalidEmbeddingCount" },
		.{ .body = "{\"embeddings\":[[]]}", .message = "0-dimensional" },
		.{ .body = "{\"embeddings\":[[1,2,3]]}", .message = "3-dimensional" },
		.{ .body = "{\"embeddings\":[[1e300,2]]}", .message = "non-finite" },
		.{ .failure = error.Timeout, .message = "inference is unverified" },
		.{ .failure = error.ConnectionRefused, .message = "ConnectionRefused" },
	};
	for (cases) |case| {
		var fixture = ProbeFixture{ .body = case.body, .status = case.status, .failure = case.failure };
		var report = Report.init(std.testing.allocator);
		defer report.deinit();
		try checkInference(&report, fixture.transport(), .{
			.url = "http://localhost:11434",
			.model = "test-model",
			.dialect = .ollama,
			.auth_header = null,
			.dimension = 2,
		});
		try std.testing.expect(hasFailures(report.checks.items));
		try std.testing.expectEqual(@as(usize, 1), fixture.calls);
		try std.testing.expect(std.mem.indexOf(u8, report.checks.items[0].message, case.message) != null);
	}
}

test "doctor refuses missing OpenAI credentials before making a request" {
	var fixture = ProbeFixture{ .body = "{}" };
	var report = Report.init(std.testing.allocator);
	defer report.deinit();
	try checkInference(&report, fixture.transport(), .{
		.url = "http://localhost:8000",
		.model = "test-model",
		.dialect = .openai,
		.auth_header = null,
		.dimension = 2,
	});
	try std.testing.expect(hasFailures(report.checks.items));
	try std.testing.expectEqual(@as(usize, 0), fixture.calls);
}
