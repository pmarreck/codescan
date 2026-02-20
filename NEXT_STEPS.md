# Next Steps

## Completed This Session

### Search Relevance Improvements (from inbox/2026-02-19-search-relevance-recommendations.md)
All 7 items complete:
1. P0: Hybrid scoring attribution bug — fixed (1e999 AS distance sentinel)
2. P0: MCP search filter parity — fixed (buildSearchFilters in MCP handler)
3. P1: Reciprocal Rank Fusion — implemented (--fusion rrf --rrf-k 60)
4. P1: Lexical token coverage gating — implemented (bm25_norm * coverage)
5. P1: FTS query modes — implemented (--fts-mode broad/balanced/strict)
6. P2: LIKE fallback ordering — implemented (exact > prefix > substring > sig-only)
7. P2: FTS tokenizer tuning — evaluated, kept default unicode61 (tokenchars _ would reduce recall)

### Schema Migration Bug Fix
- **Bug**: `codescan search` against pre-v3 DBs crashed with `SqlPrepareFailed` because search SQL references `symbol_kind`/`symbol_visibility`/`symbol_scope`/`symbol_arity` columns that didn't exist yet
- **Fix**: All DB-opening paths (search, update, watch, serve, mcp-serve) now call `initSchema` unconditionally after opening, ensuring migrations run before any queries
- **Warning**: When `initSchema` detects a schema upgrade, it prints to stderr: `note: Database schema upgraded. A full re-index is strongly recommended: codescan index`

### Schema Migration Refactor (DONE)
Refactored `initSchema` in `src/storage.zig` from one monolithic function into named migration steps:
- `createBaseTables(allocator, db, schema)` — creates all tables at current version (idempotent, uses IF NOT EXISTS)
- `migrateV2ToV3(allocator, db)` — adds symbol_kind, symbol_visibility, symbol_scope, symbol_arity columns
- `setMetaVersion(allocator, db, schema)` — stamps schema_version and embedding_dim in meta table
- `initSchema` orchestrates: detect version → create tables → run migrations → stamp version → init FTS

Future migrations slot in with pattern:
```zig
if (effective_version < 4) { try migrateV3ToV4(allocator, db); did_schema_upgrade = true; }
```

Tests added:
- `migrateV2ToV3` directly (columns added to existing table)
- `did_schema_upgrade` reported for v2 DB
- No upgrade reported for fresh DB
- No upgrade reported for current-version DB

### Symbols/Find-Symbol Merge
Already complete from prior session. `find-symbol` is an alias for `symbols`. Multi-file support, optional pattern, CWD default scope all working.

## Remaining Work

### From PLAN.md (unchecked items)
- [ ] Add tests for edge cases and filters; keep tests fast/deterministic
- [ ] `codescan symbols --depth N` — limit nesting depth in output
- [ ] CamelCase/snake_case normalization in lexical search
- [ ] Phase 7: LLM-generated code comments (`codescan add-relevant-comments`)

### Potential Improvements
- Named migration functions for tests: expose `createBaseTables` and `migrateV2ToV3` as `pub` so search.zig tests (and future integration tests) can call them directly to set up v2 DBs without duplicating raw SQL
- Consider adding `--reindex` flag that auto-triggers full reindex after schema upgrade instead of just warning
