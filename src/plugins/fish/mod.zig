const kinds = @import("../../kind.zig");

pub const language = "fish";
pub const kind = kinds.Kind.code;
pub const extensions = &[_][]const u8{".fish"};
pub const ignore_patterns = &[_][]const u8{};
