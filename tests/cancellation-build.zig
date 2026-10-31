const std = @import("std");

// Nix stages only the transport and I/O singleton alongside this build graph.
pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.standardOptimizeOption(.{});
	const tests = b.addTest(.{
		.name = "codescan-cancellation-tests",
		.filters = &.{"cancel"},
		.root_module = b.createModule(.{
			.root_source_file = b.path("embedding_http.zig"),
			.target = target,
			.optimize = optimize,
			.link_libc = true,
		}),
	});
	b.getInstallStep().dependOn(&b.addInstallArtifact(tests, .{}).step);
}
