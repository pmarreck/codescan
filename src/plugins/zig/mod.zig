const kinds = @import("../../kind.zig");

pub const language = "zig";
pub const kind = kinds.Kind.code;
pub const extensions = &[_][]const u8{ ".zig" };
pub const ignore_patterns = &[_][]const u8{
	"**/.zig-cache/**",
	"**/zig-cache/**",
	"**/.zig-out/**",
	"**/zig-out/**",
};
