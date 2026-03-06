const std = @import("std");

/// SIMD-accelerated case-insensitive substring search.
///
/// Drop-in replacement for `std.ascii.indexOfIgnoreCase` that uses
/// @Vector SIMD builtins to scan 16 bytes at a time for candidate
/// first-byte matches, then verifies with a scalar check.
///
/// Works on both aarch64 (NEON) and x86_64 (SSE2) via Zig's portable
/// vector types.

const VEC_LEN = 16;
const Vec = @Vector(VEC_LEN, u8);

/// Vectorised ASCII toLower: maps A-Z → a-z, leaves everything else unchanged.
/// Uses the branchless formula: c + 0x20 * (c >= 'A' and c <= 'Z').
inline fn vecToLower(v: Vec) Vec {
    const upper_a: Vec = @splat('A');
    const upper_z: Vec = @splat('Z');
    const diff: Vec = @splat(0x20);

    // mask = (v >= 'A') & (v <= 'Z')  → 0xFF for uppercase, 0x00 otherwise
    const ge_a = v >= upper_a;
    const le_z = v <= upper_z;
    const mask = ge_a & le_z;

    // Select: if mask then (v + 0x20) else v
    return @select(u8, mask, v +% diff, v);
}

/// SIMD-accelerated case-insensitive search. Returns the index of the first
/// occurrence of `needle` in `haystack` (ignoring ASCII case), or null.
pub fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    return indexOfIgnoreCasePos(haystack, 0, needle);
}

/// SIMD-accelerated case-insensitive search starting at `start_index`.
pub fn indexOfIgnoreCasePos(haystack: []const u8, start_index: usize, needle: []const u8) ?usize {
    if (needle.len == 0) return start_index;
    if (needle.len > haystack.len) return null;
    if (start_index > haystack.len - needle.len) return null;

    const first_lower = std.ascii.toLower(needle[0]);
    const first_splat: Vec = @splat(first_lower);

    // We need at least VEC_LEN bytes remaining to use the SIMD path.
    // The end position is the last valid start for a full needle match.
    const end = haystack.len - needle.len;
    var i: usize = start_index;

    // SIMD scanning loop: check VEC_LEN haystack positions at once for first-byte match.
    while (i + VEC_LEN <= end + 1) {
        const chunk: Vec = haystack[i..][0..VEC_LEN].*;
        const lower_chunk = vecToLower(chunk);
        const matches = lower_chunk == first_splat;

        // Convert bool vector to a bitmask for efficient iteration.
        const mask: u16 = @bitCast(matches);

        if (mask != 0) {
            // Iterate over set bits (candidate positions).
            var bits = mask;
            while (bits != 0) {
                const bit_pos = @ctz(bits);
                const pos = i + bit_pos;
                if (pos > end) break;
                if (eqlIgnoreCaseFast(haystack[pos..][0..needle.len], needle)) {
                    return pos;
                }
                // Clear lowest set bit.
                bits &= bits - 1;
            }
        }

        i += VEC_LEN;
    }

    // Scalar tail for remaining bytes.
    while (i <= end) : (i += 1) {
        if (std.ascii.toLower(haystack[i]) == first_lower) {
            if (eqlIgnoreCaseFast(haystack[i..][0..needle.len], needle)) {
                return i;
            }
        }
    }

    return null;
}

/// Fast case-insensitive equality check. Uses SIMD for slices >= VEC_LEN,
/// falls back to scalar for shorter ones.
fn eqlIgnoreCaseFast(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    const len = a.len;

    var i: usize = 0;

    // SIMD comparison in VEC_LEN-byte chunks.
    while (i + VEC_LEN <= len) {
        const va: Vec = a[i..][0..VEC_LEN].*;
        const vb: Vec = b[i..][0..VEC_LEN].*;
        const la = vecToLower(va);
        const lb = vecToLower(vb);
        if (@as(u16, @bitCast(la == lb)) != 0xFFFF) return false;
        i += VEC_LEN;
    }

    // Scalar tail.
    while (i < len) : (i += 1) {
        if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[i])) return false;
    }

    return true;
}

/// SIMD-accelerated case-insensitive equality (drop-in for std.ascii.eqlIgnoreCase).
pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return eqlIgnoreCaseFast(a, b);
}

// ── Tests ──────────────────────────────────────────────────────────────

test "indexOfIgnoreCase basic" {
    const testing = std.testing;

    // Basic matches
    try testing.expectEqual(@as(?usize, 0), indexOfIgnoreCase("Hello", "hello"));
    try testing.expectEqual(@as(?usize, 0), indexOfIgnoreCase("Hello", "HELLO"));
    try testing.expectEqual(@as(?usize, 0), indexOfIgnoreCase("Hello", "hElLo"));
    try testing.expectEqual(@as(?usize, 14), indexOfIgnoreCase("one Two Three Four", "foUr"));
    try testing.expectEqual(@as(?usize, null), indexOfIgnoreCase("one two three FouR", "gOur"));
    try testing.expectEqual(@as(?usize, 0), indexOfIgnoreCase("foO", "Foo"));
    try testing.expectEqual(@as(?usize, null), indexOfIgnoreCase("foo", "fool"));
    try testing.expectEqual(@as(?usize, 0), indexOfIgnoreCase("FOO foo", "fOo"));

    // Empty needle
    try testing.expectEqual(@as(?usize, 0), indexOfIgnoreCase("hello", ""));
    try testing.expectEqual(@as(?usize, 0), indexOfIgnoreCase("", ""));

    // Needle longer than haystack
    try testing.expectEqual(@as(?usize, null), indexOfIgnoreCase("hi", "hello"));

    // Single character
    try testing.expectEqual(@as(?usize, 0), indexOfIgnoreCase("A", "a"));
    try testing.expectEqual(@as(?usize, 0), indexOfIgnoreCase("a", "A"));

    // Non-alpha characters (should match exactly, not case-folded)
    try testing.expectEqual(@as(?usize, 0), indexOfIgnoreCase("123", "123"));
    try testing.expectEqual(@as(?usize, null), indexOfIgnoreCase("123", "124"));
}

test "indexOfIgnoreCase long strings" {
    const testing = std.testing;

    // Long enough to exercise the SIMD path
    const haystack = "abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789";
    // Case-insensitive: "ABCDEFGHIJ" first matches at index 0 (lowercase 'a'-'j')
    try testing.expectEqual(@as(?usize, 0), indexOfIgnoreCase(haystack, "ABCDEFGHIJ"));
    try testing.expectEqual(@as(?usize, 54), indexOfIgnoreCase(haystack, "0123456789"));

    // Test that finds match at a non-zero offset requiring SIMD
    const haystack3 = "0123456789---------ABCDEFGHIJKLMNOPQRSTUVWXYZ end";
    try testing.expectEqual(@as(?usize, 19), indexOfIgnoreCase(haystack3, "abcdefghij"));

    // Match in the scalar tail region
    const haystack2 = "0123456789abcdefGHIJ";
    try testing.expectEqual(@as(?usize, 10), indexOfIgnoreCase(haystack2, "ABCDEFGHIJ"));
}

test "indexOfIgnoreCase matches std behavior" {
    const testing = std.testing;

    // Verify against std.ascii.indexOfIgnoreCase for a variety of cases
    const cases = [_]struct { h: []const u8, n: []const u8 }{
        .{ .h = "one Two Three Four", .n = "foUr" },
        .{ .h = "one two three FouR", .n = "gOur" },
        .{ .h = "foO", .n = "Foo" },
        .{ .h = "foo", .n = "fool" },
        .{ .h = "FOO foo", .n = "fOo" },
        .{ .h = "one two three four five six seven eight nine ten eleven", .n = "ThReE fOUr" },
        .{ .h = "one two three four five six seven eight nine ten eleven", .n = "Two tWo" },
        .{ .h = "aBcDeFgHiJkLmNoPqRsTuVwXyZ", .n = "nop" },
        .{ .h = "Hello World! This is a test string for SIMD scanning.", .n = "SIMD" },
        .{ .h = "fn tokenCoverage(query_tokens: []const []const u8, symbol: model.Symbol) f32", .n = "coverage" },
        .{ .h = "", .n = "" },
        .{ .h = "a", .n = "a" },
        .{ .h = "a", .n = "b" },
        .{ .h = "ab", .n = "abc" },
    };

    for (cases) |c| {
        const expected = std.ascii.indexOfIgnoreCase(c.h, c.n);
        const actual = indexOfIgnoreCase(c.h, c.n);
        try testing.expectEqual(expected, actual);
    }
}

test "eqlIgnoreCase" {
    const testing = std.testing;

    try testing.expect(eqlIgnoreCase("Hello", "hello"));
    try testing.expect(eqlIgnoreCase("HELLO", "hello"));
    try testing.expect(!eqlIgnoreCase("hello", "world"));
    try testing.expect(!eqlIgnoreCase("hello", "hell"));
    try testing.expect(eqlIgnoreCase("", ""));

    // Long string (exercises SIMD path in eqlIgnoreCaseFast)
    try testing.expect(eqlIgnoreCase(
        "abcdefghijklmnopqrstuvwxyz",
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
    ));
}
