const kinds = @import("../../kind.zig");
const std = @import("std");

pub const language = "python";
pub const kind = kinds.Kind.code;
pub const extensions = &[_][]const u8{ ".py", ".pyi" };
pub const ignore_patterns = &[_][]const u8{
	"**/site-packages/**",
};

/// Recognize interpreter names with optional numeric versions without accepting
/// unrelated executables such as pythonista or malformed version suffixes.
pub fn isInterpreter(name: []const u8) bool {
	for ([_][]const u8{ "python", "pypy" }) |prefix| {
		if (!std.mem.startsWith(u8, name, prefix)) continue;
		if (name.len == prefix.len) return true;
		var digit = false;
		for (name[prefix.len..]) |byte| {
			if (std.ascii.isDigit(byte)) {
				digit = true;
			} else if (byte == '.' and digit) {
				digit = false;
			} else return false;
		}
		return digit;
	}
	return false;
}
