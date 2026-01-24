# codescan

Semantic code search for local repositories.

- Zig CLI + HTTP API
- Ollama embeddings (default: `bge-large`, override with `OLLAMA_MODEL`)
- sqlite-vec vector storage
- Hybrid search (vector + lexical)
- Language plugins (Zig, Elixir, C, TypeScript, Rust, Lean, Idris, Nix, Nim, Bash, Lua, Haskell via tree-sitter/best-effort)
- Markdown/text/log indexing with semantic chunking

## Build

```bash
nix develop -c zig build -Doptimize=ReleaseFast
```

## Test

```bash
./test
```

## CLI/HTTP tests

```bash
nix develop -c ./test-cli
nix develop -c ./test-http
```

## Integration test

```bash
# requires Ollama running with bge-large pulled (or set OLLAMA_MODEL)
nix develop -c ./test-integration
```

## CI (local, Linux only)

```bash
# requires act (https://github.com/nektos/act)
./scripts/ci-local
```

## Run (CLI)

```bash
# show or edit project config
./zig-out/bin/codescan config
./zig-out/bin/codescan config edit

# ReleaseFast builds are self-contained; no `nix develop` prefix needed to run.
# index
./zig-out/bin/codescan index --root <path>

# update (full reindex)
./zig-out/bin/codescan update --root <path>

# search
./zig-out/bin/codescan search "hash functions" --root <path> --min-score 0.2
# show doc comments in human output
./zig-out/bin/codescan search "hash functions" --root <path> --show-comments
# comment-only search (doc comments only)
./zig-out/bin/codescan search "hash functions" --root <path> --comments
# include markdown/README when using default search scope
./zig-out/bin/codescan search "design doc" --include-docs
# only markdown/README results
./zig-out/bin/codescan search "design doc" --docs
# restrict by extension/type/language
./zig-out/bin/codescan search "checksum" --ext md,zig
./zig-out/bin/codescan search "checksum" --type code,doc
./zig-out/bin/codescan search "checksum" --lang zig

# index node_modules too
./zig-out/bin/codescan index --include-node-modules
```

If `--root` is omitted, `codescan` searches upward from the current directory for a `.codescan/`
directory and uses that as the root (otherwise it falls back to the current directory).

Search defaults to the primary code language by file count unless a filter is supplied.
`--include-docs` adds markdown/README; `--docs`/`--only-docs` restricts results to markdown/README only.
`--comments`/`--only-comments` restricts results to doc comments.
Built-in ignores: `.git/`, `.codescan/`, `.codescan-fixtures/`, `deps/`, `node_modules/`, `.zig-cache/`, `zig-cache/`, `.zig-out/`, `zig-out/` (see PROJECT_STATE for full list).

Human output uses ANSI colors by default; set `NO_COLOR=1` to disable.
Set `DEBUG=1` to emit verbose indexing progress to stderr.

## Run (HTTP)

```bash
./zig-out/bin/codescan serve --root <path> --http-host 127.0.0.1 --http-port 8123
```

Endpoints: `GET /health`, `GET /help`, `POST /index`, `POST /search`.

## Config

Create `<root>/.codescan/config` to override defaults. Example:

```
# output=json|human
output=human

# search tuning
search_mode=hybrid
weight_vector=0.7
weight_lexical=0.3
min_score=0.0
max_file_size=2097152
include_docs=false
docs_only=false
comments_only=false
include_node_modules=false
primary_lang=zig
index_ext=zig,md
index_type=code,doc
search_ext=zig
search_type=code
search_lang=zig

# Ollama model override (CLI flag or OLLAMA_MODEL env var also supported)
ollama_model=bge-large

# ignores
ignore=**/.git/**, **/.codescan/**
ignore.zig=**/.zig-cache/**,**/zig-out/**
```

## Notes

- SQLite vector extension is statically linked (no runtime extension loading).
- On macOS, fully static userland binaries are not supported by the OS; `libSystem` remains dynamic.

## License

MIT. See `LICENSE`.
