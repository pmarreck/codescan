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

## Retired 2026-10-27

- [x] [Watcher reliability] Prevent watcher startup from recreating an existing database when schema initialization fails; prove index preservation with a failing regression first. (done 2026-10-14 16:17 EDT)
- [x] [Recent shipments] Respect the configured embedding API and URL during initialization and use provider-specific model recovery instructions. (done 2026-10-12 12:51 EDT)
- [x] [Recent shipments] Pass regression coverage, the complete suite, and five-target ReleaseFast builds for shipment; live-provider tests were excluded, and existing FTS5/log-test skips remain. (done 2026-10-12 13:03 EDT)
- [x] [Watcher reliability] Keep CLI integration commands in their private fixture directory so default-path edit reindexing cannot alter the checkout's index; prove the isolation guard fails first. (done 2026-10-14 16:17 EDT)
- [x] [Watcher reliability] Pass focused regressions, available complete-suite checks, and five-target ReleaseFast builds for the watcher data-preservation fix; live-provider tests were excluded and existing FTS5/log-test skips remain. (done 2026-10-14 16:17 EDT)
- [x] [CI completion and maintenance] Verify the watcher-safety shipment; exact Mechatron Prime CI and GitHub Actions both passed, including the previously queued Mac14 job. (done 2026-10-14 21:00 EDT; commit 3efd9f3a)
- [x] [CI completion and maintenance] Pin `macos-15` and require native ARM64 host/header/startup checks before packaging; prove regressions RED first and pass the complete native runner plus sandboxed Nix package/test builds in one budgeted job without changing targets or toolchain pins. (done 2026-10-14 20:41 EDT; source: https://github.com/actions/runner-images/issues/13518)
- [x] [Active triage and execution] Triage every open item, recover answered decisions, record next actions/dependencies, and ask for incident evidence, independent relevance judgments, and disposition of speculative features. (done 2026-10-27 20:25 EDT)
- [x] [Resolved decisions] Should concise I/O wrappers and whole-file/comment generation remain active, be tabled, or be discarded? Answer: Table both for now; do not resume without a concrete use case and renewed direction. (done 2026-10-27 20:43 EDT)
- [x] [Resolved decisions] Is the original watcher SQLite failure still reproducible in a known project? Answer: No current reproducer was identified; the incident is not remembered, and its underlying SQLite operation/code/message remain unavailable. Continue diagnostic improvements without claiming the historical cause. (done 2026-10-27 20:44 EDT)
- [x] [Resolved decisions] Can independent query/result examples be supplied for a relevance corpus now? Answer: Table the corpus; independent expected symbols/files are a prerequisite before judging ranking quality or reporting MRR, nDCG, or Recall@k. (done 2026-10-27 20:44 EDT)
- [x] [CI completion and maintenance] Fix the Mac15 smoke failure with a real `--about` CLI regression and compile-target PF/VARIANT identification; all five Nix release builds and actual headers passed, with native Mac execution still pending CI. (done 2026-10-27 21:12 EDT; prior failure e058546e)
- [x] [CI completion and maintenance] Prepare exact test binaries through Nix once and run mutation tests in a qualified disposable boundary; the complete local runner passed executed checks, with four unit and two live-provider exclusions reported explicitly. (done 2026-10-27 21:12 EDT)
- [x] [Validation and performance › Test provider-model failure paths for index/provider compati…] Prove real stdio MCP initialization, lexical/hybrid fallback search with agent-visible advice, create/read/versioned edits, and non-destructive indexing refusal with a stopped provider; verify subsequent file requests still succeed. (done 2026-10-27 21:53 EDT)
- [x] [CI completion and maintenance] Make Git-discovery prerequisites hard failures, inject process-aware test I/O, and force-add the deliberately ignored tracked fixture; all three regressions execute successfully in the full native and Nix runners. (done 2026-10-27 22:09 EDT)

## Retired 2026-10-28

- [x] [CI completion and maintenance] Resolve the staged-dependency rejection locally with equivalent double-quoted Nix shell syntax; cache inheritance/default tests and the real staged gate pass without an override. (done 2026-10-27 22:14 EDT; context: docs/plan_context/staged_dependency_parser.md)
- [x] [CI completion and maintenance] Ship the validated changes and verify exact-commit Mechatron Prime CI and GitHub Actions, including native macOS ARM64 execution; both services passed c97e9d2 and GitHub run 40621238947. (done 2026-10-27 22:46 EDT; commits 96d90c5 and c97e9d2)
	- [x] Move source-closure validation to declared build inputs and require its positive/negative controls in CI and the complete runner; local and cold GitHub checks pass. (done 2026-10-27 22:46 EDT; commit c97e9d2)
- [x] [Watcher reliability › Finish SQLite watcher diagnostics across remaining read/curs…] Preserve connection-local startup/write error operation, primary/extended codes, message, command, and version through cleanup; controlled busy/constraint/schema/read-only/open-failure tests and the real preservation CLI regression pass. (done 2026-10-27 22:09 EDT)
- [x] [CI completion and maintenance] Attribute and reduce the ReleaseFast diagnostic runtime from 13.43 to 4.02 seconds using a nonblocking polling test, exact lightweight source inventory, and two test lanes; exclusions prevent a complete budget claim, and ReleaseSafe correctness timing remains separate. (done 2026-10-27 23:04 EDT; context: docs/plan_context/test_latency.md)
- [x] [CI completion and maintenance] Finish exact-commit CI verification for 93a0fea3; Mechatron Prime CI passed in 42 seconds and GitHub Actions run 40624690426 passed, including native macOS ARM64 execution. (done 2026-10-27 23:17 EDT; commit 93a0fea3)
