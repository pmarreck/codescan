const std = @import("std");

/// A 3-character base-62 hash for content-anchored line addressing.
/// Used by LLMs to precisely reference code lines with staleness detection.
pub const HASH_LEN = 3;
pub const Hash = [HASH_LEN]u8;

/// Base-62 alphabet: 0-9 a-z A-Z (238,328 values per 3-char hash)
const ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";

/// Convert a u64 hash value to a 3-char base-62 string.
fn toBase62(value: u64) Hash {
	var result: Hash = undefined;
	var v = value;
	// Fill from right to left (least significant digit first)
	comptime var i: usize = HASH_LEN;
	inline while (i > 0) {
		i -= 1;
		result[i] = ALPHABET[v % 62];
		v /= 62;
	}
	return result;
}

/// Compute per-line chain hashes for a slice of lines.
/// Each hash depends on the previous line's hash (chain property),
/// so any edit above cascades through all subsequent hashes.
///
/// Returns a slice of 3-char hashes, one per line. Caller owns the memory.
pub fn computeChainHashes(allocator: std.mem.Allocator, lines: []const []const u8) ![]Hash {
	if (lines.len == 0) {
		return allocator.alloc(Hash, 0);
	}

	const hashes = try allocator.alloc(Hash, lines.len);

	var prev_hash: Hash = .{ '0', '0', '0' }; // seed for first line
	for (lines, 0..) |line, i| {
		var hasher = std.hash.XxHash64.init(0);
		hasher.update(&prev_hash);
		hasher.update(line);
		const digest = hasher.final();
		const hash = toBase62(digest);
		hashes[i] = hash;
		prev_hash = hash;
	}

	return hashes;
}

/// Compute chain hashes from raw source content (splits on newlines).
/// Returns one hash per line. Caller owns the memory.
pub fn computeSourceHashes(allocator: std.mem.Allocator, source: []const u8) ![]Hash {
	// Split source into lines
	var lines = std.ArrayListUnmanaged([]const u8){};
	defer lines.deinit(allocator);

	var start: usize = 0;
	for (source, 0..) |ch, i| {
		if (ch == '\n') {
			try lines.append(allocator, source[start..i]);
			start = i + 1;
		}
	}
	// Last line (may not end with newline)
	if (start <= source.len) {
		try lines.append(allocator, source[start..]);
	}

	return computeChainHashes(allocator, lines.items);
}

/// Compute the file-level version hash: the hashline of the last line.
/// Returns null if the source is empty.
pub fn computeFileVersion(allocator: std.mem.Allocator, source: []const u8) !?Hash {
	if (source.len == 0) return null;
	const hashes = try computeSourceHashes(allocator, source);
	defer allocator.free(hashes);
	if (hashes.len == 0) return null;
	return hashes[hashes.len - 1];
}

/// Compute the file-level version hash from a file path.
/// Returns null if the file is empty or cannot be read.
pub fn computeFileVersionFromPath(allocator: std.mem.Allocator, file_path: []const u8) ?Hash {
	const file = std.fs.cwd().openFile(file_path, .{}) catch return null;
	defer file.close();
	const source = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return null;
	defer allocator.free(source);
	return computeFileVersion(allocator, source) catch null;
}

/// Validate that a stored hash matches the current content at a given line.
/// Returns true if the hash is still valid, false if the file has changed (stale index).
/// Returns error.LineOutOfRange if line_number is out of bounds.
pub fn validateLine(allocator: std.mem.Allocator, source: []const u8, line_number: usize, expected_hash: Hash) !bool {
	if (line_number == 0) return error.LineOutOfRange;
	const hashes = try computeSourceHashes(allocator, source);
	defer allocator.free(hashes);

	const idx = line_number - 1; // convert 1-indexed to 0-indexed
	if (idx >= hashes.len) return error.LineOutOfRange;

	return std.mem.eql(u8, &hashes[idx], &expected_hash);
}

/// Format a hashline for display: "linenum:hash|content"
pub fn formatHashline(line_number: usize, hash: Hash, content: []const u8, writer: anytype) !void {
	try writer.print("{}:{s}|{s}", .{ line_number, &hash, content });
}

// ─── Tests ──────────────────────────────────────────────────────────

test "chain hashes have correct count" {
	const allocator = std.testing.allocator;
	const lines = &[_][]const u8{
		"fn main() void {",
		"    return;",
		"}",
	};
	const hashes = try computeChainHashes(allocator, lines);
	defer allocator.free(hashes);
	try std.testing.expectEqual(@as(usize, 3), hashes.len);
}

test "chain hashes are deterministic" {
	const allocator = std.testing.allocator;
	const lines = &[_][]const u8{
		"fn main() void {",
		"    return;",
		"}",
	};
	const hashes1 = try computeChainHashes(allocator, lines);
	defer allocator.free(hashes1);
	const hashes2 = try computeChainHashes(allocator, lines);
	defer allocator.free(hashes2);
	for (hashes1, hashes2) |h1, h2| {
		try std.testing.expectEqualStrings(&h1, &h2);
	}
}

test "chain hashes use base-62 alphabet and toBase62 uses modulus 62" {
	// Verify the alphabet is base-62 (0-9 a-z A-Z)
	try std.testing.expectEqual(@as(usize, 62), ALPHABET.len);

	// Verify hashes contain only base-62 characters
	const allocator = std.testing.allocator;
	const lines = &[_][]const u8{
		"const x = 42;",
		"const y = 99;",
		"return x + y;",
	};
	const hashes = try computeChainHashes(allocator, lines);
	defer allocator.free(hashes);
	for (hashes) |hash| {
		for (&hash) |c| {
			try std.testing.expect(
				(c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z'),
			);
		}
	}
}

test "changing a line changes its hash and all subsequent hashes" {
	const allocator = std.testing.allocator;
	const original = &[_][]const u8{
		"line one",
		"line two",
		"line three",
		"line four",
	};
	const modified = &[_][]const u8{
		"line one",
		"LINE TWO CHANGED",
		"line three",
		"line four",
	};
	const orig_hashes = try computeChainHashes(allocator, original);
	defer allocator.free(orig_hashes);
	const mod_hashes = try computeChainHashes(allocator, modified);
	defer allocator.free(mod_hashes);

	// Line 0 unchanged — hash must be identical
	try std.testing.expectEqualStrings(&orig_hashes[0], &mod_hashes[0]);
	// Line 1 changed — hash must differ
	try std.testing.expect(!std.mem.eql(u8, &orig_hashes[1], &mod_hashes[1]));
	// Lines 2-3 content unchanged but chain input differs — hashes must differ
	try std.testing.expect(!std.mem.eql(u8, &orig_hashes[2], &mod_hashes[2]));
	try std.testing.expect(!std.mem.eql(u8, &orig_hashes[3], &mod_hashes[3]));
}

test "identical adjacent lines produce different hashes" {
	const allocator = std.testing.allocator;
	const lines = &[_][]const u8{
		"    return;",
		"    return;",
		"    return;",
	};
	const hashes = try computeChainHashes(allocator, lines);
	defer allocator.free(hashes);
	// All three lines have identical content, but chain hashes should differ
	try std.testing.expect(!std.mem.eql(u8, &hashes[0], &hashes[1]));
	try std.testing.expect(!std.mem.eql(u8, &hashes[1], &hashes[2]));
}

test "empty input returns empty output" {
	const allocator = std.testing.allocator;
	const lines = &[_][]const u8{};
	const hashes = try computeChainHashes(allocator, lines);
	defer allocator.free(hashes);
	try std.testing.expectEqual(@as(usize, 0), hashes.len);
}

test "single line produces valid hash" {
	const allocator = std.testing.allocator;
	const lines = &[_][]const u8{"hello"};
	const hashes = try computeChainHashes(allocator, lines);
	defer allocator.free(hashes);
	try std.testing.expectEqual(@as(usize, 1), hashes.len);
	try std.testing.expectEqual(@as(usize, HASH_LEN), hashes[0].len);
}

test "formatHashline produces correct format" {
	var buf: [256]u8 = undefined;
	var fbs = std.io.fixedBufferStream(&buf);
	const hash = Hash{ 'k', '7', 'm' };
	try formatHashline(44, hash, "fn init(self: *Self) void {", fbs.writer());
	const result = fbs.getWritten();
	try std.testing.expectEqualStrings("44:k7m|fn init(self: *Self) void {", result);
}

test "validateLine returns true for matching hash" {
	const allocator = std.testing.allocator;
	const source = "line one\nline two\nline three\n";
	// Line 2 (1-indexed) should validate against its computed hash
	const hashes = try computeSourceHashes(allocator, source);
	defer allocator.free(hashes);
	// Validate line 2 against its own hash — must succeed
	try std.testing.expect(try validateLine(allocator, source, 2, hashes[1]));
}

test "validateLine returns false for stale hash after file edit" {
	const allocator = std.testing.allocator;
	const original = "fn foo() void {\n    return 42;\n}\n";
	const modified = "fn foo() void {\n    return 99;\n}\n";

	// Compute hashes from original content
	const orig_hashes = try computeSourceHashes(allocator, original);
	defer allocator.free(orig_hashes);

	// Validate original hash against MODIFIED content — must fail (stale)
	try std.testing.expect(!try validateLine(allocator, modified, 2, orig_hashes[1]));
	// Line 3 also stale (chain property: edit cascades)
	try std.testing.expect(!try validateLine(allocator, modified, 3, orig_hashes[2]));
	// Line 1 unchanged — should still validate
	try std.testing.expect(try validateLine(allocator, modified, 1, orig_hashes[0]));
}

test "validateLine detects staleness from insertion above" {
	const allocator = std.testing.allocator;
	const original = "line one\nline two\nline three\n";
	const with_insertion = "line zero\nline one\nline two\nline three\n";

	// Compute hashes from original
	const orig_hashes = try computeSourceHashes(allocator, original);
	defer allocator.free(orig_hashes);

	// After inserting a line at the top, original line 1's content is now at line 2,
	// but the hash at line 1 in the modified file is different (new content).
	// Validating original line 1 hash against modified file line 1 should fail.
	try std.testing.expect(!try validateLine(allocator, with_insertion, 1, orig_hashes[0]));
}

test "validateLine returns error for out-of-range line" {
	const allocator = std.testing.allocator;
	const source = "only one line\n";
	const result = validateLine(allocator, source, 5, .{ '0', '0', '0' });
	try std.testing.expectError(error.LineOutOfRange, result);
}

test "computeSourceHashes splits lines correctly" {
	const allocator = std.testing.allocator;
	const source = "a\nb\nc";
	const hashes = try computeSourceHashes(allocator, source);
	defer allocator.free(hashes);
	try std.testing.expectEqual(@as(usize, 3), hashes.len);
}

test "computeFileVersion returns last line hash" {
	const allocator = std.testing.allocator;
	const source = "line one\nline two\nline three\n";
	const hashes = try computeSourceHashes(allocator, source);
	defer allocator.free(hashes);
	const version = try computeFileVersion(allocator, source);
	try std.testing.expectEqual(hashes[hashes.len - 1], version.?);
}

test "computeFileVersion returns null for empty source" {
	const allocator = std.testing.allocator;
	const version = try computeFileVersion(allocator, "");
	try std.testing.expect(version == null);
}
