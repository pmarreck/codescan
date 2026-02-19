const kinds = @import("../../kind.zig");

pub const language = "assembly";
pub const kind = kinds.Kind.code;
pub const extensions = &[_][]const u8{ ".s", ".S", ".asm" };
pub const ignore_patterns = &[_][]const u8{};
