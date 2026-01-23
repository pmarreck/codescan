const std = @import("std");
const model = @import("model.zig");
const extract_zig = @import("extract_zig.zig");
const extract_elixir = @import("extract_elixir.zig");

pub const ExtractorFn = *const fn (
	allocator: std.mem.Allocator,
	file_path: []const u8,
	source: []const u8,
) anyerror![]model.Symbol;

pub const Extractor = struct {
	language: []const u8,
	extensions: []const []const u8,
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
				.language = "zig",
				.extensions = &[_][]const u8{ ".zig" },
				.extract = extract_zig.extract,
			},
			.{
				.language = "elixir",
				.extensions = &[_][]const u8{ ".ex", ".exs" },
				.extract = extract_elixir.extract,
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
				.extract = dummyExtract,
			},
			.{
				.language = "elixir",
				.extensions = &[_][]const u8{ ".ex" },
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
