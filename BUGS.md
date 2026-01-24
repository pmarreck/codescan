# Bugs

## codescan index --type doc fails with HttpStatus (resolved)

### Repro
1. Ensure Ollama is running and reachable at http://localhost:11434
2. Run:
   `codescan index --type doc --db .codescan/docs.sqlite3`

### Expected
Index builds successfully and doc-only searches return results.

### Actual
Command exits with:
`error: HttpStatus`

### Environment
- Repo: `entropy_shield`
- Date: 2026-01-24
- Ollama: http://localhost:11434 (reachable; `/api/tags` returns 200)
- Model: `bge-large:latest` is installed
- `POST /api/embeddings` with `bge-large:latest` succeeds

### Notes
- Same error occurs when specifying `--ollama-url` and `--ollama-model bge-large:latest`.
- `codescan search --only-docs` returns no results with existing index.

### Resolution
- Truncate embedding inputs to ~1600 bytes with sentence/line-aware boundaries.
- Doc-only indexing now succeeds (reindex required after upgrade).

### Update (2026-01-24)
- Retried after enabling real Ollama server usage in codescan tests.
- `codescan index --type doc --db .codescan/docs.sqlite3` still fails with `error: HttpStatus`.
