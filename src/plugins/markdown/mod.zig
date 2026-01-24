const std = @import("std");
const kinds = @import("../../kind.zig");

pub const language = "markdown";
pub const kind = kinds.Kind.doc;
pub const extensions = &[_][]const u8{ ".md", ".markdown" };
pub const ignore_patterns = &[_][]const u8{};

pub fn matchesPath(path: []const u8) bool {
	const base = std.fs.path.basename(path);
	if (std.ascii.eqlIgnoreCase(base, "README")) return true;
	if (std.ascii.startsWithIgnoreCase(base, "README.")) return true;
	return false;
}
