# Plan

- [x] Define CLI contract (subcommands, flags, output formats)
- [x] Establish project scaffolding (flake.nix, build.zig, ./test)
- [x] Implement config loading (repo-local .codescan/config)
- [x] Define storage schema (sqlite + sqlite-vec) and migrations
- [x] Build embedding pipeline (Ollama HTTP client, batching)
- [ ] Implement indexing flow (scan -> extract -> embed -> store)
- [ ] Implement search flow (query embed -> vector search -> format)
- [ ] Define plugin interface + registry
- [ ] Implement Zig extractor (function spans + comments)
- [ ] Implement Elixir extractor (function spans + comments)
- [ ] Add JSON output + human output formatting
- [ ] Add tests for edge cases and filters; keep tests fast/deterministic
- [ ] Update documentation (CODE_MINIMAP.md, PROJECT_PLAN.md)
