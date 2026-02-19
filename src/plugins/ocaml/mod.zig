const kinds = @import("../../kind.zig");

pub const language = "ocaml";
pub const kind = kinds.Kind.code;
pub const extensions = &[_][]const u8{ ".ml", ".mli" };
pub const ignore_patterns = &[_][]const u8{
	"**/_build/**",
};
