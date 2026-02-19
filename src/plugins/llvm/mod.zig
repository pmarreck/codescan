const kinds = @import("../../kind.zig");

pub const language = "llvm";
pub const kind = kinds.Kind.code;
pub const extensions = &[_][]const u8{".ll"};
pub const ignore_patterns = &[_][]const u8{};
