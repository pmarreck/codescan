const kinds = @import("../../kind.zig");

pub const language = "c";
pub const kind = kinds.Kind.code;

pub const extensions = &[_][]const u8{
	".c",
	".h",
};

pub const ignore_patterns = &[_][]const u8{
	"**/.zig-cache/**",
	"**/zig-cache/**",
	"**/.zig-out/**",
	"**/zig-out/**",
};
