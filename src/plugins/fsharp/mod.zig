const kinds = @import("../../kind.zig");

pub const language = "fsharp";
pub const kind = kinds.Kind.code;
pub const extensions = &[_][]const u8{ ".fs", ".fsi", ".fsx" };
pub const ignore_patterns = &[_][]const u8{ "**/bin/**", "**/obj/**" };
