const std = @import("std");

/// Generate a unified diff between old and new content for a given file path.
/// Returns an allocated string in unified diff format.
/// Returns empty string (no headers, no hunks) when content is identical.
/// Caller owns the returned memory.
pub fn generateUnifiedDiff(allocator: std.mem.Allocator, old: []const u8, new: []const u8, file_path: []const u8) ![]u8 {
    // Split into lines
    const old_lines = try splitLines(allocator, old);
    defer allocator.free(old_lines);
    const new_lines = try splitLines(allocator, new);
    defer allocator.free(new_lines);

    // Find first differing line
    var first_diff: ?usize = null;
    var last_diff_old: ?usize = null;
    var last_diff_new: ?usize = null;

    const min_len = @min(old_lines.len, new_lines.len);
    const max_len = @max(old_lines.len, new_lines.len);

    // Find first difference
    for (0..min_len) |i| {
        if (!std.mem.eql(u8, old_lines[i], new_lines[i])) {
            first_diff = i;
            break;
        }
    }
    // If all common lines are equal, check if lengths differ
    if (first_diff == null and old_lines.len != new_lines.len) {
        first_diff = min_len;
    }

    // No differences at all
    if (first_diff == null) {
        return try allocator.alloc(u8, 0);
    }

    // Find last difference (scanning from the end)
    var old_end = old_lines.len;
    var new_end = new_lines.len;
    while (old_end > first_diff.? and new_end > first_diff.?) {
        if (std.mem.eql(u8, old_lines[old_end - 1], new_lines[new_end - 1])) {
            old_end -= 1;
            new_end -= 1;
        } else {
            break;
        }
    }
    last_diff_old = old_end;
    last_diff_new = new_end;
    _ = max_len;

    // Compute context bounds (3 lines of context)
    const context: usize = 3;
    const hunk_start_old = if (first_diff.? >= context) first_diff.? - context else 0;
    const hunk_start_new = hunk_start_old; // same offset since lines before first_diff are identical
    const hunk_end_old = @min(last_diff_old.? + context, old_lines.len);
    const hunk_end_new = @min(last_diff_new.? + context, new_lines.len);

    // Build output
    var alloc_writer = std.Io.Writer.Allocating.init(allocator);
    defer alloc_writer.deinit();
    const writer = &alloc_writer.writer;

    // File headers
    try writer.print("--- a/{s}\n", .{file_path});
    try writer.print("+++ b/{s}\n", .{file_path});

    // Hunk header: @@ -old_start,old_count +new_start,new_count @@
    const old_count = hunk_end_old - hunk_start_old;
    const new_count = hunk_end_new - hunk_start_new;
    try writer.print("@@ -{d},{d} +{d},{d} @@\n", .{
        hunk_start_old + 1, old_count,
        hunk_start_new + 1, new_count,
    });

    // Emit context before diff
    for (hunk_start_old..first_diff.?) |i| {
        try writer.print(" {s}\n", .{old_lines[i]});
    }

    // Emit removed lines
    for (first_diff.?..last_diff_old.?) |i| {
        try writer.print("-{s}\n", .{old_lines[i]});
    }

    // Emit added lines
    for (first_diff.?..last_diff_new.?) |i| {
        try writer.print("+{s}\n", .{new_lines[i]});
    }

    // Emit context after diff
    for (last_diff_old.?..hunk_end_old) |i| {
        try writer.print(" {s}\n", .{old_lines[i]});
    }

    return try alloc_writer.toOwnedSlice();
}

/// Split content into lines (slices into the original content, no copying).
fn splitLines(allocator: std.mem.Allocator, content: []const u8) ![]const []const u8 {
    var lines = @as(std.ArrayListUnmanaged([]const u8), .empty);
    defer lines.deinit(allocator);

    var start: usize = 0;
    for (content, 0..) |ch, i| {
        if (ch == '\n') {
            try lines.append(allocator, content[start..i]);
            start = i + 1;
        }
    }
    // Last line if no trailing newline
    if (start < content.len) {
        try lines.append(allocator, content[start..]);
    }

    return try lines.toOwnedSlice(allocator);
}

test "generateUnifiedDiff shows changes" {
    const allocator = std.testing.allocator;
    const old = "line one\nline two\nline three\n";
    const new_text = "line one\nline TWO\nline three\n";
    const result = try generateUnifiedDiff(allocator, old, new_text, "test.zig");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "--- a/test.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "+++ b/test.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "-line two") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "+line TWO") != null);
}

test "generateUnifiedDiff returns empty for identical content" {
    const allocator = std.testing.allocator;
    const text = "same\nsame\n";
    const result = try generateUnifiedDiff(allocator, text, text, "test.zig");
    defer allocator.free(result);
    // Should only have headers, no hunk
    try std.testing.expect(std.mem.indexOf(u8, result, "@@") == null);
}

test "generateUnifiedDiff handles added lines" {
    const allocator = std.testing.allocator;
    const old = "line one\nline three\n";
    const new_text = "line one\nline two\nline three\n";
    const result = try generateUnifiedDiff(allocator, old, new_text, "test.zig");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "+line two") != null);
    // "line three" is context, not changed — should appear as context line
    try std.testing.expect(std.mem.indexOf(u8, result, " line three") != null);
}

test "generateUnifiedDiff handles removed lines" {
    const allocator = std.testing.allocator;
    const old = "line one\nline two\nline three\n";
    const new_text = "line one\nline three\n";
    const result = try generateUnifiedDiff(allocator, old, new_text, "test.zig");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "-line two") != null);
    // "line three" should appear as context after the removal
    try std.testing.expect(std.mem.indexOf(u8, result, " line three") != null);
}
