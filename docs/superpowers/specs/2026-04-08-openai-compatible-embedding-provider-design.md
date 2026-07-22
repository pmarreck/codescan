# OpenAI-Compatible Embedding Provider Support

**Date:** 2026-04-08
**Status:** Approved

## Motivation

codescan currently only talks to Ollama for embeddings (`/api/embed`). OpenAI-compatible embedding servers (oMLX Server, LiteLLM, vLLM, LocalAI) expose `/v1/embeddings` with better performance on Apple Silicon. Adding support lets codescan work with any of these servers.

## Architecture

### Module Rename

Rename `src/ollama.zig` to `src/embedding_http.zig`. Update all import sites (~6 files: `main.zig`, `mcp.zig`, `indexer.zig`, `server.zig`, `embedding.zig`, and any others referencing `ollama.zig`).

### ApiDialect Enum

```zig
pub const ApiDialect = enum {
    ollama,
    openai,
};
```

### Dialect Branching Points

Four functions gain a `dialect` parameter:

1. **`buildEmbedUrl(allocator, base_url, dialect)`**
   - `.ollama` → `{base}/api/embed`
   - `.openai` → `{base}/v1/embeddings`

2. **`buildEmbedRequest(allocator, model, inputs, keep_alive, dialect)`**
   - `.ollama` → `{"model":..., "input":..., "keep_alive":...}`
   - `.openai` → `{"model":..., "input":...}` (no `keep_alive`)

3. **`parseEmbeddings(allocator, body, dialect)`**
   - `.ollama` → parse `{"embeddings": [[...]]}`
   - `.openai` → parse `{"data": [{"embedding": [...], "index": N}]}`, sort by index

4. **`embed(allocator, transport, base_url, model, inputs, keep_alive, dialect, api_key)`**
   - `.openai` → adds `Authorization: Bearer <key>` header
   - `.ollama` → no auth header (same as today)

### ensureModelAvailable

Gains a `dialect` parameter. For `.openai`, returns immediately (no-op) — OpenAI-compatible servers don't expose `/api/tags` or `/api/ps`.

### Config Changes

**New fields in `Config` struct:**
- `embedding_api: ?[]const u8` — `"ollama"` (default) or `"openai"`
- `embedding_api_key: ?[]const u8` — Bearer token for OpenAI-compatible servers

**Renamed fields (with aliases):**
- `ollama_url` → `embedding_url` (config parser accepts both `ollama_url` and `embedding_url`)
- `ollama_model` → `embedding_model` (config parser accepts both `ollama_model` and `embedding_model`)

**Example `.codescan/config` for oMLX:**
```ini
embedding_api=openai
embedding_url=http://localhost:8000
embedding_model=mlx-community/bge-m3-mlx-fp16
embedding_api_key=${CODESCAN_EMBEDDING_SERVER_API_KEY}
```

Never commit a literal provider credential. Resolve it from the environment at runtime.

### Embedder Layer

Rename `OllamaEmbedder` → `HttpEmbedder` in `embedding.zig`. Add fields:
- `dialect: embedding_http.ApiDialect`
- `api_key: ?[]const u8 = null`

The `Embedder` vtable interface is unchanged. Call sites construct `HttpEmbedder` with the appropriate dialect/key from config.

## Error Handling

- **401 from OpenAI endpoint** → `error.Unauthorized` — call sites print "Invalid API key" hint
- **404 from OpenAI endpoint** → `error.ModelNotFound` — hint at wrong model name
- **Missing `embedding_api_key` when dialect is `.openai`** — validate at startup, fail early with clear message
- **`ensureModelAvailable` for `.openai`** — no-op, returns immediately

## Testing

### Unit tests in `embedding_http.zig`

1. `buildEmbedUrl` returns correct path for each dialect
2. `buildEmbedRequest` includes `keep_alive` for ollama, omits for openai
3. `parseEmbeddings` parses both response formats to identical `[][]f32`
4. Mock transport asserts `Authorization: Bearer` header present for openai, absent for ollama
5. `ensureModelAvailable` returns immediately for openai (mock errors if `/api/tags` hit)
6. 401 response maps to `error.Unauthorized`

### Config tests in `config.zig`

7. New keys parse: `embedding_api`, `embedding_url`, `embedding_model`, `embedding_api_key`
8. Alias backward compat: `ollama_url` / `ollama_model` populate `embedding_url` / `embedding_model`
9. Invalid dialect rejected: `embedding_api=banana` → error

### Existing tests

All existing `ollama.zig` tests carry over with import rename. They implicitly test the `.ollama` dialect since that's the default.

## Scope

**In scope:**
- Module rename `ollama.zig` → `embedding_http.zig`
- `ApiDialect` enum with dialect branching
- Config: `embedding_api`, `embedding_url`, `embedding_model`, `embedding_api_key` with `ollama_*` aliases
- `OllamaEmbedder` → `HttpEmbedder` rename with new fields
- ~10 unit tests for both dialects
- Error mapping for 401/404

**Out of scope (follow-ups):**
- Default model change to `jina-code-embeddings-1.5b`
- `codescan setup-model` helper command
- CLI `--embedding-api` / `--embedding-api-key` flag overrides
- Integration tests requiring a live OpenAI-compatible server
