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
	const pcre2_dep = b.dependency("pcre2", .{
		.target = target,
		.optimize = optimize,
		.linkage = .static,
		.@"code-unit-width" = .@"8",
	});
	const pcre2_lib = pcre2_dep.artifact("pcre2-8");
	const ts_lib = buildTreeSitter(b, target, optimize);
	const tsc_lib = buildTreeSitterGrammar(b, target, optimize, "tree_sitter_c", "deps/tree-sitter-c/src", false);
	const ts_typescript = buildTreeSitterGrammar(b, target, optimize, "tree_sitter_typescript", "deps/tree-sitter-typescript/typescript/src", true);
	const ts_tsx = buildTreeSitterGrammar(b, target, optimize, "tree_sitter_tsx", "deps/tree-sitter-typescript/tsx/src", true);
	const ts_rust = buildTreeSitterGrammar(b, target, optimize, "tree_sitter_rust", "deps/tree-sitter-rust/src", true);
	const ts_bash = buildTreeSitterGrammar(b, target, optimize, "tree_sitter_bash", "deps/tree-sitter-bash/src", true);
	const ts_lua = buildTreeSitterGrammar(b, target, optimize, "tree_sitter_lua", "deps/tree-sitter-lua/src", true);
	const ts_nix = buildTreeSitterGrammar(b, target, optimize, "tree_sitter_nix", "deps/tree-sitter-nix/src", true);
	const ts_nim = buildTreeSitterGrammar(b, target, optimize, "tree_sitter_nim", "deps/tree-sitter-nim/src", true);
	const ts_lean = buildTreeSitterGrammar(b, target, optimize, "tree_sitter_lean", "deps/tree-sitter-lean/src", true);
	const ts_idris = buildTreeSitterGrammar(b, target, optimize, "tree_sitter_idris2", "deps/tree-sitter-idris2/src", false);
	const ts_haskell = buildTreeSitterGrammar(b, target, optimize, "tree_sitter_haskell", "deps/tree-sitter-haskell/src", true);
	const ts_langs = [_]*std.Build.Step.Compile{
		tsc_lib,
		ts_typescript,
		ts_tsx,
		ts_rust,
		ts_bash,
		ts_lua,
		ts_nix,
		ts_nim,
		ts_lean,
		ts_idris,
		ts_haskell,
	};

	const exe = b.addExecutable(.{
		.name = "codescan",
		.root_module = main_module,
	});
	addPcre2Includes(main_module, pcre2_lib);
	linkCommon(exe, sqlite3_lib, vec_static_lib, pcre2_lib, ts_lib, &ts_langs);
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
	addPcre2Includes(cli_tests.root_module, pcre2_lib);
	linkCommon(cli_tests, sqlite3_lib, vec_static_lib, pcre2_lib, ts_lib, &ts_langs);
	test_step.dependOn(&b.addRunArtifact(cli_tests).step);

	const main_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/main.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, main_tests.root_module);
	addPcre2Includes(main_tests.root_module, pcre2_lib);
	linkCommon(main_tests, sqlite3_lib, vec_static_lib, pcre2_lib, ts_lib, &ts_langs);
	test_step.dependOn(&b.addRunArtifact(main_tests).step);

	const config_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/config.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, config_tests.root_module);
	addPcre2Includes(config_tests.root_module, pcre2_lib);
	linkCommon(config_tests, sqlite3_lib, vec_static_lib, pcre2_lib, ts_lib, &ts_langs);
	test_step.dependOn(&b.addRunArtifact(config_tests).step);

	const storage_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/storage.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, storage_tests.root_module);
	addPcre2Includes(storage_tests.root_module, pcre2_lib);
	linkCommon(storage_tests, sqlite3_lib, vec_static_lib, pcre2_lib, ts_lib, &ts_langs);
	test_step.dependOn(&b.addRunArtifact(storage_tests).step);

	const ollama_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/ollama.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, ollama_tests.root_module);
	addPcre2Includes(ollama_tests.root_module, pcre2_lib);
	linkCommon(ollama_tests, sqlite3_lib, vec_static_lib, pcre2_lib, ts_lib, &ts_langs);
	test_step.dependOn(&b.addRunArtifact(ollama_tests).step);

	const plugin_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/plugin.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, plugin_tests.root_module);
	addPcre2Includes(plugin_tests.root_module, pcre2_lib);
	linkCommon(plugin_tests, sqlite3_lib, vec_static_lib, pcre2_lib, ts_lib, &ts_langs);
	test_step.dependOn(&b.addRunArtifact(plugin_tests).step);

	const extract_zig_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/extract_zig.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, extract_zig_tests.root_module);
	addPcre2Includes(extract_zig_tests.root_module, pcre2_lib);
	linkCommon(extract_zig_tests, sqlite3_lib, vec_static_lib, pcre2_lib, ts_lib, &ts_langs);
	test_step.dependOn(&b.addRunArtifact(extract_zig_tests).step);

	const extract_elixir_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/extract_elixir.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, extract_elixir_tests.root_module);
	addPcre2Includes(extract_elixir_tests.root_module, pcre2_lib);
	linkCommon(extract_elixir_tests, sqlite3_lib, vec_static_lib, pcre2_lib, ts_lib, &ts_langs);
	test_step.dependOn(&b.addRunArtifact(extract_elixir_tests).step);

	const extract_c_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/extract_c.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, extract_c_tests.root_module);
	addPcre2Includes(extract_c_tests.root_module, pcre2_lib);
	linkCommon(extract_c_tests, sqlite3_lib, vec_static_lib, pcre2_lib, ts_lib, &ts_langs);
	test_step.dependOn(&b.addRunArtifact(extract_c_tests).step);

	const extract_util_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/extract_util.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, extract_util_tests.root_module);
	addPcre2Includes(extract_util_tests.root_module, pcre2_lib);
	linkCommon(extract_util_tests, sqlite3_lib, vec_static_lib, pcre2_lib, ts_lib, &ts_langs);
	test_step.dependOn(&b.addRunArtifact(extract_util_tests).step);

	const extract_typescript_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/extract_typescript.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, extract_typescript_tests.root_module);
	addPcre2Includes(extract_typescript_tests.root_module, pcre2_lib);
	linkCommon(extract_typescript_tests, sqlite3_lib, vec_static_lib, pcre2_lib, ts_lib, &ts_langs);
	test_step.dependOn(&b.addRunArtifact(extract_typescript_tests).step);

	const extract_rust_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/extract_rust.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, extract_rust_tests.root_module);
	addPcre2Includes(extract_rust_tests.root_module, pcre2_lib);
	linkCommon(extract_rust_tests, sqlite3_lib, vec_static_lib, pcre2_lib, ts_lib, &ts_langs);
	test_step.dependOn(&b.addRunArtifact(extract_rust_tests).step);

	const extract_bash_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/extract_bash.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, extract_bash_tests.root_module);
	addPcre2Includes(extract_bash_tests.root_module, pcre2_lib);
	linkCommon(extract_bash_tests, sqlite3_lib, vec_static_lib, pcre2_lib, ts_lib, &ts_langs);
	test_step.dependOn(&b.addRunArtifact(extract_bash_tests).step);

	const extract_lua_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/extract_lua.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, extract_lua_tests.root_module);
	addPcre2Includes(extract_lua_tests.root_module, pcre2_lib);
	linkCommon(extract_lua_tests, sqlite3_lib, vec_static_lib, pcre2_lib, ts_lib, &ts_langs);
	test_step.dependOn(&b.addRunArtifact(extract_lua_tests).step);

	const extract_nim_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/extract_nim.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, extract_nim_tests.root_module);
	addPcre2Includes(extract_nim_tests.root_module, pcre2_lib);
	linkCommon(extract_nim_tests, sqlite3_lib, vec_static_lib, pcre2_lib, ts_lib, &ts_langs);
	test_step.dependOn(&b.addRunArtifact(extract_nim_tests).step);

	const extract_nix_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/extract_nix.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, extract_nix_tests.root_module);
	addPcre2Includes(extract_nix_tests.root_module, pcre2_lib);
	linkCommon(extract_nix_tests, sqlite3_lib, vec_static_lib, pcre2_lib, ts_lib, &ts_langs);
	test_step.dependOn(&b.addRunArtifact(extract_nix_tests).step);

	const extract_lean_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/extract_lean.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, extract_lean_tests.root_module);
	addPcre2Includes(extract_lean_tests.root_module, pcre2_lib);
	linkCommon(extract_lean_tests, sqlite3_lib, vec_static_lib, pcre2_lib, ts_lib, &ts_langs);
	test_step.dependOn(&b.addRunArtifact(extract_lean_tests).step);

	const extract_idris_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/extract_idris.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, extract_idris_tests.root_module);
	addPcre2Includes(extract_idris_tests.root_module, pcre2_lib);
	linkCommon(extract_idris_tests, sqlite3_lib, vec_static_lib, pcre2_lib, ts_lib, &ts_langs);
	test_step.dependOn(&b.addRunArtifact(extract_idris_tests).step);

	const extract_haskell_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/extract_haskell.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, extract_haskell_tests.root_module);
	addPcre2Includes(extract_haskell_tests.root_module, pcre2_lib);
	linkCommon(extract_haskell_tests, sqlite3_lib, vec_static_lib, pcre2_lib, ts_lib, &ts_langs);
	test_step.dependOn(&b.addRunArtifact(extract_haskell_tests).step);

	const extract_markdown_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/extract_markdown.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addPcre2Includes(extract_markdown_tests.root_module, pcre2_lib);
	linkCommon(extract_markdown_tests, sqlite3_lib, vec_static_lib, pcre2_lib, ts_lib, &ts_langs);
	test_step.dependOn(&b.addRunArtifact(extract_markdown_tests).step);

	const extract_text_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/extract_text.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addPcre2Includes(extract_text_tests.root_module, pcre2_lib);
	linkCommon(extract_text_tests, sqlite3_lib, vec_static_lib, pcre2_lib, ts_lib, &ts_langs);
	test_step.dependOn(&b.addRunArtifact(extract_text_tests).step);

	const extract_log_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/extract_log.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addPcre2Includes(extract_log_tests.root_module, pcre2_lib);
	linkCommon(extract_log_tests, sqlite3_lib, vec_static_lib, pcre2_lib, ts_lib, &ts_langs);
	test_step.dependOn(&b.addRunArtifact(extract_log_tests).step);

	const scan_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/scan.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, scan_tests.root_module);
	addPcre2Includes(scan_tests.root_module, pcre2_lib);
	linkCommon(scan_tests, sqlite3_lib, vec_static_lib, pcre2_lib, ts_lib, &ts_langs);
	test_step.dependOn(&b.addRunArtifact(scan_tests).step);

	const embedding_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/embedding.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, embedding_tests.root_module);
	addPcre2Includes(embedding_tests.root_module, pcre2_lib);
	linkCommon(embedding_tests, sqlite3_lib, vec_static_lib, pcre2_lib, ts_lib, &ts_langs);
	test_step.dependOn(&b.addRunArtifact(embedding_tests).step);

	const indexer_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/indexer.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, indexer_tests.root_module);
	addPcre2Includes(indexer_tests.root_module, pcre2_lib);
	linkCommon(indexer_tests, sqlite3_lib, vec_static_lib, pcre2_lib, ts_lib, &ts_langs);
	test_step.dependOn(&b.addRunArtifact(indexer_tests).step);

	const search_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/search.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, search_tests.root_module);
	addPcre2Includes(search_tests.root_module, pcre2_lib);
	linkCommon(search_tests, sqlite3_lib, vec_static_lib, pcre2_lib, ts_lib, &ts_langs);
	test_step.dependOn(&b.addRunArtifact(search_tests).step);

	const output_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/output.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, output_tests.root_module);
	addPcre2Includes(output_tests.root_module, pcre2_lib);
	linkCommon(output_tests, sqlite3_lib, vec_static_lib, pcre2_lib, ts_lib, &ts_langs);
	test_step.dependOn(&b.addRunArtifact(output_tests).step);

	const server_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/server.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	addTreeSitterIncludes(b, server_tests.root_module);
	addPcre2Includes(server_tests.root_module, pcre2_lib);
	linkCommon(server_tests, sqlite3_lib, vec_static_lib, pcre2_lib, ts_lib, &ts_langs);
	test_step.dependOn(&b.addRunArtifact(server_tests).step);
}

fn addTreeSitterIncludes(b: *std.Build, module: *std.Build.Module) void {
	module.addIncludePath(b.path("deps/tree-sitter/lib/include"));
}

fn addPcre2Includes(module: *std.Build.Module, pcre2_lib: *std.Build.Step.Compile) void {
	module.addIncludePath(pcre2_lib.getEmittedIncludeTree());
}

fn linkCommon(
	compile: *std.Build.Step.Compile,
	sqlite3_lib: *std.Build.Step.Compile,
	vec_static_lib: *std.Build.Step.Compile,
	pcre2_lib: *std.Build.Step.Compile,
	ts_lib: *std.Build.Step.Compile,
	lang_libs: []const *std.Build.Step.Compile,
) void {
	compile.linkLibrary(sqlite3_lib);
	compile.linkLibrary(vec_static_lib);
	compile.linkLibrary(pcre2_lib);
	compile.linkLibrary(ts_lib);
	for (lang_libs) |lib| compile.linkLibrary(lib);
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

fn buildTreeSitterGrammar(
	b: *std.Build,
	target: std.Build.ResolvedTarget,
	optimize: std.builtin.OptimizeMode,
	name: []const u8,
	dir: []const u8,
	has_scanner: bool,
) *std.Build.Step.Compile {
	const module = b.createModule(.{
		.target = target,
		.optimize = optimize,
	});
	const lib = b.addLibrary(.{
		.name = name,
		.root_module = module,
		.linkage = .static,
	});
	module.addCSourceFile(.{
		.file = b.path(b.fmt("{s}/parser.c", .{dir})),
	});
	if (has_scanner) {
		module.addCSourceFile(.{
			.file = b.path(b.fmt("{s}/scanner.c", .{dir})),
		});
	}
	module.addIncludePath(b.path(dir));
	module.addIncludePath(b.path("deps/tree-sitter/lib/include"));
	module.addIncludePath(b.path("deps/tree-sitter/lib/src"));
	lib.linkLibC();
	return lib;
}
