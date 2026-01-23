const std = @import("std");
const model = @import("model.zig");
const extract_zig = @import("extract_zig.zig");
const extract_elixir = @import("extract_elixir.zig");
const extract_c = @import("extract_c.zig");
const extract_typescript = @import("extract_typescript.zig");
const extract_rust = @import("extract_rust.zig");
const extract_lean = @import("extract_lean.zig");
const extract_idris = @import("extract_idris.zig");
const extract_nix = @import("extract_nix.zig");
const extract_nim = @import("extract_nim.zig");
const extract_bash = @import("extract_bash.zig");
const extract_lua = @import("extract_lua.zig");
const zig_plugin = @import("plugins/zig/mod.zig");
const elixir_plugin = @import("plugins/elixir/mod.zig");
const c_plugin = @import("plugins/c/mod.zig");
const typescript_plugin = @import("plugins/typescript/mod.zig");
const rust_plugin = @import("plugins/rust/mod.zig");
const lean_plugin = @import("plugins/lean/mod.zig");
const idris_plugin = @import("plugins/idris/mod.zig");
const nix_plugin = @import("plugins/nix/mod.zig");
const nim_plugin = @import("plugins/nim/mod.zig");
const bash_plugin = @import("plugins/bash/mod.zig");
const lua_plugin = @import("plugins/lua/mod.zig");

pub const ExtractorFn = *const fn (
	allocator: std.mem.Allocator,
	file_path: []const u8,
	source: []const u8,
) anyerror![]model.Symbol;

pub const Extractor = struct {
	language: []const u8,
	extensions: []const []const u8,
	ignore_patterns: []const []const u8,
	extract: ExtractorFn,
};

pub const Registry = struct {
	extractors: []const Extractor,

	pub fn find(self: Registry, path: []const u8) ?*const Extractor {
		for (self.extractors) |*extractor| {
			for (extractor.extensions) |ext| {
				if (hasExtension(path, ext)) return extractor;
			}
		}
		return null;
	}
};

pub fn defaultRegistry() Registry {
	return .{
		.extractors = &[_]Extractor{
			.{
				.language = zig_plugin.language,
				.extensions = zig_plugin.extensions,
				.ignore_patterns = zig_plugin.ignore_patterns,
				.extract = extract_zig.extract,
			},
			.{
				.language = elixir_plugin.language,
				.extensions = elixir_plugin.extensions,
				.ignore_patterns = elixir_plugin.ignore_patterns,
				.extract = extract_elixir.extract,
			},
			.{
				.language = c_plugin.language,
				.extensions = c_plugin.extensions,
				.ignore_patterns = c_plugin.ignore_patterns,
				.extract = extract_c.extract,
			},
			.{
				.language = typescript_plugin.language,
				.extensions = typescript_plugin.extensions,
				.ignore_patterns = typescript_plugin.ignore_patterns,
				.extract = extract_typescript.extract,
			},
			.{
				.language = rust_plugin.language,
				.extensions = rust_plugin.extensions,
				.ignore_patterns = rust_plugin.ignore_patterns,
				.extract = extract_rust.extract,
			},
			.{
				.language = lean_plugin.language,
				.extensions = lean_plugin.extensions,
				.ignore_patterns = lean_plugin.ignore_patterns,
				.extract = extract_lean.extract,
			},
			.{
				.language = idris_plugin.language,
				.extensions = idris_plugin.extensions,
				.ignore_patterns = idris_plugin.ignore_patterns,
				.extract = extract_idris.extract,
			},
			.{
				.language = nix_plugin.language,
				.extensions = nix_plugin.extensions,
				.ignore_patterns = nix_plugin.ignore_patterns,
				.extract = extract_nix.extract,
			},
			.{
				.language = nim_plugin.language,
				.extensions = nim_plugin.extensions,
				.ignore_patterns = nim_plugin.ignore_patterns,
				.extract = extract_nim.extract,
			},
			.{
				.language = bash_plugin.language,
				.extensions = bash_plugin.extensions,
				.ignore_patterns = bash_plugin.ignore_patterns,
				.extract = extract_bash.extract,
			},
			.{
				.language = lua_plugin.language,
				.extensions = lua_plugin.extensions,
				.ignore_patterns = lua_plugin.ignore_patterns,
				.extract = extract_lua.extract,
			},
		},
	};
}

fn hasExtension(path: []const u8, ext: []const u8) bool {
	return std.mem.endsWith(u8, path, ext);
}

test "registry finds extractor by extension" {
	const reg = Registry{
		.extractors = &[_]Extractor{
			.{
				.language = "zig",
				.extensions = &[_][]const u8{ ".zig" },
				.ignore_patterns = &[_][]const u8{},
				.extract = dummyExtract,
			},
			.{
				.language = "elixir",
				.extensions = &[_][]const u8{ ".ex" },
				.ignore_patterns = &[_][]const u8{},
				.extract = dummyExtract,
			},
		},
	};

	const found = reg.find("src/main.zig") orelse return error.TestExpectedEqual;
	try std.testing.expectEqualStrings("zig", found.language);
	try std.testing.expect(reg.find("lib/app.ex") != null);
	try std.testing.expect(reg.find("README.md") == null);
}

fn dummyExtract(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	source: []const u8,
) anyerror![]model.Symbol {
	_ = file_path;
	_ = source;
	return allocator.alloc(model.Symbol, 0);
}
