const std = @import("std");

/// Whether a watcher should stay alive or stand down.
pub const Decision = enum {
	keep_running,
	retire,
};

/// Everything the retirement policy needs, gathered by the caller so the
/// decision itself reads no clock and touches no filesystem.
pub const Observation = struct {
	now_ns: i128,
	/// When the last successful index commit happened, or null if this project
	/// has never been indexed.
	last_index_ns: ?i128,
	/// When this watcher started. Used as the origin for a project that has
	/// never been indexed, so an idle watcher on an empty project still
	/// eventually stands down rather than living forever.
	started_ns: i128,
	/// How long the watcher may sit idle before retiring. Null means never
	/// retire, which a service manager needs — a supervised unit that exits on
	/// idle would restart-loop.
	idle_limit_ns: ?u64,
	/// True while an index pass is running. Retiring mid-index would abandon
	/// partial work, so this dominates every other input.
	index_in_progress: bool,
};

/// Decides whether an idle watcher should retire. Pure: the caller supplies the
/// clock reading, so this needs no elapsed time to test.
pub fn shouldRetire(observation: Observation) Decision {
	// Never abandon partial work; this dominates every other input.
	if (observation.index_in_progress) return .keep_running;

	const limit = observation.idle_limit_ns orelse return .keep_running;

	// A project that has never been indexed has no commit marker, so the
	// watcher's own start is the origin. Without this an idle watcher on an
	// empty project would live forever.
	const origin = observation.last_index_ns orelse observation.started_ns;

	// A marker ahead of now means clock skew, a restored backup, or a file from
	// another machine. Treat it as "just happened" rather than letting the
	// subtraction wrap and retire instantly.
	if (observation.now_ns < origin) return .keep_running;

	const idle_ns = observation.now_ns - origin;
	return if (idle_ns >= @as(i128, limit)) .retire else .keep_running;
}

/// Parses a watcher idle limit into nanoseconds, where null means "never
/// retire". Accepts a bare number of seconds, a `s`/`m`/`h`/`d` suffix, and the
/// words `never`/`off` alongside `0`.
pub fn parseIdleLimit(text: []const u8) !?u64 {
	const trimmed = std.mem.trim(u8, text, " \t\r\n");
	if (trimmed.len == 0) return error.InvalidIdleLimit;

	if (std.ascii.eqlIgnoreCase(trimmed, "never") or std.ascii.eqlIgnoreCase(trimmed, "off")) {
		return null;
	}

	const last = trimmed[trimmed.len - 1];
	const multiplier: u64 = switch (std.ascii.toLower(last)) {
		's' => std.time.ns_per_s,
		'm' => std.time.ns_per_min,
		'h' => std.time.ns_per_hour,
		'd' => std.time.ns_per_day,
		else => 0,
	};

	const digits = if (multiplier == 0) trimmed else trimmed[0 .. trimmed.len - 1];
	if (digits.len == 0) return error.InvalidIdleLimit;

	const value = std.fmt.parseInt(u64, digits, 10) catch return error.InvalidIdleLimit;
	// Zero is spelled the same way in every unit and always means "never".
	if (value == 0) return null;

	const unit = if (multiplier == 0) std.time.ns_per_s else multiplier;
	return std.math.mul(u64, value, unit) catch error.InvalidIdleLimit;
}

const day = std.time.ns_per_day;
const hour = std.time.ns_per_hour;

test "an index in progress always wins, whatever else is true" {
	// Retiring mid-index abandons partial work, so this must dominate even a
	// wildly exceeded idle limit and a null last-index marker.
	for ([_]?i128{ null, 0, day * 100 }) |last| {
		for ([_]?u64{ null, 1, day }) |limit| {
			const decision = shouldRetire(.{
				.now_ns = day * 1000,
				.last_index_ns = last,
				.started_ns = 0,
				.idle_limit_ns = limit,
				.index_in_progress = true,
			});
			try std.testing.expectEqual(Decision.keep_running, decision);
		}
	}
}

test "a null idle limit never retires" {
	// The service-manager case: a supervised watcher that exits on idle would
	// restart-loop forever.
	for ([_]?i128{ null, 0 }) |last| {
		const decision = shouldRetire(.{
			.now_ns = day * 1000,
			.last_index_ns = last,
			.started_ns = 0,
			.idle_limit_ns = null,
			.index_in_progress = false,
		});
		try std.testing.expectEqual(Decision.keep_running, decision);
	}
}

test "idleness is measured from the last index commit" {
	const limit: u64 = day;

	// Exactly at the limit retires; one nanosecond short does not. Boundaries
	// are where an off-by-one lives.
	try std.testing.expectEqual(Decision.retire, shouldRetire(.{
		.now_ns = day,
		.last_index_ns = 0,
		.started_ns = 0,
		.idle_limit_ns = limit,
		.index_in_progress = false,
	}));
	try std.testing.expectEqual(Decision.keep_running, shouldRetire(.{
		.now_ns = day - 1,
		.last_index_ns = 0,
		.started_ns = 0,
		.idle_limit_ns = limit,
		.index_in_progress = false,
	}));

	// A recent index resets the countdown even though the watcher is old.
	try std.testing.expectEqual(Decision.keep_running, shouldRetire(.{
		.now_ns = day * 10,
		.last_index_ns = day * 10 - hour,
		.started_ns = 0,
		.idle_limit_ns = limit,
		.index_in_progress = false,
	}));
}

test "a never-indexed project times from the watcher's own start" {
	const limit: u64 = day;

	// Otherwise a watcher on an empty or never-indexed project would be
	// immortal, which is the operational problem this feature exists to solve.
	try std.testing.expectEqual(Decision.retire, shouldRetire(.{
		.now_ns = day * 3,
		.last_index_ns = null,
		.started_ns = day * 2,
		.idle_limit_ns = limit,
		.index_in_progress = false,
	}));
	try std.testing.expectEqual(Decision.keep_running, shouldRetire(.{
		.now_ns = day * 2 + hour,
		.last_index_ns = null,
		.started_ns = day * 2,
		.idle_limit_ns = limit,
		.index_in_progress = false,
	}));
}

test "a marker in the future keeps the watcher alive rather than underflowing" {
	// Clock skew, a restored backup, or a file written by another machine can
	// all put the marker ahead of now. Subtracting unsigned would wrap and
	// retire instantly.
	try std.testing.expectEqual(Decision.keep_running, shouldRetire(.{
		.now_ns = 0,
		.last_index_ns = day * 5,
		.started_ns = 0,
		.idle_limit_ns = 1,
		.index_in_progress = false,
	}));
	try std.testing.expectEqual(Decision.keep_running, shouldRetire(.{
		.now_ns = 0,
		.last_index_ns = null,
		.started_ns = day * 5,
		.idle_limit_ns = 1,
		.index_in_progress = false,
	}));
}

test "parseIdleLimit accepts durations, and spells never several ways" {
	try std.testing.expectEqual(@as(?u64, std.time.ns_per_day), try parseIdleLimit("1d"));
	try std.testing.expectEqual(@as(?u64, 12 * std.time.ns_per_hour), try parseIdleLimit("12h"));
	try std.testing.expectEqual(@as(?u64, 30 * std.time.ns_per_min), try parseIdleLimit("30m"));
	try std.testing.expectEqual(@as(?u64, 45 * std.time.ns_per_s), try parseIdleLimit("45s"));
	// A bare number is seconds, matching the interval settings alongside it.
	try std.testing.expectEqual(@as(?u64, 90 * std.time.ns_per_s), try parseIdleLimit("90"));
	try std.testing.expectEqual(@as(?u64, std.time.ns_per_day), try parseIdleLimit("  1d  "));
	try std.testing.expectEqual(@as(?u64, 2 * std.time.ns_per_hour), try parseIdleLimit("2H"));

	// Every spelling of "never" must agree, including zero in any unit.
	for ([_][]const u8{ "never", "NEVER", "off", "0", "0s", "0d" }) |text| {
		try std.testing.expectEqual(@as(?u64, null), try parseIdleLimit(text));
	}

	// Rejected rather than silently defaulted: a typo'd limit must not quietly
	// become "never retire" or "retire immediately".
	for ([_][]const u8{ "", "   ", "d", "abc", "1w", "-5", "1.5h", "9999999999999d" }) |text| {
		try std.testing.expectError(error.InvalidIdleLimit, parseIdleLimit(text));
	}
}
