# Kind Filter & Search Improvements

**Date:** 2026-03-29
**Status:** Approved

## Overview

Seven improvements to codescan's `--kind` filter, search behavior, and MCP parity. All changes follow TDD: failing test first, then implementation.

## 1. Short canonical forms in DB

Change DB `symbol_kind` storage from full words to short forms matching `SymbolKind.label()`:

| Old DB value | New DB value |
|---|---|
| `"function"` | `"fn"` |
| `"variable"` | `"var"` |
| `"constant"` | `"const"` (new, see item 2) |
| `"module"` | `"mod"` |
| `"macro"` | `"macro"` (unchanged) |
| `"struct"` | `"struct"` (unchanged) |
| `"enum"` | `"enum"` (unchanged) |
| `"union"` | `"union"` (unchanged) |
| `"class"` | `"class"` (unchanged) |
| `"interface"` | `"interface"` (unchanged) |
| `"trait"` | `"trait"` (unchanged) |
| `"type"` | `"type"` (unchanged) |
| `"test"` | `"test"` (unchanged) |

**Files changed:**
- `src/indexer.zig`: `inferKindFromSignature` returns short forms
- `src/filters.zig`: `normalizeSymbolKind` maps aliases to short forms
- `src/storage.zig`: test fixtures updated

**Migration:** None needed. `codescan index` drops and recreates. `codescan update` will re-process files whose mtime changed; stale records from prior indexes coexist harmlessly until a full reindex.

## 2. const/var split (language-aware mutability)

Split the current `"variable"` kind into `"const"` (immutable) and `"var"` (mutable).

**Signature → `inferKindFromSignature(signature, language)`:**

| Keyword | Language | Stored kind |
|---|---|---|
| `const` | any | `"const"` |
| `val` | any | `"const"` |
| `let` | rust, swift | `"const"` |
| `let` | js, typescript, default | `"var"` |
| `var` | any | `"var"` |
| `mut` | any | `"var"` |

**`enrichSymbolMetadata` change:** Pass `symbol.language` through to `inferKindFromSignature`.

**Filter aliases (`normalizeSymbolKind`):**

| User input | Matches |
|---|---|
| `--kind const`, `--kind constant` | `"const"` |
| `--kind var`, `--kind variable`, `--kind mut` | `"var"` |
| `--kind val` | `"const"` |
| `--kind let` | either `"const"` or `"var"` depending on how the language in question handles `let` |
| `--kind declaration` | both `"const"` and `"var"` |

Multi-value aliases (`let`, `declaration`) require `normalizeSymbolKind` to return a slice or `parseSymbolKindList` to expand them inline.

## 3. Meta-kinds: `definition` and `declaration`

| Meta-kind | Expands to |
|---|---|
| `definition` | all non-null `symbol_kind` values (sentinel `"*"` → `WHERE symbol_kind IS NOT NULL`) |
| `declaration` | `"const"`, `"var"` |

**Implementation:** `normalizeSymbolKind` returns `null` for unknown kinds, a single canonical string for normal kinds, or a sentinel/list for meta-kinds. The simplest approach: `parseSymbolKindList` handles expansion before appending to `FilterLists.symbol_kinds`. The search filter check in `search.zig` treats `"*"` as "symbol_kind IS NOT NULL".

## 4. Empty query browse mode (`codescan search --kind fn`)

**Current:** `search.zig:100` returns `error.EmptyQuery` when `query.len == 0`.

**Change:** When query is empty but at least one filter is present (kind, lang, ext, path), run a SQL-only browse path:

```sql
SELECT id, lang, file_path, start_line, start_hash, end_line, end_hash,
       symbol_name, signature, doc_comment,
       symbol_kind, symbol_visibility, symbol_scope, symbol_arity, body
FROM symbols
WHERE symbol_kind = ?1
ORDER BY file_path, start_line
LIMIT ?2
```

Return results with `score = 1.0`, `distance = 0.0`, `lexical = 0.0`.

When no query AND no filters, keep the current `EmptyQuery` error.

## 5. `--path` (glob) and `--file` (exact) filters for search

**`--path <glob>`** — glob pattern for file path filtering. Repeatable. Uses existing `filter.zig` `PatternSet` (PCRE2-backed).
- `--path "src/extract_*.zig"`
- `--path "*.zig"`

**`--file <path>`** — exact single file path. Errors if given a glob metacharacter (`*`, `?`, `[`, `{`). Syntactic sugar that adds an exact-match entry to the same path filter set.

**Implementation:** Post-filter search results using `PatternSet.matchesAny()` on `result.symbol.file_path`. Applied after scoring, before truncation to `top_n`. This works for vector, lexical, and browse modes.

**Structs affected:**
- `cli.zig`: Parse `--path` and `--file` flags
- `search.zig`: Add `allowed_paths: []const []const u8` to `Options` (or accept a `*PatternSet`)
- `filters.zig`: Add `paths: PatternSet` to `FilterLists`, build from CLI/MCP input
- `main.zig`: Wire through
- `mcp.zig`: Wire through

## 6. Informative "no results" diagnostics

When search returns 0 results and 2+ filter dimensions were active, run cheap `SELECT COUNT(*)` queries with subsets of filters to identify which combination eliminated results.

**Output (CLI stderr):**
```
note: no results for query "foo" with kind=struct, path=src/*.zig
  -> "foo" alone: 12 results
  -> kind=struct alone: 80 results
  -> "foo" + kind=struct: 0 results  <- narrowed to nothing here
```

**Implementation:** A new function `diagnosticCounts(db, query, filters) -> DiagnosticInfo` in `search.zig` that runs targeted count queries. Called from `main.zig` and `mcp.zig` only when `results.len == 0` and multiple filter dimensions are active.

**MCP response:** Include `diagnostics` object in the JSON when 0 results:
```json
{"total_relevant": 0, "showing": 0, "results": [], "diagnostics": {
  "query_only": 12, "kind_only": 80, "query_and_kind": 0
}}
```

## 7. MCP parity

Add parameters to MCP `search` tool schema:

| Parameter | Type | Description |
|---|---|---|
| `kind` | string | Symbol kind filter (fn, struct, enum, const, var, definition, declaration, etc.) |
| `path` | string | Glob pattern for file path filtering |
| `file` | string | Exact file path filter |
| `lang` | string | Language filter |
| `top` | integer | Max results (default 20) |

Update `tools_list_json` in `mcp.zig`. Wire parameters through to `Settings` and the search call. Include diagnostics in response when applicable.

## Implementation order

Each step: write failing test -> implement -> verify passing -> CLI end-to-end check.

1. **Short canonical forms** (item 1) — foundation, everything builds on this
2. **const/var split** (item 2) — depends on canonical forms
3. **Meta-kinds: definition/declaration** (item 3) — depends on const/var
4. **Empty query browse mode** (item 4) — independent
5. **--path/--file filters** (item 5) — independent
6. **Diagnostic counts** (item 6) — needs filters working
7. **MCP parity** (item 7) — wire everything through last

## Files touched (summary)

| File | Changes |
|---|---|
| `src/indexer.zig` | `inferKindFromSignature` takes language, returns short forms, qualifier stripping |
| `src/filters.zig` | `normalizeSymbolKind` maps to short forms, multi-value expansion for let/declaration/definition |
| `src/search.zig` | Empty query browse path, path filtering, diagnostic counts |
| `src/cli.zig` | Parse `--path`, `--file` flags |
| `src/main.zig` | Wire new filters, diagnostic output |
| `src/mcp.zig` | New tool parameters, diagnostic response, wire filters |
| `src/model.zig` | No changes needed |
| `src/storage.zig` | Test fixture updates only |
| `src/filter.zig` | Already has glob support, may need minor additions |
