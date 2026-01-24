const kinds = @import("../../kind.zig");

pub const language = "rust";
pub const kind = kinds.Kind.code;
pub const extensions = &[_][]const u8{ ".rs" };
pub const ignore_patterns = &[_][]const u8{
	"**/target/**",
};
