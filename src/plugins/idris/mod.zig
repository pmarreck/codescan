const kinds = @import("../../kind.zig");

pub const language = "idris";
pub const kind = kinds.Kind.code;
pub const extensions = &[_][]const u8{ ".idr" };
pub const ignore_patterns = &[_][]const u8{
	"**/build/**",
};
