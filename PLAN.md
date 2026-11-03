# PLAN

Completed work is recorded in docs/PLAN_LOG.md. Earlier planning history remains recoverable in Git; private operational context is retained outside the repository. Execution resumed on 2026-10-30; open items remain ordered below.

## CI completion and maintenance

- [x] Verify native header preflight on exact-commit CI: complete native Linux/Mac suites, both native Windows aggregate reports and twenty-process cancellation campaigns, all eight Mechatron targets, and exactly five nonempty release archives pass. (done 2026-11-02 23:08 EST; commit 8b7af814)
- [x] Verify aggregate Windows qualification for 4081fc92: both complete native reports, both twenty-process cancellation campaigns, full native Linux/Mac checks, all eight Mechatron targets, and five canonical archives pass; one targeted dependency-download retry preserves the original failure evidence. (done 2026-11-02 21:28 EST; commit 4081fc92)
- [x] Verify ac9c918d on both CI services: complete native Linux/Mac checks, twenty complete five-case Windows processes per architecture, all eight Mechatron targets, and exactly five nonempty canonical archives pass. (done 2026-11-02 15:11 EST; commit ac9c918d)
- [x] Verify 2756e817 on both CI services: native Lua source checks and complete native Linux/Mac checks, twenty complete five-case Windows processes per architecture, all eight Mechatron targets, and exactly five nonempty canonical archives pass. (done 2026-11-02 15:11 EST; commit 2756e817)
- [ ] Report the shared profiler's failed-run WITHIN_BUDGET label and verify its repair; contact approval is pending and the failed diagnostic remains ineligible for compliance. (context: docs/plan_context/test_latency.md)
- [ ] Verify the infrastructure owner's build-budget literal-argument repair; the owner acknowledged the request and confirmed the source/installed-helper defect, but implementation remains queued, with the resource envelope and equivalent-syntax workaround unchanged.

## Watcher reliability

- [ ] Reproduce slow MCP semantic search in a disposable fixture with pending freshness work and bounded requests; October 27 root/status calls responded with the watcher stopped, but the historical cause remains unestablished. (context: docs/plan_context/inference_availability.md)
	- [ ] Decide whether pre-search reconciliation should have a total wait budget with lexical fallback while explicit indexing retains cold-model waits; no budget or request-policy change has been selected. (context: docs/plan_context/inference_availability.md)
	- [ ] Decide whether failed incremental embedding should retain new lexical rows as pending work or roll them back; the private fixture grew from four symbols/four vectors to five/four while retaining working search and file reads. (context: docs/plan_context/inference_availability.md)
- [ ] Identify the historical watcher cause only if a new reproducer or underlying SQLite record becomes available; currently blocked on evidence and not on further recollection. (context: docs/plan_context/watcher_sqlite_failures.md)

## Validation and performance

- [ ] Investigate broad ReleaseSafe host-runner variation: serialization records an 11.89-second execution lower bound and 3.93-second evaluation after about six minutes queued, following all-platform preflight's 12.37/7.95-second observation; retain both without attributing the variation, accepting a baseline, or changing coverage/exclusions/budgets. (context: docs/plan_context/test_latency.md)
- [ ] Add controlled TCP-blackhole/TLS-cancellation fixtures and run request-deadline checks on qualified native macOS/Windows runners; native execution depends on runner availability, not cross-build success.
- [ ] Reproduce watcher heap growth with deterministic event batches and explicit/implicit roots using the shared profiling engine; shared-service caller-allocator ownership is clean in the bounded fixture, while native watcher, transport, and implicit-root profiling remain open. (context: docs/plan_context/watcher_memory.md)
- [ ] Recover the interrupted reindex sweep's private completion ledger and exact remaining project set before resuming live writes; the available July handoff/static bookkeeping cannot establish the later completion state or authorize a new all-project sweep.

## Architecture and features

- [ ] Bring project builds and publication into conformance with the `cross-platform-project-build-arch` convention; preserve existing products and coordinate PATH cutover separately. (context: docs/plan_context/build_conformance.md)
	- [ ] Use `macos-arm64`, `linux-amd64`, `linux-arm64`, `mswin-amd64`, and `mswin-arm64` namespaces with separate ABI/profile products; preserve native compiler/Nix identifiers and keep writable outputs separate from retained Nix outputs.
	- [ ] Publish verified commands in `bin/<PF>/` without runtime selector wrappers; preserve previous selections on failure, serialize publishers, retain runtime resources, support native Windows entrypoints, and coordinate PATH changes separately.
		- [x] Preserve the native retained product when a successful builder omits its command or root registration fails; three native mapping controls and a disposable real-Nix-store GC/resource check pass without live publication. (done 2026-11-02 15:48 EST; context: docs/plan_context/build_conformance.md)
		- [x] Verify native default/debug header preflight through the integrated complete suite, fresh confined host run, and exact-commit CI; controlled wrong-CPU/reader failures preserve prior products and actual native bytes pass. (done 2026-11-02 23:08 EST; commit 8b7af814; context: docs/plan_context/build_conformance.md)
		- [x] Verify staged all-platform candidate preflight on exact-commit CI; all 24 failure controls, complete local/fresh host checks, native Linux/Mac/Windows qualification, eight Mechatron targets, and five canonical archives pass without changed exclusions. (done 2026-11-02 23:34 EST; commit f662a495; context: docs/plan_context/build_conformance.md)
		- [x] Verify kernel-backed native publication serialization on exact-commit CI: actual native Mac lease/competition controls, complete Linux/Mac/Windows suites, both cancellation campaigns, eight Mechatron targets, and five archives pass without changed exclusions. (done 2026-11-02 23:38 EST; commit 12240394; context: docs/plan_context/build_conformance.md)
		- [ ] Roll back selected roots if registration fails after an earlier target is promoted, under serialized publication; build/verification preflight alone does not make the registration phase failure-safe. (context: docs/plan_context/build_conformance.md)
		- [x] Decide how public entrypoints retain complete products. Answer: Hybrid retained Nix-output links on Nix hosts, with complete copied products for Windows/distribution; existing products remain recoverable and PATH changes stay separate. (done 2026-11-02 14:55 EST; context: docs/plan_context/build_conformance.md)
	- [ ] Prove conformance through failing behavioral regressions in `./test`, real binary-header/ABI checks, host/foreign/profile coexistence, and native execution where available; report unavailable target checks without claiming full conformance.
		- [x] Execute the complete aggregate unit binary on both disposable native Windows runners: each validates 806 passes, seven existing skips, and zero failures, plus twenty complete five-case cancellation processes; native preparation remains unchanged. (done 2026-11-02 21:12 EST; commit 4081fc92; context: docs/plan_context/build_conformance.md)
			- [x] Repair the first native gate's config-separator assertion and unsupported directory timestamp calls, and verify canonical Windows discovery paths while preserving literal POSIX backslashes; those cases pass on both native Windows architectures, though aggregate qualification still fails separately. (done 2026-11-02 20:28 EST; commit 08865fbb; context: docs/plan_context/build_conformance.md)
			- [x] Repair the complete Windows run's eighteen fixture failures per architecture: native paths, escaped MCP/HTTP requests, executable-bit classification, explicit Git discovery, and platform-independent log controls all pass natively without new skips or removed assertions. (done 2026-11-02 21:12 EST; commit 4081fc92; context: docs/plan_context/build_conformance.md)
- [ ] Migrate one remaining vendored grammar at a time to an exact reproducible source pin, retaining local patches and symbol/range regressions.
	- [ ] Verify the byte-identical Go pin on exact-commit CI; seven source/license identities, both missing-root/source-filter RED controls, before/after CLI characterization, complete Nix checks, and fresh confined host checks pass all 812 available unit cases while all six removals remain unstaged. (context: docs/plan_context/build_conformance.md)

## Tabled (not actionable)

- [ ] Evaluate concise I/O wrappers without changing lifetime or concurrency semantics; tabled pending a concrete use case and renewed direction.
- [ ] Specify whole-file/hashline-targeted comment generation with model/language settings, existing-comment protection, dry runs, and explicit overwrite behavior; tabled pending a concrete use case and renewed direction.
- [ ] Establish a versioned relevance corpus with independently judged expected symbols/files and MRR, nDCG, and Recall@k; tabled until those judgments and renewed direction are available.
