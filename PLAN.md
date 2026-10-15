# PLAN

Completed work is recorded in docs/PLAN_LOG.md. Earlier planning history remains recoverable in Git; private operational context is retained outside the repository.

## CI completion and maintenance

- [ ] Retain the bounded read-only GitHub Actions watch for shipped watcher fix `3efd9f3a`; exact Mechatron Prime CI passed, and the old macOS job must not be canceled or retried solely because it is queued.
- [x] Pin `macos-15` and require native ARM64 host/header/startup checks before packaging; prove regressions RED first and pass the complete native runner plus sandboxed Nix package/test builds in one budgeted job without changing targets or toolchain pins. (done 2026-10-14 20:41 EDT; source: https://github.com/actions/runner-images/issues/13518)
- [ ] Push the validated macOS CI maintenance commit and verify its exact Mechatron Prime CI and GitHub Actions outcomes separately from the old queued run.

## Watcher reliability

- [x] Prevent watcher startup from recreating an existing database when schema initialization fails; prove index preservation with a failing regression first. (done 2026-10-14 16:17 EDT)
- [x] Keep CLI integration commands in their private fixture directory so default-path edit reindexing cannot alter the checkout's index; prove the isolation guard fails first. (done 2026-10-14 16:17 EDT)
- [ ] Reproduce and diagnose repeated watcher SQLite failures without deleting the database; distinguish contention and retain actionable operation/code/message diagnostics. (context: docs/plan_context/watcher_sqlite_failures.md)
- [x] Pass focused regressions, available complete-suite checks, and five-target ReleaseFast builds for the watcher data-preservation fix; live-provider tests were excluded and existing FTS5/log-test skips remain. (done 2026-10-14 16:17 EDT)

## Recent shipments

- [x] Respect the configured embedding API and URL during initialization and use provider-specific model recovery instructions. (done 2026-10-12 12:51 EDT)
- [x] Pass regression coverage, the complete suite, and five-target ReleaseFast builds for shipment; live-provider tests were excluded, and existing FTS5/log-test skips remain. (done 2026-10-12 13:03 EDT)


## After shipping

- [ ] Extend signature queries to other typed languages after selecting the next language; walking decision `codescan-signature-query-next-language` is pending.
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
