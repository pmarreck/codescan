# PLAN

Completed work is recorded in docs/PLAN_LOG.md. Earlier planning history remains recoverable in Git; private operational context is retained outside the repository.

## Current shipment

- [x] Add Python indexing and symbol editing for `.py`, `.pyi`, and executable shebang scripts, with decorator/indentation boundaries, nested names, multiline signatures, and docstrings. (done 2026-10-12 11:22 EDT)
- [x] Exclude Python environments and generated caches, with set-based discovery tests for root and nested paths. (done 2026-10-12 11:22 EDT)
- [x] Pass regression tests, the complete suite, and five-target ReleaseFast builds; update language documentation. (done 2026-10-12 11:27 EDT)
- [x] Fix the existing macOS log-duration validation failure blocking the CLI suite. (done 2026-10-12 11:22 EDT)
- [x] Use the configured temporary directory in the reindex-runner test; its hardcoded `/dev/shm` path fails on macOS. (done 2026-10-12 11:22 EDT)
- [x] Commit the passing Python support, push `yolo`, and verify the remote commit: `357f6733`. (done 2026-10-12 11:29 EDT)

Validation: `./test`, Debug aggregate unit tests, sandboxed `checks.aarch64-darwin.test`, and `./build_all` pass. Live HTTP/integration tests skip because local Ollama is unavailable. ReleaseFast is now the default, including the cross-build script.
Publication checks use GitHub Actions and exact-commit Mechatron Prime CI.

- [x] Add Roc discovery, structural extraction, documentation, and annotation-aware symbol edits. (done 2026-10-11 19:27 EDT)
- [x] Measure and speed up initial indexing with bounded workers, ordered writes, and joined failure cleanup. (done 2026-10-11 19:27 EDT)
- [x] Match partial Roc signatures such as `ceil : -> Dec`, including associated names and multiline annotations. (done 2026-10-11 19:27 EDT)
- [x] Fix Windows watcher startup reporting by converting process handles to numeric PIDs. (done 2026-10-11 19:42 EDT)
- [x] Pass the complete suite and five-target ReleaseFast cross-builds. (done 2026-10-11 19:42 EDT)

## After shipping

- [ ] Extend signature queries to other typed languages after the Roc shipment.
- [ ] Investigate repeated watcher `SqlStepFailed` without deleting the database; distinguish lock contention and retain actionable diagnostics.
- [ ] Restore FTS5 coverage: the linked SQLite currently skips three full-text scoring regressions.

## Validation and performance

- [ ] Verify request-deadline behavior natively on macOS and Windows, including TCP blackholes and TLS cancellation.
- [ ] Reproduce watcher heap growth with deterministic event batches and compare explicit versus implicit roots.
- [ ] Establish a versioned relevance corpus with independent judgments, MRR, nDCG, and Recall@k.
- [ ] Test provider-model failover without weakening relevance checks.
- [ ] Resume the interrupted multi-project reindex sweep using retained completion evidence.
- [ ] Expand deterministic filter-classifier coverage for remaining discovery and search edge cases.

## Architecture and features

- [ ] Move update database preparation and freshness reconciliation into the shared application service.
- [ ] Split CLI command orchestration into tested command modules and decompose the remaining search scorer.
- [ ] Add `codescan symbols --depth N` for bounded hierarchy inspection.
- [ ] Normalize camelCase and snake_case identifiers for lexical matching.
- [ ] Evaluate concise I/O wrappers without changing lifetime or concurrency semantics.
- [ ] Add whole-file and hashline-targeted comment generation with model/language settings, existing-comment protection, dry runs, and explicit overwrite behavior.
- [ ] Move remaining vendored grammars to pinned package dependencies without losing local fixes.
