# CODE MINIMAP

- AGENTS.md: project-specific agent instructions
- PLAN.md: task checklist
- PROJECT_PLAN.md: high-level milestones and objective
- CODE_MINIMAP.md: overview of important files and their purpose
- .gitignore: ignored paths for build outputs and local indexes
- flake.lock: pinned Nix inputs for reproducible dev shell
- flake.nix: Nix flake providing dev dependencies (zig, sqlite, pkg-config)
- build.zig: Zig build script for CLI + unit tests
- test: unit test runner script (wraps `zig build test` in nix dev shell)
- src/main.zig: CLI entrypoint (minimal stub)
- src/cli.zig: CLI argument parsing types + tests
