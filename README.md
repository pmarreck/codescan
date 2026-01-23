# codescan

Semantic code search for local repositories.

- Zig CLI + HTTP API
- Ollama embeddings (default: `bge-large`)
- sqlite-vec vector storage
- Hybrid search (vector + lexical)
- Language plugins (Zig, Elixir, C, TypeScript, Rust, Lean, Idris, Nix, Nim, Bash, Lua via tree-sitter/best-effort)

## Build

```bash
nix develop -c zig build -Doptimize=ReleaseFast
```

## Test

```bash
./test
```

## Integration test

```bash
# requires Ollama running with bge-large pulled
nix develop -c ./test-integration
```

## CI (local, Linux only)

```bash
# requires act (https://github.com/nektos/act)
./scripts/ci-local
```

## Run (CLI)

```bash
# ReleaseFast builds are self-contained; no `nix develop` prefix needed to run.
# index
./zig-out/bin/codescan index --root <path>

# update (full reindex)
./zig-out/bin/codescan update --root <path>

# search
./zig-out/bin/codescan search "hash functions" --root <path> --min-score 0.2
# show doc comments in human output
./zig-out/bin/codescan search "hash functions" --root <path> --comments
```

If `--root` is omitted, `codescan` searches upward from the current directory for a `.codescan/`
directory and uses that as the root (otherwise it falls back to the current directory).

Human output uses ANSI colors by default; set `NO_COLOR=1` to disable.

## Run (HTTP)

```bash
./zig-out/bin/codescan serve --root <path> --http-host 127.0.0.1 --http-port 8123
```

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

# ignores
ignore=**/.git/**, **/.codescan/**
ignore.zig=**/.zig-cache/**,**/zig-out/**
```

## Notes

- SQLite vector extension is statically linked (no runtime extension loading).
- On macOS, fully static userland binaries are not supported by the OS; `libSystem` remains dynamic.

## License

MIT. See `LICENSE`.
