const kinds = @import("../../kind.zig");

pub const language = "ruby";
pub const kind = kinds.Kind.code;
pub const extensions = &[_][]const u8{".rb"};
pub const ignore_patterns = &[_][]const u8{
	"**/vendor/**",
};
