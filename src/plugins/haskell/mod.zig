const kinds = @import("../../kind.zig");

pub const language = "haskell";
pub const kind = kinds.Kind.code;
pub const extensions = &[_][]const u8{ ".hs" };
pub const ignore_patterns = &[_][]const u8{
	"**/dist-newstyle/**",
	"**/.stack-work/**",
};
