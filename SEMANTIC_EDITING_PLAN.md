# Semantic Code Editing Plan

Goal: Make codescan a sharper, leaner alternative to Serena for LLM-driven code comprehension and editing. Zero config, zero ceremony, single static binary. The tool an LLM *wants* to reach for.

## Why This Beats Serena

| Dimension | Serena | Codescan (planned) |
|-----------|--------|-------------------|
| **Setup** | pip install + project.yml + activate + onboard | `codescan symbols src/main.zig` — just works |
| **Startup** | Seconds to eagerly start LSP servers | Instant for tree-sitter ops; lazy LSP only when needed |
| **Binary** | Python + venv + 30+ pip dependencies | Single static Zig binary |
| **Language detection** | Config file required | Auto-detect from extensions + shebangs (already done) |
| **Semantic search** | Not included | Already has embedding + FTS5 hybrid search |
| **Tool count** | ~30 MCP tools, most noise | ~10 CLI commands, all useful |
| **Interface** | MCP server (requires MCP client) | CLI — LLM already has shell access |
| **Overhead per invocation** | MCP JSON-RPC round-trip | Direct subprocess, streaming stdout |

## What Serena Gets Right (Worth Adopting)

The 6 tools that matter:

1. **`find_symbol`** — Find symbols by hierarchical name path (`Class/method`), optionally include body/info
2. **`get_symbols_overview`** — Quick overview of top-level symbols grouped by kind
3. **`find_referencing_symbols`** — Find all references to a symbol across the project
4. **`replace_symbol_body`** — Replace a symbol's entire body by name path (precise, no near-misses)
5. **`insert_after_symbol` / `insert_before_symbol`** — Insert code adjacent to a named symbol
6. **`rename_symbol`** — Rename across entire codebase

Everything else in Serena is either redundant with shell access or unnecessary ceremony:
- `create_text_file`, `read_file`, `list_dir`, `find_file` — shell does this
- Memory tools — LLM writes its own markdown
- Dashboard, JetBrains, config modes — not relevant
- `think_about_*`, onboarding, activation — prompting tricks that belong in the LLM, not the tool
- `replace_content` — that's just regex find-replace; `sed`/editor tools already exist
- `execute_shell_command` — the LLM already has Bash

## What Codescan Already Has

Codescan already has **tree-sitter parsers** for 12+ languages. Each extractor walks the AST and extracts:
- Function/method names and their source text
- Class/struct/enum definitions
- Module declarations and doc comments
- Source locations (line numbers, byte offsets)

This is currently used for embedding into SQLite for semantic search. The same infrastructure serves targeted code editing with minimal new work.

## Hashline: Content-Anchored Line Addressing

Inspired by [The Harness Problem](https://blog.can.ac/2026/02/12/the-harness-problem/).

### The Problem

LLMs fail at expressing edits not because they don't understand the task, but because edit formats are fragile:
- String replacement needs exact character matching → "string not found" errors
- Diffs need valid patch syntax → 46-50% failure rates on some models
- Line numbers alone shift on any insertion/deletion

### The Solution: Hashlines

Annotate each line with a short content-chain hash:

```
44:k7m|fn init(self: *Self) void {
45:r2p|    self.count = 0;
46:a9x|    self.buffer = undefined;
47:3bw|    self.ready = false;
48:npq|}
```

- **3 characters, base-36 (0-9 a-z)** — 46,656 possible values
- **Hash chain**: each line's hash incorporates the previous line's hash
  ```
  hash[0] = base36(short_hash(line[0]))
  hash[i] = base36(short_hash(hash[i-1] || line[i]))
  ```
- **Per-symbol chains**: chain resets at each symbol boundary (tree-sitter gives us these)

### Why These Design Choices

**3 chars base-36 (not 2-char hex):**

| Encoding | 2 chars | 3 chars |
|----------|---------|---------|
| Hex (base 16) | 256 values | 4,096 values |
| Base-36 (0-9 a-z) | 1,296 values | **46,656 values** |
| Base-62 (mixed case) | 3,844 values | 238,328 values |

- False-negative rate (edit goes undetected): 1/46,656 = 0.002%
- Birthday collision 50% threshold: ~216 lines (most functions are <100 lines)
- No case ambiguity (mixed case is risky — LLMs normalize case in short tokens)
- Visually distinct from line numbers (digits-only) at a glance
- LLMs see alphanumeric short-hashes constantly in training data

**Hash chains (not content-only hashes):**

Content-only hash: inserting a line at line 5 doesn't invalidate the hash at line 50.
Hash chain: any edit above cascades through all subsequent hashes.

If the file changed above your edit point, your mental model is stale. Better to force a re-read than silently apply a wrong edit.

**Per-symbol chains (not whole-file chains):**

A comment typo fix at line 1 shouldn't invalidate hashes in an unrelated function at line 500. Per-symbol chains reset at each tree-sitter symbol boundary, so:
- Edits within a function invalidate the rest of that function's hashes (correct)
- Edits in one function don't affect another function's hashes (pragmatic)

### Hashline Usage in Commands

Every codescan command that outputs code uses hashlines:

```
$ codescan find-symbol MyStruct/init --include-body

MyStruct/init (src/lib.zig:44-48) [Function]
44:k7m|fn init(self: *Self) void {
45:r2p|    self.count = 0;
46:a9x|    self.buffer = undefined;
47:3bw|    self.ready = false;
48:npq|}
```

Editing commands accept hashline references:

```
$ echo 'self.count = 0;
self.buffer = null;
self.ready = true;' | codescan replace-lines --file src/lib.zig --from 45:r2p --to 47:3bw

$ echo 'self.initialized = true;' | codescan insert-at 47:3bw --file src/lib.zig
```

Hash mismatch = immediate error, not silent corruption:

```
$ codescan replace-lines --file src/lib.zig --from 45:r2p --to 47:3bw
error: hashline mismatch at line 45 (expected r2p, got x4f) — file changed since last read
```

## New Commands

### Phase 1: Tree-sitter Read-Only (no new dependencies)

```
codescan symbols <file>
```
List all symbols in a file grouped by kind. Compact overview for orientation.
Output: JSON or human-formatted table of symbol names, kinds, line ranges.

```
codescan find-symbol <name_path> [--file <path>] [--include-body] [--depth N]
```
Find symbols matching a hierarchical name path pattern:
- Simple: `init` — matches any symbol named "init"
- Relative: `MyStruct/init` — matches suffix of name path
- Absolute: `/MyStruct/init` — exact match within file tree
Body output includes hashlines.

### Phase 2: Tree-sitter Editing (no new dependencies)

```
codescan replace-symbol <name_path> --file <path> --body <stdin>
```
Replace a symbol's entire body. Tree-sitter provides exact byte range.
Safer than string replacement — symbol name path is unambiguous.

```
codescan insert-after <name_path> --file <path> --body <stdin>
codescan insert-before <name_path> --file <path> --body <stdin>
```
Insert code adjacent to a named symbol. Handles newline normalization
(functions get blank line separators, fields don't — inferred from AST node type).

```
codescan replace-lines --file <path> --from <line:hash> --to <line:hash> --body <stdin>
codescan insert-at <line:hash> --file <path> --body <stdin>
```
Hashline-anchored line-level edits within a file. Hash mismatch = error.

### Phase 3: Optional LSP Integration (for cross-file operations)

```
codescan references <name_path> --file <path>
```
Find all references to a symbol across the project.
Auto-detect language, lazy-start appropriate LSP server (zls, rust-analyzer, etc.).

```
codescan rename <name_path> --file <path> --to <new_name>
```
Rename symbol across entire codebase via LSP `textDocument/rename`.
Auto-detect language, lazy LSP startup.

### Phase 4: Background Auto-Indexing

Watch for file changes (kqueue/FSEvents on macOS) and re-index in background.
Or: make indexing fast enough that on-demand re-indexing of changed files is negligible.

## Architecture

```
codescan CLI
  |
  +-- search (EXISTING) ---------- embedding pipeline + FTS5 hybrid
  +-- index/update (EXISTING) ---- scan -> extract -> embed -> store
  |
  +-- symbols (NEW, Phase 1) ----- tree-sitter AST query, zero-config
  +-- find-symbol (NEW, Phase 1) - name path matching over AST
  |
  +-- replace-symbol (NEW, Phase 2) -- tree-sitter location -> byte-level splice
  +-- insert-after (NEW, Phase 2) ---- tree-sitter anchor -> byte-level insert
  +-- insert-before (NEW, Phase 2) --- tree-sitter anchor -> byte-level insert
  +-- replace-lines (NEW, Phase 2) --- hashline-anchored range replacement
  +-- insert-at (NEW, Phase 2) ------- hashline-anchored insertion
  |
  +-- references (NEW, Phase 3) ------ LSP lazy-start -> textDocument/references
  +-- rename (NEW, Phase 3) ---------- LSP lazy-start -> textDocument/rename
  |
  +-- (Phase 4) ---------------------- background file watcher + incremental reindex
```

## Implementation Notes

### Name Path Resolution from Tree-Sitter

Tree-sitter gives parent-child AST nesting. A function node inside a struct node
gives `StructName/function_name`. Codescan's extractors already walk these trees
for embedding — just need to record and expose the hierarchy.

Name path matching follows Serena's proven scheme:
- `method` — match any symbol with that name (suffix match)
- `Class/method` — match any name path ending with that suffix
- `/Class/method` — exact match of full name path within file

### Byte-Precise Editing

Tree-sitter nodes have `start_byte`/`end_byte` and `start_point`/`end_point` (line, col).
This is all we need for `replace-symbol` and `insert-after/before`:
1. Read file into memory
2. Find symbol's byte range from tree-sitter
3. Splice: `file[0..start] ++ new_body ++ file[end..]`
4. Write back

### Stdin Body Input

All editing commands accept body from stdin. This lets LLMs pipe multi-line code
without shell escaping issues:

```
echo 'fn new_impl() void {
    // ...
}' | codescan replace-symbol MyStruct/init --file src/lib.zig
```

### Auto Language Detection

Already implemented. `src/plugin.zig` has a registry mapping extensions to languages.
`src/scan.zig` detects file types including shebang scripts. No configuration needed.

### Lazy LSP for Phase 3

When `codescan references` is invoked:
1. Detect language from file extension (plugin registry)
2. Check if appropriate LS binary is on PATH (zls, rust-analyzer, etc.)
3. Start it, send initialize + didOpen
4. Make the request, return result
5. Optionally keep running for subsequent calls (with timeout)

## What We Explicitly Do NOT Build

- Memory system — LLM writes its own markdown files
- Dashboard / web UI — CLI is the interface
- Project activation / onboarding — auto-detect everything
- "Thinking" tools — the LLM handles its own reasoning
- File I/O tools — shell already does this
- Configuration modes — one mode: "it works"
- MCP server — unnecessary indirection; CLI via shell is simpler

## Open Questions

- [ ] Hash function for hashlines: xxhash? CRC32 truncated? FNV-1a? (needs to be fast, good avalanche)
- [ ] Should `codescan symbols` output hashlines too, or just line ranges?
- [ ] For Phase 3 LSP: manage a persistent daemon, or start/stop per invocation?
- [ ] Should editing commands do a tree-sitter re-parse after edit to verify the result is valid syntax?
- [ ] How to handle languages without tree-sitter grammars (fallback to line-based editing only?)
