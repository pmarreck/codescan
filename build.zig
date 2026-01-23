const std = @import("std");

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.standardOptimizeOption(.{});

	const main_module = b.createModule(.{
		.root_source_file = b.path("src/main.zig"),
		.target = target,
		.optimize = optimize,
	});

	const exe = b.addExecutable(.{
		.name = "codescan",
		.root_module = main_module,
	});
	exe.linkSystemLibrary("sqlite3");
	b.installArtifact(exe);

	const test_step = b.step("test", "Run unit tests");

	const cli_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/cli.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	cli_tests.linkSystemLibrary("sqlite3");
	test_step.dependOn(&b.addRunArtifact(cli_tests).step);

	const main_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/main.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	main_tests.linkSystemLibrary("sqlite3");
	test_step.dependOn(&b.addRunArtifact(main_tests).step);

	const config_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/config.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	config_tests.linkSystemLibrary("sqlite3");
	test_step.dependOn(&b.addRunArtifact(config_tests).step);

	const storage_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/storage.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	storage_tests.linkSystemLibrary("sqlite3");
	test_step.dependOn(&b.addRunArtifact(storage_tests).step);

	const ollama_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/ollama.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	ollama_tests.linkSystemLibrary("sqlite3");
	test_step.dependOn(&b.addRunArtifact(ollama_tests).step);
}
