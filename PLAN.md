# Plan

- [x] Add command-specific CLI help topics (`codescan help <command>`, `<command> --help`) with focused usage text for search/index/update/config (completed 2026-02-21 EST)
- [x] Simplify main `--help` to 25-line overview; add 18 per-command help topics (symbols, replace-symbol, insert-*, replace-lines, insert-at, replace-content, references, rename, watch, serve, mcp-serve, status, clean, init) plus concept topics (hashlines, name-paths, languages, lsp) (completed 2026-02-22 EST)
- [x] Add unified search scope flag (`--scope code|docs|comments|all`) while preserving existing docs/comments flags and CLI precedence rules (completed 2026-02-21 EST)
- [x] Add stdin JSON request envelope support (stateless CLI args synthesis + JSON output path) and black-box CLI coverage (completed 2026-02-21 EST)
- [x] Investigate `zig build test` runtime/timeout behavior in `tests/unit/test-unit`; replace with aggregated `zig build test-unit` to avoid multi-binary test compile blowup (completed 2026-02-22 EST)
- [x] Fix embedding-mismatch metadata clobber in `initSchema` (do not overwrite stored embedding dim/model when mismatch is detected on populated index) and add regression test (completed 2026-02-21 EST)
- [x] Align `mk_test_db` default embedding dimension with CLI default (1024) so CLI/HTTP black-box tests use stable defaults (completed 2026-02-21 EST)
- [x] Complete schema-v3 metadata migration path: add nullable `symbol_kind`/`symbol_visibility`/`symbol_scope`/`symbol_arity` columns with backward-compatible auto-migration from schema v2, and add regression tests (completed 2026-02-19 17:24 EST)
- [x] Add `.codescan/weights.toml` language-specific search weighting (default + per-language sections) with CLI/server/MCP wiring and explicit-request override precedence (completed 2026-02-19 16:54 EST)
- [x] Populate symbol metadata during indexing (inferred kind/visibility/scope/arity when extractors omit fields) and add regression tests (completed 2026-02-20 EST)
- [x] Add per-language metadata weighting (`weight_symbol_kind`/`weight_symbol_visibility`/`weight_symbol_scope`/`weight_symbol_arity`) in `weights.toml`, apply in ranking, and wire through CLI/HTTP/MCP search paths (completed 2026-02-20 EST)
- [x] Stabilize intent-aware hybrid ranking (typed boosts + conceptual cue handling + local-binding regression recovery) and re-run full `./test` (completed 2026-02-19 16:22 EST)
- [x] Lower default search score dropoff threshold from 0.65 to 0.3 (completed 2026-02-19 15:10 EST)
- [x] Respect `.gitignore` during indexing by using git file allowlist semantics when scanning repo roots (completed 2026-02-19 15:10 EST)
- [x] Always ignore `.git` and `.jj` directories during scan/index traversal (completed 2026-02-19 15:10 EST)
- [x] Fix hybrid attribution bug so lexical-only rows receive zero vector contribution (completed 2026-02-19 14:56 EST)
- [x] Add regression test for hybrid lexical-only vector-credit bug (completed 2026-02-19 14:56 EST)
- [x] Apply CLI/HTTP-equivalent search filters in MCP search path (completed 2026-02-19 14:56 EST)
- [x] Add natural-language relevance heuristics to demote local/generic symbols and reduce duplicate crowding (completed 2026-02-19 14:56 EST)
- [x] Add regression tests for local/generic demotion and duplicate-signature diversity behavior (completed 2026-02-19 14:56 EST)
- [x] Re-run `./test`, then update CODE_MINIMAP with relevance work summary (completed 2026-02-19 14:56 EST)

- [x] Define CLI contract (subcommands, flags, output formats)
- [x] Establish project scaffolding (flake.nix, build.zig, ./test)
- [x] Implement config loading (repo-local .codescan/config)
- [x] Define storage schema (sqlite + sqlite-vec) and migrations
- [x] Build embedding pipeline (Ollama HTTP client, batching)
- [x] Implement indexing flow (scan -> extract -> embed -> store)
- [x] Implement search flow (query embed -> hybrid ranking -> format)
- [x] Define plugin interface + registry
- [x] Implement Zig extractor (function spans + comments)
- [x] Implement Elixir extractor (function spans + comments)
- [x] Add HTTP server + endpoints (index/update/search/health)
- [x] Add JSON output + human output formatting
- [x] Wire main CLI (config merge, commands, .codescan setup)
- [x] Add hybrid weight knobs (CLI/config/HTTP) + tests
- [x] Normalize hybrid weights automatically
- [x] Add FTS5 lexical search with fallback to LIKE
- [x] Index bash/lua shebang scripts without extension (2026-01-25 EST)
- [x] Reorganize test scripts under ./tests (2026-01-25 EST)
- [x] Prefer static link for pcre2 dependency
- [x] Add plugin-specific ignore globs with PCRE2-backed matcher
- [x] Support ignore config overrides (global + per-language) in .codescan/config
- [x] Replace sqlite-vec runtime extension with static init
- [x] Add sqlite-vec git dependency (build.zig.zon)
- [x] Fetch sqlite amalgamation via flake for sqlite-vec build
- [x] Evaluate/tune weights on example repo queries
- [x] Add C plugin (tree-sitter runtime + grammar, extractor, registry wiring)
- [x] Skip over max_file_size files during indexing (no hard error)
- [x] Add C plugin default ignores for Zig build caches
- [x] Ensure pcre2 headers/libs are available via flake env
- [x] Update documentation (CODE_MINIMAP.md, PROJECT_PLAN.md, PROJECT_STATE.md)
- [x] Add min_score search threshold (CLI/config/HTTP) + tests
- [x] Add integration test suite across Zig/Elixir/C fixture repos
- [x] Add basic HTTP server /health test
- [x] Update runtime CLI examples to avoid nix develop prefix
- [x] Default root to nearest .codescan ancestor when --root omitted
- [x] Verify default root/db path behavior when running from subdirectory
- [x] Add new language plugins (TypeScript, Rust, Lean4, Idris2, Nix, Nim, Bash, LuaJIT, Haskell)
- [x] Vendor or fetch tree-sitter grammars for new languages (best-effort AST)
- [x] Improve human output formatting (alignment + colors) and doc-comment gating (--verbose/--comments)
- [x] Add markdown/text/log plugins with semantic chunking
- [x] Add --ext/--type/--lang filters and --include-docs default behavior
- [x] Determine primary language by file counts and use for default search
- [x] Add comment-only embeddings + `--comments`/`--only-comments` search mode
- [x] Add `--only-docs` synonym + config keys for docs/comments filters
- [x] Ensure HTTP API parity for docs/comments/ext/type/lang filters
- [x] Add black-box CLI + HTTP test scripts with mk_test_db fixture
- [x] Add OLLAMA_MODEL env override + model-availability check with helpful error
- [x] Truncate embedding inputs (~1600 bytes) using sentence/line-aware boundaries
- [x] Recreate DB on reindex (delete file before init)
- [x] Add DEBUG-index logging + built-in ignore globs for common dirs
- [x] Add config show/edit commands
- [x] Add include_node_modules opt-in for indexing
- [x] Show TTY progress for index/update
- [ ] Add tests for edge cases and filters; keep tests fast/deterministic

## Semantic Editing (see SEMANTIC_EDITING_PLAN.md for full details)

### Phase 1: Tree-sitter Read-Only
- [x] `codescan symbols [pattern] [--file ...]` — unified symbol listing/search (multi-file, optional pattern)
- [x] Merged `find-symbol` into `symbols` (`find-symbol` kept as CLI/HTTP alias)
- [x] `query` added as alias for `search` (CLI, HTTP, MCP)
- [x] Hashline output format (3-char base-36 per-symbol chain hashes on code lines)
- [x] Name path resolution from tree-sitter AST hierarchy

### Phase 2: Tree-sitter Editing
- [x] `codescan replace-symbol <name_path> --file <path>` — byte-precise symbol body replacement
- [x] `codescan insert-after <name_path> --file <path>` — insert code after named symbol
- [x] `codescan insert-before <name_path> --file <path>` — insert code before named symbol
- [x] `codescan replace-lines --from <line:hash> --to <line:hash>` — hashline-anchored edits
- [x] `codescan insert-at <line:hash> --file <path>` — hashline-anchored insertion
- [x] Stdin body input for all editing commands

### Phase 3: Optional LSP Integration
- [x] `codescan references <name_path> --file <path>` — cross-file reference lookup
- [x] `codescan rename <name_path> --file <path> --to <new_name>` — cross-file rename
- [x] Auto-detect language and lazy-start appropriate LSP server

### Phase 4: Background Auto-Indexing
- [x] File watcher (kqueue/FSEvents) for incremental reindex on changes

### Phase 4b: MCP Server
- [x] `codescan mcp-serve` — JSON-RPC 2.0 stdio MCP server exposing all tools
- [x] String + integer JSON-RPC ID support (required by Claude Code)
- [x] Single-line JSON responses (newline-delimited protocol compliance)
- [x] Wire `codescan_search` and `codescan_index` through MCP (with auto-index)
- [x] Wire `codescan_config` through MCP (returns live settings as JSON)
- [x] MCP protocol compliance test suite (string IDs, single-line JSON, full handshake)
- [x] Project `.mcp.json` for Claude Code auto-discovery

### Phase 5: Enhancements
- [ ] `codescan symbols --depth N` — limit nesting depth in output (e.g. struct methods without reading bodies)
- [ ] CamelCase/snake_case normalization in lexical search (so `nameRelevance` matches `name_relevance`)
- [ ] Refactor `io_singleton.zig` to thread `std.Io` explicitly through callers per the Zig 0.16 migration doc, instead of a process-global mutable singleton (flagged 2026-05-31 by parent-dir LLM session — "pragmatic shortcut" framing is a Peter-flagged red flag). Hazards: daemon/background paths can hit stale Io; `@panic` on startup-order regressions; `getOrInit()` hides Io-init bugs in tests. At minimum, drop the "acceptable for a CLI binary" justification language from the module doc comment if the refactor is deferred.
- [ ] Fix silent test/prod Io divergence in `io_singleton.getOrInit()` — currently falls back to `std.Io.Threaded.init_single_threaded` (allocator=.failing, concurrent_limit=.nothing), so HTTP/connect paths in tests get `error.ConcurrencyUnavailable` while prod runs real threaded Io with parallel `connectMany` (functional Happy Eyeballs). Tried 2026-05-31: swapping to `Io.Threaded.init(page_allocator, .{})` panics worker threads with `busy_count` underflow because the process-singleton has no clean tear-down across the ~500 call sites — fix is blocked on the broader explicit-threading refactor above. Until then, the regression test in `src/io_singleton.zig` LOCKS the current single-threaded fallback so a future naive change fails loudly. Next viable angles: (a) make `getOrInit()` panic in test contexts that haven't called `set()`, forcing test authors to declare intent (large blast radius), or (b) do the threading refactor first, then swap the fallback.
- [x] Watcher syslog logging + `codescan log` subcommand and MCP tool (completed 2026-04-18 EST) — OS-managed logs so we can diagnose watcher stops after the fact; filterable by project root via `log show` / `journalctl -t codescan`. Spec: `docs/superpowers/specs/2026-04-18-watcher-syslog-logging-design.md`. Plan: `docs/superpowers/plans/2026-04-18-watcher-syslog-logging.md`.
- [x] Env-var expansion in config file values (`$VAR`, `${VAR}`, `${VAR:-default}`, `${VAR-default}`, nested to depth 10) with raw-preservation on save for `embedding_api_key` (completed 2026-04-19 EST) — spec: `docs/superpowers/specs/2026-04-19-config-env-var-expansion-design.md`. Plan: `docs/superpowers/plans/2026-04-19-config-env-var-expansion.md`. Reference impl in docscan `cli/main.c:1344-1509`.
- [x] Auto-reindex after CLI edits (skip re-embedding, daemon catches up on vectors)
- [x] `codescan rename` applies edits by default (`--dry-run` for preview-only)
- [x] Hashlines in `codescan references` output for stale-edit protection
- [x] Auto-detect embedding server (Ollama/oMLX) on init, graceful lexical-only fallback when unavailable, `--lexical-only` flag (completed 2026-04-11 EST)
### Phase 6: New Language Grammars
- [x] Add Clojure tree-sitter grammar + symbol mappings (`.clj`, `.cljs`, `.cljc`, `.edn`) — custom list_lit extraction for defn/def/ns/etc.
- [x] Add Assembly tree-sitter grammar + symbol mappings (`.s`, `.S`, `.asm`) — labels + constants via RubixDev/tree-sitter-asm
- [x] Add LLVM IR indexer plugin (`extract_llvm.zig`) — `.ll` files indexed with function/global extraction

### Go Language Support
- [x] Add Go extractor (`extract_go.zig`) for embedding/indexing pipeline — function_declaration, method_declaration, type_spec with `//` and `/* */` comment extraction
- [x] Add Go plugin module (`plugins/go/mod.zig`) with `.go` extension and `**/vendor/**` ignore
- [x] Register Go plugin in `plugin.zig` defaultRegistry

### Phase 7: LLM-Generated Code Comments
- [ ] `codescan add-relevant-comments <file>` — use local Ollama LLM to generate descriptive comments for symbols lacking them
  - Walks symbols in the file, skips those already having a comment above
  - Generates a concise comment describing the symbol's purpose via a code-understanding LLM (e.g. CodeLlama, DeepSeek-Coder)
  - Inserts the comment into the actual source file (language-appropriate comment syntax)
  - Output is a modified file — developer reviews diff and commits what they like
- [ ] `codescan add-relevant-comments <file> <hashline>` — target a single symbol definition
  - Hashline must be the head of a symbol definition, errors otherwise
  - Generates and inserts a comment for just that symbol
- [ ] Config: `describe.model` — which Ollama model to use for description generation
- [ ] Config: `describe.language` — natural language for comments (default: English)
- [ ] Respect existing comments — if a symbol already has a comment block above it, skip or offer to enhance
- [ ] `--dry-run` flag — print generated comments to stdout without modifying files
- [ ] `--force` flag — regenerate even for symbols that already have comments

### Refactor: Vendored deps → proper dependencies
- [ ] Move tree-sitter grammars from `deps/` to Zig package dependencies (build.zig.zon) or Nix flake inputs
- Currently: 20+ tree-sitter grammars are raw vendored C source in `deps/tree-sitter-*/`
- Problem: patches to vendored code (like the tree-sitter-swift UB fix) are fragile and can be overwritten
- Approach options:
  1. **Zig packages**: Fork each grammar to add `build.zig.zon`, add as `.dependencies` in `build.zig.zon`. Most correct but high maintenance (20+ forks).
  2. **Nix flake inputs**: Add each grammar repo as a flake input, pass source paths to the Zig build. Works for Nix builds, but non-Nix builds still need vendored copies.
  3. **Git submodules**: Pin each grammar to a commit. Standard approach, but submodules are notoriously annoying.
  4. **Hybrid**: Use Nix flake inputs for the Nix build path, keep vendored copies as fallback for non-Nix builds. Apply patches via Nix overlay.
- Recommendation: Option 4 (hybrid) — Nix users get pinned+patched deps automatically, non-Nix users use vendored copies with a `scripts/update-deps.sh` that fetches and patches.
- Also consider: tree-sitter core itself (`deps/tree-sitter/`) should be a proper dependency too.
- Filed upstream: alex-pinkus/tree-sitter-swift#558 (UB fix)
