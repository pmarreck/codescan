# codescan

Semantic code search for local repositories.

- Zig CLI + HTTP API + MCP server
- Ollama embeddings (default: `bge-large`, override with `OLLAMA_MODEL`)
- sqlite-vec vector storage
- Hybrid search (vector + lexical)
- Symbol extraction: Zig, C/C++, TypeScript/JavaScript, Rust, Elixir, Bash, Lua, Nix, Nim, Lean, Idris, Haskell, Go, Ruby, Erlang, OCaml, Swift, LLVM IR
- LSP (references, rename): all of the above plus Clojure, Assembly
- Markdown/text/log indexing with semantic chunking

## Install

### With Nix (recommended)

```bash
# Run directly without installing
nix run github:pmarreck/codescan -- search "your query"

# Install to your profile
nix profile install github:pmarreck/codescan

# For faster downloads, add the garnix binary cache to /etc/nix/nix.conf:
#   extra-substituters = https://cache.garnix.io
#   extra-trusted-public-keys = cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g=
```

### Build from source

```bash
nix develop -c zig build -Doptimize=ReleaseFast
```

## Test

```bash
./test
```

## CLI/HTTP tests

```bash
nix develop -c ./tests/cli/test-cli
nix develop -c ./tests/http/test-http
```

## Integration test

```bash
# requires Ollama running with bge-large pulled (or set OLLAMA_MODEL)
nix develop -c ./tests/integration/test-integration
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
# default verb is search
./zig-out/bin/codescan "hash functions" --root <path>
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

# show index and watcher status
./zig-out/bin/codescan status
./zig-out/bin/codescan status --json
```

If `--root` is omitted, `codescan` searches upward from the current directory for a `.codescan/`
directory and uses that as the root (otherwise it falls back to the current directory).

Search defaults to the primary code language by file count unless a filter is supplied.
Multi-word queries use OR semantics in lexical/hybrid search — results matching any term surface, with BM25 ranking results matching all terms higher.
`--include-docs` adds markdown/README; `--docs`/`--only-docs` restricts results to markdown/README only.
`--comments`/`--only-comments` restricts results to doc comments.
Index/update defaults to code + docs unless `--type`/`index_type` is set.
Built-in ignores: `.git/`, `.codescan/`, `.codescan-fixtures/`, `deps/`, `node_modules/` (opt-in), `.zig-cache/`, `zig-cache/`, `.zig-out/`, `zig-out/` (see PROJECT_STATE for full list).

Human output uses ANSI colors by default; set `NO_COLOR=1` to disable.
Interactive index/update shows a compact per-file progress counter on stderr (TTY only).
Set `DEBUG=1` to emit verbose indexing progress to stderr.

## Run (HTTP)

```bash
./zig-out/bin/codescan serve --root <path> --http-host 127.0.0.1 --http-port 8123
```

Endpoints:

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check |
| `/help` | GET | List all endpoints |
| `/search` | POST | Semantic code search |
| `/index` | POST | Index/reindex repository |
| `/symbols` | POST | List symbols in a file |
| `/find-symbol` | POST | Find symbol by name path |
| `/replace-symbol` | POST | Replace a symbol's body |
| `/insert-after` | POST | Insert code after a symbol |
| `/insert-before` | POST | Insert code before a symbol |
| `/replace-lines` | POST | Replace hashline-validated line range |
| `/insert-at` | POST | Insert after hashline-validated line |
| `/replace-content` | POST | Find/replace text or regex |
| `/references` | POST | Find references via LSP |
| `/rename` | POST | Rename symbol via LSP |
| `/status` | GET | Index and watcher status |

```bash
# examples
curl -s localhost:8123/symbols -d '{"file":"src/main.zig"}'
curl -s localhost:8123/find-symbol -d '{"file":"src/main.zig","pattern":"runSearch","include_body":true}'
curl -s localhost:8123/replace-content -d '{"file":"src/lib.zig","needle":"old","body":"new","all":true}'
```

## Run (MCP)

codescan includes an [MCP](https://modelcontextprotocol.io/) server for direct LLM tool integration.
It communicates via JSON-RPC 2.0 over stdio (newline-delimited).

```bash
codescan mcp-serve --root <path>
```

### Claude Desktop / Claude Code configuration

Add to your MCP settings:

```json
{
  "mcpServers": {
    "codescan": {
      "command": "/path/to/codescan",
      "args": ["mcp-serve", "--root", "/path/to/your/project"]
    }
  }
}
```

### Available MCP tools

| Tool | Description |
|------|-------------|
| `codescan_search` | Semantic code search |
| `codescan_index` | Index/reindex repository |
| `codescan_symbols` | List symbols in a file |
| `codescan_find_symbol` | Find symbol by name path |
| `codescan_replace_symbol` | Replace a symbol's body |
| `codescan_insert_after` | Insert code after a symbol |
| `codescan_insert_before` | Insert code before a symbol |
| `codescan_replace_lines` | Replace hashline-validated line range |
| `codescan_insert_at` | Insert after hashline-validated line |
| `codescan_replace_content` | Find/replace text or regex |
| `codescan_references` | Find references via LSP |
| `codescan_rename` | Rename symbol via LSP |
| `codescan_config` | Show configuration |
| `codescan_status` | Index and watcher status |

## Semantic Editing

codescan provides structural editing commands for AI agents and scripts.
All editing commands read replacement text from stdin.

### Hashlines

Every codescan command that outputs source lines annotates them with a 3-character
base-36 content-chain hash:

```
44:k7m|fn init(self: *Self) void {
45:r2p|    self.count = 0;
46:a9x|    self.buffer = undefined;
47:3bw|    self.ready = false;
48:npq|}
```

Each hash incorporates the previous line's hash, forming a chain. If any line above
changes, all subsequent hashes cascade — so a stale `line:hash` reference is always
detected. This lets AI agents and scripts target exact line ranges without the silent
corruption risk of bare line numbers.

### Content-based editing
```bash
echo 'new_name' | codescan replace-content 'old_name' --file src/lib.zig
echo 'v2'       | codescan replace-content 'v1' --file src/lib.zig --all
echo 'new impl' | codescan replace-content 'fn old\(.*?\)' --file src/lib.zig --regex
```

### Symbol-based editing
```bash
echo 'new body' | codescan replace-symbol MyStruct/init --file src/lib.zig
echo 'new code' | codescan insert-after MyStruct --file src/lib.zig
echo 'new code' | codescan insert-before MyStruct --file src/lib.zig
```

### Line-based editing (hashline-validated)
```bash
echo 'replacement' | codescan replace-lines --file src/lib.zig --from 45:r2p --to 47:3bw
echo 'new code'    | codescan insert-at 42:abc --file src/lib.zig
```

### LSP operations
```bash
codescan references MyFunc --file src/lib.zig
codescan rename MyFunc --file src/lib.zig --to newName [--dry-run]
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
