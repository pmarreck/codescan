const std = @import("std");

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.standardOptimizeOption(.{});

	const main_module = b.createModule(.{
		.root_source_file = b.path("src/main.zig"),
		.target = target,
		.optimize = optimize,
	});
	addTreeSitterIncludes(b, main_module);

	const sqlite_vec_dep = b.dependency("sqlite_vec", .{
		.target = target,
		.optimize = optimize,
	});
	const sqlite3_lib = sqlite_vec_dep.artifact("sqlite3");
	const vec_static_lib = sqlite_vec_dep.artifact("sqlite_vec0");
	const ts_lib = buildTreeSitter(b, target, optimize);
	const tsc_lib = buildTreeSitterC(b, target, optimize);

	const exe = b.addExecutable(.{
		.name = "codescan",
		.root_module = main_module,
	});
	linkCommon(exe, sqlite3_lib, vec_static_lib, ts_lib, tsc_lib);
	b.installArtifact(exe);

	const test_step = b.step("test", "Run unit tests");

	const cli_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/cli.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, cli_tests.root_module);
	linkCommon(cli_tests, sqlite3_lib, vec_static_lib, ts_lib, tsc_lib);
	test_step.dependOn(&b.addRunArtifact(cli_tests).step);

	const main_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/main.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, main_tests.root_module);
	linkCommon(main_tests, sqlite3_lib, vec_static_lib, ts_lib, tsc_lib);
	test_step.dependOn(&b.addRunArtifact(main_tests).step);

	const config_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/config.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, config_tests.root_module);
	linkCommon(config_tests, sqlite3_lib, vec_static_lib, ts_lib, tsc_lib);
	test_step.dependOn(&b.addRunArtifact(config_tests).step);

	const storage_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/storage.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, storage_tests.root_module);
	linkCommon(storage_tests, sqlite3_lib, vec_static_lib, ts_lib, tsc_lib);
	test_step.dependOn(&b.addRunArtifact(storage_tests).step);

	const ollama_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/ollama.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, ollama_tests.root_module);
	linkCommon(ollama_tests, sqlite3_lib, vec_static_lib, ts_lib, tsc_lib);
	test_step.dependOn(&b.addRunArtifact(ollama_tests).step);

	const plugin_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/plugin.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, plugin_tests.root_module);
	linkCommon(plugin_tests, sqlite3_lib, vec_static_lib, ts_lib, tsc_lib);
	test_step.dependOn(&b.addRunArtifact(plugin_tests).step);

	const extract_zig_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/extract_zig.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, extract_zig_tests.root_module);
	linkCommon(extract_zig_tests, sqlite3_lib, vec_static_lib, ts_lib, tsc_lib);
	test_step.dependOn(&b.addRunArtifact(extract_zig_tests).step);

	const extract_elixir_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/extract_elixir.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, extract_elixir_tests.root_module);
	linkCommon(extract_elixir_tests, sqlite3_lib, vec_static_lib, ts_lib, tsc_lib);
	test_step.dependOn(&b.addRunArtifact(extract_elixir_tests).step);

	const extract_c_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/extract_c.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, extract_c_tests.root_module);
	linkCommon(extract_c_tests, sqlite3_lib, vec_static_lib, ts_lib, tsc_lib);
	test_step.dependOn(&b.addRunArtifact(extract_c_tests).step);

	const scan_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/scan.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, scan_tests.root_module);
	linkCommon(scan_tests, sqlite3_lib, vec_static_lib, ts_lib, tsc_lib);
	test_step.dependOn(&b.addRunArtifact(scan_tests).step);

	const embedding_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/embedding.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, embedding_tests.root_module);
	linkCommon(embedding_tests, sqlite3_lib, vec_static_lib, ts_lib, tsc_lib);
	test_step.dependOn(&b.addRunArtifact(embedding_tests).step);

	const indexer_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/indexer.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, indexer_tests.root_module);
	linkCommon(indexer_tests, sqlite3_lib, vec_static_lib, ts_lib, tsc_lib);
	test_step.dependOn(&b.addRunArtifact(indexer_tests).step);

	const search_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/search.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, search_tests.root_module);
	linkCommon(search_tests, sqlite3_lib, vec_static_lib, ts_lib, tsc_lib);
	test_step.dependOn(&b.addRunArtifact(search_tests).step);

	const output_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/output.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, output_tests.root_module);
	linkCommon(output_tests, sqlite3_lib, vec_static_lib, ts_lib, tsc_lib);
	test_step.dependOn(&b.addRunArtifact(output_tests).step);

	const server_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/server.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, server_tests.root_module);
	linkCommon(server_tests, sqlite3_lib, vec_static_lib, ts_lib, tsc_lib);
	test_step.dependOn(&b.addRunArtifact(server_tests).step);
}

fn addTreeSitterIncludes(b: *std.Build, module: *std.Build.Module) void {
	module.addIncludePath(b.path("deps/tree-sitter/lib/include"));
}

fn linkCommon(
	compile: *std.Build.Step.Compile,
	sqlite3_lib: *std.Build.Step.Compile,
	vec_static_lib: *std.Build.Step.Compile,
	ts_lib: *std.Build.Step.Compile,
	tsc_lib: *std.Build.Step.Compile,
) void {
	compile.linkLibrary(sqlite3_lib);
	compile.linkLibrary(vec_static_lib);
	compile.linkLibrary(ts_lib);
	compile.linkLibrary(tsc_lib);
	compile.root_module.linkSystemLibrary("pcre2-8", .{ .preferred_link_mode = .static });
}

fn buildTreeSitter(
	b: *std.Build,
	target: std.Build.ResolvedTarget,
	optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
	const ts_module = b.createModule(.{
		.target = target,
		.optimize = optimize,
	});
	const ts_lib = b.addLibrary(.{
		.name = "tree_sitter",
		.root_module = ts_module,
		.linkage = .static,
	});
	ts_module.addCSourceFile(.{
		.file = b.path("deps/tree-sitter/lib/src/lib.c"),
	});
	ts_module.addIncludePath(b.path("deps/tree-sitter/lib/src"));
	ts_module.addIncludePath(b.path("deps/tree-sitter/lib/include"));
	ts_lib.linkLibC();
	ts_lib.installHeader(b.path("deps/tree-sitter/lib/include/tree_sitter/api.h"), "tree_sitter/api.h");
	return ts_lib;
}

fn buildTreeSitterC(
	b: *std.Build,
	target: std.Build.ResolvedTarget,
	optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
	const tsc_module = b.createModule(.{
		.target = target,
		.optimize = optimize,
	});
	const tsc_lib = b.addLibrary(.{
		.name = "tree_sitter_c",
		.root_module = tsc_module,
		.linkage = .static,
	});
	tsc_module.addCSourceFile(.{
		.file = b.path("deps/tree-sitter-c/src/parser.c"),
	});
	tsc_module.addIncludePath(b.path("deps/tree-sitter-c/src"));
	tsc_module.addIncludePath(b.path("deps/tree-sitter/lib/include"));
	tsc_module.addIncludePath(b.path("deps/tree-sitter/lib/src"));
	tsc_lib.linkLibC();
	return tsc_lib;
}
