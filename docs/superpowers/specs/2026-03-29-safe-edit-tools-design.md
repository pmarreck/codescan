# Safe Edit Tool Suite

**Date:** 2026-03-29
**Status:** Approved

## Overview

Add `read_file`, `create_file`, `destroy_file` tools and enhance all existing write tools with optimistic concurrency control via a file-level version hash. The version hash is the hashline of the last line of the file — a 3-character content-addressed checksum that changes if any byte in the file changes. Zero storage overhead, zero external state.

## 1. `read_file` (new tool)

Reads a file with hashline annotations and a file-level version hash.

**CLI:**
```
codescan read-file <path> [--from <line>] [--to <line>] [--json]
```

**MCP:**
```json
{"name": "read_file", "arguments": {"file": "src/foo.zig", "from": 10, "to": 50}}
```

**Parameters:**
- `file` (required): relative file path
- `from` (optional): start line (1-indexed)
- `to` (optional): end line (inclusive)

**Response (JSON):**
```json
{
  "file": "src/foo.zig",
  "version": "k7m",
  "total_lines": 350,
  "from": 10,
  "to": 50,
  "content": "10:abc|fn init() void {\n11:def|    ...\n..."
}
```

**Key behavior:**
- `version` is always the hashline of the last line of the **entire file**, even for partial reads
- `total_lines` is always the total line count of the entire file
- Content lines use hashline format: `<line>:<hash>|<content>`
- Human output shows hashlines inline; JSON output separates them

## 2. `replace_content` (enhanced)

Add `version` parameter for optimistic concurrency control.

**New parameters:**
- `version` (optional, string): 3-char file version hash from a prior `read_file`. Before writing, recompute the file's current version. If mismatch, error: `"file modified since last read (expected k7m, now x9a) — re-read and retry"`. If omitted, warn: `"warning: no --version provided; edit is unprotected against concurrent modifications"`
- `from` (optional, string): hashline ref (e.g. `10:k7m`) — scope match to lines at or after this
- `to` (optional, string): hashline ref (e.g. `20:x9a`) — scope match to lines at or before this

**Existing behavior preserved:**
- Uniqueness enforced by default (errors on multiple matches unless `--all`)
- Literal and regex modes
- Returns affected line numbers with hashlines

**New response format (JSON):**
```json
{
  "file": "src/foo.zig",
  "old_version": "k7m",
  "new_version": "x9a",
  "diff": "--- a/src/foo.zig\n+++ b/src/foo.zig\n@@ -10,3 +10,5 @@\n-old line\n+new line",
  "message": "Replaced 1 occurrence (line 10:abc)"
}
```

## 3. Version check on all existing write tools

Add optional `version` parameter to:
- `replace_symbol`
- `replace_lines`
- `insert_at`
- `insert_before`
- `insert_after`

Same logic: if provided, verify current file version matches before writing. If mismatch, error with clear message. If omitted, warn about concurrent modification risk.

All write tools return the unified diff and new version hash in their response.

## 4. `create_file` (new tool)

Creates a new file. Errors if the file already exists.

**CLI:**
```
codescan create-file --file <relative-path>    # reads body from stdin
```

**MCP:**
```json
{"name": "create_file", "arguments": {"file": "src/new.zig", "body": "const std = @import(\"std\");\n"}}
```

**Parameters:**
- `file` (required): relative path from project root
- `body` (required for MCP, stdin for CLI): file content

**Behavior:**
- Errors if file already exists (use `replace_content` for existing files)
- Creates parent directories as needed (`mkdir -p` equivalent)
- Returns the new file's version hash

**Response (JSON):**
```json
{
  "file": "src/new.zig",
  "version": "x9a",
  "total_lines": 5,
  "message": "Created src/new.zig (5 lines)"
}
```

## 5. `destroy_file` (new tool)

Moves a file to the system trash. Safer than `rm`.

**CLI:**
```
codescan destroy-file --file <relative-path> [--version <hash>]
```

**MCP:**
```json
{"name": "destroy_file", "arguments": {"file": "src/old.zig", "version": "k7m"}}
```

**Parameters:**
- `file` (required): relative path from project root
- `version` (optional): verify file hasn't changed before deletion

**Behavior:**
- If `--version` provided: recompute file's version hash, error on mismatch
- If `--version` omitted: warn about concurrent modification risk
- **macOS:** `osascript -e 'tell app "Finder" to move POSIX file "/abs/path" to trash'` (supports Finder "Put Back")
- **Linux:** `gio trash <path>` if available, else `trash-put <path>`, else move to `~/.local/share/Trash/files/` per freedesktop spec
- Errors if file does not exist
- After trashing, remove from codescan index (`deleteSymbolsByFile` + `deleteIndexedFile`)

**Response (JSON):**
```json
{
  "file": "src/old.zig",
  "message": "Moved src/old.zig to trash"
}
```

## 6. Diff output format

All write tools (`replace_content`, `replace_symbol`, `replace_lines`, `insert_at`, `insert_before`, `insert_after`, `create_file`) return a unified diff in their response:

```
--- a/src/foo.zig
+++ b/src/foo.zig
@@ -10,3 +10,5 @@
-old line
+new line
+added line
```

- Unified diff format is automatically syntax-highlighted by Claude Code
- JSON responses include the diff as a `"diff"` field
- Human (CLI) responses print the diff to stdout
- `create_file` returns a diff showing all lines as additions
- `destroy_file` does not return a diff (file is gone)

## 7. MCP schema updates

New tools added to `tools_list_json`:

```json
{"name":"read_file","description":"Read a file with hashline annotations and version hash for safe concurrent editing","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"File path (relative to project root)"},"from":{"type":"integer","description":"Start line (1-indexed, optional)"},"to":{"type":"integer","description":"End line (inclusive, optional)"}},"required":["file"]}}

{"name":"create_file","description":"Create a new file (errors if file exists)","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"File path (relative to project root)"},"body":{"type":"string","description":"File content"}},"required":["file","body"]}}

{"name":"destroy_file","description":"Move a file to system trash (safer than rm, supports undo)","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"File path (relative to project root)"},"version":{"type":"string","description":"File version hash from read_file (prevents race conditions)"}},"required":["file"]}}
```

Updated existing tool schemas to include `version` parameter:
- `replace_content`: add `"version":{"type":"string","description":"File version hash from read_file (prevents race conditions)"}` and `"from":{"type":"string","description":"Hashline ref to scope match start (e.g. 10:k7m)"}` and `"to":{"type":"string","description":"Hashline ref to scope match end (e.g. 20:x9a)"}`
- `replace_symbol`: add `version`
- `replace_lines`: add `version`
- `insert_at`: add `version`
- `insert_before`: add `version`
- `insert_after`: add `version`

## 8. Version hash computation

The version hash is computed by the existing `computeFileHashes` function in `src/indexer.zig` which chains hashline hashes line by line. For the file-level version:

```
version = hashline_of_last_line(file)
```

This is the same hash that appears as the last entry in the hashline annotation. To compute it without annotating every line, read the file and compute the chain hash up to the last line.

A dedicated helper `computeFileVersion(allocator, file_path) -> ?hashline.Hash` should be extracted for use by all write tools.

## Implementation order

1. **Extract `computeFileVersion` helper** — shared by all tools
2. **`read_file`** — foundation, agents need this to get version hashes
3. **Version check on `replace_content`** + diff output
4. **Version check on other existing write tools** + diff output
5. **`create_file`**
6. **`destroy_file`**
7. **MCP schemas for all new/updated tools**
8. **Update PreToolUse hook** to also intercept `Read` tool

## Files touched

| File | Changes |
|---|---|
| `src/main.zig` | New `runReadFile`, `runCreateFile`, `runDestroyFile` commands; version check in existing edit commands; diff generation |
| `src/mcp.zig` | New tool handlers and schemas; version parameter on existing tools |
| `src/cli.zig` | Parse `read-file`, `create-file`, `destroy-file` commands and `--version` flag |
| `src/hashline.zig` | Extract `computeFileVersion` helper |
| `src/indexer.zig` | May reuse `computeFileHashes` or extract shared logic |
| `src/storage.zig` | `deleteSymbolsByFile` + `deleteIndexedFile` already exist (used by destroy_file) |
| `~/.claude/hooks/codescan-redirect/redirect.sh` | Add `Read` to intercepted tools |
| `~/.claude/CLAUDE.md` | Update codescan section to mention read_file, version hashes |
