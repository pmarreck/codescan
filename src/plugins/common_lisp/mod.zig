const kinds = @import("../../kind.zig");

pub const language = "common-lisp";
pub const kind = kinds.Kind.code;
pub const extensions = &[_][]const u8{ ".lisp", ".lsp", ".cl", ".asd" };
pub const ignore_patterns = &[_][]const u8{};
