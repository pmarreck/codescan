# PLAN

Completed work is recorded in docs/PLAN_LOG.md. Earlier planning history remains recoverable in Git; private operational context is retained outside the repository. Execution resumed on 2026-10-30; open items remain ordered below.

## CI completion and maintenance

- [x] Verify native header preflight on exact-commit CI: complete native Linux/Mac suites, both native Windows aggregate reports and twenty-process cancellation campaigns, all eight Mechatron targets, and exactly five nonempty release archives pass. (done 2026-11-02 23:08 EST; commit 8b7af814)
- [ ] Report the shared profiler's failed-run WITHIN_BUDGET label and verify its repair; contact approval is pending and the failed diagnostic remains ineligible for compliance. (context: docs/plan_context/test_latency.md)
- [ ] Verify the infrastructure owner's build-budget literal-argument repair; the owner acknowledged the request and confirmed the source/installed-helper defect, but implementation remains queued, with the resource envelope and equivalent-syntax workaround unchanged.

## Watcher reliability

- [ ] Reproduce slow MCP semantic search in a disposable fixture with pending freshness work and bounded requests; October 27 root/status calls responded with the watcher stopped, but the historical cause remains unestablished. (context: docs/plan_context/inference_availability.md)
	- [ ] Decide whether pre-search reconciliation should have a total wait budget with lexical fallback while explicit indexing retains cold-model waits; no budget or request-policy change has been selected. (context: docs/plan_context/inference_availability.md)
	- [ ] Decide whether failed incremental embedding should retain new lexical rows as pending work or roll them back; the private fixture grew from four symbols/four vectors to five/four while retaining working search and file reads. (context: docs/plan_context/inference_availability.md)
- [ ] Identify the historical watcher cause only if a new reproducer or underlying SQLite record becomes available; currently blocked on evidence and not on further recollection. (context: docs/plan_context/watcher_sqlite_failures.md)

## Validation and performance

- [ ] Investigate broad ReleaseSafe host-runner variation: the Assembly-pin host run records a 25.01-second execution lower bound and 3.84-second evaluation after about 36 minutes queued; retain earlier observations without attributing the variation, accepting a baseline, or changing coverage/exclusions/budgets. (context: docs/plan_context/test_latency.md)
	- [x] Qualify immutable build-fixture templates on exact-commit native CI: complete Linux/Mac/Windows suites, both cancellation campaigns, eight Mechatron targets, and five archives pass with all 64 failure controls, no accepted baseline, and no changed budget. (done 2026-11-03 02:05 EST; commit f4597fce; context: docs/plan_context/test_latency.md)
- [ ] Add controlled TCP-blackhole/TLS-cancellation fixtures and run request-deadline checks on qualified native macOS/Windows runners; native execution depends on runner availability, not cross-build success.
- [ ] Reproduce watcher heap growth with deterministic event batches and explicit/implicit roots using the shared profiling engine; shared-service caller-allocator ownership is clean in the bounded fixture, while native watcher, transport, and implicit-root profiling remain open. (context: docs/plan_context/watcher_memory.md)
- [ ] Recover the interrupted reindex sweep's private completion ledger and exact remaining project set before resuming live writes; bounded archived evidence and retained-journal recovery cannot establish later completion, so later result records are required and live writes remain held.

## Architecture and features

- [ ] Bring project builds and publication into conformance with the `cross-platform-project-build-arch` convention; preserve existing products and coordinate PATH cutover separately. (context: docs/plan_context/build_conformance.md)
	- [ ] Use `macos-arm64`, `linux-amd64`, `linux-arm64`, `mswin-amd64`, and `mswin-arm64` namespaces with separate ABI/profile products; preserve native compiler/Nix identifiers and keep writable outputs separate from retained Nix outputs.
	- [ ] Publish verified commands in `bin/<PF>/` without runtime selector wrappers; preserve previous selections on failure, serialize publishers, retain runtime resources, support native Windows entrypoints, and coordinate PATH changes separately.
		- [x] Verify native default/debug header preflight through the integrated complete suite, fresh confined host run, and exact-commit CI; controlled wrong-CPU/reader failures preserve prior products and actual native bytes pass. (done 2026-11-02 23:08 EST; commit 8b7af814; context: docs/plan_context/build_conformance.md)
		- [x] Verify staged all-platform candidate preflight on exact-commit CI; all 24 failure controls, complete local/fresh host checks, native Linux/Mac/Windows qualification, eight Mechatron targets, and five canonical archives pass without changed exclusions. (done 2026-11-02 23:34 EST; commit f662a495; context: docs/plan_context/build_conformance.md)
		- [x] Verify kernel-backed native publication serialization on exact-commit CI: actual native Mac lease/competition controls, complete Linux/Mac/Windows suites, both cancellation campaigns, eight Mechatron targets, and five archives pass without changed exclusions. (done 2026-11-02 23:38 EST; commit 12240394; context: docs/plan_context/build_conformance.md)
		- [x] Verify selected-root rollback on exact-commit native CI: actual native Mac registration/GC/recovery controls, complete Linux/Mac/Windows suites, both cancellation campaigns, eight Mechatron targets, and five archives pass without changed exclusions. (done 2026-11-03 00:40 EST; commit 0249e153; context: docs/plan_context/build_conformance.md)
		- [x] Qualify Nix-host `bin/<PF>/` links on exact-commit CI: actual native Mac publication controls, complete Linux/Mac/Windows suites, both cancellation campaigns, eight Mechatron targets, and five archives pass without changed exclusions or PATH changes. (done 2026-11-03 01:17 EST; commit 58e41052; context: docs/plan_context/build_conformance.md)
		- [ ] Obtain approval for a proposal-only PATH coordination request to the shell-configuration maintainer; contacting the maintainer and activating PATH remain separate from the qualified Nix-host publisher. (context: docs/plan_context/build_conformance.md)
		- [x] Qualify complete copied release products on exact-commit CI: native x64/ARM64 Windows ZIP extraction/direct execution, both aggregate/cancellation campaigns, complete Linux/Mac checks, eight Mechatron targets, and five archives pass without retries or PATH changes. (done 2026-11-03 02:29 EST; commit 8abeef16; context: docs/plan_context/build_conformance.md)
		- [ ] Decide whether native Windows scope remains extracted releases for now or also needs a checkout `bin/mswin-<arch>/` publisher from a Nix-built product; the owner question is pending and does not authorize installation. (context: docs/plan_context/build_conformance.md)
	- [ ] Prove conformance through failing behavioral regressions in `./test`, real binary-header/ABI checks, host/foreign/profile coexistence, and native execution where available; report unavailable target checks without claiming full conformance.
- [ ] Migrate one remaining vendored grammar at a time to an exact reproducible source pin, retaining local patches and symbol/range regressions.
	- [x] Verify the byte-identical Ruby pin at the exact integrated CI tip: actual native Mac eight-file identity gate, complete Linux/Mac/Windows checks, both cancellation campaigns, copied Windows release execution, eight Mechatron targets, and five archives pass without retries. (done 2026-11-03 02:29 EST; source commit 75cf7caf; qualified tip 8abeef16; context: docs/plan_context/build_conformance.md)
	- [ ] Qualify the unchanged Assembly source pin at revision 839741fe on exact-commit native CI; original CLI characterization, both independent REDs, seven identities, complete local/fresh host checks, and five actual cross-build headers pass with both existing header edits preserved. (context: docs/plan_context/build_conformance.md)
	- [x] Verify the byte-identical Go pin on exact-commit CI: seven identities, both missing-root/source-filter REDs, CLI characterization, complete local/fresh host checks, native Linux/Mac/Windows qualification, eight Mechatron targets, and five archives pass without changed exclusions. (done 2026-11-03 00:27 EST; commit 8221bcb2; context: docs/plan_context/build_conformance.md)

## Tabled (not actionable)

- [ ] Evaluate concise I/O wrappers without changing lifetime or concurrency semantics; tabled pending a concrete use case and renewed direction.
- [ ] Specify whole-file/hashline-targeted comment generation with model/language settings, existing-comment protection, dry runs, and explicit overwrite behavior; tabled pending a concrete use case and renewed direction.
- [ ] Establish a versioned relevance corpus with independently judged expected symbols/files and MRR, nDCG, and Recall@k; tabled until those judgments and renewed direction are available.
