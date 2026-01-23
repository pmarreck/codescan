# Plan

- [x] Define CLI contract (subcommands, flags, output formats)
- [x] Establish project scaffolding (flake.nix, build.zig, ./test)
- [x] Implement config loading (repo-local .codescan/config)
- [x] Define storage schema (sqlite + sqlite-vec) and migrations
- [x] Build embedding pipeline (Ollama HTTP client, batching)
- [ ] Implement indexing flow (scan -> extract -> embed -> store)
- [ ] Implement search flow (query embed -> hybrid ranking -> format)
- [x] Define plugin interface + registry
- [x] Implement Zig extractor (function spans + comments)
- [x] Implement Elixir extractor (function spans + comments)
- [ ] Add HTTP server + endpoints (index/update/search/health)
- [ ] Add JSON output + human output formatting
- [ ] Wire main CLI (config merge, commands, .codescan setup)
- [ ] Add tests for edge cases and filters; keep tests fast/deterministic
- [ ] Update documentation (CODE_MINIMAP.md, PROJECT_PLAN.md)
