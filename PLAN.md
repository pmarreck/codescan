# PLAN

Completed work is recorded in docs/PLAN_LOG.md. Earlier planning history remains recoverable in Git; private operational context is retained outside the repository.

## CI completion and maintenance

- [ ] Verify the FTS prerequisite and real-socket cancellation shipments on exact-commit Mechatron Prime CI and GitHub Actions; FTS commit 591c07a8 is pushed and its GitHub test job passes.
- [x] Repair the native macOS profiler-fixture failure without disabling checks; Mechatron Prime CI and GitHub Actions run 40638927693 pass, including native macOS ARM64 build/header/about execution. (done 2026-10-28 01:52 EDT; commit 784da056; context: docs/plan_context/test_latency.md)
- [x] Send the approved Nix tokenizer repair request through durable inbox and native delivery; the owning agent acknowledged acceptance and failing-first validation, with unsafe-path and staged/worktree controls retained. (done 2026-10-28 00:25 EDT; context: docs/plan_context/staged_dependency_parser.md)
- [x] Verify the shared tokenizer repair in 9c935fb: the exact installed blob accepts escaped cache interpolation, rejects unsafe dependencies, and honors staged content in both disagreement directions inside a disposable consumer fixture. (done 2026-10-28 02:36 EDT; context: docs/plan_context/staged_dependency_parser.md)
- [x] Verify the profiler-pin shipment on exact-commit Mechatron Prime CI and GitHub Actions run 40634162232, including native macOS ARM64 build/header/about execution. (done 2026-10-28 00:58 EDT; commit b7dc4595)
- [ ] Report the shared profiler's failed-run WITHIN_BUDGET label and verify its repair; contact approval is pending and the failed diagnostic remains ineligible for compliance. (context: docs/plan_context/test_latency.md)

## Watcher reliability

- [ ] Reproduce slow MCP semantic search in a disposable fixture with pending freshness work and bounded requests; live root/status calls respond, the watcher is stopped, and pre-search reconciliation is a candidate for the October 27 delay, not an established cause.
	- [x] Preserve inference-unavailable advice after a reachable server rejects embeddings; complete Nix/fresh host checks pass 754 unit cases, and exact-commit Mechatron Prime CI plus GitHub Actions run 40644259465 pass, including native macOS CLI smoke checks. (done 2026-10-28 02:49 EDT; commit 28602f00; context: docs/plan_context/inference_availability.md)
	- [ ] Decide whether failed incremental embedding should retain new lexical rows as pending work or roll them back; the private fixture grew from four symbols/four vectors to five/four while retaining working search and file reads. (context: docs/plan_context/inference_availability.md)
- [x] Finish SQLite watcher diagnostics across controlled open/write/read/cursor failures while preserving the index and retry policy; complete Linux Nix/fresh host checks, five-target builds, and native macOS CLI smoke checks pass. (done 2026-10-28 01:52 EDT; commit 784da056; context: docs/plan_context/watcher_sqlite_failures.md)
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
- [x] Require FTS5 in all seven dependent scoring regressions instead of silently returning or skipping; the complete Nix check passes 754 unit cases with the pinned FTS5-enabled SQLite. (done 2026-10-28 03:04 EDT)

## Validation and performance

- [ ] Attribute and reduce the ReleaseSafe prepared runtime's 6.23-second lower bound, pin the shared profiling adapter, and separate Nix evaluation/setup from execution; retain safety checks and exclusions without widening the five-second budget. (context: docs/plan_context/test_latency.md)
	- [x] Overlap unit execution with source-fixture preparation after a FIFO-barrier regression failed on the old runner; copy and lane failures remain checked, and fresh prepared runtime measured 4.51 seconds with unchanged exclusions. (done 2026-10-28 01:34 EDT; context: docs/plan_context/test_latency.md)
	- [x] Pin the shared profiler and verify monotonic stamps inside the isolated runtime after a missing-tool regression failed; complete Nix and fresh host runners pass without recompiling the CLI or unit artifacts. (done 2026-10-28 00:46 EDT)
- [ ] Add controlled TCP-blackhole/TLS-cancellation fixtures and run request-deadline checks on qualified native macOS/Windows runners; native execution depends on runner availability, not cross-build success.
	- [x] Bound the unit process independently and verify real held HTTP/TLS exchanges close and join on cancellation; the complete Linux Nix check passes 755 unit cases without changing cold-model request policy. (done 2026-10-28 03:15 EDT; context: docs/plan_context/request_deadlines.md)
- [ ] Reproduce watcher heap growth with deterministic event batches and explicit/implicit roots using the shared profiling engine; record allocation ownership before changing it.
- [ ] Test provider-model failure paths for index/provider compatibility and preserved lexical/file operations; ranking-quality comparisons depend on the tabled independently judged corpus.
- [ ] Recover the interrupted reindex sweep's private completion ledger and exact remaining project set before resuming live index writes; do not infer a new all-project sweep.
- [ ] Test standalone search-path restrictions over mixed candidate sets in every search mode, then cover the remaining inventoried discovery/search classifiers one bounded suite at a time. (context: docs/plan_context/filter_classifiers.md)

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
