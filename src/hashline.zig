const std = @import("std");

/// A 3-character base-36 hash for content-anchored line addressing.
/// Used by LLMs to precisely reference code lines with staleness detection.
pub const HASH_LEN = 3;
pub const Hash = [HASH_LEN]u8;

/// Base-36 alphabet: 0-9 a-z (no uppercase to avoid LLM case-normalization issues)
const BASE36 = "0123456789abcdefghijklmnopqrstuvwxyz";

/// Convert a u64 hash value to a 3-char base-36 string.
fn toBase36(value: u64) Hash {
	var result: Hash = undefined;
	var v = value;
	// Fill from right to left (least significant digit first)
	comptime var i: usize = HASH_LEN;
	inline while (i > 0) {
		i -= 1;
		result[i] = BASE36[v % 36];
		v /= 36;
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
		const hash = toBase36(digest);
		hashes[i] = hash;
		prev_hash = hash;
	}

	return hashes;
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

test "chain hashes use only base-36 characters" {
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
				(c >= '0' and c <= '9') or (c >= 'a' and c <= 'z'),
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
