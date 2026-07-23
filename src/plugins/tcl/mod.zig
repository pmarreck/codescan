const kinds = @import("../../kind.zig");

pub const language = "tcl";
pub const kind = kinds.Kind.code;
pub const extensions = &[_][]const u8{ ".tcl", ".tm" };
pub const ignore_patterns = &[_][]const u8{};
