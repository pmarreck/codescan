# PLAN

Completed work is recorded in docs/PLAN_LOG.md. Earlier planning history remains recoverable in Git; private operational context is retained outside the repository. Execution resumed on 2026-10-30; open items remain ordered below.

## CI completion and maintenance

- [ ] Verify the complete native macOS suite-before-archive gate on exact-commit GitHub Actions and Mechatron Prime CI after its failing real-packager regression and 804 passing local Nix unit cases; do not equate local request-port checks with native execution.
- [ ] Verify the Nim source pin and preserved scanner guard on exact-commit Mechatron Prime CI and GitHub Actions, including all five builds/archives after fourteen byte-identity checks, 804 passing local unit cases, and actual procedure/range/body controls.
- [x] Verify the byte-identical Lean grammar pin and recoverable source retirement on exact-commit Mechatron Prime CI and GitHub Actions; both pass for 6be8c117, including all five release builds, native macOS smoke checks, and exactly five nonempty canonical archives after 804 passing local unit cases and actual definition/range/body controls. (done 2026-10-31 12:04 EDT; commit 6be8c117)
- [x] Verify match-relative symbols depth and parser error cleanup on exact-commit Mechatron Prime CI and GitHub Actions; both pass for 3dca2123, including all five release builds, native macOS smoke checks, and exactly five nonempty canonical archives after 804 passing local unit cases and actual CLI/MCP controls. (done 2026-10-31 11:32 EDT; commit 3dca2123)
- [x] Verify native/shared TypeScript signature queries and mixed-language isolation on exact-commit Mechatron Prime CI and GitHub Actions; both pass for 88ae2a2e, including all five release targets, native macOS smoke checks, and five nonempty canonical archives after 795 passing local unit cases and fourteen actual CLI forms. (done 2026-10-31 10:35 EDT; commit 88ae2a2e)
- [x] Verify native/shared Rust signature queries on exact-commit Mechatron Prime CI and GitHub Actions; both pass for d9c166a3, including all five release targets, native macOS smoke checks, and five nonempty canonical archives after 790 passing local unit cases and ten actual CLI queries. (done 2026-10-31 09:45 EDT; commit d9c166a3)
- [x] Verify native/shared Zig signature queries on exact-commit Mechatron Prime CI and GitHub Actions; both pass for 5fe609d2, including all five release targets, native macOS smoke checks, and five nonempty canonical archives after 784 passing local unit cases and the original CLI failure. (done 2026-10-31 09:23 EDT; commit 5fe609d2)
- [ ] Report the shared profiler's failed-run WITHIN_BUDGET label and verify its repair; contact approval is pending and the failed diagnostic remains ineligible for compliance. (context: docs/plan_context/test_latency.md)
- [ ] Verify the infrastructure owner's build-budget literal-argument repair; the owner acknowledged the request and confirmed the source/installed-helper defect, but implementation remains queued, with the resource envelope and equivalent-syntax workaround unchanged.

## Watcher reliability

- [ ] Reproduce slow MCP semantic search in a disposable fixture with pending freshness work and bounded requests; October 27 root/status calls responded with the watcher stopped, but the historical cause remains unestablished. (context: docs/plan_context/inference_availability.md)
	- [ ] Decide whether pre-search reconciliation should have a total wait budget with lexical fallback while explicit indexing retains cold-model waits; no budget or request-policy change has been selected. (context: docs/plan_context/inference_availability.md)
	- [ ] Decide whether failed incremental embedding should retain new lexical rows as pending work or roll them back; the private fixture grew from four symbols/four vectors to five/four while retaining working search and file reads. (context: docs/plan_context/inference_availability.md)
- [ ] Identify the historical watcher cause only if a new reproducer or underlying SQLite record becomes available; currently blocked on evidence and not on further recollection. (context: docs/plan_context/watcher_sqlite_failures.md)

## After shipping

- [x] Extend partial signature queries through the approved Zig, Rust, then TypeScript order, with native/shared forms, explicit declaration constraints, mixed-language sets, and inference-free actual CLI coverage; complete Nix/fresh confined host checks pass 795 unit cases, with exact TypeScript CI verification tracked separately. (done 2026-10-31 10:06 EDT)
	- [x] Resolve the signature-query syntax choice; Answer: accept both native language signatures and the shared Roc-style form, preserving the approved Zig, Rust, then TypeScript implementation order. (done 2026-10-31 08:41 EDT)
	- [x] Add native/shared Zig signature queries after failing recognition and actual CLI regressions; complete Nix/fresh confined host checks pass 784 unit cases, exact declaration sets, nested types, qualifiers, name boundaries, and seven actual CLI query forms without inference or live-index changes. (done 2026-10-31 09:10 EDT)
	- [x] Add native/shared Rust signature queries for functions/methods with explicit generic/where constraints, receivers, lifetimes, nested types, and actual CLI coverage after failing regressions; complete Nix/fresh confined host checks pass 790 unit cases without inference or live-index changes. (done 2026-10-31 09:31 EDT)
	- [x] Add native/shared TypeScript signature queries for annotated functions/methods after recognition, empty-result, and explicit-input comparison-default failures; 795 unit cases and fourteen CLI query forms cover mixed-language sets, native isolation, generic/parameter shape, and missing-annotation refusal without live-index changes. (done 2026-10-31 10:06 EDT)

## Validation and performance

- [ ] Investigate the latest ReleaseSafe host runner's broad slowdown to 15.53 seconds of execution lower bound and 10.37 seconds of flake evaluation, then reduce feedback time; retain prior variation and delayed finalization without accepting a baseline or changing coverage, exclusions, or the five-second budget. (context: docs/plan_context/test_latency.md)
- [ ] Add controlled TCP-blackhole/TLS-cancellation fixtures and run request-deadline checks on qualified native macOS/Windows runners; native execution depends on runner availability, not cross-build success.
	- [x] Gate Mac archive publication on the complete native Nix test/source checks after the real packager first ignores a controlled failure; exact requests/order, prior archive/staging preservation, host refusal, other targets, and existing payload/smoke controls pass complete Nix checks with 804 unit cases; actual native CI verification remains separate. (done 2026-10-31 12:20 EDT)
- [ ] Reproduce watcher heap growth with deterministic event batches and explicit/implicit roots using the shared profiling engine; shared-service caller-allocator ownership is clean in the bounded fixture, while native watcher, transport, and implicit-root profiling remain open. (context: docs/plan_context/watcher_memory.md)
- [ ] Recover the interrupted reindex sweep's private completion ledger and exact remaining project set before resuming live writes; the available July handoff/static bookkeeping cannot establish the later completion state or authorize a new all-project sweep.

## Architecture and features

- [ ] Bring project builds and publication into conformance with the `cross-platform-project-build-arch` convention; preserve existing products and coordinate PATH cutover separately. (context: docs/plan_context/build_conformance.md)
	- [ ] Use `macos-arm64`, `linux-amd64`, `linux-arm64`, `mswin-amd64`, and `mswin-arm64` namespaces with separate ABI/profile products; preserve native compiler/Nix identifiers and keep writable outputs separate from retained Nix outputs.
	- [ ] Publish verified commands in `bin/<PF>/` without runtime selector wrappers; preserve previous selections on failure, serialize publishers, retain runtime resources, support native Windows entrypoints, and coordinate PATH changes separately.
	- [ ] Prove conformance through failing behavioral regressions in `./test`, real binary-header/ABI checks, host/foreign/profile coexistence, and native execution where available; report unavailable target checks without claiming full conformance.
- [ ] Move update database preparation/freshness into the shared service after characterization tests prove CLI/MCP/HTTP behavior remains identical.
- [x] Add `codescan symbols --depth N` with match-relative child expansion and preserved deep lookup, bodies, and hashes; failing parser/rendering/MCP controls drive the implementation and allocation cleanup, then complete Nix/fresh confined host checks pass 804 unit cases and actual CLI/MCP sessions. (done 2026-10-31 11:15 EDT)
	- [x] Resolve symbols depth semantics; Answer: match-relative depth preserves deep name lookup, depth 0 returns a matched symbol without children, and depth 1 includes its immediate children. (done 2026-10-31 08:41 EDT)
- [ ] Migrate one remaining vendored grammar at a time to an exact reproducible source pin, retaining local patches and symbol/range regressions.
	- [x] Pin the existing Nim grammar at 9b4ede21 with its scanner guard preserved explicitly after source-boundary and unpatched-identity failures; fourteen files match byte-for-byte, attribution stays unchanged, seven source copies retire recoverably, and complete Nix/fresh host checks pass 804 unit cases plus exact CLI controls. (done 2026-10-31 12:04 EDT)
	- [x] Pin the byte-identical Lean grammar at efe6b871 after a failing source-boundary control; retire five source copies recoverably, preserve the original license, and pass complete Nix/fresh confined host checks with 804 unit cases and exact CLI definition/range/body controls. (done 2026-10-31 11:32 EDT)

## Tabled (not actionable)

- [ ] Evaluate concise I/O wrappers without changing lifetime or concurrency semantics; tabled pending a concrete use case and renewed direction.
- [ ] Specify whole-file/hashline-targeted comment generation with model/language settings, existing-comment protection, dry runs, and explicit overwrite behavior; tabled pending a concrete use case and renewed direction.
- [ ] Establish a versioned relevance corpus with independently judged expected symbols/files and MRR, nDCG, and Recall@k; tabled until those judgments and renewed direction are available.
