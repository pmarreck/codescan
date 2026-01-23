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
	exe.linkSystemLibrary("pcre2-8");
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
	cli_tests.linkSystemLibrary("pcre2-8");
	test_step.dependOn(&b.addRunArtifact(cli_tests).step);

	const main_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/main.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	main_tests.linkSystemLibrary("sqlite3");
	main_tests.linkSystemLibrary("pcre2-8");
	test_step.dependOn(&b.addRunArtifact(main_tests).step);

	const config_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/config.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	config_tests.linkSystemLibrary("sqlite3");
	config_tests.linkSystemLibrary("pcre2-8");
	test_step.dependOn(&b.addRunArtifact(config_tests).step);

	const storage_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/storage.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	storage_tests.linkSystemLibrary("sqlite3");
	storage_tests.linkSystemLibrary("pcre2-8");
	test_step.dependOn(&b.addRunArtifact(storage_tests).step);

	const ollama_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/ollama.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	ollama_tests.linkSystemLibrary("sqlite3");
	ollama_tests.linkSystemLibrary("pcre2-8");
	test_step.dependOn(&b.addRunArtifact(ollama_tests).step);

	const plugin_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/plugin.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	plugin_tests.linkSystemLibrary("sqlite3");
	plugin_tests.linkSystemLibrary("pcre2-8");
	test_step.dependOn(&b.addRunArtifact(plugin_tests).step);

	const extract_zig_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/extract_zig.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	extract_zig_tests.linkSystemLibrary("sqlite3");
	extract_zig_tests.linkSystemLibrary("pcre2-8");
	test_step.dependOn(&b.addRunArtifact(extract_zig_tests).step);

	const extract_elixir_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/extract_elixir.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	extract_elixir_tests.linkSystemLibrary("sqlite3");
	extract_elixir_tests.linkSystemLibrary("pcre2-8");
	test_step.dependOn(&b.addRunArtifact(extract_elixir_tests).step);

	const scan_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/scan.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	scan_tests.linkSystemLibrary("sqlite3");
	scan_tests.linkSystemLibrary("pcre2-8");
	test_step.dependOn(&b.addRunArtifact(scan_tests).step);

	const embedding_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/embedding.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	embedding_tests.linkSystemLibrary("sqlite3");
	embedding_tests.linkSystemLibrary("pcre2-8");
	test_step.dependOn(&b.addRunArtifact(embedding_tests).step);

	const indexer_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/indexer.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	indexer_tests.linkSystemLibrary("sqlite3");
	indexer_tests.linkSystemLibrary("pcre2-8");
	test_step.dependOn(&b.addRunArtifact(indexer_tests).step);

	const search_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/search.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	search_tests.linkSystemLibrary("sqlite3");
	search_tests.linkSystemLibrary("pcre2-8");
	test_step.dependOn(&b.addRunArtifact(search_tests).step);

	const output_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/output.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	output_tests.linkSystemLibrary("sqlite3");
	output_tests.linkSystemLibrary("pcre2-8");
	test_step.dependOn(&b.addRunArtifact(output_tests).step);

	const server_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/server.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	server_tests.linkSystemLibrary("sqlite3");
	server_tests.linkSystemLibrary("pcre2-8");
	test_step.dependOn(&b.addRunArtifact(server_tests).step);
}
