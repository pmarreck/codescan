# codescan

Semantic code search for local repositories.

- Zig CLI + HTTP API
- Ollama embeddings (default: `bge-large`)
- sqlite-vec vector storage
- Hybrid search (vector + lexical)
- Language plugins (Zig, Elixir, C via tree-sitter)

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

## Run (CLI)

```bash
# index
nix develop -c ./zig-out/bin/codescan index --root <path>

# update (full reindex)
nix develop -c ./zig-out/bin/codescan update --root <path>

# search
nix develop -c ./zig-out/bin/codescan search "hash functions" --root <path> --min-score 0.2
```

## Run (HTTP)

```bash
nix develop -c ./zig-out/bin/codescan serve --root <path> --http-host 127.0.0.1 --http-port 8123
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

# ignores
ignore=**/.git/**, **/.codescan/**
ignore.zig=**/.zig-cache/**,**/zig-out/**
```

## Notes

- SQLite vector extension is statically linked (no runtime extension loading).
- On macOS, fully static userland binaries are not supported by the OS; `libSystem` remains dynamic.

## License

MIT. See `LICENSE`.
