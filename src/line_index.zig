const std = @import("std");

/// Pre-computed line-offset table for O(log n) byte-offset → line-number lookups.
/// Replaces the O(n) `tokenLocation(0, tok)` pattern that scans from byte 0 every call.
pub const LineIndex = struct {
    line_starts: []const usize,

    /// Build the index by scanning source once for newlines. O(n) in source length.
    pub fn build(allocator: std.mem.Allocator, source: []const u8) !LineIndex {
        var starts = @as(std.ArrayListUnmanaged(usize), .empty);
        errdefer starts.deinit(allocator);
        try starts.append(allocator, 0); // line 0 starts at byte 0
        for (source, 0..) |byte, i| {
            if (byte == '\n') {
                try starts.append(allocator, i + 1);
            }
        }
        return .{ .line_starts = try starts.toOwnedSlice(allocator) };
    }

    pub fn deinit(self: *LineIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.line_starts);
    }

    /// Returns 0-indexed line number for a byte offset. O(log n) via binary search.
    pub fn lineForOffset(self: LineIndex, byte_offset: usize) usize {
        // Find largest i where line_starts[i] <= byte_offset
        var lo: usize = 0;
        var hi: usize = self.line_starts.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.line_starts[mid] <= byte_offset) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        // lo-1 is the last index where line_starts[lo-1] <= byte_offset
        return if (lo > 0) lo - 1 else 0;
    }
};

test "LineIndex basic" {
    const allocator = std.testing.allocator;
    const source = "line0\nline1\nline2\n";
    var idx = try LineIndex.build(allocator, source);
    defer idx.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), idx.lineForOffset(0)); // 'l' of line0
    try std.testing.expectEqual(@as(usize, 0), idx.lineForOffset(4)); // '0' of line0
    try std.testing.expectEqual(@as(usize, 1), idx.lineForOffset(6)); // 'l' of line1
    try std.testing.expectEqual(@as(usize, 2), idx.lineForOffset(12)); // 'l' of line2
}

test "LineIndex empty source" {
    const allocator = std.testing.allocator;
    var idx = try LineIndex.build(allocator, "");
    defer idx.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), idx.lineForOffset(0));
}

test "LineIndex single line no newline" {
    const allocator = std.testing.allocator;
    var idx = try LineIndex.build(allocator, "hello");
    defer idx.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), idx.lineForOffset(0));
    try std.testing.expectEqual(@as(usize, 0), idx.lineForOffset(4));
}
