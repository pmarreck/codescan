const kinds = @import("../../kind.zig");

pub const language = "racket";
pub const kind = kinds.Kind.code;
pub const extensions = &[_][]const u8{ ".rkt", ".rktd", ".scrbl" };
pub const ignore_patterns = &[_][]const u8{"**/compiled/**"};
