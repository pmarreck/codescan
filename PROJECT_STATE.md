# PROJECT_STATE

## What this repo is
`codescan` is a Zig CLI + HTTP server for semantic code search. It indexes function-like symbols via language plugins, stores embeddings in sqlite-vec, and supports vector/lexical/hybrid search. Defaults target Ollama `bge-large` on `http://localhost:11434`.

## Build + test
- Build: `nix develop -c zig build`
- Unit tests: `./test`

## Run (CLI)
- Index (creates `.codescan/index.sqlite3` under the root):
  - `nix develop -c ./zig-out/bin/codescan index --root <path>`
- Update (full reindex for now):
  - `nix develop -c ./zig-out/bin/codescan update --root <path>`
- Search:
  - `nix develop -c ./zig-out/bin/codescan search "<query>" --root <path>`
  - Optional knobs: `--mode <vector|lexical|hybrid>`, `--weight-vector`, `--weight-lexical`, `--top`

## Run (HTTP)
- `nix develop -c ./zig-out/bin/codescan serve --root <path> --http-host 127.0.0.1 --http-port 8123`
- Endpoints: `/health`, `/index`, `/search` (see `src/server.zig` for request shape)

## Config (.codescan/config)
- Load path: `<root>/.codescan/config`
- Keys: `output`, `top`, `root`, `db`, `ollama_url`, `ollama_model`, `embedding_dim`, `batch_size`,
  `max_file_size`, `search_mode`, `weight_vector`, `weight_lexical`, `http_host`, `http_port`.
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
- Plugin defaults live in `src/plugins/<lang>/mod.zig`.

## Dependencies + build notes
- sqlite-vec fork: `pmarreck/sqlite-vec` is used via `build.zig.zon` and statically linked.
  - Static init in `src/storage.zig` calls `sqlite3_vec_init` (no runtime extension loading).
- SQLite amalgamation path is provided via `SQLITE_VEC_SQLITE_AMALGAMATION_DIR` (set in `flake.nix`).
- tree-sitter runtime + tree-sitter-c grammar are vendored under `deps/` and built as static libs.
- PCRE2 is required for glob matching; `flake.nix` sets `C_INCLUDE_PATH` and `LIBRARY_PATH`.

## Known behaviors
- Files larger than `max_file_size` are skipped during indexing (no hard error).
- Default DB location is `.codescan/index.sqlite3` under the target root.
