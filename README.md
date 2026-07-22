# codescan

[![build](https://github.com/pmarreck/codescan/actions/workflows/build.yml/badge.svg?branch=yolo)](https://github.com/pmarreck/codescan/actions/workflows/build.yml)
[![built with garnix](https://img.shields.io/endpoint.svg?url=https%3A%2F%2Fgarnix.io%2Fapi%2Fbadges%2Fpmarreck%2Fcodescan%3Fbranch%3Dyolo)](https://garnix.io)

Semantic code search for local repositories.

- Zig CLI + HTTP API + MCP server
- Embedding providers: Ollama and OpenAI-compatible (oMLX, LiteLLM, vLLM) — default model: `bge-large`
- sqlite-vec vector storage
- Hybrid search (vector + lexical)
- Symbol extraction: Zig, C/C++, TypeScript/JavaScript, Rust, Elixir, Bash, Lua, Nix, Nim, Lean, Idris, Haskell, Go, Ruby, Erlang, OCaml, Swift, LLVM IR, Clojure, Assembly
- LSP (references, rename): all of the above
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

### Pre-built binaries (no Nix required)

Pre-built binaries for Linux (x86_64, arm64) and macOS (arm64) are available as
artifacts from the latest CI build:

**[Download from GitHub Actions](https://github.com/pmarreck/codescan/actions/workflows/build.yml?query=branch%3Ayolo+is%3Asuccess)**

1. Click the most recent successful run
2. Scroll to the **Artifacts** section at the bottom
3. Download the archive for your platform
4. Extract and place `codescan` somewhere on your `PATH`

> Note: GitHub requires you to be signed in to download workflow artifacts.

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
codescan config
codescan config edit

# ReleaseFast builds are self-contained; no `nix develop` prefix needed to run.
# index
codescan index --root <path>

# update (full reindex)
codescan update --root <path>

# search
codescan search "hash functions" --root <path> --min-score 0.2
# default verb is search
codescan "hash functions" --root <path>
# show doc comments in human output
codescan search "hash functions" --root <path> --show-comments
# comment-only search (doc comments only)
codescan search "hash functions" --root <path> --comments
# include markdown/README when using default search scope
codescan search "design doc" --include-docs
# only markdown/README results
codescan search "design doc" --docs
# unified scope selector
codescan search "design doc" --scope docs
codescan search "hash functions" --scope comments
# restrict by extension/type/language
codescan search "checksum" --ext md,zig
codescan search "checksum" --type code,doc
codescan search "checksum" --lang zig

# filter by symbol kind (fn, struct, enum, const, var, test, mod, type, macro, ...)
codescan search "config" --kind struct
codescan search "init" --kind fn
codescan search "config" --kind const,var
# meta-kinds: declaration (const+var), definition (any defined symbol)
codescan search "config" --kind declaration
codescan search --kind definition --top 20

# browse mode: list symbols by kind without a text query
codescan search --kind fn --top 10
codescan search --kind struct

# filter by file path (glob) or exact file
codescan search "init" --path "src/storage*"
codescan search "hash" --file src/hash.zig

# regex search (PCRE2) with context lines
codescan search "pub fn \w+Init" --regex --context 5
codescan search "TODO|FIXME|HACK" --regex --top 20
codescan search "defer.*free" --regex --path "src/*.zig"
codescan search "fixme|todo" --regex -i  # case-insensitive
codescan search "computeHash" --regex --include-body  # show full symbol body containing match

# show uncommitted changes with hashlines (for safe editing from diff output)
codescan diff
codescan diff --staged

# index node_modules too
codescan index --include-node-modules

# show index and watcher status
codescan status
codescan status --json

# focused command help
codescan help search
codescan search --help

# stdin JSON request mode (auto-routed to CLI args, always emits JSON)
printf '{"action":"search","query":"checksum","mode":"lexical","db":".codescan/index.sqlite3"}\n' | codescan --json
```

If `--root` is omitted, `codescan` searches upward from the current directory for a `.codescan/`
directory and uses that as the root (otherwise it falls back to the current directory).

Search defaults to the primary code language by file count unless a filter is supplied.
Multi-word queries use OR semantics in lexical/hybrid search — results matching any term surface, with BM25 ranking results matching all terms higher.
`--include-docs` adds markdown/README; `--docs`/`--only-docs` restricts results to markdown/README only.
`--comments`/`--only-comments` restricts results to doc comments.
`--scope <code|docs|comments|all>` is a unified alias for common filter combinations.
Index/update defaults to code + docs unless `--type`/`index_type` is set.
Built-in ignores: `.git/`, `.codescan/`, `.codescan-fixtures/`, `deps/`, `node_modules/` (opt-in), `.zig-cache/`, `zig-cache/`, `.zig-out/`, `zig-out/` (see PROJECT_STATE for full list).

Human output uses ANSI colors by default; set `NO_COLOR=1` to disable.
Interactive index/update shows a compact per-file progress counter on stderr (TTY only).
Set `DEBUG=1` to emit verbose indexing progress to stderr.

## Run (HTTP)

```bash
codescan serve --root <path> --http-host 127.0.0.1 --http-port 8123
```

Endpoints:

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check |
| `/help` | GET | List all endpoints |
| `/search` | POST | Semantic code search (`/query` is an alias) |
| `/index` | POST | Index/reindex repository |
| `/symbols` | POST | List or find symbols (`/find-symbol` is an alias) |
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
curl -s localhost:8123/symbols -d '{"file":"src/main.zig","pattern":"runSearch","include_body":true}'
curl -s localhost:8123/symbols -d '{"file":["src/main.zig","src/cli.zig"],"pattern":"parse"}'
curl -s localhost:8123/symbols -d '{"pattern":"init"}'
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

### Codex CLI / Codex Desktop configuration

Use an absolute binary path so startup does not depend on `PATH`:

```bash
codex mcp remove codescan
codex mcp add codescan -- /path/to/codescan mcp-serve --root /path/to/your/project
codex mcp get codescan
```

If you prefer `command = "codescan"` in `~/.codex/config.toml`, ensure the app's
launch environment includes the directory that contains `codescan`.

### MCP troubleshooting

- `MCP startup failed: No such file or directory (os error 2)` usually means the MCP command could not be resolved.
- Fix: configure an absolute binary path (recommended), or fix `PATH` for the app launch environment.
- Verify with `codex mcp list` / `codex mcp get codescan`.

### Available MCP tools

| Tool | Description |
|------|-------------|
| `search` | Semantic code search (`query` is an alias). Params: `query`, `kind`, `path`, `file`, `lang`, `top` |
| `index` | Index/reindex repository |
| `symbols` | List or find symbols (optional `file`, `pattern`, `include_body`) |
| `replace_symbol` | Replace a symbol's body |
| `insert_after` | Insert code after a symbol |
| `insert_before` | Insert code before a symbol |
| `replace_lines` | Replace hashline-validated line range |
| `insert_at` | Insert after hashline-validated line |
| `replace_content` | Find/replace text or regex |
| `references` | Find references via LSP |
| `rename` | Rename symbol via LSP |
| `config` | Show configuration |
| `status` | Index and watcher status |
| `setup-model` | Show model installation instructions |

## Semantic Editing

codescan provides structural editing commands for AI agents and scripts.
All editing commands read replacement text from stdin.

### Hashlines

Every codescan command that outputs source lines annotates them with a 3-character
base-62 content-chain hash:

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

# Embedding model (default: jina-code-embeddings-1.5b)
# Use ollama_model as alias, or OLLAMA_MODEL env var
embedding_model=bge-large

# For OpenAI-compatible providers (oMLX, LiteLLM, vLLM):
#embedding_api=openai
#embedding_url=http://localhost:8000
#embedding_api_key=<your-key>

# ignores
ignore=**/.git/**, **/.codescan/**
ignore.zig=**/.zig-cache/**,**/zig-out/**
```

Optional language-specific weight overrides live in `<root>/.codescan/weights.toml`:

```toml
[default]
weight_vector = 0.7
weight_lexical = 0.3
weight_symbol_kind = 0.0
weight_symbol_visibility = 0.0
weight_symbol_scope = 0.0
weight_symbol_arity = 0.0

[zig]
weight_vector = 0.55
weight_lexical = 0.45
weight_symbol_kind = 0.15
weight_symbol_visibility = 0.10
```

When both are present:
- explicit CLI/HTTP weights win
- otherwise `weights.toml` applies
- otherwise `.codescan/config` global `weight_*` applies

Metadata weights apply when the query includes metadata cues such as `function`, `public`, `top-level`, or `arity 2`.

## Model Setup

codescan defaults to `bge-large` via Ollama — no extra setup needed beyond `ollama pull bge-large`.

For better code search quality, run `codescan setup-model` to see instructions for upgrading to `jina-code-embeddings-1.5b` (1536-dim, 32K context, code-specific training).

**Ollama caveat:** the upstream Jina GGUF currently lacks the `qwen2.pooling_type`
metadata Ollama uses to recognize embedding-only models. A raw `ollama pull` is
therefore classified as completion-only and `/api/embed` rejects it. See
[local Jina through Ollama](docs/jina-code-embeddings-ollama.md) for the verified
last-token-pooling import and acceptance check. Until the CLI help moves into the
i18n string registry, this README caveat supersedes its raw-pull instruction.

### Set up Jina locally through Ollama

This procedure keeps the multi-gigabyte conversion in RAM, verifies the official
Jina artifact, adds the required last-token pooling metadata without changing the
model tensors, and imports the result under the stable local name
`jina-code-embeddings:1.5b`.

The temporary Python invocation uses llama.cpp's official GGUF writer because
neither Ollama's Modelfile nor its compiled utilities can currently add missing
pooling metadata. It does not add Python to codescan or the host environment.

1. Confirm `/dev/shm` has at least 4 GB free, then download the official Q8 model
   into a RAM-backed workspace:

```sh
df -h /dev/shm
jina_work="$(mktemp -d /dev/shm/jina-ollama.XXXXXX)"

curl --fail --location --output "$jina_work/jina-q8.gguf" \
  'https://huggingface.co/jinaai/jina-code-embeddings-1.5b-GGUF/resolve/main/jina-code-embeddings-1.5b-Q8_0.gguf'

printf '%s  %s\n' \
  '3a09a8817b852b5a4faaa6ebb1a5590322746d2b570b578d0b7e3b6e849062aa' \
  "$jina_work/jina-q8.gguf" | sha256sum -c -
```

2. Copy the GGUF while adding `qwen2.pooling_type=3` (`LAST`, Jina's required
   EOS pooling strategy):

```sh
nix shell --impure \
  --expr 'let pkgs = import <nixpkgs> {}; in pkgs.python3.withPackages (ps: [ps.gguf])' \
  -c python3 - \
  "$jina_work/jina-q8.gguf" \
  "$jina_work/jina-q8-last-pooling.gguf" <<'PY'
import sys
import gguf
from gguf.scripts.gguf_new_metadata import (
    MetadataDetails,
    copy_with_new_metadata,
    get_field_data,
)

source, target = sys.argv[1:]
reader = gguf.GGUFReader(source, "r")
arch = get_field_data(reader, gguf.Keys.General.ARCHITECTURE)
key = gguf.Keys.LLM.POOLING_TYPE.format(arch=arch)
if reader.get_field(key) is not None:
    raise SystemExit(f"refusing to replace existing {key}")

writer = gguf.GGUFWriter(target, arch=arch, endianess=reader.endianess)
alignment = get_field_data(reader, gguf.Keys.General.ALIGNMENT)
if alignment is not None:
    writer.data_alignment = alignment

metadata = {
    key: MetadataDetails(gguf.GGUFValueType.UINT32, 3, "= last"),
}
copy_with_new_metadata(reader, writer, metadata, [])
PY

nix shell --impure \
  --expr 'let pkgs = import <nixpkgs> {}; in pkgs.python3.withPackages (ps: [ps.gguf])' \
  -c gguf-dump "$jina_work/jina-q8-last-pooling.gguf" --no-tensors \
  | rg 'qwen2\.pooling_type = 3'
```

3. Import the patched model and prove Ollama returns 1536-dimensional vectors:

```sh
printf '%s\n' \
  "FROM $jina_work/jina-q8-last-pooling.gguf" \
  'PARAMETER num_ctx 8192' > "$jina_work/Modelfile"

ollama create jina-code-embeddings:1.5b -f "$jina_work/Modelfile"
./test_jina
```

4. Configure each project and rebuild its old-model index:

```ini
embedding_api=ollama
embedding_url=http://127.0.0.1:11434
embedding_model=jina-code-embeddings:1.5b
embedding_dim=1536
```

```sh
codescan index --root /path/to/project
```

5. Release the RAM-backed conversion files after the model is safely imported:

```sh
truncate -s 0 \
  "$jina_work/jina-q8.gguf" \
  "$jina_work/jina-q8-last-pooling.gguf"
rm-safe -r "$jina_work"
```

Do not use this host's `/tmp` for the rewrite: it resides on the spinning ZFS
mirror. Do not edit Ollama's content-addressed model blobs in place.

### OpenAI-compatible providers (oMLX, LiteLLM, vLLM)

Set `embedding_api=openai` in `.codescan/config` along with `embedding_url` and `embedding_api_key`. See `codescan setup-model` for details.

For oMLX users wanting the jina model specifically, see [jina-code-embeddings on oMLX](docs/jina-code-embeddings-omlx.md) (requires interim patches until oMLX adds native Qwen2 embedding support).

## AI Agent Integration (Optional)

codescan can replace Claude Code's built-in Read, Edit, Grep, and Glob tools with safer,
hashline-validated alternatives. This is especially valuable for multi-agent workflows
where concurrent file access can cause stale edits.

### Why use codescan's tools instead of built-in ones?

- **Optimistic concurrency**: Every `read-file` returns a 3-character version hash
  (the hashline of the last line — a content-addressed checksum of the entire file).
  Pass it back to any write tool via `--version` — if the file changed since your read,
  the edit fails cleanly instead of silently corrupting.
- **Hashline validation**: Line-level edits use content-chain hashes that detect if
  the target lines have shifted since your last read.
- **Structured search**: `codescan search --kind fn` returns semantically relevant
  results instead of raw text matches, using fewer tokens.
- **Safe deletion**: `destroy-file` moves files to the system trash (with undo support)
  instead of permanent `rm`.

### Setup: Global Claude Code Hook

Add a `PreToolUse` hook to `~/.claude/settings.json` that nudges Claude toward codescan
tools in indexed projects:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Grep|Glob|Agent|Read",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/codescan-redirect/redirect.sh",
            "timeout": 5,
            "statusMessage": "Checking codescan availability..."
          }
        ]
      }
    ]
  }
}
```

The hook checks if `.codescan/` exists in the project and injects a context reminder to
use codescan's tools instead. It's non-blocking — the built-in tool still runs, but the
model learns to prefer codescan over time.

Add to `~/.claude/CLAUDE.md`:

```markdown
## Code Navigation: Prefer codescan

At the start of every session, run `codescan status` to check if the project is indexed
and the watcher is running. A running watcher means the index stays up to date
automatically.

When a `.codescan/` directory exists:
- Use `codescan search` / `codescan symbols` instead of Grep/Glob
- Use `codescan read-file` instead of Read (returns version hash for safe edits)
- Use `codescan replace-content --version <hash>` instead of Edit
- Use `codescan create-file` instead of Write (for new files)
- Use `codescan destroy-file` instead of rm (moves to trash)
```

### Typical safe-edit workflow

```bash
# 1. Read a file — get version hash
codescan read-file src/foo.zig --json
# → {"file":"src/foo.zig","version":"k7m","total_lines":50,...}

# 2. Edit with version check — prevents stale edits
codescan replace-content src/foo.zig "old text" --version k7m <<< "new text"
# → Replaced 1 occurrence (line 10:abc)
# → version: x9a

# 3. If another agent edited the file between steps 1 and 2:
# → error: file modified since last read (expected version k7m, current p3q) — re-read and retry
```

## Troubleshooting

### Diagnosing watcher stops

The background watcher logs its lifecycle and error events to the system log. If your watcher appears to have stopped unexpectedly, inspect recent logs with:

    codescan log --since 1h

Pass `--all` to see activity across every codescan project. Under the hood this uses `log show` on macOS and `journalctl -t codescan` on Linux, so the OS handles rotation and compression automatically.

## Notes

- SQLite vector extension is statically linked (no runtime extension loading).
- On macOS, fully static userland binaries are not supported by the OS; `libSystem` remains dynamic.

## License

MIT. See `LICENSE`.
