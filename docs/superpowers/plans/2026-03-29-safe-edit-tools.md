# Safe Edit Tool Suite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `read_file`, `create_file`, `destroy_file` tools and enhance all write tools with optimistic concurrency via a file-level version hash, making codescan's edit tools a safe superset of Claude Code's built-in Edit/Write/Read.

**Architecture:** Every file operation gets a 3-char version hash (the hashline of the last line). Reads return it; writes verify it before modifying. This gives optimistic concurrency control with zero storage overhead. All write tools return unified diffs. New `create_file` and `destroy_file` round out the CRUD operations.

**Tech Stack:** Zig 0.15, SQLite (via C FFI), hashline chain hashing, PCRE2, osascript (macOS trash)

**Build/test:** `nix develop -c zig build test --summary all`

**Build binary:** `nix develop -c zig build install` (produces `./zig-out/bin/codescan`)

**Spec:** `docs/superpowers/specs/2026-03-29-safe-edit-tools-design.md`

---

## File Map

| File | Responsibility | Tasks |
|---|---|---|
| `src/hashline.zig` | Add `computeFileVersion` helper | 1 |
| `src/main.zig` | `runReadFile`, `runCreateFile`, `runDestroyFile`; version check + diff in existing edit commands | 2, 3, 5, 6 |
| `src/mcp.zig` | New tool handlers + schemas; version param on existing tools | 7 |
| `src/cli.zig` | Parse `read-file`, `create-file`, `destroy-file` commands; `--version` flag | 2, 5, 6 |
| `src/diff.zig` (new) | Unified diff generation | 3 |
| `README.md` | Document hook-based integration for AI agents | 8 |

---

### Task 1: Extract `computeFileVersion` helper

**Files:**
- Modify: `src/hashline.zig`

- [ ] **Step 1: Write failing test**

Add test at end of `src/hashline.zig`:

```zig
test "computeFileVersion returns last line hash" {
    const allocator = std.testing.allocator;
    const source = "line one\nline two\nline three\n";
    const hashes = try computeSourceHashes(allocator, source);
    defer allocator.free(hashes);
    // computeFileVersion should return the same as the last hash
    const version = try computeFileVersion(allocator, source);
    try std.testing.expectEqual(hashes[hashes.len - 1], version.?);
}

test "computeFileVersion returns null for empty source" {
    const allocator = std.testing.allocator;
    const version = try computeFileVersion(allocator, "");
    try std.testing.expect(version == null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nix develop -c zig build test --summary all 2>&1 | grep -A5 "FAIL\|error.*test\|panic"`

Expected: Compilation error — `computeFileVersion` does not exist.

- [ ] **Step 3: Implement `computeFileVersion`**

Add in `src/hashline.zig` after `computeSourceHashes`:

```zig
/// Compute the file-level version hash: the hashline of the last line.
/// Returns null if the source is empty.
pub fn computeFileVersion(allocator: std.mem.Allocator, source: []const u8) !?Hash {
    if (source.len == 0) return null;
    const hashes = try computeSourceHashes(allocator, source);
    defer allocator.free(hashes);
    if (hashes.len == 0) return null;
    return hashes[hashes.len - 1];
}
```

Also add a file-path variant that reads from disk:

```zig
/// Compute the file-level version hash from a file path.
/// Returns null if the file is empty or cannot be read.
pub fn computeFileVersionFromPath(allocator: std.mem.Allocator, file_path: []const u8) ?Hash {
    const file = std.fs.cwd().openFile(file_path, .{}) catch return null;
    defer file.close();
    const source = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return null;
    defer allocator.free(source);
    return computeFileVersion(allocator, source) catch null;
}
```

- [ ] **Step 4: Run tests**

Run: `nix develop -c zig build test --summary all`

Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/hashline.zig
git commit -m "feat: add computeFileVersion helper for optimistic concurrency"
```

---

### Task 2: `read_file` CLI command and MCP tool

**Files:**
- Modify: `src/cli.zig` (add `read_file` to CommandTag, parse `read-file` command)
- Modify: `src/main.zig` (add `runReadFile`, wire command dispatch)
- Modify: `src/mcp.zig` (add `read_file` handler and schema)

- [ ] **Step 1: Write failing test for `runReadFile`**

Add test in `src/main.zig` near other edit tests:

```zig
test "runReadFile returns content with version and hashlines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const content = "line one\nline two\nline three\n";
    try tmp.dir.writeFile(.{ .sub_path = "test.zig", .data = content });

    const allocator = std.testing.allocator;
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const file_path = try std.fs.path.join(allocator, &.{ root, "test.zig" });
    defer allocator.free(file_path);

    var out_buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&out_buf);
    const writer_impl = fbs.writer();
    var writer = std.Io.Writer.init(&writer_impl);
    try runReadFile(allocator, file_path, null, null, .json, &writer);
    try writer.flush();
    const output = out_buf[0..fbs.pos];

    // Should be valid JSON with version, total_lines, content
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, output, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expect(obj.get("version") != null);
    try std.testing.expect(obj.get("total_lines") != null);
    try std.testing.expect(obj.get("content") != null);
    try std.testing.expectEqual(@as(i64, 4), obj.get("total_lines").?.integer); // 3 lines + trailing empty
}
```

Note: The writer API in Zig 0.15 may differ. Look at existing tests in main.zig for the exact pattern of constructing a writer for test output capture. Adapt the test to match the codebase's writer pattern (e.g. `std.ArrayListUnmanaged(u8)` with a writer interface).

- [ ] **Step 2: Run test to verify it fails**

Expected: Compilation error — `runReadFile` does not exist.

- [ ] **Step 3: Add `read_file` to CommandTag**

In `src/cli.zig`, add `read_file` to the `CommandTag` enum (after `status`):

```zig
pub const CommandTag = enum {
    // ... existing ...
    status,
    read_file,
};
```

- [ ] **Step 4: Parse `read-file` command in CLI**

In `src/cli.zig`, in the command dispatch section (around line 285), add:

```zig
} else if (std.mem.eql(u8, cmd, "read-file")) {
    parsed.command = .read_file;
    help_topic_default = "read-file";
    i += 1;
    if (i < args.len and !std.mem.startsWith(u8, args[i], "-")) {
        parsed.pattern = args[i]; // reuse pattern for file path
        i += 1;
    }
```

Add `--version` flag parsing in the flag loop:

```zig
if (std.mem.eql(u8, arg, "--version")) {
    i += 1;
    if (i >= args.len) return error.MissingValue;
    parsed.version_hash = args[i];
    i += 1;
    continue;
}
```

Add `version_hash: ?[]const u8` field to `Parsed` struct, initialized to `null`.

- [ ] **Step 5: Implement `runReadFile`**

Add in `src/main.zig`:

```zig
pub fn runReadFile(allocator: std.mem.Allocator, file_path: []const u8, from: ?usize, to: ?usize, format: output.OutputFormat, writer: *std.Io.Writer) !void {
    const source = try readFileContents(allocator, file_path);
    defer allocator.free(source);

    const hashes = try hashline.computeSourceHashes(allocator, source);
    defer allocator.free(hashes);

    // Compute version (last line hash)
    const version: ?hashline.Hash = if (hashes.len > 0) hashes[hashes.len - 1] else null;

    // Split into lines for output
    var lines = std.ArrayListUnmanaged([]const u8){};
    defer lines.deinit(allocator);
    var start_off: usize = 0;
    for (source, 0..) |ch, idx| {
        if (ch == '\n') {
            try lines.append(allocator, source[start_off..idx]);
            start_off = idx + 1;
        }
    }
    if (start_off <= source.len) {
        try lines.append(allocator, source[start_off..]);
    }

    const total_lines = lines.items.len;
    const from_line = if (from) |f| @min(f, total_lines) else 1;
    const to_line = if (to) |t| @min(t, total_lines) else total_lines;

    if (format == .json) {
        // Build content with hashlines
        var content_buf = std.ArrayListUnmanaged(u8){};
        defer content_buf.deinit(allocator);
        var line_num: usize = from_line;
        while (line_num <= to_line) : (line_num += 1) {
            if (line_num > from_line) try content_buf.append(allocator, '\n');
            const idx = line_num - 1;
            if (idx < hashes.len) {
                try content_buf.appendSlice(allocator, &std.fmt.digitToChar(line_num / 1000 % 10, .lower)); // use proper formatting
                // Use std.fmt.formatInt or print pattern
                var line_buf: [32]u8 = undefined;
                const line_str = std.fmt.bufPrint(&line_buf, "{d}:{s}|", .{ line_num, &hashes[idx] }) catch continue;
                try content_buf.appendSlice(allocator, line_str);
            }
            if (idx < lines.items.len) {
                try content_buf.appendSlice(allocator, lines.items[idx]);
            }
        }

        try writer.print("{{\"file\":\"{s}\",\"version\":\"{s}\",\"total_lines\":{d},\"from\":{d},\"to\":{d},\"content\":", .{
            file_path,
            if (version) |v| &v else "null",
            total_lines,
            from_line,
            to_line,
        });
        // Write content as JSON string
        try writer.writeByte('"');
        for (content_buf.items) |ch| {
            switch (ch) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\t' => try writer.writeAll("\\t"),
                '\r' => try writer.writeAll("\\r"),
                else => {
                    if (ch < 0x20) {
                        try writer.print("\\u{x:0>4}", .{ch});
                    } else {
                        try writer.writeByte(ch);
                    }
                },
            }
        }
        try writer.writeAll("\"}\n");
    } else {
        // Human format: version header + hashlined content
        try writer.print("# {s} (version: {s}, {d} lines)\n", .{
            file_path,
            if (version) |v| &v else "---",
            total_lines,
        });
        var line_num: usize = from_line;
        while (line_num <= to_line) : (line_num += 1) {
            const idx = line_num - 1;
            if (idx < hashes.len and idx < lines.items.len) {
                try writer.print("{d}:{s}|{s}\n", .{ line_num, &hashes[idx], lines.items[idx] });
            }
        }
    }
}
```

Note: This is a sketch. The implementer should follow existing patterns in main.zig for JSON output (look at how `output.writeResults` works for JSON). The writer API may need `try writer.flush()` at the end.

- [ ] **Step 6: Wire command dispatch in main.zig**

In the main command dispatch switch, add:

```zig
.read_file => {
    const file_path = parsed.pattern orelse {
        // error: file path required
        _ = stderr.print("error: file path required\nUsage: codescan read-file <path> [--from N] [--to N]\n", .{}) catch {};
        _ = stderr.flush() catch {};
        return;
    };
    try runReadFile(allocator, file_path, parsed.from_line, parsed.to_line, parsed.output, writer);
},
```

Add `from_line` and `to_line` fields to CLI parsed if not already present. Parse `--from` and `--to` as usize for read-file (existing `--from`/`--to` are hashline refs for replace-lines; for read-file they're line numbers — handle this in the dispatch).

- [ ] **Step 7: Add MCP handler and schema**

In `src/mcp.zig`, add handler:

```zig
} else if (std.mem.eql(u8, name, "read_file")) {
    const file = getArg(args, "file") orelse return error.MissingArgument;
    const from = getArgInt(args, "from");
    const to = getArgInt(args, "to");
    main.runReadFile(allocator, file, from, to, .json, &out.writer) catch |err|
        return toolError("MCP read_file: failed on '{s}': {}\n", .{ file, err });
```

Add to `tools_list_json`:

```
{"name":"read_file","description":"Read a file with hashline annotations and version hash for safe concurrent editing","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"File path (relative to project root)"},"from":{"type":"integer","description":"Start line (1-indexed, optional)"},"to":{"type":"integer","description":"End line (inclusive, optional)"}},"required":["file"]}}
```

- [ ] **Step 8: Run all tests**

Run: `nix develop -c zig build test --summary all`

- [ ] **Step 9: End-to-end CLI verification**

```bash
nix develop -c zig build install
./zig-out/bin/codescan read-file src/hashline.zig --json 2>&1 | head -1 | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'version={d[\"version\"]} lines={d[\"total_lines\"]}')"
./zig-out/bin/codescan read-file src/hashline.zig --from 1 --to 10
```

- [ ] **Step 10: Commit**

```bash
git add src/hashline.zig src/cli.zig src/main.zig src/mcp.zig
git commit -m "feat: add read_file tool with version hash for optimistic concurrency"
```

---

### Task 3: Unified diff generation + version check on `replace_content`

**Files:**
- Create: `src/diff.zig` (unified diff generator)
- Modify: `src/main.zig` (add version check and diff output to `runReplaceContent`)
- Modify: `src/mcp.zig` (add `version` param to `replace_content` handler)

- [ ] **Step 1: Write failing test for diff generation**

Create `src/diff.zig` with test:

```zig
const std = @import("std");

test "generateUnifiedDiff shows additions and deletions" {
    const allocator = std.testing.allocator;
    const old = "line one\nline two\nline three\n";
    const new = "line one\nline TWO\nline three\n";
    const result = try generateUnifiedDiff(allocator, old, new, "src/test.zig");
    defer allocator.free(result);
    // Should contain --- a/ and +++ b/ headers
    try std.testing.expect(std.mem.indexOf(u8, result, "--- a/src/test.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "+++ b/src/test.zig") != null);
    // Should show the changed line
    try std.testing.expect(std.mem.indexOf(u8, result, "-line two") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "+line TWO") != null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: Compilation error — `generateUnifiedDiff` does not exist.

- [ ] **Step 3: Implement `generateUnifiedDiff`**

In `src/diff.zig`:

```zig
const std = @import("std");

/// Generate a unified diff between old and new content for a given file path.
/// Returns an owned string the caller must free.
pub fn generateUnifiedDiff(allocator: std.mem.Allocator, old: []const u8, new: []const u8, file_path: []const u8) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    errdefer buf.deinit(allocator);

    const old_lines = try splitLines(allocator, old);
    defer allocator.free(old_lines);
    const new_lines = try splitLines(allocator, new);
    defer allocator.free(new_lines);

    try buf.appendSlice(allocator, "--- a/");
    try buf.appendSlice(allocator, file_path);
    try buf.append(allocator, '\n');
    try buf.appendSlice(allocator, "+++ b/");
    try buf.appendSlice(allocator, file_path);
    try buf.append(allocator, '\n');

    // Simple diff: find first and last differing lines, emit one hunk
    var first_diff: ?usize = null;
    var last_diff_old: usize = 0;
    var last_diff_new: usize = 0;
    const max_len = @max(old_lines.len, new_lines.len);
    for (0..max_len) |i| {
        const old_line = if (i < old_lines.len) old_lines[i] else null;
        const new_line = if (i < new_lines.len) new_lines[i] else null;
        const same = if (old_line != null and new_line != null)
            std.mem.eql(u8, old_line.?, new_line.?)
        else
            old_line == null and new_line == null;
        if (!same) {
            if (first_diff == null) first_diff = i;
            if (i < old_lines.len) last_diff_old = i;
            if (i < new_lines.len) last_diff_new = i;
        }
    }

    if (first_diff == null) return buf.toOwnedSlice(allocator); // no diff

    const fd = first_diff.?;
    const context_before = @min(fd, 3);
    const context_after_old = @min(old_lines.len -| (last_diff_old + 1), 3);
    const context_after_new = @min(new_lines.len -| (last_diff_new + 1), 3);
    const hunk_start = fd - context_before;
    const hunk_end_old = @min(last_diff_old + 1 + context_after_old, old_lines.len);
    const hunk_end_new = @min(last_diff_new + 1 + context_after_new, new_lines.len);

    // Hunk header
    var hdr_buf: [128]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "@@ -{d},{d} +{d},{d} @@\n", .{
        hunk_start + 1, hunk_end_old - hunk_start,
        hunk_start + 1, hunk_end_new - hunk_start,
    }) catch "@@ @@\n";
    try buf.appendSlice(allocator, hdr);

    // Context before
    for (hunk_start..fd) |i| {
        try buf.append(allocator, ' ');
        if (i < old_lines.len) try buf.appendSlice(allocator, old_lines[i]);
        try buf.append(allocator, '\n');
    }

    // Changed lines: show all old lines as deletions, then all new lines as additions
    // This is simplified — a proper LCS diff would interleave better, but for
    // tool output this is clear enough.
    for (fd..@min(last_diff_old + 1, old_lines.len)) |i| {
        try buf.append(allocator, '-');
        try buf.appendSlice(allocator, old_lines[i]);
        try buf.append(allocator, '\n');
    }
    for (fd..@min(last_diff_new + 1, new_lines.len)) |i| {
        try buf.append(allocator, '+');
        try buf.appendSlice(allocator, new_lines[i]);
        try buf.append(allocator, '\n');
    }

    // Context after
    const ctx_start = @max(last_diff_old + 1, last_diff_new + 1);
    const ctx_end = @max(hunk_end_old, hunk_end_new);
    for (ctx_start..ctx_end) |i| {
        try buf.append(allocator, ' ');
        const line = if (i < new_lines.len) new_lines[i] else if (i < old_lines.len) old_lines[i] else "";
        try buf.appendSlice(allocator, line);
        try buf.append(allocator, '\n');
    }

    return buf.toOwnedSlice(allocator);
}

fn splitLines(allocator: std.mem.Allocator, text: []const u8) ![]const ?[]const u8 {
    var lines = std.ArrayListUnmanaged(?[]const u8){};
    errdefer lines.deinit(allocator);
    var start: usize = 0;
    for (text, 0..) |ch, i| {
        if (ch == '\n') {
            try lines.append(allocator, text[start..i]);
            start = i + 1;
        }
    }
    if (start < text.len) {
        try lines.append(allocator, text[start..]);
    }
    return lines.toOwnedSlice(allocator);
}
```

Note: This is a simple single-hunk diff. For most edit operations (replacing a few lines), this is sufficient. The implementer should test with real examples and adjust if needed.

- [ ] **Step 4: Add version check to `runReplaceContent`**

In `src/main.zig`, modify `runReplaceContent` signature to accept optional version:

```zig
pub fn runReplaceContent(allocator: std.mem.Allocator, file_path: []const u8, needle: []const u8, regex_mode: bool, replace_all: bool, input_text: []const u8, version: ?[]const u8, writer: *std.Io.Writer) !void {
```

At the top of the function, after reading the source, add version check:

```zig
const source = try readFileContents(allocator, file_path);
defer allocator.free(source);

// Version check for optimistic concurrency
if (version) |expected_version| {
    if (hashline.computeFileVersion(allocator, source) catch null) |current_version| {
        if (!std.mem.eql(u8, &current_version, expected_version)) {
            try writer.print("error: file modified since last read (expected version {s}, current {s}) — re-read and retry\n", .{ expected_version, &current_version });
            return;
        }
    }
} else {
    // No version provided — warn
    try writer.print("warning: no --version provided; edit is unprotected against concurrent modifications\n", .{});
}
```

After writing the modified content, compute and return the new version + diff:

```zig
// After file.writeAll(result):
const new_version = hashline.computeFileVersionFromPath(allocator, file_path);
const diff_text = diff.generateUnifiedDiff(allocator, source, result, file_path) catch null;
defer if (diff_text) |d| allocator.free(d);

// Include version and diff in output
if (new_version) |nv| {
    try writer.print("version: {s}\n", .{&nv});
}
if (diff_text) |d| {
    try writer.writeAll(d);
}
```

- [ ] **Step 5: Update all callers of `runReplaceContent`**

Add `null` version parameter to existing callers:
- `src/main.zig` command dispatch: pass `parsed.version_hash`
- `src/mcp.zig` handler: pass `getArg(args, "version")`

Update MCP schema to include `version`, `from`, `to` params.

- [ ] **Step 6: Register `diff.zig` in test runner**

Add `@import("diff.zig")` to `src/all_tests.zig`.

- [ ] **Step 7: Run all tests**

Run: `nix develop -c zig build test --summary all`

- [ ] **Step 8: Commit**

```bash
git add src/diff.zig src/main.zig src/mcp.zig src/all_tests.zig
git commit -m "feat: add version check and unified diff to replace_content"
```

---

### Task 4: Version check on remaining write tools

**Files:**
- Modify: `src/main.zig` (add version param to `runReplaceSymbol`, `runReplaceLines`, `runInsertAt`, `runInsertAfter`, `runInsertBefore`)
- Modify: `src/mcp.zig` (add version param to all edit tool handlers and schemas)

- [ ] **Step 1: Write failing test for version check on replace_symbol**

Add test in `src/main.zig`:

```zig
test "runReplaceSymbol rejects stale version" {
    // Create temp file, compute version, modify file, then try replace with old version
    // Should get "file modified since last read" error
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const content = "pub fn foo() u32 { return 42; }\n";
    try tmp.dir.writeFile(.{ .sub_path = "test.zig", .data = content });
    // ... compute version, modify file, attempt replace with stale version, verify error
}
```

- [ ] **Step 2: Add version parameter to all 5 existing write functions**

For each of `runReplaceSymbol`, `runReplaceLines`, `runInsertAt`, `runInsertAfter`, `runInsertBefore`:

1. Add `version: ?[]const u8` parameter
2. At the top, read the source and check version (same pattern as replace_content)
3. After writing, return new version and diff
4. Update all callers (main.zig dispatch + mcp.zig handler)

The version check code is identical for all — extract a helper:

```zig
fn checkFileVersion(allocator: std.mem.Allocator, source: []const u8, expected: ?[]const u8, writer: *std.Io.Writer) !bool {
    if (expected) |ev| {
        if (hashline.computeFileVersion(allocator, source) catch null) |current| {
            if (!std.mem.eql(u8, &current, ev)) {
                try writer.print("error: file modified since last read (expected version {s}, current {s}) — re-read and retry\n", .{ ev, &current });
                return false;
            }
        }
    } else {
        try writer.print("warning: no --version provided; edit is unprotected against concurrent modifications\n", .{});
    }
    return true;
}
```

- [ ] **Step 3: Update MCP schemas for all edit tools**

Add `"version":{"type":"string","description":"File version hash from read_file (prevents race conditions)"}` to all edit tool schemas in `tools_list_json`.

- [ ] **Step 4: Run all tests**

Run: `nix develop -c zig build test --summary all`

- [ ] **Step 5: Commit**

```bash
git add src/main.zig src/mcp.zig
git commit -m "feat: add version check to all write tools (replace_symbol, replace_lines, insert_at, insert_before, insert_after)"
```

---

### Task 5: `create_file` CLI command and MCP tool

**Files:**
- Modify: `src/cli.zig` (add `create_file` to CommandTag, parse command)
- Modify: `src/main.zig` (add `runCreateFile`)
- Modify: `src/mcp.zig` (add handler and schema)

- [ ] **Step 1: Write failing test**

```zig
test "runCreateFile creates new file and returns version" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const file_path = try std.fs.path.join(allocator, &.{ root, "new_file.zig" });
    defer allocator.free(file_path);

    // ... call runCreateFile, verify file created, verify JSON response has version
}

test "runCreateFile errors if file exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "existing.zig", .data = "content" });
    // ... call runCreateFile, verify error message about existing file
}
```

- [ ] **Step 2: Implement `runCreateFile`**

```zig
pub fn runCreateFile(allocator: std.mem.Allocator, file_path: []const u8, body: []const u8, format: output.OutputFormat, writer: *std.Io.Writer) !void {
    // Check file doesn't exist
    if (std.fs.cwd().access(file_path, .{})) |_| {
        try writer.print("error: file already exists: {s} (use replace_content to modify existing files)\n", .{file_path});
        return;
    } else |_| {}

    // Create parent directories
    if (std.fs.path.dirname(file_path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }

    // Write file
    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();
    try file.writeAll(body);

    // Compute version
    const version = hashline.computeFileVersionFromPath(allocator, file_path);

    // Count lines
    var line_count: usize = 1;
    for (body) |ch| {
        if (ch == '\n') line_count += 1;
    }

    if (format == .json) {
        try writer.print("{{\"file\":\"{s}\",\"version\":\"{s}\",\"total_lines\":{d},\"message\":\"Created {s} ({d} lines)\"}}\n", .{
            file_path,
            if (version) |v| &v else "---",
            line_count,
            file_path,
            line_count,
        });
    } else {
        try writer.print("Created {s} ({d} lines, version: {s})\n", .{
            file_path,
            line_count,
            if (version) |v| &v else "---",
        });
    }
}
```

- [ ] **Step 3: Add CLI parsing and MCP handler**

CLI: Add `create_file` to CommandTag. Parse `create-file` command with `--file` argument.

MCP: Add handler and schema:
```json
{"name":"create_file","description":"Create a new file (errors if file exists)","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"File path (relative to project root)"},"body":{"type":"string","description":"File content"}},"required":["file","body"]}}
```

- [ ] **Step 4: Run all tests**

- [ ] **Step 5: Commit**

```bash
git add src/cli.zig src/main.zig src/mcp.zig
git commit -m "feat: add create_file tool for safe file creation"
```

---

### Task 6: `destroy_file` CLI command and MCP tool

**Files:**
- Modify: `src/cli.zig` (add `destroy_file` to CommandTag)
- Modify: `src/main.zig` (add `runDestroyFile` with OS-specific trash)
- Modify: `src/mcp.zig` (add handler and schema)

- [ ] **Step 1: Write failing test**

```zig
test "runDestroyFile moves file to trash" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "doomed.zig", .data = "bye" });
    const allocator = std.testing.allocator;
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const file_path = try std.fs.path.join(allocator, &.{ root, "doomed.zig" });
    defer allocator.free(file_path);

    // ... call runDestroyFile, verify file no longer accessible
    // Note: can't easily verify it's in trash from a test, just verify it's removed
}

test "runDestroyFile rejects stale version" {
    // Create file, get version, modify file, try destroy with old version → error
}
```

- [ ] **Step 2: Implement `runDestroyFile`**

```zig
pub fn runDestroyFile(allocator: std.mem.Allocator, file_path: []const u8, version: ?[]const u8, writer: *std.Io.Writer) !void {
    // Version check
    const source = readFileContents(allocator, file_path) catch |err| {
        try writer.print("error: cannot read file '{s}': {}\n", .{ file_path, err });
        return;
    };
    defer allocator.free(source);

    if (!try checkFileVersion(allocator, source, version, writer)) return;

    // Get absolute path for trash commands
    const abs_path = try std.fs.cwd().realpathAlloc(allocator, file_path);
    defer allocator.free(abs_path);

    // Move to trash (OS-specific)
    const builtin = @import("builtin");
    if (builtin.os.tag == .macos) {
        // macOS: use osascript for Finder "Put Back" support
        const script = try std.fmt.allocPrintZ(allocator,
            "tell application \"Finder\" to move POSIX file \"{s}\" to trash",
            .{abs_path},
        );
        defer allocator.free(script);
        var child = std.process.Child.init(&.{ "osascript", "-e", script }, allocator);
        child.stderr_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        _ = try child.spawnAndWait();
    } else {
        // Linux: try gio trash, then trash-put, then manual move
        const trash_cmds = [_][]const []const u8{
            &.{ "gio", "trash", abs_path },
            &.{ "trash-put", abs_path },
        };
        var trashed = false;
        for (trash_cmds) |cmd| {
            var child = std.process.Child.init(cmd, allocator);
            child.stderr_behavior = .Ignore;
            child.stdout_behavior = .Ignore;
            const term = child.spawnAndWait() catch continue;
            if (term.Exited == 0) { trashed = true; break; }
        }
        if (!trashed) {
            // Fallback: move to ~/.local/share/Trash/files/
            const home = std.posix.getenvZ("HOME") orelse "/tmp";
            const trash_dir = try std.fs.path.join(allocator, &.{ home, ".local/share/Trash/files" });
            defer allocator.free(trash_dir);
            std.fs.cwd().makePath(trash_dir) catch {};
            const basename = std.fs.path.basename(abs_path);
            const dest = try std.fs.path.join(allocator, &.{ trash_dir, basename });
            defer allocator.free(dest);
            std.fs.cwd().rename(abs_path, dest) catch {
                try writer.print("error: could not move '{s}' to trash\n", .{file_path});
                return;
            };
        }
    }

    try writer.print("Moved {s} to trash\n", .{file_path});
}
```

- [ ] **Step 3: Add CLI parsing and MCP handler**

MCP schema:
```json
{"name":"destroy_file","description":"Move a file to system trash (safer than rm, supports undo)","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"File path (relative to project root)"},"version":{"type":"string","description":"File version hash from read_file (prevents race conditions)"}},"required":["file"]}}
```

- [ ] **Step 4: Run all tests**

- [ ] **Step 5: End-to-end test**

```bash
nix develop -c zig build install
echo "test content" > /tmp/codescan-test-destroy.txt
./zig-out/bin/codescan destroy-file --file /tmp/codescan-test-destroy.txt
# Verify file is gone: ls /tmp/codescan-test-destroy.txt should fail
# macOS: check Trash for the file
```

- [ ] **Step 6: Commit**

```bash
git add src/cli.zig src/main.zig src/mcp.zig
git commit -m "feat: add destroy_file tool with OS-native trash support"
```

---

### Task 7: README update — hook-based AI agent integration

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add section after the MCP tools table**

Add a new section documenting the hook-based integration:

```markdown
## AI Agent Integration (Optional)

codescan can replace Claude Code's built-in Read, Edit, Grep, and Glob tools with safer,
hashline-validated alternatives. This is especially valuable for multi-agent workflows where
concurrent file access can cause stale edits.

### Why use codescan's tools instead of built-in ones?

- **Optimistic concurrency**: Every `read_file` returns a 3-character version hash. Pass it
  back to any write tool — if the file changed since your read, the edit fails cleanly
  instead of silently corrupting. This prevents race conditions when multiple agents work
  on the same codebase.
- **Hashline validation**: Line-level edits use content-chain hashes that detect if the
  target lines have shifted since your last read.
- **Structured search**: `codescan search --kind fn` returns semantically relevant results
  instead of raw text matches, using fewer tokens.
- **Safe deletion**: `destroy_file` moves files to the system trash (with undo support)
  instead of `rm`.

### Setup: Global Claude Code Hook

Add to `~/.claude/settings.json` to nudge Claude toward codescan tools in indexed projects:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Grep|Glob|Agent",
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/.claude/hooks/codescan-redirect/redirect.sh",
            "timeout": 5,
            "statusMessage": "Checking codescan availability..."
          }
        ]
      }
    ]
  }
}
```

The hook checks if `.codescan/` exists in the project and injects a reminder to use
codescan's tools instead. It's non-blocking — the built-in tool still runs, but the
model learns to prefer codescan over time.

Add to `~/.claude/CLAUDE.md`:

```markdown
## Code Navigation: Prefer codescan

At the start of every session, run `codescan status` to check if the project is indexed
and the watcher is running.

When a `.codescan/` directory exists:
- Use `codescan search` / `codescan symbols` instead of Grep/Glob
- Use `codescan read-file` instead of Read (returns version hash for safe edits)
- Use `codescan replace-content --version <hash>` instead of Edit
- Use `codescan create-file` instead of Write
- Use `codescan destroy-file` instead of rm
```
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add AI agent integration section with hook setup"
```

---

### Task 8: Final integration test + push

- [ ] **Step 1: Run full test suite**

```bash
nix develop -c zig build test --summary all
```

- [ ] **Step 2: Build and end-to-end verification**

```bash
nix develop -c zig build install
./zig-out/bin/codescan index

# read_file
./zig-out/bin/codescan read-file src/hashline.zig --from 1 --to 5
./zig-out/bin/codescan read-file src/hashline.zig --json | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'version={d[\"version\"]}')"

# create_file + destroy_file round trip
./zig-out/bin/codescan create-file --file /tmp/codescan-roundtrip.txt <<< "hello world"
./zig-out/bin/codescan read-file /tmp/codescan-roundtrip.txt --json
./zig-out/bin/codescan destroy-file --file /tmp/codescan-roundtrip.txt

# replace_content with version
VERSION=$(./zig-out/bin/codescan read-file src/hashline.zig --json | python3 -c "import sys,json; print(json.load(sys.stdin)['version'])")
echo "Version: $VERSION"
```

- [ ] **Step 3: Push and check CI**

```bash
git push origin yolo
gh run list --branch yolo --limit 1 --json status,conclusion
# Wait for CI to pass
```

- [ ] **Step 4: Update hook to also intercept Read**

In `~/.claude/hooks/codescan-redirect/redirect.sh`, add `Read` to the tool case:

```bash
case "$TOOL_NAME" in
  Grep|Glob|Agent|Read) ;;
  *) exit 0 ;;
esac
```

Update `~/.claude/settings.json` matcher:

```json
"matcher": "Grep|Glob|Agent|Read",
```
