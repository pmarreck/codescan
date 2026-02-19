const kinds = @import("../../kind.zig");

pub const language = "clojure";
pub const kind = kinds.Kind.code;
pub const extensions = &[_][]const u8{ ".clj", ".cljs", ".cljc", ".edn" };
pub const ignore_patterns = &[_][]const u8{
	"**/target/**",
};
