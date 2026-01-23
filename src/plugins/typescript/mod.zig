pub const language = "typescript";
pub const extensions = &[_][]const u8{ ".ts", ".tsx", ".mts", ".cts" };
pub const ignore_patterns = &[_][]const u8{
	"**/node_modules/**",
	"**/dist/**",
	"**/build/**",
};
