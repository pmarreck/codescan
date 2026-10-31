# PLAN

Completed work is recorded in docs/PLAN_LOG.md. Earlier planning history remains recoverable in Git; private operational context is retained outside the repository. Execution resumed on 2026-10-30; open items remain ordered below.

## CI completion and maintenance

- [x] Verify source-fixture streaming on exact-commit Mechatron Prime CI and GitHub Actions; all five release targets and native macOS smoke checks pass for c53ae6c6, following 776 passing local unit cases, exact-copy checks, and both pipeline failure controls. (done 2026-10-31 06:03 EDT; commit c53ae6c6)
- [x] Verify exact-product `./run` on exact-commit Mechatron Prime CI and GitHub Actions; all five release targets and native macOS smoke checks pass for 5b4aee34, following 776 passing local unit cases, all eight launcher scenarios, and seven retained build controls. (done 2026-10-31 06:10 EDT; commit 5b4aee34)
- [x] Verify overlapping cache-inheritance checks on exact-commit Mechatron Prime CI and GitHub Actions; all five release targets and native macOS smoke checks pass for 456d7192, following 776 passing local unit cases, both real shell assertions, and all three barrier/failure/join scenarios. (done 2026-10-31 06:26 EDT; commit 456d7192)
- [x] Verify the byte-identical C grammar source pin on exact-commit Mechatron Prime CI and GitHub Actions; all five release targets and native macOS smoke checks pass for 522d5f49, following 776 passing local unit cases, the source-boundary classifier, and old/new CLI range/body controls. (done 2026-10-31 06:42 EDT; commit 522d5f49)
- [x] Verify redundant C-source retirement on exact-commit Mechatron Prime CI and GitHub Actions; all five release targets and native macOS smoke checks pass for 34d4176b, with all 24 package identities unchanged, 776 passing local unit cases, and attribution retained. (done 2026-10-31 06:42 EDT; commit 34d4176b)
- [ ] Verify shared CLI/MCP root JSON reporting on exact-commit Mechatron Prime CI and GitHub Actions; complete Nix and fresh confined host checks pass 778 unit cases, all 20 path/state/adapter cases, and allocation-failure cleanup.
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

- [ ] Reduce the latest ReleaseSafe host runner's 5.46-second execution lower bound and 3.92-second flake-evaluation span; retain the earlier broad 18.01-second host/19.13-second component observations without accepting a baseline or changing coverage, exclusions, or the five-second budget. (context: docs/plan_context/test_latency.md)
	- [x] Overlap the two independent real Nix cache-inheritance checks after a failing FIFO-barrier regression; both real assertions and all three failure/join controls pass, and paired real checks favor overlap under one- and twelve-CPU affinity without a complete budget pass. (done 2026-10-31 06:04 EDT; context: docs/plan_context/test_latency.md)
- [ ] Add controlled TCP-blackhole/TLS-cancellation fixtures and run request-deadline checks on qualified native macOS/Windows runners; native execution depends on runner availability, not cross-build success.
- [ ] Reproduce watcher heap growth with deterministic event batches and explicit/implicit roots using the shared profiling engine; shared-service caller-allocator ownership is clean in the bounded fixture, while native watcher, transport, and implicit-root profiling remain open. (context: docs/plan_context/watcher_memory.md)
- [ ] Recover the interrupted reindex sweep's private completion ledger and exact remaining project set before resuming live writes; the available July handoff/static bookkeeping cannot establish the later completion state or authorize a new all-project sweep.

## Architecture and features

- [ ] Bring project builds and publication into conformance with the `cross-platform-project-build-arch` convention; preserve existing products and coordinate PATH cutover separately. (context: docs/plan_context/build_conformance.md)
	- [ ] Use `macos-arm64`, `linux-amd64`, `linux-arm64`, `mswin-amd64`, and `mswin-arm64` namespaces with separate ABI/profile products; preserve native compiler/Nix identifiers and keep writable outputs separate from retained Nix outputs.
	- [ ] Consolidate legacy `build_all` into thin Nix-required `./build` scope flags/aliases and exact-product `./run`/`./test`; remove direct-build fallbacks and prepare compiled tests through Nix; add canonical-implementation selection only if multiple executable implementations exist.
		- [x] Add an explicit `./run` after a failing entrypoint regression; all eight launcher controls and a real prepared CLI pass complete Nix and fresh confined host checks, preserving stdin/arguments/caller directory/process identity/status without publication or stale PATH execution. (done 2026-10-31 05:53 EDT; context: docs/plan_context/build_conformance.md)
	- [ ] Publish verified commands in `bin/<PF>/` without runtime selector wrappers; preserve previous selections on failure, serialize publishers, retain runtime resources, support native Windows entrypoints, and coordinate PATH changes separately.
	- [ ] Prove conformance through failing behavioral regressions in `./test`, real binary-header/ABI checks, host/foreign/profile coexistence, and native execution where available; report unavailable target checks without claiming full conformance.
- [ ] Move update database preparation/freshness into the shared service after characterization tests prove CLI/MCP/HTTP behavior remains identical.
- [ ] Extract one CLI command/scorer component at a time behind existing behavioral tests; begin with command orchestration rather than rewriting scoring policy.
	- [x] Fix CLI/MCP root JSON after independent actual-adapter failures on quoted paths; a shared pure renderer passes all 20 path/state/adapter cases, metadata and allocation-failure controls, complete Nix, and fresh confined host checks with 778 passing unit cases. (done 2026-10-31 06:44 EDT; context: docs/plan_context/inference_availability.md)
- [ ] Add `codescan symbols --depth N` with explicit root-depth, invalid-value, and JSON/human truncation tests.
	- [ ] Resolve whether depth is relative to matched symbols with child expansion or an absolute file-root limit that also excludes deeper name matches; existing design text lists the flag without defining its semantics, and independent work continues pending the answer.
- [ ] Migrate one remaining vendored grammar at a time to an exact reproducible source pin, retaining local patches and symbol/range regressions.
	- [x] Pin the C grammar to byte-identical upstream revision 7fa1be1b after a failing source-closure classifier; legacy parser files cannot enter compiled inputs, attribution remains tracked, and complete Nix/fresh confined host checks pass 776 unit cases plus old/new CLI range/body controls. (done 2026-10-31 06:15 EDT; context: docs/plan_context/build_conformance.md)
	- [x] Retire four unused C parser/header copies recoverably from pushed commit 522d5f49 while retaining the unchanged license; all 24 package derivation identities remain identical and complete Nix/fresh host/component checks pass 776 unit cases. (done 2026-10-31 06:26 EDT; context: docs/plan_context/build_conformance.md)

## Tabled (not actionable)

- [ ] Evaluate concise I/O wrappers without changing lifetime or concurrency semantics; tabled pending a concrete use case and renewed direction.
- [ ] Specify whole-file/hashline-targeted comment generation with model/language settings, existing-comment protection, dry runs, and explicit overwrite behavior; tabled pending a concrete use case and renewed direction.
- [ ] Establish a versioned relevance corpus with independently judged expected symbols/files and MRR, nDCG, and Recall@k; tabled until those judgments and renewed direction are available.
