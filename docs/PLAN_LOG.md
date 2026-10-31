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
- [x] [CI completion and maintenance] Send the approved Nix tokenizer repair request through durable inbox and native delivery; the owning agent acknowledged acceptance and failing-first validation, with unsafe-path and staged/worktree controls retained. (done 2026-10-28 00:25 EDT; context: docs/plan_context/staged_dependency_parser.md)
- [x] [CI completion and maintenance] Verify the profiler-pin shipment on exact-commit Mechatron Prime CI and GitHub Actions run 40634162232, including native macOS ARM64 build/header/about execution. (done 2026-10-28 00:58 EDT; commit b7dc4595)
- [x] [Validation and performance › Attribute and reduce the ReleaseSafe prepared runtime's 6.23…] Pin the shared profiler and verify monotonic stamps inside the isolated runtime after a missing-tool regression failed; complete Nix and fresh host runners pass without recompiling the CLI or unit artifacts. (done 2026-10-28 00:46 EDT)

## Retired 2026-10-30

- [x] [Validation and performance › Attribute and reduce the ReleaseSafe prepared runtime's 6.23…] Overlap unit execution with source-fixture preparation after a FIFO-barrier regression failed on the old runner; copy and lane failures remain checked, and fresh prepared runtime measured 4.51 seconds with unchanged exclusions. (done 2026-10-28 01:34 EDT; context: docs/plan_context/test_latency.md)
- [x] [CI completion and maintenance] Repair the native macOS profiler-fixture failure without disabling checks; Mechatron Prime CI and GitHub Actions run 40638927693 pass, including native macOS ARM64 build/header/about execution. (done 2026-10-28 01:52 EDT; commit 784da056; context: docs/plan_context/test_latency.md)
- [x] [Watcher reliability] Finish SQLite watcher diagnostics across controlled open/write/read/cursor failures while preserving the index and retry policy; complete Linux Nix/fresh host checks, five-target builds, and native macOS CLI smoke checks pass. (done 2026-10-28 01:52 EDT; commit 784da056; context: docs/plan_context/watcher_sqlite_failures.md)
	- [x] Preserve symbol-body preparation diagnostics after an authorizer regression reported expected 23, found 0; complete Nix and fresh host runners now pass 753 unit cases, with one optional skip and unchanged live-provider exclusions. (done 2026-10-28 01:00 EDT)
	- [x] Ship shared cursor error handling after complete Nix/fresh host checks; Mechatron Prime CI and GitHub Actions run 40626218384 pass, including native macOS ARM64 execution. (done 2026-10-27 23:33 EDT; commit 85bf226a)
	- [x] Verify the populated-index guard and error-path ownership fixes after private regressions reproduced metadata replacement and 14 unfreed bytes; complete Nix and fresh host runners pass without changing retry policy. (done 2026-10-28 00:02 EDT)
	- [x] Require ReleaseSafe correctness artifacts after a failing runtime-safety control exposed disabled allocator leak checks; explicit byte accounting and 752 passing unit cases verify cleanup, with one optional skip. (done 2026-10-28 00:02 EDT)
	- [x] Pass the complete ReleaseSafe runner with compatible sqlite-vec cleanup callbacks and explicit scanner creation prototypes; real insertion and Bash parsing regressions exposed the callback failures first. (done 2026-10-28 00:02 EDT; context: docs/plan_context/sqlite_vec_callback_safety.md)
	- [x] Ship the populated-index, ownership, and callback-safety fixes; exact-commit Mechatron Prime CI and GitHub Actions run 40630870526 pass, including native macOS ARM64 execution. (done 2026-10-28 00:24 EDT; commit 75172eb4)
- [x] [CI completion and maintenance] Verify the shared tokenizer repair in 9c935fb: the exact installed blob accepts escaped cache interpolation, rejects unsafe dependencies, and honors staged content in both disagreement directions inside a disposable consumer fixture. (done 2026-10-28 02:36 EDT; context: docs/plan_context/staged_dependency_parser.md)
- [x] [Watcher reliability › Reproduce slow MCP semantic search in a disposable fixture w…] Preserve inference-unavailable advice after a reachable server rejects embeddings; complete Nix/fresh host checks pass 754 unit cases, and exact-commit Mechatron Prime CI plus GitHub Actions run 40644259465 pass, including native macOS CLI smoke checks. (done 2026-10-28 02:49 EDT; commit 28602f00; context: docs/plan_context/inference_availability.md)

## Retired 2026-10-31

- [x] [After shipping] Require FTS5 in all seven dependent scoring regressions instead of silently returning or skipping; the complete Nix check passes 754 unit cases with the pinned FTS5-enabled SQLite. (done 2026-10-28 03:04 EDT)
- [x] [Validation and performance › Add controlled TCP-blackhole/TLS-cancellation fixtures and r…] Bound the unit process independently and verify real held HTTP/TLS exchanges close and join on cancellation; the complete Linux Nix check passes 755 unit cases without changing cold-model request policy. (done 2026-10-28 03:15 EDT; context: docs/plan_context/request_deadlines.md)
- [x] [CI completion and maintenance] Verify the FTS prerequisite and real-socket cancellation shipments on exact-commit Mechatron Prime CI and GitHub Actions, including native macOS CLI smoke checks; all pass for 591c07a8 and b2d2ebd9. (done 2026-10-28 12:32 EDT)
- [x] [Architecture and features › Bring project builds and publication into conformance with t…] Inventory the single Zig implementation, Nix profiles, five release targets, legacy publication/callers, exact test artifacts, and rollback boundary without moving live products. (done 2026-10-28 03:24 EDT; context: docs/plan_context/build_conformance.md)
- [x] [CI completion and maintenance] Verify the held-MCP characterization shipment on exact-commit Mechatron Prime CI and GitHub Actions; all five release builds and native macOS smoke checks pass for f3cad46c, following 757 passing local unit cases. (done 2026-10-30 22:46 EDT)
- [x] [Watcher reliability › Reproduce slow MCP semantic search in a disposable fixture w…] Characterize a held pending-file embedding through the real MCP handler and HTTP transport; wire input identifies reconciliation, search remains pending until release, and rejection restores lexical results plus provider advice; complete Nix and fresh confined host checks pass 757 unit cases. (done 2026-10-30 22:28 EDT; context: docs/plan_context/inference_availability.md)
