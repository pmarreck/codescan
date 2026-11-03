# PLAN

Completed work is recorded in docs/PLAN_LOG.md. Earlier planning history remains recoverable in Git; private operational context is retained outside the repository. Execution resumed on 2026-10-30; open items remain ordered below.

## CI completion and maintenance

- [ ] Diagnose the native Windows x64 held-body peer-closure failure in the seventh cancellation repetition at commit 4a4d6048; retain its failed run and expose the underlying native status without relaxing socket-closure assertions or retrying it into a passing verdict. (context: docs/plan_context/inference_availability.md)
- [ ] Report the shared profiler's failed-run WITHIN_BUDGET label and verify its repair; contact approval is pending and the failed diagnostic remains ineligible for compliance. (context: docs/plan_context/test_latency.md)
- [ ] Verify the infrastructure owner's build-budget literal-argument repair; the owner acknowledged the request and confirmed the source/installed-helper defect, but implementation remains queued, with the resource envelope and equivalent-syntax workaround unchanged.

## Watcher reliability

- [ ] Reproduce slow MCP semantic search in a disposable fixture with pending freshness work and bounded requests; October 27 root/status calls responded with the watcher stopped, but the historical cause remains unestablished. (context: docs/plan_context/inference_availability.md)
	- [ ] Decide whether pre-search reconciliation should have a total wait budget with lexical fallback while explicit indexing retains cold-model waits; no budget or request-policy change has been selected. (context: docs/plan_context/inference_availability.md)
	- [ ] Decide whether failed incremental embedding should retain new lexical rows as pending work or roll them back; the private fixture grew from four symbols/four vectors to five/four while retaining working search and file reads. (context: docs/plan_context/inference_availability.md)
- [ ] Identify the historical watcher cause only if a new reproducer or underlying SQLite record becomes available; currently blocked on evidence and not on further recollection. (context: docs/plan_context/watcher_sqlite_failures.md)

## Validation and performance

- [ ] Investigate broad ReleaseSafe host-runner variation: the LLVM-pin host run records a 25.01-second execution lower bound and 3.78-second evaluation after about 30 minutes queued; retain earlier observations without attributing the variation, accepting a baseline, or changing coverage/exclusions/budgets. (context: docs/plan_context/test_latency.md)
	- [x] Qualify immutable build-fixture templates on exact-commit native CI: complete Linux/Mac/Windows suites, both cancellation campaigns, eight Mechatron targets, and five archives pass with all 64 failure controls, no accepted baseline, and no changed budget. (done 2026-11-03 02:05 EST; commit f4597fce; context: docs/plan_context/test_latency.md)
- [ ] Add controlled TCP-blackhole/TLS-cancellation fixtures and run request-deadline checks on qualified native macOS/Windows runners; native execution depends on runner availability, not cross-build success.
- [ ] Reproduce watcher heap growth with deterministic event batches and explicit/implicit roots using the shared profiling engine; bounded per-call caller and native SQLite ownership checks are clean, while native watcher, transport, implicit-root, and whole-process profiling remain open. (context: docs/plan_context/watcher_memory.md)
	- [ ] Qualify the full watcher-loop caller-ownership fixture and truthful polling-backend diagnostics on exact-commit native CI; complete local checks pass, while an omitted-free mutation and wrong-backend-message regression fail independently without changing inference policy. (context: docs/plan_context/watcher_memory.md)
	- [x] Qualify conditional schema-result cleanup on exact-commit native CI: complete Linux/Mac suites, both Windows aggregate/cancellation campaigns and copied releases, eight Mechatron targets, and five archives pass; the earlier failed Windows peer-read run remains separately tracked. (done 2026-11-03 05:54 EST; implementation 4a4d6048; qualified tip 6edb3d91; context: docs/plan_context/watcher_memory.md)
	- [x] Qualify real SQLite allocation-counter checks around the 24-pass absolute/relative-root fixture on native Linux/Mac and both Windows architectures; complete suites, both cancellation campaigns, eight Mechatron targets, and five archives pass without a production change or new skips. (done 2026-11-03 03:54 EST; commit 3eddd084; context: docs/plan_context/watcher_memory.md)
- [ ] Recover the interrupted reindex sweep's private completion ledger and exact remaining project set before resuming live writes; bounded archived evidence and retained-journal recovery cannot establish later completion, so later result records are required and live writes remain held.

## Architecture and features

- [ ] Bring project builds and publication into conformance with the `cross-platform-project-build-arch` convention; preserve existing products and coordinate PATH cutover separately. (context: docs/plan_context/build_conformance.md)
	- [x] Use all five canonical PF namespaces with separate ABI/profile products, preserved compiler/Nix identifiers, and separate writable/retained outputs; scope/coexistence/refusal controls and exact-commit native qualification pass. (done 2026-11-03 03:30 EST; implementation 58e41052; qualified tip 8abeef16; context: docs/plan_context/build_conformance.md)
	- [ ] Publish verified commands in `bin/<PF>/` without runtime selector wrappers; preserve previous selections on failure, serialize publishers, retain runtime resources, support native Windows entrypoints, and coordinate PATH changes separately.
		- [x] Verify selected-root rollback on exact-commit native CI: actual native Mac registration/GC/recovery controls, complete Linux/Mac/Windows suites, both cancellation campaigns, eight Mechatron targets, and five archives pass without changed exclusions. (done 2026-11-03 00:40 EST; commit 0249e153; context: docs/plan_context/build_conformance.md)
		- [x] Qualify Nix-host `bin/<PF>/` links on exact-commit CI: actual native Mac publication controls, complete Linux/Mac/Windows suites, both cancellation campaigns, eight Mechatron targets, and five archives pass without changed exclusions or PATH changes. (done 2026-11-03 01:17 EST; commit 58e41052; context: docs/plan_context/build_conformance.md)
		- [ ] Obtain approval for a proposal-only PATH coordination request to the shell-configuration maintainer; contacting the maintainer and activating PATH remain separate from the qualified Nix-host publisher. (context: docs/plan_context/build_conformance.md)
		- [x] Qualify complete copied release products on exact-commit CI: native x64/ARM64 Windows ZIP extraction/direct execution, both aggregate/cancellation campaigns, complete Linux/Mac checks, eight Mechatron targets, and five archives pass without retries or PATH changes. (done 2026-11-03 02:29 EST; commit 8abeef16; context: docs/plan_context/build_conformance.md)
		- [ ] Decide whether native Windows scope remains extracted releases for now or also needs a checkout `bin/mswin-<arch>/` publisher from a Nix-built product; the owner question is pending and does not authorize installation. (context: docs/plan_context/build_conformance.md)
	- [ ] Prove conformance through failing behavioral regressions in `./test`, real binary-header/ABI checks, host/foreign/profile coexistence, and native execution where available; report unavailable target checks without claiming full conformance.
- [ ] Migrate one remaining vendored grammar at a time to an exact reproducible source pin, retaining local patches and symbol/range regressions.
	- [x] Verify the byte-identical Ruby pin at the exact integrated CI tip: actual native Mac eight-file identity gate, complete Linux/Mac/Windows checks, both cancellation campaigns, copied Windows release execution, eight Mechatron targets, and five archives pass without retries. (done 2026-11-03 02:29 EST; source commit 75cf7caf; qualified tip 8abeef16; context: docs/plan_context/build_conformance.md)
	- [x] Qualify the unchanged Assembly source pin on exact-commit CI: actual native Mac seven-file identity gate, complete Linux/Mac/Windows suites, both cancellation campaigns, eight Mechatron targets, and five archives pass with both existing header edits preserved and no retries. (done 2026-11-03 03:45 EST; commit d91a48d2; context: docs/plan_context/build_conformance.md)
	- [x] Qualify the unchanged LLVM source pin on exact-commit CI: actual native Mac seven-file identity gate, complete Linux/Mac/Windows suites, both cancellation campaigns, eight Mechatron targets, and five archives pass; the earlier Windows peer-read failure remains separately tracked. (done 2026-11-03 05:54 EST; source commit b3ddad3c; qualified tip 6edb3d91; context: docs/plan_context/build_conformance.md)

## Tabled (not actionable)

- [ ] Evaluate concise I/O wrappers without changing lifetime or concurrency semantics; tabled pending a concrete use case and renewed direction.
- [ ] Specify whole-file/hashline-targeted comment generation with model/language settings, existing-comment protection, dry runs, and explicit overwrite behavior; tabled pending a concrete use case and renewed direction.
- [ ] Establish a versioned relevance corpus with independently judged expected symbols/files and MRR, nDCG, and Recall@k; tabled until those judgments and renewed direction are available.
