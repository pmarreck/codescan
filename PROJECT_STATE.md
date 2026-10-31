# PROJECT_STATE

## What this repo is
`codescan` is a Zig CLI + HTTP server for semantic code search. It indexes function-like symbols via language plugins, stores embeddings in sqlite-vec, and supports vector/lexical/hybrid search. Defaults target Ollama `bge-large` on `http://localhost:11434` (override model via `OLLAMA_MODEL`).

## Terminology
- **Type**: high-level content kind (`code`, `doc`, `text`, `log`).
- **Language**: plugin language id (e.g., `zig`, `elixir`, `c`).
- **Extension**: file suffix filter (e.g., `zig`, `md`).
- **Primary language**: optional configured search restriction; default searches include all code languages when it is unset.
- **Docs**: markdown + README (README with or without extension).
- **Comments**: doc comments extracted by language plugins (searchable via comment-only mode).

## Build + test
- Build and publish the native release CLI: `./build` (Nix is required).
- Native release/debug products are retained under `.nix-out/<PF>/[<VARIANT>/]<profile>`; legacy command publication remains until the separate verified-publication/PATH migration.
- Build current source and execute the exact native output without publication: `./run ARGS...`.
- Prepare exact Nix artifacts and run the complete available suite: `./test` (includes units, CLI, HTTP, and integration checks; live-provider exclusions are reported explicitly).
- Prepare compiled test prerequisites without publication: `./build --test`.
- Selected suites require the prepared artifact environment supplied by the harness; they do not replace `./test`.
- The host filesystem boundary is qualified on Linux; native Nix checks and macOS release smoke checks are separate evidence, not a claim of full native Windows test execution.
- Dated plans under `docs/superpowers/` are historical records, not current build instructions.

## Run (CLI)
- Config:
  - `./run config` (show)
  - `./run config edit`
- Index (creates `.codescan/index.sqlite3` under the root):
  - `./run index --root <path>`
- Update (incremental; incompatible schema/model settings can require a verified rebuild):
  - `./run update --root <path>`
- Search:
  - `./run search "<query>" --root <path>`
  - Optional knobs: `--mode <vector|lexical|hybrid>`, `--weight-vector`, `--weight-lexical`, `--top`
  - Filters: `--ext <csv>`, `--type <csv>`, `--lang <csv>`, `--include-docs`, `--docs/--only-docs`, `--comments/--only-comments`
  - Output: `--show-comments`/`--verbose` to display doc comments in human output
- If `--root` is omitted, codescan searches upward from the current directory for a `.codescan/` directory and uses that root (else current dir).

## Run (HTTP)
- `./run serve --root <path> --http-host 127.0.0.1 --http-port 8123`
- Endpoints: `/health`, `/help`, `/index`, `/search` (see `src/server.zig` for request shape)

## Config (.codescan/config.ini)
- Canonical path: `<root>/.codescan/config.ini`; the legacy `config` filename remains a fallback.
- Keys: `output`, `top`, `root`, `db`, `ollama_url`, `ollama_model` (or env `OLLAMA_MODEL`), `embedding_dim`, `batch_size`,
  `max_file_size` (default 2097152), `search_mode`, `weight_vector`, `weight_lexical`, `min_score`, `http_host`, `http_port`,
  `index_ext`, `index_type`, `search_ext`, `search_type`, `search_lang`, `primary_lang`, `include_docs`, `docs_only`, `comments_only`,
  `include_node_modules`.
- Optional language-specific search weights:
  - Path: `<root>/.codescan/weights.toml`
  - Sections: `[default]` and canonical language sections (for example `[zig]`, `[elixir]`)
  - Keys per section: `weight_vector`, `weight_lexical`, `weight_symbol_kind`, `weight_symbol_visibility`, `weight_symbol_scope`, `weight_symbol_arity`
  - Precedence: explicit CLI/HTTP request weights > `weights.toml` > `.codescan/config` global weights
- Ignore globs:
  - Global: `ignore=**/.git/**, **/.codescan/**`
  - Per-language: `ignore.zig=**/zig-out/**,**/.zig-cache/**`
- Glob semantics: match against repo-relative paths unless the pattern begins with `/` (root-anchored).
- Plugin defaults provide language-specific ignore globs; config adds more (no removal yet).
- Built-in ignore globs:
  - VCS/metadata: `.git`, `.hg`, `.svn`, `.bzr`, `CVS`
  - Project metadata: `.codescan`, `.codescan-fixtures`, `.idea`, `.vscode`, `.cache`
  - Dependencies: `deps`, `node_modules` (opt-in), `vendor`, `third_party`, `.pnpm-store`, `.yarn`, `.pnp`
  - Build/output: `build`, `dist`, `out`, `target`, `bin`, `obj`, `coverage`, `.build`, `CMakeFiles`
  - JS frameworks: `.next`, `.nuxt`, `.svelte-kit`, `.turbo`, `.parcel-cache`, `.vite`
  - Mobile: `Pods`
  - Language caches: `.zig-cache`, `zig-cache`, `.zig-out`, `zig-out`, `__pycache__`, `.venv`, `venv`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `.tox`, `.nox`, `.stack-work`, `dist-newstyle`, `nimcache`, `result`
  - Misc: `.DS_Store`
  - `include_node_modules=true` or `--include-node-modules` will index `node_modules`.

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
  - Python: `src/extract_python.zig` (pinned tree-sitter-python; functions/classes, decorators, nested names, docstrings, and `.pyi` stubs)
  - Markdown: `src/extract_markdown.zig` (heading-based)
  - Text: `src/extract_text.zig` (paragraph/line/sentence)
  - Log: `src/extract_log.zig` (line-based)
- Plugin defaults live in `src/plugins/<lang>/mod.zig`.

## Dependencies + build notes
- sqlite-vec fork: `pmarreck/sqlite-vec` is used via `build.zig.zon` and statically linked.
  - Static init in `src/storage.zig` calls `sqlite3_vec_init` (no runtime extension loading).
- SQLite amalgamation path is provided via `SQLITE_VEC_SQLITE_AMALGAMATION_DIR` (set in `flake.nix`).
- The tree-sitter runtime and remaining older grammars are vendored under `deps/` and built as static libraries.
- Fourteen grammars, including C, are pinned Nix fetches exposed through `CODESCAN_GRAMMAR_ROOT`. C is pinned at `tree-sitter/tree-sitter-c@7fa1be1b694b6e763686793d97da01f36a0e5c12`, byte-identical to the retired parser/header copies; its unchanged license remains in `deps/tree-sitter-c/LICENSE`. A source-boundary fixture rejects reintroduced legacy C parser inputs. `deps/tree-sitter-nim/src/scanner.c` retains its null-buffer guard for Zig's runtime checks.
- PCRE2 is required for glob matching and is built as a Zig dependency (`qaptoR-support/pcre2`).

## Known behaviors
- Files larger than `max_file_size` are skipped during indexing (no hard error).
- A warning is emitted when a file exceeds `max_file_size / 4`.
- Default DB location is `.codescan/index.sqlite3` under the target root.
- `min_score` filters low-scoring results after ranking (default `0.0`).
- Indexed symbols are enriched with inferred metadata when extractors do not provide it (`symbol_kind`, `symbol_visibility`, `symbol_scope`, `symbol_arity`).
- Interactive index/update shows a compact per-file progress counter on stderr (TTY only).
- Search defaults to all code languages; a configured primary language restricts that default only when explicitly selected in settings.
- `--include-docs` (or `include_docs=true`) adds markdown/README results to the default search.
- `--docs`/`--only-docs` restrict results to markdown/README only.
- `--comments`/`--only-comments` restrict results to doc comments only.
- Index/update defaults to code + docs unless `index_type` is set.
- `--show-comments`/`--verbose` shows doc comments in human output (hidden by default).
- `NO_COLOR=1` disables ANSI colors in human output.
- `DEBUG=1` enables verbose indexing progress logs to stderr.
- Comment-only vector/hybrid search uses the `embeddings_comment` table (reindex if migrating older DBs).
- Embedding inputs are truncated to ~1600 bytes for code/logs and ~1000 bytes for docs/text (sentence/line-aware).

## Integration tests
- `tests/integration/test-integration` runs end-to-end indexing/search against pinned fixture repos.
- Fixture repos live in `.codescan-fixtures/` (gitignored) with pins in `fixtures/manifest.toml`.
- Run with: `nix develop -c ./tests/integration/test-integration` (requires Ollama + model).

## CI / Releases
- GitHub Actions workflow: `.github/workflows/build.yml`
- GitHub Actions builds ReleaseFast artifacts for macOS ARM64 and Linux AMD64/ARM64 (musl); native macOS packaging includes header/about smoke checks.
- Mechatron Prime CI additionally builds the declared Windows AMD64/ARM64 release packages; cross-build success does not establish native Windows execution.
- Tag pushes (`v*`) create a GitHub Release with attached artifacts.
- CI helpers: `scripts/ci-setup-nix`, `scripts/ci-build`.
- Local CI runner: `scripts/ci-local` (uses `act`, Linux-only).
