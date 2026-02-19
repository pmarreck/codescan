const std = @import("std");
const model = @import("model.zig");
const kind = @import("kind.zig");
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
const extract_haskell = @import("extract_haskell.zig");
const extract_go = @import("extract_go.zig");
const extract_generic = @import("extract_generic.zig");
const extract_markdown = @import("extract_markdown.zig");
const extract_text = @import("extract_text.zig");
const extract_log = @import("extract_log.zig");
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
const haskell_plugin = @import("plugins/haskell/mod.zig");
const go_plugin = @import("plugins/go/mod.zig");
const ruby_plugin = @import("plugins/ruby/mod.zig");
const erlang_plugin = @import("plugins/erlang/mod.zig");
const ocaml_plugin = @import("plugins/ocaml/mod.zig");
const swift_plugin = @import("plugins/swift/mod.zig");
const llvm_plugin = @import("plugins/llvm/mod.zig");
const clojure_plugin = @import("plugins/clojure/mod.zig");
const assembly_plugin = @import("plugins/assembly/mod.zig");
const markdown_plugin = @import("plugins/markdown/mod.zig");
const text_plugin = @import("plugins/text/mod.zig");
const log_plugin = @import("plugins/log/mod.zig");

pub const ExtractorFn = *const fn (
	allocator: std.mem.Allocator,
	file_path: []const u8,
	source: []const u8,
) anyerror![]model.Symbol;

pub const Extractor = struct {
	language: []const u8,
	kind: kind.Kind,
	extensions: []const []const u8,
	ignore_patterns: []const []const u8,
	matches_path: ?*const fn (path: []const u8) bool = null,
	extract: ExtractorFn,
};

pub const Registry = struct {
	extractors: []const Extractor,

	pub fn find(self: Registry, path: []const u8) ?*const Extractor {
		for (self.extractors) |*extractor| {
			if (extractor.matches_path) |matcher| {
				if (matcher(path)) return extractor;
			}
			for (extractor.extensions) |ext| {
				if (hasExtension(path, ext)) return extractor;
			}
		}
		return null;
	}

	pub fn kindForLanguage(self: Registry, language: []const u8) ?kind.Kind {
		for (self.extractors) |*extractor| {
			if (std.mem.eql(u8, extractor.language, language)) return extractor.kind;
		}
		return null;
	}

	pub fn findByLanguage(self: Registry, language: []const u8) ?*const Extractor {
		for (self.extractors) |*extractor| {
			if (std.mem.eql(u8, extractor.language, language)) return extractor;
		}
		return null;
	}

	pub fn languagesForKinds(
		self: Registry,
		allocator: std.mem.Allocator,
		kinds: []const kind.Kind,
	) ![]const []const u8 {
		var out = std.ArrayListUnmanaged([]const u8){};
		errdefer {
			for (out.items) |item| allocator.free(item);
			out.deinit(allocator);
		}

		for (self.extractors) |extractor| {
			for (kinds) |wanted| {
				if (extractor.kind == wanted) {
					if (!containsString(out.items, extractor.language)) {
						try out.append(allocator, try allocator.dupe(u8, extractor.language));
					}
					break;
				}
			}
		}

		return out.toOwnedSlice(allocator);
	}
};

pub fn defaultRegistry() Registry {
	return .{
		.extractors = &[_]Extractor{
			.{
				.language = zig_plugin.language,
				.kind = zig_plugin.kind,
				.extensions = zig_plugin.extensions,
				.ignore_patterns = zig_plugin.ignore_patterns,
				.extract = extract_zig.extract,
			},
			.{
				.language = elixir_plugin.language,
				.kind = elixir_plugin.kind,
				.extensions = elixir_plugin.extensions,
				.ignore_patterns = elixir_plugin.ignore_patterns,
				.extract = extract_elixir.extract,
			},
			.{
				.language = c_plugin.language,
				.kind = c_plugin.kind,
				.extensions = c_plugin.extensions,
				.ignore_patterns = c_plugin.ignore_patterns,
				.extract = extract_c.extract,
			},
			.{
				.language = typescript_plugin.language,
				.kind = typescript_plugin.kind,
				.extensions = typescript_plugin.extensions,
				.ignore_patterns = typescript_plugin.ignore_patterns,
				.extract = extract_typescript.extract,
			},
			.{
				.language = rust_plugin.language,
				.kind = rust_plugin.kind,
				.extensions = rust_plugin.extensions,
				.ignore_patterns = rust_plugin.ignore_patterns,
				.extract = extract_rust.extract,
			},
			.{
				.language = lean_plugin.language,
				.kind = lean_plugin.kind,
				.extensions = lean_plugin.extensions,
				.ignore_patterns = lean_plugin.ignore_patterns,
				.extract = extract_lean.extract,
			},
			.{
				.language = idris_plugin.language,
				.kind = idris_plugin.kind,
				.extensions = idris_plugin.extensions,
				.ignore_patterns = idris_plugin.ignore_patterns,
				.extract = extract_idris.extract,
			},
			.{
				.language = nix_plugin.language,
				.kind = nix_plugin.kind,
				.extensions = nix_plugin.extensions,
				.ignore_patterns = nix_plugin.ignore_patterns,
				.extract = extract_nix.extract,
			},
			.{
				.language = nim_plugin.language,
				.kind = nim_plugin.kind,
				.extensions = nim_plugin.extensions,
				.ignore_patterns = nim_plugin.ignore_patterns,
				.extract = extract_nim.extract,
			},
			.{
				.language = bash_plugin.language,
				.kind = bash_plugin.kind,
				.extensions = bash_plugin.extensions,
				.ignore_patterns = bash_plugin.ignore_patterns,
				.matches_path = bash_plugin.matchesPath,
				.extract = extract_bash.extract,
			},
			.{
				.language = lua_plugin.language,
				.kind = lua_plugin.kind,
				.extensions = lua_plugin.extensions,
				.ignore_patterns = lua_plugin.ignore_patterns,
				.extract = extract_lua.extract,
			},
			.{
				.language = haskell_plugin.language,
				.kind = haskell_plugin.kind,
				.extensions = haskell_plugin.extensions,
				.ignore_patterns = haskell_plugin.ignore_patterns,
				.extract = extract_haskell.extract,
			},
			.{
				.language = go_plugin.language,
				.kind = go_plugin.kind,
				.extensions = go_plugin.extensions,
				.ignore_patterns = go_plugin.ignore_patterns,
				.extract = extract_go.extract,
			},
			.{
				.language = ruby_plugin.language,
				.kind = ruby_plugin.kind,
				.extensions = ruby_plugin.extensions,
				.ignore_patterns = ruby_plugin.ignore_patterns,
				.extract = extract_generic.extractRuby,
			},
			.{
				.language = erlang_plugin.language,
				.kind = erlang_plugin.kind,
				.extensions = erlang_plugin.extensions,
				.ignore_patterns = erlang_plugin.ignore_patterns,
				.extract = extract_generic.extractErlang,
			},
			.{
				.language = ocaml_plugin.language,
				.kind = ocaml_plugin.kind,
				.extensions = ocaml_plugin.extensions,
				.ignore_patterns = ocaml_plugin.ignore_patterns,
				.extract = extract_generic.extractOcaml,
			},
			.{
				.language = swift_plugin.language,
				.kind = swift_plugin.kind,
				.extensions = swift_plugin.extensions,
				.ignore_patterns = swift_plugin.ignore_patterns,
				.extract = extract_generic.extractSwift,
			},
			.{
				.language = llvm_plugin.language,
				.kind = llvm_plugin.kind,
				.extensions = llvm_plugin.extensions,
				.ignore_patterns = llvm_plugin.ignore_patterns,
				.extract = extract_generic.extractLlvm,
			},
			.{
				.language = clojure_plugin.language,
				.kind = clojure_plugin.kind,
				.extensions = clojure_plugin.extensions,
				.ignore_patterns = clojure_plugin.ignore_patterns,
				.extract = extract_generic.extractClojure,
			},
			.{
				.language = assembly_plugin.language,
				.kind = assembly_plugin.kind,
				.extensions = assembly_plugin.extensions,
				.ignore_patterns = assembly_plugin.ignore_patterns,
				.extract = extract_generic.extractAssembly,
			},
			.{
				.language = markdown_plugin.language,
				.kind = markdown_plugin.kind,
				.extensions = markdown_plugin.extensions,
				.ignore_patterns = markdown_plugin.ignore_patterns,
				.matches_path = markdown_plugin.matchesPath,
				.extract = extract_markdown.extract,
			},
			.{
				.language = text_plugin.language,
				.kind = text_plugin.kind,
				.extensions = text_plugin.extensions,
				.ignore_patterns = text_plugin.ignore_patterns,
				.extract = extract_text.extract,
			},
			.{
				.language = log_plugin.language,
				.kind = log_plugin.kind,
				.extensions = log_plugin.extensions,
				.ignore_patterns = log_plugin.ignore_patterns,
				.extract = extract_log.extract,
			},
		},
	};
}

fn hasExtension(path: []const u8, ext: []const u8) bool {
	return std.mem.endsWith(u8, path, ext);
}

fn containsString(list: []const []const u8, value: []const u8) bool {
	for (list) |item| {
		if (std.mem.eql(u8, item, value)) return true;
	}
	return false;
}

test "registry finds extractor by extension" {
	const reg = Registry{
		.extractors = &[_]Extractor{
			.{
				.language = "zig",
				.kind = .code,
				.extensions = &[_][]const u8{ ".zig" },
				.ignore_patterns = &[_][]const u8{},
				.extract = dummyExtract,
			},
			.{
				.language = "elixir",
				.kind = .code,
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

test "registry prefers matcher when provided" {
	const reg = Registry{
		.extractors = &[_]Extractor{
			.{
				.language = "markdown",
				.kind = .doc,
				.extensions = &[_][]const u8{},
				.ignore_patterns = &[_][]const u8{},
				.matches_path = markdownMatch,
				.extract = dummyExtract,
			},
		},
	};

	try std.testing.expect(reg.find("README") != null);
	try std.testing.expect(reg.find("README.md") != null);
	try std.testing.expect(reg.find("docs/guide.txt") == null);
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

fn markdownMatch(path: []const u8) bool {
	const base = std.fs.path.basename(path);
	if (std.ascii.eqlIgnoreCase(base, "README")) return true;
	if (std.ascii.startsWithIgnoreCase(base, "README.")) return true;
	return false;
}
