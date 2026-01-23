//! PCRE2 wrapper for Zig.
//!
//! Provides a Zig-friendly interface to the PCRE2 regular expression library.
//! Uses UTF-8 mode with Unicode Character Properties (UCP) support.

const std = @import("std");
const Allocator = std.mem.Allocator;

// PCRE2 C bindings
const c = @cImport({
    @cDefine("PCRE2_CODE_UNIT_WIDTH", "8");
    @cInclude("pcre2.h");
});

/// PCRE2 error codes
pub const Error = error{
    CompileFailed,
    MatchFailed,
    OutOfMemory,
    WorkspaceOverflow,
    InvalidPattern,
};

/// Compiled PCRE2 pattern for matching.
pub const Regex = struct {
    code: *c.pcre2_code_8,
    match_data: *c.pcre2_match_data_8,
    workspace: []c_int,
    allocator: Allocator,

    const Self = @This();

    /// Default workspace size for DFA matching.
    const DEFAULT_WORKSPACE_SIZE: usize = 256;

    /// Compile a regex pattern.
    /// Uses UTF-8 and UCP options by default for Unicode support.
    pub fn compile(allocator: Allocator, pattern: []const u8) Error!Self {
        var error_code: c_int = 0;
        var error_offset: c.PCRE2_SIZE = 0;

        const options: u32 = c.PCRE2_UTF | c.PCRE2_UCP;
        const code = c.pcre2_compile_8(
            pattern.ptr,
            pattern.len,
            options,
            &error_code,
            &error_offset,
            null,
        ) orelse return Error.CompileFailed;

        const match_data = c.pcre2_match_data_create_from_pattern_8(code, null) orelse {
            c.pcre2_code_free_8(code);
            return Error.OutOfMemory;
        };

        const workspace = allocator.alloc(c_int, DEFAULT_WORKSPACE_SIZE) catch {
            c.pcre2_match_data_free_8(match_data);
            c.pcre2_code_free_8(code);
            return Error.OutOfMemory;
        };

        return Self{
            .code = code,
            .match_data = match_data,
            .workspace = workspace,
            .allocator = allocator,
        };
    }

    /// Free the compiled pattern.
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.workspace);
        c.pcre2_match_data_free_8(self.match_data);
        c.pcre2_code_free_8(self.code);
    }

    /// Check if the subject matches the pattern (full match, anchored at both ends).
    pub fn matches(self: *Self, subject: []const u8) bool {
        const options: u32 = c.PCRE2_ANCHORED | c.PCRE2_ENDANCHORED;

        while (true) {
            const rc = c.pcre2_dfa_match_8(
                self.code,
                subject.ptr,
                subject.len,
                0, // start offset
                options,
                self.match_data,
                null, // match context
                self.workspace.ptr,
                self.workspace.len,
            );

            if (rc == c.PCRE2_ERROR_DFA_WSSIZE) {
                // Workspace too small, try to grow it
                if (!self.growWorkspace()) {
                    return false;
                }
                continue;
            }

            return rc >= 0;
        }
    }

    /// Check if the subject contains a match (partial match, not anchored).
    pub fn find(self: *Self, subject: []const u8) bool {
        while (true) {
            const rc = c.pcre2_dfa_match_8(
                self.code,
                subject.ptr,
                subject.len,
                0, // start offset
                0, // no special options
                self.match_data,
                null, // match context
                self.workspace.ptr,
                self.workspace.len,
            );

            if (rc == c.PCRE2_ERROR_DFA_WSSIZE) {
                if (!self.growWorkspace()) {
                    return false;
                }
                continue;
            }

            return rc >= 0;
        }
    }

    /// Grow the workspace buffer for DFA matching.
    fn growWorkspace(self: *Self) bool {
        const new_size = self.workspace.len * 2;
        if (new_size < self.workspace.len) {
            return false; // overflow
        }

        const new_workspace = self.allocator.realloc(self.workspace, new_size) catch return false;
        self.workspace = new_workspace;
        return true;
    }
};

/// Get the compile error message for a given error code.
pub fn getErrorMessage(error_code: c_int, buffer: []u8) ?[]const u8 {
    const len = c.pcre2_get_error_message_8(error_code, buffer.ptr, buffer.len);
    if (len < 0) {
        return null;
    }
    return buffer[0..@intCast(len)];
}

// ============ Tests ============

test "Regex: simple pattern" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "hello");
    defer re.deinit();

    try std.testing.expect(re.matches("hello"));
    try std.testing.expect(!re.matches("Hello")); // case sensitive
    try std.testing.expect(!re.matches("hello world")); // not a full match
}

test "Regex: case insensitive" {
    const allocator = std.testing.allocator;

    // Use (?i) flag for case insensitive
    var re = try Regex.compile(allocator, "(?i)hello");
    defer re.deinit();

    try std.testing.expect(re.matches("hello"));
    try std.testing.expect(re.matches("Hello"));
    try std.testing.expect(re.matches("HELLO"));
}

test "Regex: wildcard pattern" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, ".*\\.txt");
    defer re.deinit();

    try std.testing.expect(re.matches("file.txt"));
    try std.testing.expect(re.matches("document.txt"));
    try std.testing.expect(!re.matches("file.doc"));
}

test "Regex: find (partial match)" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "world");
    defer re.deinit();

    try std.testing.expect(re.find("hello world"));
    try std.testing.expect(re.find("world"));
    try std.testing.expect(!re.find("hello"));
}

test "Regex: unicode" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "caf\u{00e9}");
    defer re.deinit();

    try std.testing.expect(re.matches("caf\u{00e9}"));
    try std.testing.expect(!re.matches("cafe"));
}

test "Regex: character classes" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "[a-z]+");
    defer re.deinit();

    try std.testing.expect(re.matches("hello"));
    try std.testing.expect(!re.matches("Hello")); // uppercase not in class
    try std.testing.expect(!re.matches("123"));
}

test "Regex: alternation" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "cat|dog");
    defer re.deinit();

    try std.testing.expect(re.matches("cat"));
    try std.testing.expect(re.matches("dog"));
    try std.testing.expect(!re.matches("bird"));
}

test "Regex: quantifiers" {
    const allocator = std.testing.allocator;

    var re = try Regex.compile(allocator, "a{2,4}");
    defer re.deinit();

    try std.testing.expect(!re.matches("a"));
    try std.testing.expect(re.matches("aa"));
    try std.testing.expect(re.matches("aaa"));
    try std.testing.expect(re.matches("aaaa"));
    try std.testing.expect(!re.matches("aaaaa"));
}

test "Regex: compile error" {
    const allocator = std.testing.allocator;

    // Invalid pattern - unmatched parenthesis
    const result = Regex.compile(allocator, "(unclosed");
    try std.testing.expectError(Error.CompileFailed, result);
}
