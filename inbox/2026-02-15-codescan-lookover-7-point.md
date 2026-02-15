# codescan look-over (friendly, slightly poking)

You’ve built a lot, quickly. Respect. Now for the gremlins that are still chewing on cables.

## Findings first (ordered by severity)

1. **`references`/`rename` are scoped to the file's parent dir, not repo root**
- `src/main.zig:2012` and `src/main.zig:2165` set `root_uri` from `dirname(abs_path)`.
- Effect: cross-file LSP ops can silently under-scope to one folder tree.
- This directly weakens the “targeted code editing across codebase” goal.

2. **LSP edit coordinates are treated as bytes, not UTF-16 code units**
- LSP positions are read as `character` values in `src/lsp.zig:623`.
- Edits are applied with byte math in `src/main.zig:2331`.
- Effect: rename/reference edit application can corrupt placement in files containing non-ASCII before edit points.

3. **Incremental index change detection can miss real edits**
- mtime is truncated to seconds at `src/indexer.zig:169` and `src/indexer.zig:311`.
- `unchanged` check compares only mtime at `src/indexer.zig:315`.
- Stored file size exists but is not used for unchanged checks (`src/storage.zig:116`, `src/storage.zig:460`).
- Effect: same-second edits (and some equal-mtime scenarios) can be skipped.

4. **Integration suite is currently red (reproducible) and appears brittle on C baseline ranking**
- Fails at `tests/integration/test-integration:278` with `c baseline query missing crc32`.
- Current top results for `"crc32 checksum"` place `crc32_z` around rank 7, not top 5.
- This is a correctness signal for test expectations, ranking behavior, or both.

5. **URI handling is too literal for robust LSP interop**
- `pathToUri` just prefixes `file://` without percent-encoding (`src/lsp.zig:651`).
- `uriToPath` strips prefix without decoding (`src/lsp.zig:660`).
- Effect: spaces/special chars in paths are undefined behavior territory.

## 1) Inconsistent, incomplete, or undefined functionality

- README claims symbol extraction support for Go/Ruby/Erlang/OCaml/Swift (`README.md:9`), but indexing registry doesn’t include those extractors (`src/plugin.zig:105`).
- `PROJECT_STATE` says `update` is full reindex (`PROJECT_STATE.md:18`), but code uses incremental (`src/main.zig:302`, `src/main.zig:319`).
- `PLAN.md` leaves semantic editing/LSP phases unchecked while commands exist and are wired (`PLAN.md:61`, `PLAN.md:75`, `src/main.zig:507`, `src/main.zig:578`, `src/main.zig:586`).

## 2) Inadequate test coverage

- No end-to-end test for multi-file `rename`/`references` scope rooted at project root.
- No tests for UTF-16/Unicode position handling in LSP edits.
- No test proving incremental indexing catches same-second modified files.
- CI only builds artifacts and does not run test suites (`.github/workflows/build.yml:41`).

## 3) Futile test coverage

- `FsWatch wait detects file creation` asserts nothing about the result (`src/fs_watch.zig:371`, `src/fs_watch.zig:397`).
- `replace-lines rejects stale hashlines...` validates the concept but never executes `runReplaceLines` behavior (`src/main.zig:2774`).

## 4) Superfluous or duplicated functionality

- `PatternSet` optimization exists (`src/filter.zig:212`) but scan path still does per-pattern matching loops (`src/scan.zig:265`); optimization is effectively idle in production path.
- `parseMode` is triplicated (`src/cli.zig:610`, `src/server.zig:389`, `src/main.zig:1229`).
- `runReferences` and `runRename` duplicate large setup blocks (symbol locate, server bootstrap, URI plumbing), making bugfix drift likely.

## 5) Suboptimal/inconcise/disorganized code

- `src/main.zig` is a 2900+ line “everything file” (`src/main.zig:1`), mixing CLI routing, search/index orchestration, symbol editing, and LSP application.
- Documentation is fragmented with overlap and drift (`PLAN.md`, `PROJECT_PLAN.md`, `PROJECT_STATE.md`, `SEMANTIC_EDITING_PLAN.md`).

## 6) Complexity and hot-loop estimates

- **Search dedupe is O(R^2)** due to linear `appendUnique` scans (`src/search.zig:96`, `src/search.zig:213`).
- **Ignore matching is O(F*P)** (files × patterns) via looped regex checks (`src/scan.zig:265`), despite a combined-regex strategy existing in `PatternSet`.
- **Lexical rescoring is O(R*T*K)** where `R` results, `T` query tokens, and `K` string scan/split work per token (`src/search.zig:704`).

Potential reductions:
- Replace dedupe with `AutoHashMap(i64, void)` for O(R).
- Use `PatternSet` in `scan` for combined matching path.
- Pre-tokenize/lowercase query once per search and reuse in scoring.

## 7) Files without clearly defined purpose

Not “useless,” but currently ambiguous/overlapping in operational purpose:
- `PLAN.md`, `PROJECT_PLAN.md`, `PROJECT_STATE.md`, `SEMANTIC_EDITING_PLAN.md`.
- They each look authoritative, but disagree in places (especially around update semantics and completed semantic-editing phases).

## Bonus poke: test taxonomy drift

- `tests/unit/test-unit` runs `zig build test` (`tests/unit/test-unit:4`) which includes network/Ollama-bound tests like `doc truncation avoids Ollama context length errors` (`src/indexer.zig:824`).
- Great integration check, not a true deterministic unit test. It’s wearing the wrong badge.

