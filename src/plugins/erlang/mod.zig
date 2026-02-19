const kinds = @import("../../kind.zig");

pub const language = "erlang";
pub const kind = kinds.Kind.code;
pub const extensions = &[_][]const u8{ ".erl", ".hrl" };
pub const ignore_patterns = &[_][]const u8{
	"**/_build/**",
};
