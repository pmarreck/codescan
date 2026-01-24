const kinds = @import("../../kind.zig");

pub const language = "log";
pub const kind = kinds.Kind.log;
pub const extensions = &[_][]const u8{ ".log" };
pub const ignore_patterns = &[_][]const u8{};
