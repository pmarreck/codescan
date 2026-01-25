# Project Overview

`codescan` is a Zig CLI + HTTP server that indexes code and docs using embeddings (Ollama) and stores them in sqlite-vec for semantic search across a repo. It provides language plugins to extract symbols and comments, plus doc/text/log plugins for non-code content.

## Goals
- Fast, local semantic search over a repo (CLI + HTTP API parity).
- Indexing that can be recreated or updated safely (full reindex on update).
- Language-aware symbol extraction via plugins (AST when possible).
- Human-friendly output with machine-friendly JSON option.

## Key Components
- CLI (`src/main.zig`, `src/cli.zig`) for index/update/search/config/serve.
- Plugins (`src/plugin.zig`, `src/plugins/*`) for language-specific extraction.
- Storage (`src/storage.zig`) for sqlite + sqlite-vec schema and queries.
- Embedding (`src/ollama.zig`, `src/embedding.zig`) for Ollama model access.

## Terminology
- **Type**: high-level content kind (`code`, `doc`, `text`, `log`).
- **Language**: plugin language id (e.g., `zig`, `elixir`, `c`).
- **Extension**: file suffix filter (e.g., `zig`, `md`).
- **Primary language**: most common code extension in the repo; used as default search scope.
- **Docs**: markdown + README (README with or without extension).
- **Comments**: doc comments extracted by language plugins (searchable via comment-only mode).

## Defaults
- Index/update: `code,doc` types.
- Search: primary language only; `--include-docs` adds markdown/README.
- Model: `bge-large` (configurable via `OLLAMA_MODEL`).
- Index location: `.codescan/index.sqlite3` under repo root.
