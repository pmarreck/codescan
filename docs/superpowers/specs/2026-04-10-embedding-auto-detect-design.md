# Embedding Server Auto-Detect and Graceful Degradation

## Problem

Two related issues:

1. **Bug**: When the embedding server is unreachable, `codescan init` and auto-index paths create an `HttpEmbedder` and pass it to `performFullIndex` unconditionally. The embedder tries to connect and crashes with `ConnectionRefused`, even after printing "Ollama not available, using lexical-only search."

2. **Feature**: `codescan init` requires manual embedding server configuration. Users who don't configure it get a crash on first use. There is no auto-discovery of available embedding servers.

## Design

### NullEmbedder

Add a `NullEmbedder` to `src/embedding.zig` alongside `HttpEmbedder`. It implements the `Embedder` interface but returns empty slices — no HTTP calls, no crashes. When `indexer.indexAll` receives this, it stores symbols without embeddings. Lexical search works immediately; semantic search becomes available after running `codescan update` with a real server.

```zig
pub const NullEmbedder = struct {
    pub fn embedder() Embedder {
        return .{ .ctx = undefined, .embed = embed_fn, .free = free_fn };
    }
    fn embed_fn(_: *anyopaque, _: std.mem.Allocator, inputs: []const []const u8) ![][]f32 {
        _ = inputs;
        return &.{};
    }
    fn free_fn(_: *anyopaque, _: std.mem.Allocator, _: [][]f32) void {}
};
```

### Auto-Detect Function

A new function in `main.zig`:

```
fn detectEmbeddingServer(allocator, http_client, stderr) -> ?DetectedServer

struct DetectedServer {
    url: []const u8,
    dialect: ApiDialect,
    model: ?[]const u8,  // null if server up but model not installed
}
```

Probe order (sequential, stop on first hit):
1. Ollama at `http://localhost:11434` — GET `/api/tags`, check for `bge-large`
2. oMLX at `http://localhost:8000` — GET `/v1/models` (OpenAI-compatible), check for any model

Returns `null` if neither responds.

### `codescan init` Flow

1. Create `.codescan/` dir, write default weights
2. Run `detectEmbeddingServer`
3. **Server found with model**: write detected settings to `config.ini`, print "Detected {dialect} on {url} with model '{model}'. Saved to .codescan/config.ini.", index with `HttpEmbedder`
4. **Server found, model missing**: write server settings to `config.ini`, print "Found {dialect} on {url} but model 'bge-large' not installed. Run `ollama pull bge-large` then `codescan index`.", prompt "Index in lexical-only mode? [Y/n]"
5. **No server found**: print "No embedding server detected.", prompt "Index in lexical-only mode? (Semantic search available later via `codescan setup-model`). [Y/n]"
6. User says yes: index with `NullEmbedder`
7. User says no: exit with setup instructions

Non-TTY mode (piped stdin): default to "yes" so scripted usage doesn't hang.

### `codescan index` Changes

1. Add `--lexical-only` CLI flag to `cli.zig`
2. If `--lexical-only` set: skip server check, use `NullEmbedder`, index
3. If not set: try `ensureModelAvailableOrExit`
4. If server unreachable: prompt "Embedding server unreachable. Index lexical-only? [Y/n]"
5. User says yes: `NullEmbedder`, index
6. User says no: exit
7. Non-TTY without `--lexical-only`: exit (explicit flag required for scripts)

The `update` command gets the same treatment.

### Auto-Index Path (Bug Fix)

Current code (lines 560-588 in `main.zig`): `tryInitOllama` returns false, sets `effective_search_mode = .lexical`, but still creates `HttpEmbedder` and passes to `performFullIndex` which crashes.

Fix:
1. Replace `tryInitOllama` with `detectEmbeddingServer`
2. If detected with model: `HttpEmbedder`, index with embeddings
3. If not detected or no model: `NullEmbedder`, set `effective_search_mode = .lexical`, index lexical-only
4. No prompt in this path (user ran a search, not an explicit index). Print note to stderr: "No embedding server found. Using lexical-only search. Run `codescan setup-model` for semantic search."

### Config Writing

When auto-detect finds a server, write discovered values into `.codescan/config.ini`:

For Ollama:
```ini
embedding_url = http://localhost:11434
embedding_api = ollama
embedding_model = bge-large
```

For oMLX:
```ini
embedding_url = http://localhost:8000
embedding_api = openai
embedding_model = <detected model name>
```

- Fresh `init`: fill in detected values in the config template instead of commented-out defaults
- Existing `config.ini`: update only embedding keys, preserve everything else
- Lexical-only chosen: write `search_mode = lexical`

## Testing

- Unit test for `NullEmbedder`: returns empty slices, `free` is safe to call
- Unit test for `detectEmbeddingServer` with mock transport: Ollama-responds, oMLX-responds, neither-responds, server-up-but-no-model
- Integration/CLI test: `codescan index --lexical-only` succeeds without any embedding server
- Integration/CLI test: `codescan init` with no server, piped stdin defaults to lexical-only
- Regression: auto-index path no longer crashes when embedding server is unreachable

## Files Modified

- `src/embedding.zig` — add `NullEmbedder`
- `src/main.zig` — add `detectEmbeddingServer`, `DetectedServer`, `promptYesNo`; modify `init` command, `index` command, `update` command, auto-index path; refactor or remove `tryInitOllama`
- `src/cli.zig` — add `--lexical-only` flag
- `src/config.zig` — add config-writing helpers for detected values
