const kinds = @import("../../kind.zig");

pub const language = "nushell";
pub const kind = kinds.Kind.code;
pub const extensions = &[_][]const u8{".nu"};
pub const ignore_patterns = &[_][]const u8{};
