# PLAN

Completed work is recorded in docs/PLAN_LOG.md. Earlier planning history remains recoverable in Git; private operational context is retained outside the repository. Execution resumed on 2026-10-30; open items remain ordered below.

## CI completion and maintenance

- [x] Verify orchestration-count batching for d3a349de on both CI services: native Linux/Mac complete checks, both twenty-process Windows campaigns, all eight Mechatron targets, five archive jobs, and exactly five nonempty canonical archives pass. (done 2026-10-31 16:24 EDT; commit d3a349de)
- [x] Verify 637a0cbc on both CI services: native Linux/Mac complete checks, both twenty-process Windows campaigns, all eight Mechatron targets, and exactly five nonempty canonical archives pass; scanner ABI controls do not claim native Swift runtime qualification. (done 2026-10-31 16:49 EDT; commit 637a0cbc)
- [x] Verify 4cbd56da on both CI services: all three native generator/source builds and complete native Linux/Mac checks pass, both Windows campaigns pass twenty complete five-case processes, all eight Mechatron targets pass, and the artifact API confirms exactly five nonempty canonical archives. (done 2026-10-31 17:23 EDT; commit 4cbd56da)
- [x] Verify a2ccf89a on both CI services: complete native Linux/Mac checks, both twenty-process Windows campaigns, all eight Mechatron targets, and exactly five nonempty canonical archives pass with unchanged CLI/unit products. (done 2026-10-31 17:26 EDT; commit a2ccf89a)
- [x] Verify 5d3e876e on both CI services: complete native Linux/Mac checks, both twenty-process five-case Windows campaigns, all eight Mechatron targets, and exactly five nonempty canonical archives pass. (done 2026-11-02 13:33 EST; commit 5d3e876e)
- [ ] Verify the HTTP bound-port correction on exact-commit CI after complete local Nix and fresh confined host checks; retain native Linux/Mac execution, both Windows campaigns, all eight Mechatron targets, and five canonical archives.
- [ ] Report the shared profiler's failed-run WITHIN_BUDGET label and verify its repair; contact approval is pending and the failed diagnostic remains ineligible for compliance. (context: docs/plan_context/test_latency.md)
- [ ] Verify the infrastructure owner's build-budget literal-argument repair; the owner acknowledged the request and confirmed the source/installed-helper defect, but implementation remains queued, with the resource envelope and equivalent-syntax workaround unchanged.

## Watcher reliability

- [x] Report the actual HTTP listener port instead of requested zero after the real fixture first rejects the old announcement; both offline fixture servers use OS-assigned endpoints, and complete Nix/fresh confined host checks pass 807 unit cases and every available suite. (done 2026-11-02 13:37 EST; context: docs/plan_context/inference_availability.md)
- [ ] Reproduce slow MCP semantic search in a disposable fixture with pending freshness work and bounded requests; October 27 root/status calls responded with the watcher stopped, but the historical cause remains unestablished. (context: docs/plan_context/inference_availability.md)
	- [ ] Decide whether pre-search reconciliation should have a total wait budget with lexical fallback while explicit indexing retains cold-model waits; no budget or request-policy change has been selected. (context: docs/plan_context/inference_availability.md)
	- [ ] Decide whether failed incremental embedding should retain new lexical rows as pending work or roll them back; the private fixture grew from four symbols/four vectors to five/four while retaining working search and file reads. (context: docs/plan_context/inference_availability.md)
- [ ] Identify the historical watcher cause only if a new reproducer or underlying SQLite record becomes available; currently blocked on evidence and not on further recollection. (context: docs/plan_context/watcher_sqlite_failures.md)

## Validation and performance

- [x] Make source snapshots handle unstaged tracked deletions while preserving broken links, forced-tracked ignored files, spaces/newlines, empty snapshots, private-file exclusion, and tar error controls; the persistent test first fails, then complete Nix and fresh confined host checks pass 807 unit cases. (done 2026-10-31 17:04 EDT; context: docs/plan_context/test_latency.md)
- [ ] Investigate broad ReleaseSafe host-runner variation: the bound-port correction records a 7.77-second execution lower bound and 5.63-second evaluation, while earlier observations vary from 6.35/3.44 to 20.14/10.34 seconds; retain all records and the unresolved cause without accepting a baseline or changing coverage/exclusions/budgets. (context: docs/plan_context/test_latency.md)
	- [x] Attribute the unchanged prepared suites at one/twelve-core affinities: all 807 unit cases and available adapters pass, with 9.02/4.91-second execution lower bounds; both records remain partial-scope INCOMPLETE, not full-run budget passes or causal evidence for earlier variation. (done 2026-10-31 17:11 EDT; context: docs/plan_context/test_latency.md)
- [ ] Add controlled TCP-blackhole/TLS-cancellation fixtures and run request-deadline checks on qualified native macOS/Windows runners; native execution depends on runner availability, not cross-build success.
- [ ] Reproduce watcher heap growth with deterministic event batches and explicit/implicit roots using the shared profiling engine; shared-service caller-allocator ownership is clean in the bounded fixture, while native watcher, transport, and implicit-root profiling remain open. (context: docs/plan_context/watcher_memory.md)
- [ ] Recover the interrupted reindex sweep's private completion ledger and exact remaining project set before resuming live writes; the available July handoff/static bookkeeping cannot establish the later completion state or authorize a new all-project sweep.

## Architecture and features

- [ ] Bring project builds and publication into conformance with the `cross-platform-project-build-arch` convention; preserve existing products and coordinate PATH cutover separately. (context: docs/plan_context/build_conformance.md)
	- [ ] Use `macos-arm64`, `linux-amd64`, `linux-arm64`, `mswin-amd64`, and `mswin-arm64` namespaces with separate ABI/profile products; preserve native compiler/Nix identifiers and keep writable outputs separate from retained Nix outputs.
	- [ ] Publish verified commands in `bin/<PF>/` without runtime selector wrappers; preserve previous selections on failure, serialize publishers, retain runtime resources, support native Windows entrypoints, and coordinate PATH changes separately.
		- [ ] Decide whether public entrypoints use retained Nix links on development hosts with Windows/distribution copies, or complete copied products everywhere; the hybrid is proposed, existing products and PATH cutover remain untouched. (context: docs/plan_context/build_conformance.md)
	- [ ] Prove conformance through failing behavioral regressions in `./test`, real binary-header/ABI checks, host/foreign/profile coexistence, and native execution where available; report unavailable target checks without claiming full conformance.
- [ ] Extract remaining freshness orchestration from `main.zig` after CLI/MCP/HTTP characterization; database preparation already lives in `update_service.prepare`, while pending wait-budget and partial-row rollback decisions must remain unchanged. (context: docs/plan_context/inference_availability.md)
- [ ] Migrate one remaining vendored grammar at a time to an exact reproducible source pin, retaining local patches and symbol/range regressions.
	- [x] Pin Bash without changing its eight source/license files: both declared-root/source-filter regressions first fail, complete Nix and fresh host checks pass 807 unit cases, and seven recoverable deletions remain unstaged throughout the successful host check; exact-commit CI remains separate. (done 2026-10-31 17:33 EDT; context: docs/plan_context/build_conformance.md)
	- [x] Pin Swift without changing its parser: all seven source identities, both unsigned-shift backports, upstream attribution, source-filter regression, complete Nix checks, and fresh confined host checks pass; native-generator CI qualification remains separate. (done 2026-10-31 16:49 EDT; context: docs/plan_context/build_conformance.md)
		- [x] Repair the reproduced Swift Windows-width mask using a 64-bit literal; three real ABI compilations, both Windows overflow-rejection controls, complete Nix and fresh confined host checks pass all 807 available unit cases; exact-commit CI and source pinning remain separate. (done 2026-10-31 16:27 EDT; context: docs/plan_context/build_conformance.md)

## Tabled (not actionable)

- [ ] Evaluate concise I/O wrappers without changing lifetime or concurrency semantics; tabled pending a concrete use case and renewed direction.
- [ ] Specify whole-file/hashline-targeted comment generation with model/language settings, existing-comment protection, dry runs, and explicit overwrite behavior; tabled pending a concrete use case and renewed direction.
- [ ] Establish a versioned relevance corpus with independently judged expected symbols/files and MRR, nDCG, and Recall@k; tabled until those judgments and renewed direction are available.
