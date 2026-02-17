const std = @import("std");
const kinds = @import("../../kind.zig");

pub const language = "bash";
pub const kind = kinds.Kind.code;
pub const extensions = &[_][]const u8{ ".sh", ".bash" };
pub const ignore_patterns = &[_][]const u8{};

/// Matches common bash/shell dotfile names that lack extensions and shebangs.
pub fn matchesPath(path: []const u8) bool {
	const base = std.fs.path.basename(path);
	for (known_bash_dotfiles) |name| {
		if (std.mem.eql(u8, base, name)) return true;
	}
	return false;
}

const known_bash_dotfiles = &[_][]const u8{
	".bashrc",
	".bash_profile",
	".bash_login",
	".bash_logout",
	".bash_aliases",
	".bash_functions",
	".bash_completion",
	".profile",
	".shrc",
	".kshrc",
	".shinit",
	".environ",
	".envrc",
};
