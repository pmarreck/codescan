const kinds = @import("../../kind.zig");

pub const language = "elixir";
pub const kind = kinds.Kind.code;
pub const extensions = &[_][]const u8{ ".ex", ".exs" };
pub const ignore_patterns = &[_][]const u8{
	"**/deps/**",
	"**/_build/**",
	"**/.elixir_ls/**",
};
