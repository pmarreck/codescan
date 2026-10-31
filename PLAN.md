# PLAN

Completed work is recorded in docs/PLAN_LOG.md. Earlier planning history remains recoverable in Git; private operational context is retained outside the repository. Execution resumed on 2026-10-30; open items remain ordered below.

## CI completion and maintenance

- [x] Verify identifier-alias matched-field provenance on exact-commit Mechatron Prime CI and GitHub Actions; all five release targets and native macOS smoke checks pass for 01529aab, following 776 passing local unit cases and all matched-field evidence controls. (done 2026-10-31 05:51 EDT; commit 01529aab)
- [x] Verify the build-scope request-adapter refactor on exact-commit Mechatron Prime CI and GitHub Actions; all five release targets and native macOS smoke checks pass for 232f2e73, following 775 passing local unit cases and unchanged scope assertions. (done 2026-10-31 05:43 EDT; commit 232f2e73)
- [ ] Verify source-fixture streaming on exact-commit Mechatron Prime CI and GitHub Actions; complete Nix and fresh confined host/component runs pass 776 unit cases, exact-copy checks, and both pipeline failure controls.
- [ ] Verify exact-product `./run` on exact-commit Mechatron Prime CI and GitHub Actions; complete Nix and fresh confined host checks pass 776 unit cases, all eight new launcher scenarios, and the retained seven build controls.
- [x] Verify consolidated build-scope flags on exact-commit Mechatron Prime CI and GitHub Actions; all five release targets and native macOS smoke checks pass for a4429bdd, following 775 passing local unit cases and all 18 scope/failure/escape scenarios. (done 2026-10-31 05:27 EDT; commit a4429bdd)
- [x] Verify repeated incremental-index ownership characterization on exact-commit Mechatron Prime CI and GitHub Actions; all five release targets and native macOS smoke checks pass for f3fdcdf0, following 775 passing local unit cases and 24 controlled service passes. (done 2026-10-31 05:07 EDT; commit f3fdcdf0)
- [x] Verify lexical identifier candidate normalization and allocation-failure cleanup on exact-commit Mechatron Prime CI and GitHub Actions; all five release targets and native macOS smoke checks pass for 9deaba9a, following 774 passing local unit cases and the candidate-set, CLI, and ownership controls. (done 2026-10-31 05:07 EDT; commit 9deaba9a)
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

- [ ] Reduce the latest ReleaseSafe host runner's 7.16-second execution lower bound and 5.37-second flake-evaluation span; retain safety, coverage, exclusions, and the five-second budget despite substantial host timing variation. (context: docs/plan_context/test_latency.md)
	- [x] Stream source-fixture payloads without a whole-archive scratch file after a failing scratch-limit regression; exact-copy and both pipeline failure controls pass, and the one permitted paired repeat favors streaming under one- and twelve-CPU affinity without a complete budget pass. (done 2026-10-31 05:47 EDT; context: docs/plan_context/test_latency.md)
	- [x] Remove unasserted retained-link simulation from the build-scope request adapter; all 18 controls and assertions remain, complete Nix and fresh host/component checks pass 775 unit cases, and the measured scope span decreases from 0.63 to 0.53 seconds without a complete budget pass. (done 2026-10-31 05:14 EDT; context: docs/plan_context/test_latency.md)
- [ ] Add controlled TCP-blackhole/TLS-cancellation fixtures and run request-deadline checks on qualified native macOS/Windows runners; native execution depends on runner availability, not cross-build success.
- [ ] Reproduce watcher heap growth with deterministic event batches and explicit/implicit roots using the shared profiling engine; shared-service caller-allocator ownership is clean in the bounded fixture, while native watcher, transport, and implicit-root profiling remain open. (context: docs/plan_context/watcher_memory.md)
- [ ] Recover the interrupted reindex sweep's private completion ledger and exact remaining project set before resuming live writes; the available July handoff/static bookkeeping cannot establish the later completion state or authorize a new all-project sweep.

## Architecture and features

- [x] Report matched-field provenance for recognized identifier aliases after a failing real CLI evidence assertion; all 776 unit cases, 20 field classifications, and six CLI query/mode checks pass complete Nix and fresh confined host verification; README defaults now match existing language-filter behavior. (done 2026-10-31 05:27 EDT; context: docs/plan_context/filter_classifiers.md)
- [ ] Bring project builds and publication into conformance with the `cross-platform-project-build-arch` convention; preserve existing products and coordinate PATH cutover separately. (context: docs/plan_context/build_conformance.md)
	- [ ] Use `macos-arm64`, `linux-amd64`, `linux-arm64`, `mswin-amd64`, and `mswin-arm64` namespaces with separate ABI/profile products; preserve native compiler/Nix identifiers and keep writable outputs separate from retained Nix outputs.
	- [ ] Consolidate legacy `build_all` into thin Nix-required `./build` scope flags/aliases and exact-product `./run`/`./test`; remove direct-build fallbacks and prepare compiled tests through Nix; add canonical-implementation selection only if multiple executable implementations exist.
		- [x] Consolidate all-target builds behind independent, idempotent `./build` scope flags after a failing real-wrapper regression; all 18 target/profile, alias, failure-preservation, and retained-parent escape scenarios pass complete Nix and fresh confined host checks; the legacy script is recoverably retired. (done 2026-10-31 05:07 EDT; context: docs/plan_context/build_conformance.md)
		- [x] Add an explicit `./run` after a failing entrypoint regression; all eight launcher controls and a real prepared CLI pass complete Nix and fresh confined host checks, preserving stdin/arguments/caller directory/process identity/status without publication or stale PATH execution. (done 2026-10-31 05:53 EDT; context: docs/plan_context/build_conformance.md)
	- [ ] Publish verified commands in `bin/<PF>/` without runtime selector wrappers; preserve previous selections on failure, serialize publishers, retain runtime resources, support native Windows entrypoints, and coordinate PATH changes separately.
	- [ ] Prove conformance through failing behavioral regressions in `./test`, real binary-header/ABI checks, host/foreign/profile coexistence, and native execution where available; report unavailable target checks without claiming full conformance.
- [ ] Move update database preparation/freshness into the shared service after characterization tests prove CLI/MCP/HTTP behavior remains identical.
- [ ] Extract one CLI command/scorer component at a time behind existing behavioral tests; begin with command orchestration rather than rewriting scoring policy.
- [ ] Add `codescan symbols --depth N` with explicit root-depth, invalid-value, and JSON/human truncation tests.
- [ ] Migrate one remaining vendored grammar at a time to an exact reproducible source pin, retaining local patches and symbol/range regressions.

## Tabled (not actionable)

- [ ] Evaluate concise I/O wrappers without changing lifetime or concurrency semantics; tabled pending a concrete use case and renewed direction.
- [ ] Specify whole-file/hashline-targeted comment generation with model/language settings, existing-comment protection, dry runs, and explicit overwrite behavior; tabled pending a concrete use case and renewed direction.
- [ ] Establish a versioned relevance corpus with independently judged expected symbols/files and MRR, nDCG, and Recall@k; tabled until those judgments and renewed direction are available.
