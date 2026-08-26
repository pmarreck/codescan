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
	SubstituteFailed,
};

/// A byte-offset match pair.
pub const Match = struct { start: usize, end: usize };

/// Result of a substitution operation.
pub const SubstituteResult = struct {
	output: []u8,
	count: usize,
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

	/// Compile options for regex patterns.
	pub const CompileOptions = struct {
		case_insensitive: bool = false,
	};

	/// Compile a regex pattern.
	/// Uses UTF-8 and UCP options by default for Unicode support.
	pub fn compile(allocator: Allocator, pattern: []const u8) Error!Self {
		return compileEx(allocator, pattern, .{});
	}

	/// Compile a regex pattern with additional options.
	pub fn compileEx(allocator: Allocator, pattern: []const u8, opts: CompileOptions) Error!Self {
		var error_code: c_int = 0;
		var error_offset: c.PCRE2_SIZE = 0;

		var options: u32 = c.PCRE2_UTF | c.PCRE2_UCP;
		if (opts.case_insensitive) options |= c.PCRE2_CASELESS;
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

	/// Find the byte-offset position of the first match at or after `start_offset`.
	/// Uses the standard (NFA) matcher so that capture groups work correctly.
	pub fn findPosition(self: *Self, subject: []const u8, start_offset: usize) ?Match {
		const rc = c.pcre2_match_8(
			self.code,
			subject.ptr,
			subject.len,
			start_offset,
			0,
			self.match_data,
			null,
		);
		if (rc < 0) return null;

		const ovector = c.pcre2_get_ovector_pointer_8(self.match_data);
		return Match{
			.start = @intCast(ovector[0]),
			.end = @intCast(ovector[1]),
		};
	}

	/// Perform PCRE2 substitution, returning the result and match count.
	/// Uses `pcre2_substitute_8` which handles backreferences ($1, $2, etc.).
	/// Caller owns the returned `output` slice.
	pub fn substituteOwned(self: *Self, allocator: Allocator, subject: []const u8, replacement: []const u8, global: bool) Error!SubstituteResult {
		var options: u32 = c.PCRE2_SUBSTITUTE_OVERFLOW_LENGTH | c.PCRE2_SUBSTITUTE_EXTENDED;
		if (global) options |= c.PCRE2_SUBSTITUTE_GLOBAL;

		// First attempt with a reasonably-sized buffer
		var buf_size: usize = subject.len + replacement.len + 256;
		while (true) {
			const buf = allocator.alloc(u8, buf_size) catch return Error.OutOfMemory;
			var out_len: c.PCRE2_SIZE = buf.len;
			const rc = c.pcre2_substitute_8(
				self.code,
				subject.ptr,
				subject.len,
				0, // start offset
				options,
				self.match_data,
				null, // match context
				replacement.ptr,
				replacement.len,
				buf.ptr,
				&out_len,
			);
			if (rc == c.PCRE2_ERROR_NOMEMORY) {
				allocator.free(buf);
				// out_len now contains required size
				buf_size = @intCast(out_len);
				continue;
			}
			if (rc < 0) {
				allocator.free(buf);
				return Error.SubstituteFailed;
			}
			// rc = number of replacements made
			const result_slice = allocator.dupe(u8, buf[0..@intCast(out_len)]) catch {
				allocator.free(buf);
				return Error.OutOfMemory;
			};
			allocator.free(buf);
			return SubstituteResult{
				.output = result_slice,
				.count = @intCast(rc),
			};
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

test "Regex: findPosition basic" {
	const allocator = std.testing.allocator;

	var re = try Regex.compile(allocator, "world");
	defer re.deinit();

	const m = re.findPosition("hello world", 0).?;
	try std.testing.expectEqual(@as(usize, 6), m.start);
	try std.testing.expectEqual(@as(usize, 11), m.end);
}

test "Regex: findPosition with start offset" {
	const allocator = std.testing.allocator;

	var re = try Regex.compile(allocator, "ab");
	defer re.deinit();

	// "ab--ab--ab"
	const subject = "ab--ab--ab";
	const m1 = re.findPosition(subject, 0).?;
	try std.testing.expectEqual(@as(usize, 0), m1.start);
	try std.testing.expectEqual(@as(usize, 2), m1.end);

	const m2 = re.findPosition(subject, 2).?;
	try std.testing.expectEqual(@as(usize, 4), m2.start);
	try std.testing.expectEqual(@as(usize, 6), m2.end);

	const m3 = re.findPosition(subject, 6).?;
	try std.testing.expectEqual(@as(usize, 8), m3.start);
	try std.testing.expectEqual(@as(usize, 10), m3.end);

	try std.testing.expect(re.findPosition(subject, 9) == null);
}

test "Regex: findPosition no match" {
	const allocator = std.testing.allocator;

	var re = try Regex.compile(allocator, "xyz");
	defer re.deinit();

	try std.testing.expect(re.findPosition("hello world", 0) == null);
}

test "Regex: substituteOwned single" {
	const allocator = std.testing.allocator;

	var re = try Regex.compile(allocator, "foo");
	defer re.deinit();

	const result = try re.substituteOwned(allocator, "foo bar foo", "baz", false);
	defer allocator.free(result.output);
	try std.testing.expectEqualStrings("baz bar foo", result.output);
	try std.testing.expectEqual(@as(usize, 1), result.count);
}

test "Regex: substituteOwned global" {
	const allocator = std.testing.allocator;

	var re = try Regex.compile(allocator, "foo");
	defer re.deinit();

	const result = try re.substituteOwned(allocator, "foo bar foo baz foo", "X", true);
	defer allocator.free(result.output);
	try std.testing.expectEqualStrings("X bar X baz X", result.output);
	try std.testing.expectEqual(@as(usize, 3), result.count);
}

test "Regex: substituteOwned with backreferences" {
	const allocator = std.testing.allocator;

	var re = try Regex.compile(allocator, "(\\w+)=(\\w+)");
	defer re.deinit();

	const result = try re.substituteOwned(allocator, "key=value", "$2:$1", false);
	defer allocator.free(result.output);
	try std.testing.expectEqualStrings("value:key", result.output);
	try std.testing.expectEqual(@as(usize, 1), result.count);
}

test "Regex: substituteOwned no match returns original" {
	const allocator = std.testing.allocator;

	var re = try Regex.compile(allocator, "xyz");
	defer re.deinit();

	const result = try re.substituteOwned(allocator, "hello world", "replaced", false);
	defer allocator.free(result.output);
	try std.testing.expectEqualStrings("hello world", result.output);
	try std.testing.expectEqual(@as(usize, 0), result.count);
}
