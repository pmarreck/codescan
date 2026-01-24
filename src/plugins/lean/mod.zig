const kinds = @import("../../kind.zig");

pub const language = "lean";
pub const kind = kinds.Kind.code;
pub const extensions = &[_][]const u8{ ".lean" };
pub const ignore_patterns = &[_][]const u8{
	"**/.lake/**",
	"**/lake-packages/**",
};
