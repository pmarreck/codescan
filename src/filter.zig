//! Glob pattern matching for file filtering.
//!
//! # Design Decision: PCRE2 Backend
//!
//! This module uses PCRE2 as the regex backend for glob matching. This was a deliberate
//! design choice from the original Swift implementation for several reasons:
//!
//! 1. **Performance**: PCRE2's DFA (Deterministic Finite Automaton) matching provides
//!    O(n) time complexity, compared to O(n*m) for naive recursive backtracking.
//!    This matters when filtering hundreds of thousands of files.
//!
//! 2. **JIT compilation**: PCRE2 supports JIT compilation of patterns for even faster
//!    matching on repeated use (same pattern, many paths).
//!
//! 3. **Consistent semantics**: Using PCRE2 ensures consistent regex behavior across
//!    platforms. Character class negation uses `[^abc]` (PCRE2 standard), not `[!abc]`
//!    (Unix glob convention). This avoids subtle cross-platform bugs.
//!
//! 4. **Battle-tested**: PCRE2 is widely used and well-tested, reducing the risk of
//!    edge-case bugs in pattern matching.
//!
//! # Glob to Regex Translation
//!
//! Glob patterns are translated to PCRE2 regex as follows:
//! - `*` → `[^/\\]*` (match any chars except path separators)
//! - `**` → `.*` (match anything including path separators)
//! - `?` → `[^/\\]` (match single non-separator char)
//! - `[abc]` → `[abc]` (pass through to PCRE2)
//! - `[^abc]` → `[^abc]` (PCRE2 negation - matches any char NOT in set)
//! - `[!abc]` → `[!abc]` (! is literal in PCRE2, NOT negation)
//!
//! Special regex metacharacters (`.+{}()|$^`) are escaped in literal portions.
//!
//! # Performance Optimization: Combined Regex
//!
//! When a PatternSet contains multiple patterns, they are automatically combined into
//! a single PCRE2 regex of the form `^(?:pattern1|pattern2|...|patternN)$` on first use.
//! This reduces matching from O(n*m) to O(n) where n=files and m=patterns, providing
//! ~30x speedup for large directory scans with many ignore patterns.

const std = @import("std");
const Allocator = std.mem.Allocator;
const pcre2 = @import("pcre2.zig");

/// A compiled glob pattern (backed by PCRE2).
pub const Pattern = struct {
	source: []const u8,
	regex: pcre2.Regex,
	allocator: Allocator,

	pub fn deinit(self: *Pattern) void {
		self.regex.deinit();
		self.allocator.free(self.source);
	}

	/// Tests if the pattern matches the given path.
	pub fn matches(self: *Pattern, path: []const u8) bool {
		return self.regex.matches(path);
	}
};

/// Errors that can occur during pattern compilation.
pub const CompileError = error{
	OutOfMemory,
	InvalidPattern,
};

/// Compiles a glob pattern string into a Pattern backed by PCRE2.
pub fn compile(allocator: Allocator, pattern: []const u8) CompileError!Pattern {
	// Convert glob to PCRE2 regex
	const regex_pattern = try globToRegex(allocator, pattern);
	defer allocator.free(regex_pattern);

	const regex = pcre2.Regex.compile(allocator, regex_pattern) catch |err| {
		return switch (err) {
			pcre2.Error.CompileFailed, pcre2.Error.InvalidPattern => CompileError.InvalidPattern,
			pcre2.Error.OutOfMemory => CompileError.OutOfMemory,
			else => CompileError.InvalidPattern,
		};
	};
	errdefer {
		var r = regex;
		r.deinit();
	}

	const source = allocator.dupe(u8, pattern) catch return CompileError.OutOfMemory;

	return Pattern{
		.source = source,
		.regex = regex,
		.allocator = allocator,
	};
}

/// Converts a glob pattern to a PCRE2-compatible regex pattern (anchored).
///
/// Translations:
/// - `*` → `[^/\\]*` (match any chars except path separators)
/// - `**` → `.*` (match anything including separators)
/// - `?` → `[^/\\]` (match single non-separator char)
/// - `[abc]` → `[abc]` (pass through)
/// - `[^abc]` → `[^abc]` (pass through - PCRE2 negation)
/// - `[!abc]` → `[!abc]` (pass through - ! is literal in PCRE2)
/// - Special regex chars are escaped: . + { } ( ) | $ \
///
/// The pattern is anchored with ^ and $ to ensure full-string matching.
/// PCRE2's ANCHORED/ENDANCHORED options don't work correctly with DFA matching
/// when the pattern starts with `.*`, so we use explicit anchors instead.
/// The returned string must be freed by the caller.
pub fn globToRegex(allocator: Allocator, glob: []const u8) CompileError![]const u8 {
	return globToRegexInner(allocator, glob, true);
}

/// Converts a glob pattern to a PCRE2-compatible regex pattern without anchors.
/// Used internally for building combined regex patterns.
/// The returned string must be freed by the caller.
fn globToRegexUnanchored(allocator: Allocator, glob: []const u8) CompileError![]const u8 {
	return globToRegexInner(allocator, glob, false);
}

/// Internal implementation of glob-to-regex conversion.
/// If `anchored` is true, adds ^ and $ anchors for full-string matching.
fn globToRegexInner(allocator: Allocator, glob: []const u8, anchored: bool) CompileError![]const u8 {
	var result: std.ArrayListUnmanaged(u8) = .empty;
	errdefer result.deinit(allocator);

	// Add start anchor for full-string matching
	if (anchored) {
		result.append(allocator, '^') catch return CompileError.OutOfMemory;
	}

	var i: usize = 0;
	while (i < glob.len) {
		const c = glob[i];

		switch (c) {
			'*' => {
				// Check for **
				if (i + 1 < glob.len and glob[i + 1] == '*') {
					// ** matches anything including path separators
					result.appendSlice(allocator, ".*") catch return CompileError.OutOfMemory;
					i += 2;
					// Skip trailing / after ** (e.g., **/foo → .*foo)
					if (i < glob.len and (glob[i] == '/' or glob[i] == '\\')) {
						// But we need to match the separator too, so add optional separator
						result.appendSlice(allocator, "(?:/|\\\\|)") catch return CompileError.OutOfMemory;
						i += 1;
					}
				} else {
					// * matches any chars except path separators
					result.appendSlice(allocator, "[^/\\\\]*") catch return CompileError.OutOfMemory;
					i += 1;
				}
			},
			'?' => {
				// ? matches any single non-separator char
				result.appendSlice(allocator, "[^/\\\\]") catch return CompileError.OutOfMemory;
				i += 1;
			},
			'[' => {
				// Character class - pass through to PCRE2
				result.append(allocator, '[') catch return CompileError.OutOfMemory;
				i += 1;

				// Copy everything until closing ]
				// Handle ] as first char (literal]) and ^ for negation
				var first = true;
				while (i < glob.len) {
					const cc = glob[i];
					if (cc == ']' and !first) {
						result.append(allocator, ']') catch return CompileError.OutOfMemory;
						i += 1;
						break;
					}
					// Pass through ^ (negation) and ! (literal) and all other chars
					result.append(allocator, cc) catch return CompileError.OutOfMemory;
					i += 1;
					first = false;
				}
			},
			// Escape special PCRE2 metacharacters
			'.', '+', '{', '}', '(', ')', '|', '$', '^' => {
				result.append(allocator, '\\') catch return CompileError.OutOfMemory;
				result.append(allocator, c) catch return CompileError.OutOfMemory;
				i += 1;
			},
			'\\' => {
				// Backslash in glob is a path separator on Windows, escape for regex
				result.appendSlice(allocator, "\\\\") catch return CompileError.OutOfMemory;
				i += 1;
			},
			else => {
				result.append(allocator, c) catch return CompileError.OutOfMemory;
				i += 1;
			},
		}
	}

	// Add end anchor for full-string matching
	if (anchored) {
		result.append(allocator, '$') catch return CompileError.OutOfMemory;
	}

	return result.toOwnedSlice(allocator) catch return CompileError.OutOfMemory;
}

/// A set of patterns for filtering files.
///
/// Performance: When multiple patterns are added, they are automatically combined
/// into a single PCRE2 regex on first use of matchesAny(). This provides O(1)
/// pattern matching instead of O(m) where m = number of patterns.
pub const PatternSet = struct {
	/// Individual compiled patterns (used as fallback if combined regex fails).
	patterns: []Pattern,
	/// Source pattern strings (kept for rebuilding combined regex after add()).
	source_patterns: [][]const u8,
	/// Combined regex for fast matching: ^(?:pat1|pat2|...|patN)$
	/// Populated lazily on first matchesAny() call.
	combined_regex: ?pcre2.Regex,
	/// Whether the combined regex has been built and is valid.
	is_finalized: bool,
	allocator: Allocator,

	pub fn init(allocator: Allocator) PatternSet {
		return .{
			.patterns = &[_]Pattern{},
			.source_patterns = &[_][]const u8{},
			.combined_regex = null,
			.is_finalized = false,
			.allocator = allocator,
		};
	}

	pub fn deinit(self: *PatternSet) void {
		// Free combined regex
		if (self.combined_regex) |*r| {
			r.deinit();
		}

		// Free individual patterns
		for (self.patterns) |*p| {
			p.deinit();
		}
		if (self.patterns.len > 0) {
			self.allocator.free(self.patterns);
		}

		// Free source pattern strings
		for (self.source_patterns) |s| {
			self.allocator.free(s);
		}
		if (self.source_patterns.len > 0) {
			self.allocator.free(self.source_patterns);
		}
	}

	/// Adds a pattern to the set.
	pub fn add(self: *PatternSet, pattern_str: []const u8) CompileError!void {
		const pattern = try compile(self.allocator, pattern_str);
		errdefer {
			var p = pattern;
			p.deinit();
		}

		// Store source pattern for later rebuilding of combined regex
		const source_copy = self.allocator.dupe(u8, pattern_str) catch return CompileError.OutOfMemory;
		errdefer self.allocator.free(source_copy);

		// Grow patterns array
		const new_patterns = self.allocator.alloc(Pattern, self.patterns.len + 1) catch return CompileError.OutOfMemory;
		if (self.patterns.len > 0) {
			@memcpy(new_patterns[0..self.patterns.len], self.patterns);
			self.allocator.free(self.patterns);
		}
		new_patterns[self.patterns.len] = pattern;
		self.patterns = new_patterns;

		// Grow source_patterns array
		const new_sources = self.allocator.alloc([]const u8, self.source_patterns.len + 1) catch return CompileError.OutOfMemory;
		if (self.source_patterns.len > 0) {
			@memcpy(new_sources[0..self.source_patterns.len], self.source_patterns);
			self.allocator.free(self.source_patterns);
		}
		new_sources[self.source_patterns.len] = source_copy;
		self.source_patterns = new_sources;

		// Invalidate combined regex if we were finalized
		if (self.is_finalized) {
			if (self.combined_regex) |*r| {
				r.deinit();
			}
			self.combined_regex = null;
			self.is_finalized = false;
		}
	}

	/// Builds the combined regex from all source patterns.
	/// Called lazily on first matchesAny() call.
	fn finalize(self: *PatternSet) void {
		if (self.is_finalized) return;
		if (self.source_patterns.len == 0) {
			self.is_finalized = true;
			return;
		}

		// Build combined regex: ^(?:regex1|regex2|...|regexN)$
		var combined: std.ArrayListUnmanaged(u8) = .empty;
		defer combined.deinit(self.allocator);

		combined.appendSlice(self.allocator, "^(?:") catch {
			self.is_finalized = true; // Mark as finalized, will use slow path
			return;
		};

		for (self.source_patterns, 0..) |source, i| {
			if (i > 0) {
				combined.append(self.allocator, '|') catch {
					self.is_finalized = true;
					return;
				};
			}
			// Convert glob to regex without anchors
			const regex_pattern = globToRegexUnanchored(self.allocator, source) catch {
				self.is_finalized = true;
				return;
			};
			defer self.allocator.free(regex_pattern);
			combined.appendSlice(self.allocator, regex_pattern) catch {
				self.is_finalized = true;
				return;
			};
		}

		combined.appendSlice(self.allocator, ")$") catch {
			self.is_finalized = true;
			return;
		};

		// Compile the combined regex
		const regex = pcre2.Regex.compile(self.allocator, combined.items) catch {
			// If combined regex fails to compile, we'll fall back to individual patterns
			self.is_finalized = true;
			return;
		};

		self.combined_regex = regex;
		self.is_finalized = true;
	}

	/// Tests if any pattern in the set matches the path.
	/// Optionally tests a second path (e.g., basename) if provided.
	/// Returns true if either path matches any pattern.
	pub fn matchesAny(self: *PatternSet, path: []const u8, alt_path: ?[]const u8) bool {
		// Lazy finalization - build combined regex on first use
		if (!self.is_finalized) {
			self.finalize();
		}

		// Fast path: use combined regex if available
		if (self.combined_regex) |*regex| {
			if (regex.matches(path)) {
				return true;
			}
			if (alt_path) |alt| {
				if (regex.matches(alt)) {
					return true;
				}
			}
			return false;
		}

		// Fallback: iterate individual patterns (if combined regex failed to build)
		for (self.patterns) |*pattern| {
			const mutable_pattern: *Pattern = @constCast(pattern);
			if (mutable_pattern.matches(path)) {
				return true;
			}
			if (alt_path) |alt| {
				if (mutable_pattern.matches(alt)) {
					return true;
				}
			}
		}
		return false;
	}

	/// Returns the number of patterns in the set.
	pub fn count(self: *const PatternSet) usize {
		return self.patterns.len;
	}
};

// ============ Internal Tests ============

test "globToRegex: simple literal" {
	const allocator = std.testing.allocator;
	const result = try globToRegex(allocator, "hello.txt");
	defer allocator.free(result);
	try std.testing.expectEqualStrings("^hello\\.txt$", result);
}

test "globToRegex: single star" {
	const allocator = std.testing.allocator;
	const result = try globToRegex(allocator, "*.txt");
	defer allocator.free(result);
	try std.testing.expectEqualStrings("^[^/\\\\]*\\.txt$", result);
}

test "globToRegex: double star" {
	const allocator = std.testing.allocator;
	const result = try globToRegex(allocator, "**/*.txt");
	defer allocator.free(result);
	try std.testing.expectEqualStrings("^.*(?:/|\\\\|)[^/\\\\]*\\.txt$", result);
}

test "globToRegex: question mark" {
	const allocator = std.testing.allocator;
	const result = try globToRegex(allocator, "test?.txt");
	defer allocator.free(result);
	try std.testing.expectEqualStrings("^test[^/\\\\]\\.txt$", result);
}

test "globToRegex: character class" {
	const allocator = std.testing.allocator;
	const result = try globToRegex(allocator, "[abc].txt");
	defer allocator.free(result);
	try std.testing.expectEqualStrings("^[abc]\\.txt$", result);
}

test "globToRegex: negated character class" {
	const allocator = std.testing.allocator;
	const result = try globToRegex(allocator, "[^abc].txt");
	defer allocator.free(result);
	try std.testing.expectEqualStrings("^[^abc]\\.txt$", result);
}

// ============ Pattern Matching Tests ============

test "literal pattern" {
	var pattern = try compile(std.testing.allocator, "hello.txt");
	defer pattern.deinit();

	try std.testing.expect(pattern.matches("hello.txt"));
	try std.testing.expect(!pattern.matches("hello.log"));
	try std.testing.expect(!pattern.matches("hello.txt.bak"));
	// Literal pattern should NOT match in subdirectories (that's what ** is for)
	try std.testing.expect(!pattern.matches("dir/hello.txt"));
	try std.testing.expect(!pattern.matches("a/b/c/hello.txt"));
}

test "single star matches filename" {
	var pattern = try compile(std.testing.allocator, "*.txt");
	defer pattern.deinit();

	try std.testing.expect(pattern.matches("hello.txt"));
	try std.testing.expect(pattern.matches("world.txt"));
	try std.testing.expect(!pattern.matches("hello.log"));
	try std.testing.expect(!pattern.matches("dir/hello.txt"));
}

test "double star matches across directories" {
	var pattern = try compile(std.testing.allocator, "**/*.txt");
	defer pattern.deinit();

	try std.testing.expect(pattern.matches("hello.txt"));
	try std.testing.expect(pattern.matches("dir/hello.txt"));
	try std.testing.expect(pattern.matches("a/b/c/hello.txt"));
	try std.testing.expect(!pattern.matches("hello.log"));
}

test "question mark matches single char" {
	var pattern = try compile(std.testing.allocator, "test?.txt");
	defer pattern.deinit();

	try std.testing.expect(pattern.matches("test1.txt"));
	try std.testing.expect(pattern.matches("testA.txt"));
	try std.testing.expect(!pattern.matches("test.txt"));
	try std.testing.expect(!pattern.matches("test12.txt"));
}

test "character class" {
	var pattern = try compile(std.testing.allocator, "test[abc].txt");
	defer pattern.deinit();

	try std.testing.expect(pattern.matches("testa.txt"));
	try std.testing.expect(pattern.matches("testb.txt"));
	try std.testing.expect(pattern.matches("testc.txt"));
	try std.testing.expect(!pattern.matches("testd.txt"));
}

test "negated character class (PCRE2 syntax with ^)" {
	// PCRE2 uses ^ for negation, not !
	var pattern = try compile(std.testing.allocator, "test[^abc].txt");
	defer pattern.deinit();

	try std.testing.expect(!pattern.matches("testa.txt"));
	try std.testing.expect(!pattern.matches("testb.txt"));
	try std.testing.expect(pattern.matches("testd.txt"));
	try std.testing.expect(pattern.matches("test1.txt"));
}

test "pattern set" {
	var set = PatternSet.init(std.testing.allocator);
	defer set.deinit();

	try set.add("*.txt");
	try set.add("*.log");

	try std.testing.expect(set.matchesAny("hello.txt", null));
	try std.testing.expect(set.matchesAny("hello.log", null));
	try std.testing.expect(!set.matchesAny("hello.doc", null));
}

test "sqlite journal patterns" {
	var pattern = try compile(std.testing.allocator, "*.sqlite-wal");
	defer pattern.deinit();

	try std.testing.expect(pattern.matches("database.sqlite-wal"));
	try std.testing.expect(!pattern.matches("database.sqlite"));
}

// Tests translated from Swift GlobMatcherTests.swift - these are the source of truth

test "swift: compiled pattern matches basename" {
	var pattern = try compile(std.testing.allocator, "*.tmp");
	defer pattern.deinit();

	try std.testing.expect(pattern.matches("file.tmp"));
	try std.testing.expect(!pattern.matches("file.txt"));
}

test "swift: compiled pattern matches recursive path" {
	var pattern = try compile(std.testing.allocator, "**/skip.txt");
	defer pattern.deinit();

	try std.testing.expect(pattern.matches("a/b/skip.txt"));
	try std.testing.expect(pattern.matches("skip.txt"));
	try std.testing.expect(!pattern.matches("a/b/skip.bin"));
}

test "swift: wildcard and question mark matching" {
	var pat1 = try compile(std.testing.allocator, "*");
	defer pat1.deinit();
	try std.testing.expect(pat1.matches("file.txt"));

	var pat2 = try compile(std.testing.allocator, "file.?xt");
	defer pat2.deinit();
	try std.testing.expect(pat2.matches("file.txt"));
	try std.testing.expect(!pat2.matches("file.jpeg"));
}

test "swift: negation like pattern is literal" {
	// In glob patterns, ! at start of pattern is NOT special - it's just a literal !
	var pattern = try compile(std.testing.allocator, "!secret");
	defer pattern.deinit();

	try std.testing.expect(!pattern.matches("secret"));
	try std.testing.expect(pattern.matches("!secret"));
}

test "swift: character class matching" {
	// Character classes [ab] should match a or b, not c
	var pattern = try compile(std.testing.allocator, "[ab].txt");
	defer pattern.deinit();

	try std.testing.expect(pattern.matches("a.txt"));
	try std.testing.expect(pattern.matches("b.txt"));
	try std.testing.expect(!pattern.matches("c.txt"));
	// The literal [ab].txt should NOT match (it's a char class, not literal)
	try std.testing.expect(!pattern.matches("[ab].txt"));
}

test "swift: character class with exclamation is NOT negation (PCRE2 semantics)" {
	// In PCRE2/Swift, [!abc] means: match !, a, b, or c (NOT negation)
	// This differs from Unix glob where [!abc] means negation
	var pattern = try compile(std.testing.allocator, "[!ab].txt");
	defer pattern.deinit();

	// Should match ! character
	try std.testing.expect(pattern.matches("!.txt"));
	// Should match a and b
	try std.testing.expect(pattern.matches("a.txt"));
	try std.testing.expect(pattern.matches("b.txt"));
	// Should NOT match c (c is not in the set !, a, b)
	try std.testing.expect(!pattern.matches("c.txt"));
}

test "swift: path component mismatch fails" {
	var pattern1 = try compile(std.testing.allocator, "a/b/*.txt");
	defer pattern1.deinit();
	try std.testing.expect(!pattern1.matches("a/b/c/d.txt")); // Single * doesn't cross /

	var pattern2 = try compile(std.testing.allocator, "a/**/d.txt");
	defer pattern2.deinit();
	try std.testing.expect(pattern2.matches("a/b/c/d.txt")); // ** crosses /
}

test "swift: absolute pattern matches absolute paths only" {
	var pattern = try compile(std.testing.allocator, "/**/foo.txt");
	defer pattern.deinit();

	try std.testing.expect(pattern.matches("/foo.txt"));
	try std.testing.expect(pattern.matches("/a/b/foo.txt"));
	try std.testing.expect(!pattern.matches("a/b/foo.txt")); // Not absolute
}

test "double star with nested path" {
	var pattern = try compile(std.testing.allocator, "**/Cache/*");
	defer pattern.deinit();

	try std.testing.expect(pattern.matches("Cache/file.txt"));
	try std.testing.expect(pattern.matches("some/path/Cache/file.txt"));
	try std.testing.expect(!pattern.matches("some/path/file.txt"));
}

test "cloudsync noindex pattern - should not match nested paths" {
	// Pattern should match direct children of cloudsync.noindex, not deeper paths
	var pattern = try compile(std.testing.allocator, "**/cpl/cloudsync.noindex/*");
	defer pattern.deinit();

	// Should match: direct children
	try std.testing.expect(pattern.matches("cpl/cloudsync.noindex/state"));
	try std.testing.expect(pattern.matches("resources/cpl/cloudsync.noindex/state"));

	// Should NOT match: nested paths (has /storage/ subdirectory)
	try std.testing.expect(!pattern.matches("cpl/cloudsync.noindex/storage/state"));
	try std.testing.expect(!pattern.matches("resources/cpl/cloudsync.noindex/storage/store.cloudphotodb"));
}

test "journal pattern - exact match not prefix" {
	// Pattern should match exact filename, not filename prefix
	var pattern = try compile(std.testing.allocator, "**/journals/Memory-change.plj");
	defer pattern.deinit();

	// Should match: exact name
	try std.testing.expect(pattern.matches("journals/Memory-change.plj"));
	try std.testing.expect(pattern.matches("database/journals/Memory-change.plj"));

	// Should NOT match: filename with additional suffix
	try std.testing.expect(!pattern.matches("journals/Memory-change.plj.bak"));
	try std.testing.expect(!pattern.matches("database/journals/Memory-change.plj.bak"));
}

// ============ Combined Regex Optimization Tests ============

test "pattern set uses combined regex after first match" {
	var set = PatternSet.init(std.testing.allocator);
	defer set.deinit();

	try set.add("*.txt");
	try set.add("*.log");
	try set.add("*.tmp");

	// Before first matchesAny, not finalized
	try std.testing.expect(!set.is_finalized);
	try std.testing.expect(set.combined_regex == null);

	// First matchesAny triggers finalization
	try std.testing.expect(set.matchesAny("hello.txt", null));

	// Now should be finalized with combined regex
	try std.testing.expect(set.is_finalized);
	try std.testing.expect(set.combined_regex != null);

	// Subsequent matches should still work
	try std.testing.expect(set.matchesAny("hello.log", null));
	try std.testing.expect(set.matchesAny("hello.tmp", null));
	try std.testing.expect(!set.matchesAny("hello.doc", null));
}

test "pattern set add after finalize rebuilds combined regex" {
	var set = PatternSet.init(std.testing.allocator);
	defer set.deinit();

	try set.add("*.txt");
	_ = set.matchesAny("test.txt", null); // Triggers finalization
	try std.testing.expect(set.is_finalized);

	// Add new pattern - should invalidate
	try set.add("*.log");
	try std.testing.expect(!set.is_finalized);
	try std.testing.expect(set.combined_regex == null);

	// Next matchesAny should re-finalize
	try std.testing.expect(set.matchesAny("test.log", null));
	try std.testing.expect(set.is_finalized);
	try std.testing.expect(set.combined_regex != null);
}

test "pattern set matchesAny with alt_path" {
	var set = PatternSet.init(std.testing.allocator);
	defer set.deinit();

	// Pattern that only matches basename (no path separator handling)
	try set.add("*.txt");

	// rel_path has directories, won't match *.txt
	// but alt_path (basename) should match
	try std.testing.expect(!set.matchesAny("a/b/file.txt", null)); // *.txt doesn't match paths with /
	try std.testing.expect(set.matchesAny("a/b/file.txt", "file.txt")); // alt_path matches

	// If neither matches, should return false
	try std.testing.expect(!set.matchesAny("a/b/file.doc", "file.doc"));
}

test "pattern set combined regex handles complex patterns" {
	var set = PatternSet.init(std.testing.allocator);
	defer set.deinit();

	// Add patterns similar to default_ignore_patterns
	try set.add("*.sqlite-wal");
	try set.add("*.sqlite-shm");
	try set.add("**/DerivedData/**");
	try set.add("**/node_modules/**");

	// Trigger finalization
	try std.testing.expect(set.matchesAny("database.sqlite-wal", null));
	try std.testing.expect(set.is_finalized);

	// Test all patterns still work
	try std.testing.expect(set.matchesAny("app.sqlite-shm", null));
	try std.testing.expect(set.matchesAny("project/DerivedData/Build/something.o", null));
	try std.testing.expect(set.matchesAny("project/node_modules/lodash/index.js", null));
	try std.testing.expect(!set.matchesAny("normal_file.txt", null));
}

test "pattern set empty set returns false" {
	var set = PatternSet.init(std.testing.allocator);
	defer set.deinit();

	// Empty set should finalize cleanly and return false
	try std.testing.expect(!set.matchesAny("anything.txt", null));
	try std.testing.expect(set.is_finalized);
	try std.testing.expect(set.combined_regex == null); // No patterns = no regex
}

test "pattern set count" {
	var set = PatternSet.init(std.testing.allocator);
	defer set.deinit();

	try std.testing.expectEqual(@as(usize, 0), set.count());

	try set.add("*.txt");
	try std.testing.expectEqual(@as(usize, 1), set.count());

	try set.add("*.log");
	try std.testing.expectEqual(@as(usize, 2), set.count());
}

test "globToRegexUnanchored produces unanchored pattern" {
	const allocator = std.testing.allocator;

	// Anchored version
	const anchored = try globToRegex(allocator, "*.txt");
	defer allocator.free(anchored);
	try std.testing.expectEqualStrings("^[^/\\\\]*\\.txt$", anchored);

	// Unanchored version (internal function)
	const unanchored = try globToRegexUnanchored(allocator, "*.txt");
	defer allocator.free(unanchored);
	try std.testing.expectEqualStrings("[^/\\\\]*\\.txt", unanchored);
}
