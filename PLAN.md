# PLAN

Completed work is recorded in docs/PLAN_LOG.md. Earlier planning history remains recoverable in Git; private operational context is retained outside the repository. Execution resumed on 2026-10-30; open items remain ordered below.

## CI completion and maintenance

- [ ] Verify consolidated build-scope flags on exact-commit Mechatron Prime CI and GitHub Actions; complete Nix and fresh confined host checks pass 775 unit cases and all 18 behavioral target/profile, alias, failure-preservation, and output-escape scenarios.
- [x] Verify repeated incremental-index ownership characterization on exact-commit Mechatron Prime CI and GitHub Actions; all five release targets and native macOS smoke checks pass for f3fdcdf0, following 775 passing local unit cases and 24 controlled service passes. (done 2026-10-31 05:07 EDT; commit f3fdcdf0)
- [x] Verify lexical identifier candidate normalization and allocation-failure cleanup on exact-commit Mechatron Prime CI and GitHub Actions; all five release targets and native macOS smoke checks pass for 9deaba9a, following 774 passing local unit cases and the candidate-set, CLI, and ownership controls. (done 2026-10-31 05:07 EDT; commit 9deaba9a)
- [x] Verify packaging-suite lane reuse on exact-commit Mechatron Prime CI and GitHub Actions; all five release targets and native macOS smoke checks pass for 1532513d, following 772 passing local unit cases and all 16 scheduling/failure scenarios. (done 2026-10-31 04:27 EDT; commit 1532513d)
- [x] Verify automatic symbol-discovery root handling on exact-commit Mechatron Prime CI and GitHub Actions; all five release targets and native macOS smoke checks pass for 370067d9, following 772 passing local unit cases and actual CLI/MCP discovery controls. (done 2026-10-31 04:27 EDT; commit 370067d9)
- [x] Verify shared scanner ignore preparation and allocation-failure cleanup on exact-commit Mechatron Prime CI and GitHub Actions; all five release targets and native macOS smoke checks pass for aef038b1, following 771 passing local unit cases and 2,050 paired CLI output checks. (done 2026-10-31 04:07 EDT; commit aef038b1)
- [ ] Report the shared profiler's failed-run WITHIN_BUDGET label and verify its repair; contact approval is pending and the failed diagnostic remains ineligible for compliance. (context: docs/plan_context/test_latency.md)
- [ ] Report shared build-budget literal-argument expansion to its owner once contact is approved; systemd-run expands Bash parameter expressions before launch, and diagnostic commands currently avoid those expressions without bypassing resource limits.

## Watcher reliability

- [ ] Reproduce slow MCP semantic search in a disposable fixture with pending freshness work and bounded requests; October 27 root/status calls responded with the watcher stopped, but the historical cause remains unestablished. (context: docs/plan_context/inference_availability.md)
	- [ ] Decide whether pre-search reconciliation should have a total wait budget with lexical fallback while explicit indexing retains cold-model waits; no budget or request-policy change has been selected. (context: docs/plan_context/inference_availability.md)
	- [ ] Decide whether failed incremental embedding should retain new lexical rows as pending work or roll them back; the private fixture grew from four symbols/four vectors to five/four while retaining working search and file reads. (context: docs/plan_context/inference_availability.md)
- [ ] Identify the historical watcher cause only if a new reproducer or underlying SQLite record becomes available; currently blocked on evidence and not on further recollection. (context: docs/plan_context/watcher_sqlite_failures.md)

## After shipping

- [ ] Extend partial signature queries in the selected language order, beginning with the existing partial-signature acceptance example. (decision 2026-10-20)
	- [ ] Resolve the query-syntax choice: native signatures such as Zig `fn ceil(...) f64`, the shared `ceil : -> f64` form, or both; language order is already approved and independent work continues meanwhile.
	- [ ] Add Zig signature-query matching and negative cases, then exercise the actual CLI against indexed Zig fixtures.
	- [ ] Add Rust signature-query matching for functions/methods with type constraints and actual CLI coverage.
	- [ ] Add TypeScript signature-query matching for typed functions/methods with actual CLI coverage.

## Validation and performance

- [ ] Reduce the latest ReleaseSafe host runner's 6.43-second execution lower bound and 5.42-second flake-evaluation span; retain safety, coverage, exclusions, and the five-second budget despite substantial host timing variation. (context: docs/plan_context/test_latency.md)
	- [x] Move CI architecture/publication into the freed unit lane after a failing FIFO-overlap regression; all 16 scheduling/failure scenarios and 772 unit cases pass, with 4.53-second component elapsed execution and a retained two-suite limit. (done 2026-10-31 04:12 EDT; context: docs/plan_context/test_latency.md)
- [ ] Add controlled TCP-blackhole/TLS-cancellation fixtures and run request-deadline checks on qualified native macOS/Windows runners; native execution depends on runner availability, not cross-build success.
- [ ] Reproduce watcher heap growth with deterministic event batches and explicit/implicit roots using the shared profiling engine; shared-service caller-allocator ownership is clean in the bounded fixture, while native watcher, transport, and implicit-root profiling remain open. (context: docs/plan_context/watcher_memory.md)
	- [x] Characterize repeated add/modify/no-op/delete indexing through absolute and relative roots; all 24 passes have exact SQLite/vector effects, embedding request counts, and zero unowned caller-allocator bytes; complete Nix and fresh confined host checks pass 775 unit cases without a production change. (done 2026-10-31 04:46 EDT; context: docs/plan_context/watcher_memory.md)
- [ ] Recover the interrupted reindex sweep's private completion ledger and exact remaining project set before resuming live writes; the available July handoff/static bookkeeping cannot establish the later completion state or authorize a new all-project sweep.

## Architecture and features

- [x] Resolve automatically discovered symbol files against the supplied root; CLI and MCP regressions first returned empty results outside that root, then complete Nix and fresh confined host checks passed 772 unit cases and absolute/relative root controls. (done 2026-10-31 04:07 EDT; context: docs/plan_context/inference_availability.md)
- [ ] Bring project builds and publication into conformance with the `cross-platform-project-build-arch` convention; preserve existing products and coordinate PATH cutover separately. (context: docs/plan_context/build_conformance.md)
	- [ ] Use `macos-arm64`, `linux-amd64`, `linux-arm64`, `mswin-amd64`, and `mswin-arm64` namespaces with separate ABI/profile products; preserve native compiler/Nix identifiers and keep writable outputs separate from retained Nix outputs.
	- [ ] Consolidate legacy `build_all` into thin Nix-required `./build` scope flags/aliases and exact-product `./run`/`./test`; remove direct-build fallbacks and prepare compiled tests through Nix; add canonical-implementation selection only if multiple executable implementations exist.
		- [x] Consolidate all-target builds behind independent, idempotent `./build` scope flags after a failing real-wrapper regression; all 18 target/profile, alias, failure-preservation, and retained-parent escape scenarios pass complete Nix and fresh confined host checks; the legacy script is recoverably retired. (done 2026-10-31 05:07 EDT; context: docs/plan_context/build_conformance.md)
	- [ ] Publish verified commands in `bin/<PF>/` without runtime selector wrappers; preserve previous selections on failure, serialize publishers, retain runtime resources, support native Windows entrypoints, and coordinate PATH changes separately.
	- [ ] Prove conformance through failing behavioral regressions in `./test`, real binary-header/ABI checks, host/foreign/profile coexistence, and native execution where available; report unavailable target checks without claiming full conformance.
- [ ] Move update database preparation/freshness into the shared service after characterization tests prove CLI/MCP/HTTP behavior remains identical.
- [ ] Extract one CLI command/scorer component at a time behind existing behavioral tests; begin with command orchestration rather than rewriting scoring policy.
- [ ] Add `codescan symbols --depth N` with explicit root-depth, invalid-value, and JSON/human truncation tests.
- [x] Normalize camelCase/snake_case identifier candidates in FTS and SQL fallback after failing set/CLI regressions; all 774 unit cases, 132 membership decisions, four comment-only controls, six CLI lookups, and allocation-failure cleanup pass complete Nix and fresh confined host checks. (done 2026-10-31 04:37 EDT; context: docs/plan_context/filter_classifiers.md)
- [ ] Migrate one remaining vendored grammar at a time to an exact reproducible source pin, retaining local patches and symbol/range regressions.

## Tabled (not actionable)

- [ ] Evaluate concise I/O wrappers without changing lifetime or concurrency semantics; tabled pending a concrete use case and renewed direction.
- [ ] Specify whole-file/hashline-targeted comment generation with model/language settings, existing-comment protection, dry runs, and explicit overwrite behavior; tabled pending a concrete use case and renewed direction.
- [ ] Establish a versioned relevance corpus with independently judged expected symbols/files and MRR, nDCG, and Recall@k; tabled until those judgments and renewed direction are available.
