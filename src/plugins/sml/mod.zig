const kinds = @import("../../kind.zig");

pub const language = "sml";
pub const kind = kinds.Kind.code;
pub const extensions = &[_][]const u8{ ".sml", ".sig", ".fun" };
pub const ignore_patterns = &[_][]const u8{".cm/**"};
