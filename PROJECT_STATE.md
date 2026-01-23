# PROJECT_STATE

## What this repo is
`codescan` is a Zig CLI + HTTP server for semantic code search. It indexes function-like symbols via language plugins, stores embeddings in sqlite-vec, and supports vector/lexical/hybrid search. Defaults target Ollama `bge-large` on `http://localhost:11434`.

## Build + test
- Build: `nix develop -c zig build`
- Unit tests: `./test`

## Run (CLI)
- Index (creates `.codescan/index.sqlite3` under the root):
  - `./zig-out/bin/codescan index --root <path>`
- Update (full reindex for now):
  - `./zig-out/bin/codescan update --root <path>`
- Search:
  - `./zig-out/bin/codescan search "<query>" --root <path>`
  - Optional knobs: `--mode <vector|lexical|hybrid>`, `--weight-vector`, `--weight-lexical`, `--top`
- If `--root` is omitted, codescan searches upward from the current directory for a `.codescan/` directory and uses that root (else current dir).

## Run (HTTP)
- `./zig-out/bin/codescan serve --root <path> --http-host 127.0.0.1 --http-port 8123`
- Endpoints: `/health`, `/index`, `/search` (see `src/server.zig` for request shape)

## Config (.codescan/config)
- Load path: `<root>/.codescan/config`
- Keys: `output`, `top`, `root`, `db`, `ollama_url`, `ollama_model`, `embedding_dim`, `batch_size`,
  `max_file_size` (default 2097152), `search_mode`, `weight_vector`, `weight_lexical`, `min_score`, `http_host`, `http_port`.
- Ignore globs:
  - Global: `ignore=**/.git/**, **/.codescan/**`
  - Per-language: `ignore.zig=**/zig-out/**,**/.zig-cache/**`
- Glob semantics: match against repo-relative paths unless the pattern begins with `/` (root-anchored).
- Plugin defaults provide language-specific ignore globs; config adds more (no removal yet).

## Plugin architecture
- Registry in `src/plugin.zig` selects extractors by file extension.
- Extractors:
  - Zig: `src/extract_zig.zig` (AST)
  - Elixir: `src/extract_elixir.zig`
  - C: `src/extract_c.zig` (tree-sitter)
  - TypeScript: `src/extract_typescript.zig` (tree-sitter)
  - Rust: `src/extract_rust.zig` (tree-sitter)
  - Lean: `src/extract_lean.zig` (tree-sitter)
  - Idris2: `src/extract_idris.zig` (line-based fallback)
  - Nix: `src/extract_nix.zig` (tree-sitter)
  - Nim: `src/extract_nim.zig` (tree-sitter)
  - Bash: `src/extract_bash.zig` (tree-sitter)
  - Lua: `src/extract_lua.zig` (tree-sitter)
  - Haskell: `src/extract_haskell.zig` (tree-sitter)
- Plugin defaults live in `src/plugins/<lang>/mod.zig`.

## Dependencies + build notes
- sqlite-vec fork: `pmarreck/sqlite-vec` is used via `build.zig.zon` and statically linked.
  - Static init in `src/storage.zig` calls `sqlite3_vec_init` (no runtime extension loading).
- SQLite amalgamation path is provided via `SQLITE_VEC_SQLITE_AMALGAMATION_DIR` (set in `flake.nix`).
- tree-sitter runtime + tree-sitter-c grammar are vendored under `deps/` and built as static libs.
- tree-sitter grammars for new languages are vendored under `deps/` (see CODE_MINIMAP). `deps/tree-sitter-nim/src/scanner.c` includes a null-buffer guard for Zig's runtime checks.
- PCRE2 is required for glob matching and is built as a Zig dependency (`qaptoR-support/pcre2`).

## Known behaviors
- Files larger than `max_file_size` are skipped during indexing (no hard error).
- A warning is emitted when a file exceeds `max_file_size / 4`.
- Default DB location is `.codescan/index.sqlite3` under the target root.
- `min_score` filters low-scoring results after ranking (default `0.0`).
- `--comments` / `--verbose` shows doc comments in human output (hidden by default).
- `NO_COLOR=1` disables ANSI colors in human output.

## Integration tests
- `test-integration` runs end-to-end indexing/search against pinned fixture repos.
- Fixture repos live in `.codescan-fixtures/` (gitignored) with pins in `fixtures/manifest.toml`.
- Run with: `nix develop -c ./test-integration` (requires Ollama + model).

## CI / Releases
- GitHub Actions workflow: `.github/workflows/build.yml`
- Builds ReleaseFast artifacts for macOS arm64, Linux x86_64 (musl), Windows x86_64.
- Tag pushes (`v*`) create a GitHub Release with attached artifacts.
- CI helpers: `scripts/ci-setup-nix`, `scripts/ci-build`.
- Local CI runner: `scripts/ci-local` (uses `act`, Linux-only).
