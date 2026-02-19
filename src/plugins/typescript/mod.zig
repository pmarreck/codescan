const kinds = @import("../../kind.zig");

pub const language = "typescript";
pub const kind = kinds.Kind.code;
pub const extensions = &[_][]const u8{ ".ts", ".tsx", ".js", ".jsx", ".mts", ".cts", ".mjs", ".cjs" };
pub const ignore_patterns = &[_][]const u8{
	"**/node_modules/**",
	"**/dist/**",
	"**/build/**",
};
