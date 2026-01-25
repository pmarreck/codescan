# Rules

These are non-negotiable project rules unless explicitly changed by the user.

- Use `nix develop -c` for commands that depend on flake-provided tooling.
- Keep tests in `./tests/` and run the master test runner `./test`.
- Index/update defaults to `code,doc` unless overridden by config or CLI.
- `.codescan/` is the repo-local config/index root and must not be deleted from the repo.
- Ollama is required for embeddings; default model is `bge-large` unless overridden.
- sqlite-vec is linked statically; no runtime extension loading.
- Release builds target static artifacts for redistribution.
