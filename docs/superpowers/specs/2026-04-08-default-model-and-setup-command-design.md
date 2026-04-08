# Default Model Change + setup-model Command

**Date:** 2026-04-08
**Status:** Approved

## Motivation

codescan defaults to `bge-large` (1024-dim, 512-token context, general-purpose). `jina-code-embeddings-1.5b` is purpose-built for code search: 1536-dim embeddings, 32K token context, trained on nl2code/code2code/QA tasks. Switching the default improves search quality for all users. A `setup-model` command provides clear instructions for procuring the model.

## Changes

### 1. Default Model + Dimension

Change defaults across 4 files:

| Location | Field | Old | New |
|----------|-------|-----|-----|
| `main.zig` Defaults | `embedding_model` | `"bge-large"` | `"jina-code-embeddings-1.5b"` |
| `main.zig` Defaults | `embedding_dim` | `1024` | `1536` |
| `mcp.zig` Settings | `embedding_model` | `"bge-large"` | `"jina-code-embeddings-1.5b"` |
| `mcp.zig` Settings | `embedding_dim` | `1024` | `1536` |
| `cli.zig` Parsed | `embedding_model` | `"bge-large"` | `"jina-code-embeddings-1.5b"` |
| `cli.zig` Parsed | `embedding_dim` | `1024` | `1536` |
| `config.zig` template | comment | `bge-large` | `jina-code-embeddings-1.5b` |

### 2. `codescan setup-model` Command

New CLI action: `setup_model`. No flags. Reads the current config to determine dialect, then prints instructions.

**For Ollama dialect (default):**
```
Recommended model: jina-code-embeddings-1.5b
  1536 dimensions, 32K token context, code-specific training
  License: CC-BY-NC-4.0 (non-commercial)

To install via Ollama, run:

  ollama pull hf.co/jinaai/jina-code-embeddings-1.5b-GGUF:Q8_0

Then reindex your project:

  codescan index --force

Note: If you use a different model, update embedding_model and embedding_dim
in .codescan/config to match. Mismatched dimensions will cause search errors.
```

**For OpenAI dialect:**
```
Recommended model: jina-code-embeddings-1.5b
  1536 dimensions, 32K token context, code-specific training
  License: CC-BY-NC-4.0 (non-commercial)

For oMLX Server, download the MLX model from HuggingFace:

  huggingface-cli download jinaai/jina-code-embeddings-1.5b-mlx

Then configure your oMLX Server to serve it and set in .codescan/config:

  embedding_api=openai
  embedding_url=http://localhost:8000
  embedding_model=jinaai/jina-code-embeddings-1.5b-mlx
  embedding_api_key=<your-omlx-key>

Then reindex your project:

  codescan index --force

Note: If you use a different model, update embedding_model and embedding_dim
in .codescan/config to match. Mismatched dimensions will cause search errors.
```

### 3. README Updates

- Line 9: Update from `bge-large` to `jina-code-embeddings-1.5b` with note about OpenAI-compatible providers
- Line 68: Update integration test comment from `bge-large` to new model name
- Lines 339-340: Update config example from `ollama_model=bge-large` to new config keys
- Add `setup-model` to the commands table
- Add a "Model Setup" section near the Config section explaining the new default, how to run `setup-model`, and mentioning both provider options

### 4. Reindex Detection

Already implemented — `storage.zig` checks `embedding_model` + `embedding_dim` in the `meta` table. Existing users upgrading will see a mismatch warning and need to reindex. No code changes needed.

## Testing

- CLI test: parse `setup-model` / `setup_model` action from args
- Config tests: update assertions for new default values where needed
- Existing tests that hardcode `bge-large` or `1024` as defaults need updating

## Scope

**In scope:**
- Default model/dim change (4 files)
- `setup-model` CLI action + handler
- README updates
- Test updates

**Out of scope:**
- Auto-pulling models
- `--provider` flag on setup-model
- Matryoshka dimension truncation support (future optimization)
