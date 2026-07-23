const kinds = @import("../../kind.zig");

pub const language = "oil";
pub const kind = kinds.Kind.code;
pub const extensions = &[_][]const u8{ ".osh", ".oil", ".ysh" };
pub const ignore_patterns = &[_][]const u8{};
