const kinds = @import("../../kind.zig");

pub const language = "gleam";
pub const kind = kinds.Kind.code;
pub const extensions = &[_][]const u8{".gleam"};
pub const ignore_patterns = &[_][]const u8{"**/build/**"};
