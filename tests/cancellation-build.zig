const std = @import("std");

// Nix stages the transport, I/O singleton, and the pinned diagnostic test runner.
pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.standardOptimizeOption(.{});
	const tests = b.addTest(.{
		.name = "codescan-cancellation-tests",
		.filters = &.{ "cancel", "send errors close" },
		.test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
		.root_module = b.createModule(.{
			.root_source_file = b.path("embedding_http.zig"),
			.target = target,
			.optimize = optimize,
			.link_libc = true,
		}),
	});
	b.getInstallStep().dependOn(&b.addInstallArtifact(tests, .{}).step);
}
