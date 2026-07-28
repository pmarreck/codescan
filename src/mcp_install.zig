const std = @import("std");

/// A coding agent whose MCP server list codescan can register itself in.
pub const Agent = enum {
	claude,
	codex,

	/// The executable name looked up on PATH. Absence of this binary is how
	/// "this agent is not installed" is detected.
	pub fn cli(self: Agent) []const u8 {
		return switch (self) {
			.claude => "claude",
			.codex => "codex",
		};
	}

	pub fn label(self: Agent) []const u8 {
		return switch (self) {
			.claude => "Claude Code",
			.codex => "Codex",
		};
	}
};

/// Where a registration is written. Claude Code distinguishes user scope
/// (every session) from project scope (one repository); Codex keeps a single
/// global list, so both values collapse to it there.
pub const Scope = enum {
	user,
	project,

	pub fn flagValue(self: Scope) []const u8 {
		return switch (self) {
			.user => "user",
			.project => "project",
		};
	}
};

/// What was observed about one agent before deciding whether to register.
pub const AgentState = struct {
	cli_present: bool,
	already_registered: bool,
};

/// The registration verdict for a single agent.
pub const Action = enum {
	install,
	reinstall_forced,
	skip_already_registered,
	skip_cli_absent,
};

/// Decides whether to register codescan with one agent. Pure and total over the
/// finite state × force domain so the policy can be exhausted rather than
/// sampled — in particular, `force` must never turn a first-time install into a
/// reinstall, and a missing CLI must dominate everything else.
pub fn decideAction(state: AgentState, force: bool) Action {
	// Without the agent's CLI there is nothing to probe and nothing to write,
	// so this dominates both remaining inputs.
	if (!state.cli_present) return .skip_cli_absent;

	// `force` only means "replace what is there"; with nothing registered it
	// must not escalate into a remove-then-add of a nonexistent entry.
	if (!state.already_registered) return .install;

	return if (force) .reinstall_forced else .skip_already_registered;
}

/// Argv for the presence probe. Both CLIs expose `mcp get <name>`, exiting 0
/// when the server is registered and non-zero when it is not, so membership is
/// decided by the owning tool rather than by matching text in its output — a
/// server named `codescan-old` cannot be mistaken for `codescan`.
pub fn probeArgv(agent: Agent, name: []const u8) [4][]const u8 {
	return .{ agent.cli(), "mcp", "get", name };
}

/// Argv that registers the server. Caller owns the returned slice (the elements
/// are borrowed). Claude Code takes an explicit `--scope`; Codex has no scope
/// concept and always writes its single global list.
pub fn installArgv(
	allocator: std.mem.Allocator,
	agent: Agent,
	scope: Scope,
	name: []const u8,
	command: []const u8,
	command_args: []const []const u8,
) ![][]const u8 {
	var argv: std.ArrayListUnmanaged([]const u8) = .empty;
	errdefer argv.deinit(allocator);

	try argv.appendSlice(allocator, &.{ agent.cli(), "mcp", "add", name });
	if (agent == .claude) {
		try argv.appendSlice(allocator, &.{ "--scope", scope.flagValue() });
	}
	try argv.appendSlice(allocator, &.{ "--", command });
	try argv.appendSlice(allocator, command_args);

	return argv.toOwnedSlice(allocator);
}

/// Argv that removes an existing registration, used only to make `--force`
/// idempotent — `mcp add` refuses to overwrite an existing entry.
pub fn removeArgv(
	allocator: std.mem.Allocator,
	agent: Agent,
	scope: Scope,
	name: []const u8,
) ![][]const u8 {
	var argv: std.ArrayListUnmanaged([]const u8) = .empty;
	errdefer argv.deinit(allocator);

	try argv.appendSlice(allocator, &.{ agent.cli(), "mcp", "remove", name });
	if (agent == .claude) {
		try argv.appendSlice(allocator, &.{ "--scope", scope.flagValue() });
	}

	return argv.toOwnedSlice(allocator);
}

const DecisionCase = struct {
	state: AgentState,
	force: bool,
	expected: Action,
};

/// Every point of the `cli_present` × `already_registered` × `force` domain
/// (2^3 = 8). Written from the intended contract, not from the implementation.
const decision_table = [_]DecisionCase{
	// A missing CLI dominates: we can neither probe nor install, and `force`
	// must not pretend otherwise. All four combinations must agree.
	.{ .state = .{ .cli_present = false, .already_registered = false }, .force = false, .expected = .skip_cli_absent },
	.{ .state = .{ .cli_present = false, .already_registered = false }, .force = true, .expected = .skip_cli_absent },
	.{ .state = .{ .cli_present = false, .already_registered = true }, .force = false, .expected = .skip_cli_absent },
	.{ .state = .{ .cli_present = false, .already_registered = true }, .force = true, .expected = .skip_cli_absent },

	// Not yet registered: install. `force` is irrelevant here — if it flipped
	// this to a reinstall we would issue a remove for an entry that does not
	// exist, which is the "do nothing loudly" failure this command exists to
	// avoid.
	.{ .state = .{ .cli_present = true, .already_registered = false }, .force = false, .expected = .install },
	.{ .state = .{ .cli_present = true, .already_registered = false }, .force = true, .expected = .install },

	// Already registered: leave a user's hand-edited entry alone unless forced.
	.{ .state = .{ .cli_present = true, .already_registered = true }, .force = false, .expected = .skip_already_registered },
	.{ .state = .{ .cli_present = true, .already_registered = true }, .force = true, .expected = .reinstall_forced },
};

test "decision table covers every state/force domain point exactly once" {
	for ([_]bool{ false, true }) |cli_present| {
		for ([_]bool{ false, true }) |already_registered| {
			for ([_]bool{ false, true }) |force| {
				var matches: usize = 0;
				for (decision_table) |case| {
					if (case.state.cli_present == cli_present and
						case.state.already_registered == already_registered and
						case.force == force) matches += 1;
				}
				if (matches != 1) {
					std.debug.print(
						"domain point cli_present={} already_registered={} force={} matched {d} rows\n",
						.{ cli_present, already_registered, force, matches },
					);
					return error.DomainPointNotCoveredExactlyOnce;
				}
			}
		}
	}
}

test "decideAction matches the registration policy across the whole domain" {
	for (decision_table) |case| {
		const actual = decideAction(case.state, case.force);
		if (actual != case.expected) {
			std.debug.print(
				"cli_present={} already_registered={} force={}: expected {s}, got {s}\n",
				.{
					case.state.cli_present,
					case.state.already_registered,
					case.force,
					@tagName(case.expected),
					@tagName(actual),
				},
			);
			return error.DecisionMismatch;
		}
	}
}

test "probeArgv delegates membership to the agent's own tool" {
	const claude = probeArgv(.claude, "codescan");
	try std.testing.expectEqualStrings("claude", claude[0]);
	try std.testing.expectEqualStrings("mcp", claude[1]);
	try std.testing.expectEqualStrings("get", claude[2]);
	try std.testing.expectEqualStrings("codescan", claude[3]);

	const codex = probeArgv(.codex, "codescan");
	try std.testing.expectEqualStrings("codex", codex[0]);
	try std.testing.expectEqualStrings("get", codex[2]);
}

test "installArgv passes scope to Claude and omits it for Codex" {
	const allocator = std.testing.allocator;

	const claude = try installArgv(allocator, .claude, .user, "codescan", "codescan", &.{"mcp-serve"});
	defer allocator.free(claude);
	try std.testing.expectEqualDeep(
		@as([]const []const u8, &.{ "claude", "mcp", "add", "codescan", "--scope", "user", "--", "codescan", "mcp-serve" }),
		claude,
	);

	const claude_project = try installArgv(allocator, .claude, .project, "codescan", "codescan", &.{"mcp-serve"});
	defer allocator.free(claude_project);
	try std.testing.expectEqualStrings("project", claude_project[5]);

	// Codex has no scope concept, so the flag must not leak into its argv in
	// either scope — it would be rejected as an unknown option.
	for ([_]Scope{ .user, .project }) |scope| {
		const codex = try installArgv(allocator, .codex, scope, "codescan", "codescan", &.{"mcp-serve"});
		defer allocator.free(codex);
		try std.testing.expectEqualDeep(
			@as([]const []const u8, &.{ "codex", "mcp", "add", "codescan", "--", "codescan", "mcp-serve" }),
			codex,
		);
	}
}

test "removeArgv mirrors installArgv's scope handling" {
	const allocator = std.testing.allocator;

	const claude = try removeArgv(allocator, .claude, .user, "codescan");
	defer allocator.free(claude);
	try std.testing.expectEqualDeep(
		@as([]const []const u8, &.{ "claude", "mcp", "remove", "codescan", "--scope", "user" }),
		claude,
	);

	const codex = try removeArgv(allocator, .codex, .user, "codescan");
	defer allocator.free(codex);
	try std.testing.expectEqualDeep(
		@as([]const []const u8, &.{ "codex", "mcp", "remove", "codescan" }),
		codex,
	);
}
