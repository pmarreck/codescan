const kinds = @import("../../kind.zig");

pub const language = "powershell";
pub const kind = kinds.Kind.code;
pub const extensions = &[_][]const u8{ ".ps1", ".psm1", ".psd1" };
pub const ignore_patterns = &[_][]const u8{};
