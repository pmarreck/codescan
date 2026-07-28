const std = @import("std");

/// How an update database open is allowed to react to an unusable index.
/// `inspect_only` reports the problem without touching data; `immediate_recreate`
/// is permitted to destroy and rebuild it.
pub const OpenMode = enum {
	inspect_only,
	immediate_recreate,
};

/// Observations about an existing index gathered while opening it: whether the
/// schema could be initialized at all, and whether the stored embedding
/// model/dimension still match the configured ones.
pub const SchemaProbe = struct {
	init_failed: bool = false,
	model_mismatch: bool = false,
	dim_mismatch: bool = false,
};

/// The lifecycle verdict for an update database: reuse it, refuse it, or
/// recreate it — and, when refusing or recreating, why.
pub const DbAction = enum {
	use_existing,
	fail_incompatible,
	fail_embedding_mismatch,
	recreate_incompatible,
	recreate_embedding_mismatch,
};

/// Decides the update database lifecycle action from a schema probe and the
/// caller's destruction budget. Pure and total over the finite probe × mode
/// domain so the policy can be exhausted in tests rather than sampled.
pub fn decideDbAction(probe: SchemaProbe, mode: OpenMode) DbAction {
	// A schema that would not initialize tells us nothing about its embedding
	// metadata, so this case dominates the mismatch flags rather than combining
	// with them.
	if (probe.init_failed) return switch (mode) {
		.inspect_only => .fail_incompatible,
		.immediate_recreate => .recreate_incompatible,
	};

	if (!probe.model_mismatch and !probe.dim_mismatch) return .use_existing;

	return switch (mode) {
		.inspect_only => .fail_embedding_mismatch,
		.immediate_recreate => .recreate_embedding_mismatch,
	};
}

const DecisionCase = struct {
	probe: SchemaProbe,
	mode: OpenMode,
	expected: DbAction,
};

/// Every point of the `SchemaProbe` × `OpenMode` domain (2 modes × 2^3 probe
/// states = 16), with the action transcribed from the behavior of `openUpdateDb`
/// in `main.zig`: a failed schema init dominates the embedding flags, a clean
/// probe reuses the index, and either embedding mismatch is one verdict.
const decision_table = [_]DecisionCase{
	// Clean probe: reuse regardless of what destruction is permitted.
	.{ .probe = .{}, .mode = .inspect_only, .expected = .use_existing },
	.{ .probe = .{}, .mode = .immediate_recreate, .expected = .use_existing },

	// Embedding model mismatch alone.
	.{ .probe = .{ .model_mismatch = true }, .mode = .inspect_only, .expected = .fail_embedding_mismatch },
	.{ .probe = .{ .model_mismatch = true }, .mode = .immediate_recreate, .expected = .recreate_embedding_mismatch },

	// Embedding dimension mismatch alone.
	.{ .probe = .{ .dim_mismatch = true }, .mode = .inspect_only, .expected = .fail_embedding_mismatch },
	.{ .probe = .{ .dim_mismatch = true }, .mode = .immediate_recreate, .expected = .recreate_embedding_mismatch },

	// Both embedding flags: still one verdict, not a distinct one.
	.{ .probe = .{ .model_mismatch = true, .dim_mismatch = true }, .mode = .inspect_only, .expected = .fail_embedding_mismatch },
	.{ .probe = .{ .model_mismatch = true, .dim_mismatch = true }, .mode = .immediate_recreate, .expected = .recreate_embedding_mismatch },

	// A failed schema init dominates: the embedding flags were never observed,
	// so they must not change the verdict in any of their four combinations.
	.{ .probe = .{ .init_failed = true }, .mode = .inspect_only, .expected = .fail_incompatible },
	.{ .probe = .{ .init_failed = true }, .mode = .immediate_recreate, .expected = .recreate_incompatible },
	.{ .probe = .{ .init_failed = true, .model_mismatch = true }, .mode = .inspect_only, .expected = .fail_incompatible },
	.{ .probe = .{ .init_failed = true, .model_mismatch = true }, .mode = .immediate_recreate, .expected = .recreate_incompatible },
	.{ .probe = .{ .init_failed = true, .dim_mismatch = true }, .mode = .inspect_only, .expected = .fail_incompatible },
	.{ .probe = .{ .init_failed = true, .dim_mismatch = true }, .mode = .immediate_recreate, .expected = .recreate_incompatible },
	.{ .probe = .{ .init_failed = true, .model_mismatch = true, .dim_mismatch = true }, .mode = .inspect_only, .expected = .fail_incompatible },
	.{ .probe = .{ .init_failed = true, .model_mismatch = true, .dim_mismatch = true }, .mode = .immediate_recreate, .expected = .recreate_incompatible },
};

test "decision table covers every probe/mode domain point exactly once" {
	// Sweep the domain mechanically rather than trusting the table's length, so
	// a duplicated row cannot mask a missing one.
	for ([_]OpenMode{ .inspect_only, .immediate_recreate }) |mode| {
		for (0..8) |bits| {
			const probe = SchemaProbe{
				.init_failed = bits & 0b001 != 0,
				.model_mismatch = bits & 0b010 != 0,
				.dim_mismatch = bits & 0b100 != 0,
			};
			var matches: usize = 0;
			for (decision_table) |case| {
				if (case.mode == mode and std.meta.eql(case.probe, probe)) matches += 1;
			}
			if (matches != 1) {
				std.debug.print(
					"domain point mode={s} init_failed={} model_mismatch={} dim_mismatch={} matched {d} table rows\n",
					.{ @tagName(mode), probe.init_failed, probe.model_mismatch, probe.dim_mismatch, matches },
				);
				return error.DomainPointNotCoveredExactlyOnce;
			}
		}
	}
}

test "decideDbAction matches the openUpdateDb decision table across the whole domain" {
	for (decision_table) |case| {
		const actual = decideDbAction(case.probe, case.mode);
		if (actual != case.expected) {
			std.debug.print(
				"mode={s} init_failed={} model_mismatch={} dim_mismatch={}: expected {s}, got {s}\n",
				.{
					@tagName(case.mode),
					case.probe.init_failed,
					case.probe.model_mismatch,
					case.probe.dim_mismatch,
					@tagName(case.expected),
					@tagName(actual),
				},
			);
			return error.DecisionMismatch;
		}
	}
}
