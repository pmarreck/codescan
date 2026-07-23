const kinds = @import("../../kind.zig");

pub const language = "scheme";
pub const kind = kinds.Kind.code;
pub const extensions = &[_][]const u8{ ".scm", ".ss" };
pub const ignore_patterns = &[_][]const u8{};
