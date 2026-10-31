# PLAN

Completed work is recorded in docs/PLAN_LOG.md. Earlier planning history remains recoverable in Git; private operational context is retained outside the repository. Execution resumed on 2026-10-30; open items remain ordered below.

## CI completion and maintenance

- [ ] Verify orchestration-count batching and its added mutation controls on exact-commit GitHub Actions and Mechatron Prime CI; complete Nix and fresh confined host checks already pass all available suites with unchanged compiled products.
- [x] Verify f2101093 on GitHub Actions, native Windows, and Mechatron Prime CI; all native Linux/Mac checks, five archive jobs, eight Mechatron targets, and twenty complete five-case processes per Windows architecture pass, with exactly five nonempty canonical archives. (done 2026-10-31 15:50 EDT; commit f2101093)
- [x] Verify the release-header gate for 3c87c5f7 on both CI services: actual Linux/Windows header inspection, native Linux/Mac checks, both twenty-process Windows campaigns, all five archive jobs, and exactly five nonempty canonical archives pass. (done 2026-10-31 16:00 EDT; commit 3c87c5f7)
- [x] Fix the captured native Windows ARM64 hang by closing failed HTTP requests before pool release; the deterministic early-allocation fault first finds one retained connection, complete Nix/fresh isolated host checks pass 807 unit cases, and both native Windows architectures pass twenty complete five-case processes. (done 2026-10-31 15:33 EDT; commit f2101093; context: docs/plan_context/build_conformance.md)
- [x] Verify focused cancellation prerequisites on exact-commit GitHub Actions and Mechatron Prime CI; both pass for c914cbff, including complete native Mac checks, both selected cancellation cases, eight rejection controls, all five release targets, and exactly five nonempty canonical archives. (done 2026-10-31 13:41 EDT; commit c914cbff)
- [x] Finish complete CI verification for cd3002f4; both services and the native Windows workflow pass, including full native Mac checks, actual x64/ARM64 cancellation execution, and exactly five nonempty canonical archives; the later ARM64 hang is tracked separately rather than erasing this result. (done 2026-10-31 14:03 EDT; commit cd3002f4)
- [x] Verify native Linux ARM64 full-suite gating for 8295fd41: the GitHub build workflow and Mechatron Prime CI pass, actual native Linux x64/ARM64 checks finish before all five archives, and the artifact API confirms exactly five nonempty canonical archives; the separate Windows ARM64 runtime failure remains open. (done 2026-10-31 14:21 EDT; commit 8295fd41)
- [ ] Report the shared profiler's failed-run WITHIN_BUDGET label and verify its repair; contact approval is pending and the failed diagnostic remains ineligible for compliance. (context: docs/plan_context/test_latency.md)
- [ ] Verify the infrastructure owner's build-budget literal-argument repair; the owner acknowledged the request and confirmed the source/installed-helper defect, but implementation remains queued, with the resource envelope and equivalent-syntax workaround unchanged.

## Watcher reliability

- [ ] Reproduce slow MCP semantic search in a disposable fixture with pending freshness work and bounded requests; October 27 root/status calls responded with the watcher stopped, but the historical cause remains unestablished. (context: docs/plan_context/inference_availability.md)
	- [ ] Decide whether pre-search reconciliation should have a total wait budget with lexical fallback while explicit indexing retains cold-model waits; no budget or request-policy change has been selected. (context: docs/plan_context/inference_availability.md)
	- [ ] Decide whether failed incremental embedding should retain new lexical rows as pending work or roll them back; the private fixture grew from four symbols/four vectors to five/four while retaining working search and file reads. (context: docs/plan_context/inference_availability.md)
- [ ] Identify the historical watcher cause only if a new reproducer or underlying SQLite record becomes available; currently blocked on evidence and not on further recollection. (context: docs/plan_context/watcher_sqlite_failures.md)

## Validation and performance

- [ ] Investigate broad ReleaseSafe host-runner variation: the latest 6.91-second execution lower bound and 3.60-second evaluation contrast with 20.14/10.34 seconds earlier; retain all observations and the unresolved cause without attributing the entire change to count batching, accepting a baseline, or changing coverage/exclusions/budgets. (context: docs/plan_context/test_latency.md)
	- [x] Reject cross-system Nix source hoisting after the fixed A/B/B/A diagnostic: all 33 package identities match and all eight one/twelve-core evaluations pass, but no gain is demonstrated; restore the original flake byte-for-byte and preserve partial-scope records without accepting a baseline. (done 2026-10-31 15:50 EDT; context: docs/plan_context/test_latency.md)
	- [x] Batch orchestration-fixture call counts into one AWK pass after 21 missing/duplicate/copy-failure controls first validate the original logic; all sixteen barrier/error scenarios remain, both pinned-core A/B/B/A comparisons favor one pass, and complete Nix checks pass 807 unit cases. (done 2026-10-31 16:00 EDT; context: docs/plan_context/test_latency.md)
- [ ] Add controlled TCP-blackhole/TLS-cancellation fixtures and run request-deadline checks on qualified native macOS/Windows runners; native execution depends on runner availability, not cross-build success.
- [ ] Reproduce watcher heap growth with deterministic event batches and explicit/implicit roots using the shared profiling engine; shared-service caller-allocator ownership is clean in the bounded fixture, while native watcher, transport, and implicit-root profiling remain open. (context: docs/plan_context/watcher_memory.md)
- [ ] Recover the interrupted reindex sweep's private completion ledger and exact remaining project set before resuming live writes; the available July handoff/static bookkeeping cannot establish the later completion state or authorize a new all-project sweep.

## Architecture and features

- [ ] Bring project builds and publication into conformance with the `cross-platform-project-build-arch` convention; preserve existing products and coordinate PATH cutover separately. (context: docs/plan_context/build_conformance.md)
	- [ ] Use `macos-arm64`, `linux-amd64`, `linux-arm64`, `mswin-amd64`, and `mswin-arm64` namespaces with separate ABI/profile products; preserve native compiler/Nix identifiers and keep writable outputs separate from retained Nix outputs.
	- [ ] Publish verified commands in `bin/<PF>/` without runtime selector wrappers; preserve previous selections on failure, serialize publishers, retain runtime resources, support native Windows entrypoints, and coordinate PATH changes separately.
	- [ ] Prove conformance through failing behavioral regressions in `./test`, real binary-header/ABI checks, host/foreign/profile coexistence, and native execution where available; report unavailable target checks without claiming full conformance.
		- [x] Verify release CPU/format and static ELF before archive staging, preserving prior archives on rejection; 120 header/target pairs, actual native CLI discrimination, filesystem/reader/arity controls, and complete Nix checks pass 807 unit cases; exact-commit CI remains separate. (done 2026-10-31 15:36 EDT; context: docs/plan_context/build_conformance.md)
		- [x] Require complete Nix test/source checks on native Linux ARM64 and x86-64 before archive builds after missing-runner and foreign-host regressions; all forty host/request cases and 804 available unit cases pass local complete checks, while actual native ARM64 execution remains separately pending. (done 2026-10-31 13:45 EDT)
- [ ] Move update database preparation/freshness into the shared service after characterization tests prove CLI/MCP/HTTP behavior remains identical.
- [ ] Migrate one remaining vendored grammar at a time to an exact reproducible source pin, retaining local patches and symbol/range regressions.

## Tabled (not actionable)

- [ ] Evaluate concise I/O wrappers without changing lifetime or concurrency semantics; tabled pending a concrete use case and renewed direction.
- [ ] Specify whole-file/hashline-targeted comment generation with model/language settings, existing-comment protection, dry runs, and explicit overwrite behavior; tabled pending a concrete use case and renewed direction.
- [ ] Establish a versioned relevance corpus with independently judged expected symbols/files and MRR, nDCG, and Recall@k; tabled until those judgments and renewed direction are available.
