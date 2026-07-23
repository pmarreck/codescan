const kinds = @import("../../kind.zig");

pub const language = "wat";
pub const kind = kinds.Kind.code;
pub const extensions = &[_][]const u8{ ".wat", ".wast" };
pub const ignore_patterns = &[_][]const u8{};
