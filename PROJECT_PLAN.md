# Project Plan

## Objective
Build `codescan`: a Zig CLI for semantic code search using Ollama embeddings (bge-large) and sqlite-vec, with a plugin architecture covering code + docs (Markdown/text/log) and multiple languages.

## Milestones
- M1: CLI scaffolding + config + tests
- M2: Storage layer + embeddings client
- M3: Indexing pipeline
- M4: Search pipeline + output formatting + hybrid weight knobs + FTS lexical search
- M5: Zig + Elixir + C plugins (tree-sitter runtime + grammar)
- M6: Docs + stability pass
