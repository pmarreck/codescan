const kinds = @import("../../kind.zig");

pub const language = "text";
pub const kind = kinds.Kind.text;
pub const extensions = &[_][]const u8{ ".txt" };
pub const ignore_patterns = &[_][]const u8{};
