# Intent

Codescan provides semantic and lexical search, source inspection, and targeted editing for local code repositories through a CLI, HTTP API, and MCP server.

Developers and coding agents should be able to find relevant definitions with their source provenance, inspect hierarchical symbols, and make edits guarded against stale source versions. Supported source languages and document formats share discovery, filtering, and indexing behavior across adapters.

Embedding providers supply vectors; SQLite and statically linked sqlite-vec store the index. An unavailable inference server must leave existing lexical search and file/edit operations usable. Index replacement must preserve existing data until its replacement provider is validated. Watcher failures must have actionable, durable diagnostics.

The CLI targets macOS ARM64, Linux ARM64/x86_64, and Windows ARM64/x86_64. Source builds use pinned Nix dependencies; distributed executables are self-contained. Runtime Git integration is optional.

Correctness is verified through `./test`, including isolated behavioral tests and CLI/HTTP integration contracts. Cross-compilation establishes build portability; native execution is separate evidence. Indexing optimizations must preserve symbols, source ranges, embeddings, and file-completion semantics.

See [README.md](README.md) for the supported interfaces, [RULES.md](RULES.md) for invariants, and [PLAN.md](PLAN.md) for remaining work. This document records the existing product scope and the accepted operational requirements.
