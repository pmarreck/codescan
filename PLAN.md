# PLAN

Completed work is recorded in docs/PLAN_LOG.md. Earlier planning history remains recoverable in Git; private operational context is retained outside the repository.

## CI completion and maintenance

- [x] Send the approved Nix tokenizer repair request through durable inbox and native delivery; the owning agent acknowledged acceptance and failing-first validation, with unsafe-path and staged/worktree controls retained. (done 2026-10-28 00:25 EDT; context: docs/plan_context/staged_dependency_parser.md)
- [ ] Verify the shared tokenizer repair when its owning agent reports the fix commit and complete gate results; keep the tested local quoting workaround meanwhile. (context: docs/plan_context/staged_dependency_parser.md)
- [x] Verify the profiler-pin shipment on exact-commit Mechatron Prime CI and GitHub Actions run 40634162232, including native macOS ARM64 build/header/about execution. (done 2026-10-28 00:58 EDT; commit b7dc4595)
- [ ] Report the shared profiler's failed-run WITHIN_BUDGET label and verify its repair; contact approval is pending and the failed diagnostic remains ineligible for compliance. (context: docs/plan_context/test_latency.md)
- [x] Finish exact-commit CI verification for 93a0fea3; Mechatron Prime CI passed in 42 seconds and GitHub Actions run 40624690426 passed, including native macOS ARM64 execution. (done 2026-10-27 23:17 EDT; commit 93a0fea3)

## Watcher reliability

- [ ] Reproduce slow MCP semantic search in a disposable fixture with pending freshness work and bounded requests; live root/status calls respond, the watcher is stopped, and pre-search reconciliation is a candidate for the October 27 delay, not an established cause.
- [ ] Finish SQLite watcher diagnostics across remaining read/cursor failures, including controlled I/O faults, without broadening retry policy. (context: docs/plan_context/watcher_sqlite_failures.md)
	- [x] Preserve symbol-body preparation diagnostics after an authorizer regression reported expected 23, found 0; complete Nix and fresh host runners now pass 753 unit cases, with one optional skip and unchanged live-provider exclusions. (done 2026-10-28 01:00 EDT)
	- [x] Ship shared cursor error handling after complete Nix/fresh host checks; Mechatron Prime CI and GitHub Actions run 40626218384 pass, including native macOS ARM64 execution. (done 2026-10-27 23:33 EDT; commit 85bf226a)
	- [x] Verify the populated-index guard and error-path ownership fixes after private regressions reproduced metadata replacement and 14 unfreed bytes; complete Nix and fresh host runners pass without changing retry policy. (done 2026-10-28 00:02 EDT)
	- [x] Require ReleaseSafe correctness artifacts after a failing runtime-safety control exposed disabled allocator leak checks; explicit byte accounting and 752 passing unit cases verify cleanup, with one optional skip. (done 2026-10-28 00:02 EDT)
	- [x] Pass the complete ReleaseSafe runner with compatible sqlite-vec cleanup callbacks and explicit scanner creation prototypes; real insertion and Bash parsing regressions exposed the callback failures first. (done 2026-10-28 00:02 EDT; context: docs/plan_context/sqlite_vec_callback_safety.md)
	- [x] Ship the populated-index, ownership, and callback-safety fixes; exact-commit Mechatron Prime CI and GitHub Actions run 40630870526 pass, including native macOS ARM64 execution. (done 2026-10-28 00:24 EDT; commit 75172eb4)
- [ ] Identify the historical watcher cause only if a new reproducer or underlying SQLite record becomes available; currently blocked on evidence and not on further recollection. (context: docs/plan_context/watcher_sqlite_failures.md)

## After shipping

- [ ] Extend partial signature queries in the selected language order, beginning with the existing partial-signature acceptance example. (decision 2026-10-20)
	- [ ] Resolve the query-syntax choice: native signatures such as Zig `fn ceil(...) f64`, the shared `ceil : -> f64` form, or both; language order is already approved and independent work continues meanwhile.
	- [ ] Add Zig signature-query matching and negative cases, then exercise the actual CLI against indexed Zig fixtures.
	- [ ] Add Rust signature-query matching for functions/methods with type constraints and actual CLI coverage.
	- [ ] Add TypeScript signature-query matching for typed functions/methods with actual CLI coverage.
- [ ] Require FTS5 availability in behavioral regressions instead of silent early returns; current Nix artifacts execute the three formerly skipped scoring cases, and the pinned SQLite build already enables FTS5.

## Validation and performance

- [ ] Attribute and reduce the ReleaseSafe prepared runtime's 6.23-second lower bound, pin the shared profiling adapter, and separate Nix evaluation/setup from execution; retain safety checks and exclusions without widening the five-second budget. (context: docs/plan_context/test_latency.md)
	- [x] Pin the shared profiler and verify monotonic stamps inside the isolated runtime after a missing-tool regression failed; complete Nix and fresh host runners pass without recompiling the CLI or unit artifacts. (done 2026-10-28 00:46 EDT)
- [ ] Add controlled TCP-blackhole/TLS-cancellation fixtures and run request-deadline checks on qualified native macOS/Windows runners; native execution depends on runner availability, not cross-build success.
- [ ] Reproduce watcher heap growth with deterministic event batches and explicit/implicit roots using the shared profiling engine; record allocation ownership before changing it.
- [ ] Test provider-model failure paths for index/provider compatibility and preserved lexical/file operations; ranking-quality comparisons depend on the tabled independently judged corpus.
- [ ] Recover the interrupted reindex sweep's private completion ledger and exact remaining project set before resuming live index writes; do not infer a new all-project sweep.
- [ ] Inventory discovery/search filters lacking set-level tests and add one bounded classifier suite at a time.

## Architecture and features

- [ ] Bring project builds and publication into conformance with the `cross-platform-project-build-arch` convention; inventory products, callers, profiles, and rollback before migration.
	- [ ] Use `macos-arm64`, `linux-amd64`, `linux-arm64`, `mswin-amd64`, and `mswin-arm64` namespaces with separate ABI/profile products; preserve native compiler/Nix identifiers and keep writable outputs separate from retained Nix outputs.
	- [ ] Consolidate legacy `build_all` into thin Nix-required `./build` scope flags/aliases and exact-product `./run`/`./test`; remove direct-build fallbacks and prepare compiled tests through Nix; add canonical-implementation selection only if multiple executable implementations exist.
	- [ ] Publish verified commands in `bin/<PF>/` without runtime selector wrappers; preserve previous selections on failure, serialize publishers, retain runtime resources, support native Windows entrypoints, and coordinate PATH changes separately.
	- [ ] Prove conformance through failing behavioral regressions in `./test`, real binary-header/ABI checks, host/foreign/profile coexistence, and native execution where available; report unavailable target checks without claiming full conformance.
- [ ] Move update database preparation/freshness into the shared service after characterization tests prove CLI/MCP/HTTP behavior remains identical.
- [ ] Extract one CLI command/scorer component at a time behind existing behavioral tests; begin with command orchestration rather than rewriting scoring policy.
- [ ] Add `codescan symbols --depth N` with explicit root-depth, invalid-value, and JSON/human truncation tests.
- [ ] Add lexical fixtures proving camelCase/snake_case cross-matching without unrelated matches, then normalize at the candidate-selection boundary.
- [ ] Migrate one remaining vendored grammar at a time to an exact reproducible source pin, retaining local patches and symbol/range regressions.

## Tabled (not actionable)

- [ ] Evaluate concise I/O wrappers without changing lifetime or concurrency semantics; tabled pending a concrete use case and renewed direction.
- [ ] Specify whole-file/hashline-targeted comment generation with model/language settings, existing-comment protection, dry runs, and explicit overwrite behavior; tabled pending a concrete use case and renewed direction.
- [ ] Establish a versioned relevance corpus with independently judged expected symbols/files and MRR, nDCG, and Recall@k; tabled until those judgments and renewed direction are available.
