# PLAN

Completed work is recorded in docs/PLAN_LOG.md. Earlier planning history remains recoverable in Git; private operational context is retained outside the repository. Execution resumed on 2026-10-30; open items remain ordered below.

## CI completion and maintenance

- [ ] Fix the native Windows ARM64 HTTP-header cancellation hang: 45e8281d reproduces it on process eleven, but SDK startup/attachment exceeds its unqualified 1.5-second capture bound without output; qualify a separate bounded diagnostic budget and obtain thread stacks before choosing a root-cause repair. (context: docs/plan_context/build_conformance.md)
- [x] Verify focused cancellation prerequisites on exact-commit GitHub Actions and Mechatron Prime CI; both pass for c914cbff, including complete native Mac checks, both selected cancellation cases, eight rejection controls, all five release targets, and exactly five nonempty canonical archives. (done 2026-10-31 13:41 EDT; commit c914cbff)
- [x] Finish complete CI verification for cd3002f4; both services and the native Windows workflow pass, including full native Mac checks, actual x64/ARM64 cancellation execution, and exactly five nonempty canonical archives; the later ARM64 hang is tracked separately rather than erasing this result. (done 2026-10-31 14:03 EDT; commit cd3002f4)
- [x] Verify native Linux ARM64 full-suite gating for 8295fd41: the GitHub build workflow and Mechatron Prime CI pass, actual native Linux x64/ARM64 checks finish before all five archives, and the artifact API confirms exactly five nonempty canonical archives; the separate Windows ARM64 runtime failure remains open. (done 2026-10-31 14:21 EDT; commit 8295fd41)
- [x] Verify the complete native macOS suite-before-archive gate and host-independent latency fixture on exact-commit GitHub Actions and Mechatron Prime CI; both pass for 9f4ee1a8, including 804 native macOS unit cases, CLI/MCP/source checks, the repaired fixture, actual ARM64 smoke execution, and exactly five nonempty release archives. (done 2026-10-31 13:13 EDT; commit 9f4ee1a8)
- [x] Verify the Nim source pin and preserved scanner guard on exact-commit Mechatron Prime CI and GitHub Actions; both pass for 0215e1e7, including all five release targets, native macOS smoke checks, and exactly five nonempty canonical archives after fourteen byte-identity checks, 804 passing local unit cases, and actual procedure/range/body controls. (done 2026-10-31 12:36 EDT; commit 0215e1e7)
- [ ] Report the shared profiler's failed-run WITHIN_BUDGET label and verify its repair; contact approval is pending and the failed diagnostic remains ineligible for compliance. (context: docs/plan_context/test_latency.md)
- [ ] Verify the infrastructure owner's build-budget literal-argument repair; the owner acknowledged the request and confirmed the source/installed-helper defect, but implementation remains queued, with the resource envelope and equivalent-syntax workaround unchanged.

## Watcher reliability

- [ ] Reproduce slow MCP semantic search in a disposable fixture with pending freshness work and bounded requests; October 27 root/status calls responded with the watcher stopped, but the historical cause remains unestablished. (context: docs/plan_context/inference_availability.md)
	- [ ] Decide whether pre-search reconciliation should have a total wait budget with lexical fallback while explicit indexing retains cold-model waits; no budget or request-policy change has been selected. (context: docs/plan_context/inference_availability.md)
	- [ ] Decide whether failed incremental embedding should retain new lexical rows as pending work or roll them back; the private fixture grew from four symbols/four vectors to five/four while retaining working search and file reads. (context: docs/plan_context/inference_availability.md)
- [ ] Identify the historical watcher cause only if a new reproducer or underlying SQLite record becomes available; currently blocked on evidence and not on further recollection. (context: docs/plan_context/watcher_sqlite_failures.md)

## Validation and performance

- [ ] Investigate the latest ReleaseSafe host runner's broad slowdown to 15.53 seconds of execution lower bound and 10.37 seconds of flake evaluation, then reduce feedback time; retain prior variation and delayed finalization without accepting a baseline or changing coverage, exclusions, or the five-second budget. (context: docs/plan_context/test_latency.md)
	- [x] Characterize source-copy overlap with one bounded alone/overlap/overlap/alone diagnostic; all four 456-path copies verify, both unit overlaps are real, and copies take 0.79-1.00 seconds without reproducing the earlier 6.38-second span; preserve earlier records, partial scope, and the unresolved broad cause without accepting a baseline or choosing a rewrite. (done 2026-10-31 13:39 EDT; context: docs/plan_context/test_latency.md)
- [ ] Add controlled TCP-blackhole/TLS-cancellation fixtures and run request-deadline checks on qualified native macOS/Windows runners; native execution depends on runner availability, not cross-build success.
	- [x] Prepare isolated native and Windows ARM64/x86_64 cancellation-test artifacts through Nix and verify actual executable headers, both selected cancellation cases, eight rejection controls, nine compiler-concurrency probes, and default-runner integration; complete Nix checks pass all 804 available unit cases with unchanged exclusions. (done 2026-10-31 13:21 EDT)
	- [x] Qualify bounded native Windows ARM64/x86_64 cancellation execution using Nix products, actual OS/PE checks, private process state, and complete non-skipped evidence; both native CI jobs pass both selected tests and qualification controls, without changing the five release archives or claiming TCP-connect-blackhole coverage. (done 2026-10-31 13:39 EDT; commit cd3002f4)
	- [x] Gate Mac archive publication on the complete native Nix test/source checks after the real packager first ignores a controlled failure; exact requests/order, prior archive/staging preservation, host refusal, other targets, and existing payload/smoke controls pass complete Nix checks with 804 unit cases; actual native CI verification remains separate. (done 2026-10-31 12:20 EDT)
- [ ] Reproduce watcher heap growth with deterministic event batches and explicit/implicit roots using the shared profiling engine; shared-service caller-allocator ownership is clean in the bounded fixture, while native watcher, transport, and implicit-root profiling remain open. (context: docs/plan_context/watcher_memory.md)
- [ ] Recover the interrupted reindex sweep's private completion ledger and exact remaining project set before resuming live writes; the available July handoff/static bookkeeping cannot establish the later completion state or authorize a new all-project sweep.

## Architecture and features

- [ ] Bring project builds and publication into conformance with the `cross-platform-project-build-arch` convention; preserve existing products and coordinate PATH cutover separately. (context: docs/plan_context/build_conformance.md)
	- [ ] Use `macos-arm64`, `linux-amd64`, `linux-arm64`, `mswin-amd64`, and `mswin-arm64` namespaces with separate ABI/profile products; preserve native compiler/Nix identifiers and keep writable outputs separate from retained Nix outputs.
	- [ ] Publish verified commands in `bin/<PF>/` without runtime selector wrappers; preserve previous selections on failure, serialize publishers, retain runtime resources, support native Windows entrypoints, and coordinate PATH changes separately.
	- [ ] Prove conformance through failing behavioral regressions in `./test`, real binary-header/ABI checks, host/foreign/profile coexistence, and native execution where available; report unavailable target checks without claiming full conformance.
		- [ ] Finish release CPU/header and static-ELF verification before archive staging, preserving previous archives on rejection; the reproduced packaging gap and implementation are recoverably checkpointed while the Windows ARM64 hang takes priority.
		- [x] Require complete Nix test/source checks on native Linux ARM64 and x86-64 before archive builds after missing-runner and foreign-host regressions; all forty host/request cases and 804 available unit cases pass local complete checks, while actual native ARM64 execution remains separately pending. (done 2026-10-31 13:45 EDT)
- [ ] Move update database preparation/freshness into the shared service after characterization tests prove CLI/MCP/HTTP behavior remains identical.
- [ ] Migrate one remaining vendored grammar at a time to an exact reproducible source pin, retaining local patches and symbol/range regressions.

## Tabled (not actionable)

- [ ] Evaluate concise I/O wrappers without changing lifetime or concurrency semantics; tabled pending a concrete use case and renewed direction.
- [ ] Specify whole-file/hashline-targeted comment generation with model/language settings, existing-comment protection, dry runs, and explicit overwrite behavior; tabled pending a concrete use case and renewed direction.
- [ ] Establish a versioned relevance corpus with independently judged expected symbols/files and MRR, nDCG, and Recall@k; tabled until those judgments and renewed direction are available.
