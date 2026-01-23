pub const language = "lua";
pub const extensions = &[_][]const u8{ ".lua" };
pub const ignore_patterns = &[_][]const u8{
	"**/.luarocks/**",
	"**/luarocks/**",
	"**/build/**",
};
