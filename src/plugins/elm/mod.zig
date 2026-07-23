const kinds = @import("../../kind.zig");

pub const language = "elm";
pub const kind = kinds.Kind.code;
pub const extensions = &[_][]const u8{".elm"};
pub const ignore_patterns = &[_][]const u8{"**/elm-stuff/**"};
