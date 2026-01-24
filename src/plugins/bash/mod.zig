const kinds = @import("../../kind.zig");

pub const language = "bash";
pub const kind = kinds.Kind.code;
pub const extensions = &[_][]const u8{ ".sh", ".bash" };
pub const ignore_patterns = &[_][]const u8{};
