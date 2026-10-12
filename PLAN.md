# PLAN

Completed work is recorded in docs/PLAN_LOG.md. Earlier planning history remains recoverable in Git; private operational context is retained outside the repository.

## Current fixes

- [x] Start the watcher after successful initialization; keep ordinary index/update/search commands non-spawning and report startup failures. (done 2026-10-12 12:51 EDT)
- [x] Respect the configured embedding API and URL during initialization and use provider-specific model recovery instructions. (done 2026-10-12 12:51 EDT)
- [x] Pass regression coverage, the complete suite, and five-target ReleaseFast builds for shipment; live-provider tests were excluded, and existing FTS5/log-test skips remain. (done 2026-10-12 13:03 EDT)

## Recent shipments

- [x] Pass regression tests, the complete suite, and five-target ReleaseFast builds; update language documentation. (done 2026-10-12 11:27 EDT)
- [x] Use the configured temporary directory in the reindex-runner test; its hardcoded `/dev/shm` path fails on macOS. (done 2026-10-12 11:22 EDT)
- [x] Commit the passing Python support, push `yolo`, and verify the remote commit: `357f6733`. (done 2026-10-12 11:29 EDT)

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
