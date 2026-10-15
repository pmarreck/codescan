# Completed work

The legacy plan mixed implementation history with private operational details. Its complete text was archived privately before condensation; earlier committed versions remain in Git history. New entries here contain public-safe completion records.

- [x] Repair MCP registration to record an absolute executable path, independent of the agent host's PATH. (done 2026-09-06 15:17 EDT; commit 6e9dc902)
- [x] Repair watcher startup failures caused by unhandled directory-descriptor write errors and add bounded retries with durable diagnostics. (done 2026-10-03 10:16 EDT; commit 5fc4dda7)
- [x] Add `codescan doctor` checks for settings, SQLite integrity, inference/model availability, watcher state, and permissions; a stopped watcher is informational. (done 2026-10-03 10:16 EDT; commit 5fc4dda7)

## Python shipment validation (2026-10-12)

Validation: `./test`, Debug aggregate unit tests, sandboxed `checks.aarch64-darwin.test`, and `./build_all` pass. Live HTTP/integration tests skip because local Ollama is unavailable. ReleaseFast is now the default, including the cross-build script.
Publication checks use GitHub Actions and exact-commit Mechatron Prime CI.

## Retired 2026-10-12

- [x] [Recent shipments] Add Roc discovery, structural extraction, documentation, and annotation-aware symbol edits. (done 2026-10-11 19:27 EDT)
- [x] [Recent shipments] Measure and speed up initial indexing with bounded workers, ordered writes, and joined failure cleanup. (done 2026-10-11 19:27 EDT)
- [x] [Recent shipments] Match partial Roc signatures such as `ceil : -> Dec`, including associated names and multiline annotations. (done 2026-10-11 19:27 EDT)
- [x] [Recent shipments] Fix Windows watcher startup reporting by converting process handles to numeric PIDs. (done 2026-10-11 19:42 EDT)
- [x] [Recent shipments] Pass the complete suite and five-target ReleaseFast cross-builds. (done 2026-10-11 19:42 EDT)
- [x] [Recent shipments] Add Python indexing and symbol editing for `.py`, `.pyi`, and executable shebang scripts, with decorator/indentation boundaries, nested names, multiline signatures, and docstrings. (done 2026-10-12 11:22 EDT)
- [x] [Recent shipments] Exclude Python environments and generated caches, with set-based discovery tests for root and nested paths. (done 2026-10-12 11:22 EDT)
- [x] [Recent shipments] Fix the existing macOS log-duration validation failure blocking the CLI suite. (done 2026-10-12 11:22 EDT)

## Retired 2026-10-14

- [x] [Recent shipments] Pass regression tests, the complete suite, and five-target ReleaseFast builds; update language documentation. (done 2026-10-12 11:27 EDT)
- [x] [Recent shipments] Use the configured temporary directory in the reindex-runner test; its hardcoded `/dev/shm` path fails on macOS. (done 2026-10-12 11:22 EDT)
- [x] [Recent shipments] Commit the passing Python support, push `yolo`, and verify the remote commit: `357f6733`. (done 2026-10-12 11:29 EDT)
- [x] [Recent shipments] Start the watcher after successful initialization; keep ordinary index/update/search commands non-spawning and report startup failures. (done 2026-10-12 12:51 EDT)
