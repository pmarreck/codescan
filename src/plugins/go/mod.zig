const kinds = @import("../../kind.zig");

pub const language = "go";
pub const kind = kinds.Kind.code;
pub const extensions = &[_][]const u8{".go"};
pub const ignore_patterns = &[_][]const u8{
	"**/vendor/**",
};
