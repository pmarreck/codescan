const std = @import("std");

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.standardOptimizeOption(.{});

	const main_module = b.createModule(.{
		.root_source_file = b.path("src/main.zig"),
		.target = target,
		.optimize = optimize,
	});

	const sqlite_vec_dep = b.dependency("sqlite_vec", .{
		.target = target,
		.optimize = optimize,
	});
	const sqlite3_lib = sqlite_vec_dep.artifact("sqlite3");
	const vec_static_lib = sqlite_vec_dep.artifact("sqlite_vec0");

	const exe = b.addExecutable(.{
		.name = "codescan",
		.root_module = main_module,
	});
	exe.linkLibrary(sqlite3_lib);
	exe.linkLibrary(vec_static_lib);
	exe.root_module.linkSystemLibrary("pcre2-8", .{ .preferred_link_mode = .static });
	b.installArtifact(exe);

	const test_step = b.step("test", "Run unit tests");

	const cli_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/cli.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	cli_tests.linkLibrary(sqlite3_lib);
	cli_tests.linkLibrary(vec_static_lib);
	cli_tests.root_module.linkSystemLibrary("pcre2-8", .{ .preferred_link_mode = .static });
	test_step.dependOn(&b.addRunArtifact(cli_tests).step);

	const main_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/main.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	main_tests.linkLibrary(sqlite3_lib);
	main_tests.linkLibrary(vec_static_lib);
	main_tests.root_module.linkSystemLibrary("pcre2-8", .{ .preferred_link_mode = .static });
	test_step.dependOn(&b.addRunArtifact(main_tests).step);

	const config_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/config.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	config_tests.linkLibrary(sqlite3_lib);
	config_tests.linkLibrary(vec_static_lib);
	config_tests.root_module.linkSystemLibrary("pcre2-8", .{ .preferred_link_mode = .static });
	test_step.dependOn(&b.addRunArtifact(config_tests).step);

	const storage_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/storage.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	storage_tests.linkLibrary(sqlite3_lib);
	storage_tests.linkLibrary(vec_static_lib);
	storage_tests.root_module.linkSystemLibrary("pcre2-8", .{ .preferred_link_mode = .static });
	test_step.dependOn(&b.addRunArtifact(storage_tests).step);

	const ollama_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/ollama.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	ollama_tests.linkLibrary(sqlite3_lib);
	ollama_tests.linkLibrary(vec_static_lib);
	ollama_tests.root_module.linkSystemLibrary("pcre2-8", .{ .preferred_link_mode = .static });
	test_step.dependOn(&b.addRunArtifact(ollama_tests).step);

	const plugin_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/plugin.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	plugin_tests.linkLibrary(sqlite3_lib);
	plugin_tests.linkLibrary(vec_static_lib);
	plugin_tests.root_module.linkSystemLibrary("pcre2-8", .{ .preferred_link_mode = .static });
	test_step.dependOn(&b.addRunArtifact(plugin_tests).step);

	const extract_zig_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/extract_zig.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	extract_zig_tests.linkLibrary(sqlite3_lib);
	extract_zig_tests.linkLibrary(vec_static_lib);
	extract_zig_tests.root_module.linkSystemLibrary("pcre2-8", .{ .preferred_link_mode = .static });
	test_step.dependOn(&b.addRunArtifact(extract_zig_tests).step);

	const extract_elixir_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/extract_elixir.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	extract_elixir_tests.linkLibrary(sqlite3_lib);
	extract_elixir_tests.linkLibrary(vec_static_lib);
	extract_elixir_tests.root_module.linkSystemLibrary("pcre2-8", .{ .preferred_link_mode = .static });
	test_step.dependOn(&b.addRunArtifact(extract_elixir_tests).step);

	const scan_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/scan.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	scan_tests.linkLibrary(sqlite3_lib);
	scan_tests.linkLibrary(vec_static_lib);
	scan_tests.root_module.linkSystemLibrary("pcre2-8", .{ .preferred_link_mode = .static });
	test_step.dependOn(&b.addRunArtifact(scan_tests).step);

	const embedding_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/embedding.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	embedding_tests.linkLibrary(sqlite3_lib);
	embedding_tests.linkLibrary(vec_static_lib);
	embedding_tests.root_module.linkSystemLibrary("pcre2-8", .{ .preferred_link_mode = .static });
	test_step.dependOn(&b.addRunArtifact(embedding_tests).step);

	const indexer_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/indexer.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	indexer_tests.linkLibrary(sqlite3_lib);
	indexer_tests.linkLibrary(vec_static_lib);
	indexer_tests.root_module.linkSystemLibrary("pcre2-8", .{ .preferred_link_mode = .static });
	test_step.dependOn(&b.addRunArtifact(indexer_tests).step);

	const search_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/search.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	search_tests.linkLibrary(sqlite3_lib);
	search_tests.linkLibrary(vec_static_lib);
	search_tests.root_module.linkSystemLibrary("pcre2-8", .{ .preferred_link_mode = .static });
	test_step.dependOn(&b.addRunArtifact(search_tests).step);

	const output_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/output.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	output_tests.linkLibrary(sqlite3_lib);
	output_tests.linkLibrary(vec_static_lib);
	output_tests.root_module.linkSystemLibrary("pcre2-8", .{ .preferred_link_mode = .static });
	test_step.dependOn(&b.addRunArtifact(output_tests).step);

	const server_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/server.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	server_tests.linkLibrary(sqlite3_lib);
	server_tests.linkLibrary(vec_static_lib);
	server_tests.root_module.linkSystemLibrary("pcre2-8", .{ .preferred_link_mode = .static });
	test_step.dependOn(&b.addRunArtifact(server_tests).step);
}
