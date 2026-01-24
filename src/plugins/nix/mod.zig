const kinds = @import("../../kind.zig");

pub const language = "nix";
pub const kind = kinds.Kind.code;
pub const extensions = &[_][]const u8{ ".nix" };
pub const ignore_patterns = &[_][]const u8{
	"**/result/**",
};
