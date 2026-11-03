# PLAN

Completed work is recorded in docs/PLAN_LOG.md. Earlier planning history remains recoverable in Git; private operational context is retained outside the repository. Execution resumed on 2026-10-30; open items remain ordered below.

## CI completion and maintenance

- [ ] Investigate the retained Linux x64 Nix bootstrap evaluation failure at watcher tip dbc859ca; tests never started, no retry was performed, and infrastructure contact approval is pending. (context: docs/plan_context/ci_bootstrap.md)
- [ ] Attribute the retained Windows peer-read incident at 4a4d6048 only if fresh underlying native evidence becomes available; its original status was not recorded, while the controlled reset defect is repaired and qualified independently. (context: docs/plan_context/inference_availability.md)
- [ ] Report the shared profiler's failed-run WITHIN_BUDGET label and verify its repair; contact approval is pending and the failed diagnostic remains ineligible for compliance. (context: docs/plan_context/test_latency.md)
- [ ] Verify the infrastructure owner's build-budget literal-argument repair; the owner acknowledged the request and confirmed the source/installed-helper defect, but implementation remains queued, with the resource envelope and equivalent-syntax workaround unchanged.

## Watcher reliability

- [x] Qualify native watcher startup errors, failed-resource cleanup, and visible polling-fallback causes: complete native Linux/Mac/Windows suites, both reset/cancellation campaigns, extracted releases, eight Mechatron targets, and five matching archives pass with all five new cases required. (done 2026-11-03 07:35 EST; commit 1c6019f7; context: docs/plan_context/watcher_native_startup.md)
- [x] Qualify corrected FSEvents LP64 bindings: complete native Linux/Mac/Windows suites, both reset/cancellation campaigns, extracted releases, eight Mechatron targets, and five matching archives pass without retries or new skips. (done 2026-11-03 07:04 EST; commit 71f16717; context: docs/plan_context/watcher_memory.md)
- [ ] Reproduce slow MCP semantic search in a disposable fixture with pending freshness work and bounded requests; October 27 root/status calls responded with the watcher stopped, but the historical cause remains unestablished. (context: docs/plan_context/inference_availability.md)
	- [ ] Decide whether pre-search reconciliation should have a total wait budget with lexical fallback while explicit indexing retains cold-model waits; no budget or request-policy change has been selected. (context: docs/plan_context/inference_availability.md)
	- [ ] Decide whether failed incremental embedding should retain new lexical rows as pending work or roll them back; the private fixture grew from four symbols/four vectors to five/four while retaining working search and file reads. (context: docs/plan_context/inference_availability.md)
- [ ] Identify the historical watcher cause only if a new reproducer or underlying SQLite record becomes available; currently blocked on evidence and not on further recollection. (context: docs/plan_context/watcher_sqlite_failures.md)

## Validation and performance

- [ ] Investigate measured publisher overhead in the 64-case rollback matrix: current diagnostics identify 11.05 seconds in publication and 5,297 child commands; retain prior observations without claiming a historical cause, accepting a baseline, or changing coverage/exclusions/budgets. (context: docs/plan_context/test_latency.md)
	- [ ] Make owned publisher staging-cleanup failures fatal and visible without reverting successfully selected products or masking original build errors; the real-wrapper regression returns zero after a forced cleanup failure. (context: docs/plan_context/test_latency.md)
	- [x] Qualify the independent four-case cleanup completeness guard in complete native Linux/Mac source suites, retaining all existing checks, unchanged native Windows products, eight Mechatron targets, and five matching archives without retries. (done 2026-11-03 09:57 EST; implementation acc8d61c; qualified tip 940a0fa7; context: docs/plan_context/test_latency.md)
	- [x] Qualify fatal, physical cleanup of owned read-only Nix fixtures: complete native Linux/Mac/Windows checks, both reset/cancellation campaigns, extracted releases, eight Mechatron targets, and five archives pass while preserving all rollback/GC cases and original failure statuses. (done 2026-11-03 09:05 EST; commit 3e36a3fa; context: docs/plan_context/test_latency.md)
- [ ] Add controlled TCP-blackhole/TLS-cancellation fixtures and run request-deadline checks on qualified native macOS/Windows runners; native execution depends on runner availability, not cross-build success.
- [ ] Reproduce watcher heap growth with deterministic event batches and explicit/implicit roots using the shared profiling engine; bounded per-call caller and native SQLite ownership checks are clean, while native watcher, transport, implicit-root, and whole-process profiling remain open. (context: docs/plan_context/watcher_memory.md)
	- [x] Qualify the full watcher-loop caller-ownership fixture and truthful polling diagnostics: complete native Linux/Mac/Windows suites, both reset/cancellation campaigns, extracted releases, eight Mechatron targets, and five archives pass; the omitted-free and wrong-message controls remain biting. (done 2026-11-03 06:45 EST; implementation dbc859ca; qualified tip 796fc682; context: docs/plan_context/watcher_memory.md)
- [ ] Recover the interrupted reindex sweep's private completion ledger and exact remaining project set before resuming live writes; bounded archived evidence and retained-journal recovery cannot establish later completion, so later result records are required and live writes remain held.

## Architecture and features

- [ ] Bring project builds and publication into conformance with the `cross-platform-project-build-arch` convention; preserve existing products and coordinate PATH cutover separately. (context: docs/plan_context/build_conformance.md)
	- [ ] Publish verified commands in `bin/<PF>/` without runtime selector wrappers; preserve previous selections on failure, serialize publishers, retain runtime resources, support native Windows entrypoints, and coordinate PATH changes separately.
		- [ ] Obtain approval for a proposal-only PATH coordination request to the shell-configuration maintainer; contacting the maintainer and activating PATH remain separate from the qualified Nix-host publisher. (context: docs/plan_context/build_conformance.md)
		- [ ] Decide whether native Windows scope remains extracted releases for now or also needs a checkout `bin/mswin-<arch>/` publisher from a Nix-built product; the owner question is pending and does not authorize installation. (context: docs/plan_context/build_conformance.md)
	- [ ] Prove conformance through failing behavioral regressions in `./test`, real binary-header/ABI checks, host/foreign/profile coexistence, and native execution where available; report unavailable target checks without claiming full conformance.
- [ ] Migrate one remaining vendored grammar at a time to an exact reproducible source pin, retaining local patches and symbol/range regressions.
	- [x] Qualify the unchanged OCaml source pin: actual Mac ten-file identity and complete native Linux/Mac/Windows suites, both reset/cancellation campaigns, extracted releases, eight Mechatron targets, and five matching archives pass without retries, preserving both header locations and ABI 15. (done 2026-11-03 09:19 EST; commit 8ae60f2c; context: docs/plan_context/build_conformance.md)
	- [x] Qualify the OCaml iterative nested-comment repair: balanced/unfinished deep inputs and exact following declarations pass complete native Linux/Mac/Windows suites, ten Mac source identities, both reset/cancellation campaigns, extracted releases, eight Mechatron targets, and five matching archives without retries. (done 2026-11-03 09:57 EST; commit 940a0fa7; context: docs/plan_context/build_conformance.md)
	- [x] Qualify the unchanged Erlang source pin: the actual Mac eight-file identity gate, complete native Linux/Mac/Windows suites, both reset/cancellation campaigns, extracted releases, eight Mechatron targets, and five matching archives pass without retries, preserving ABI 14 and all scanner/header bytes. (done 2026-11-03 08:31 EST; commit 28051b42; context: docs/plan_context/build_conformance.md)
	- [x] Qualify the unchanged Clojure source pin: the actual Mac seven-file combined identity gate, complete native Linux/Mac/Windows suites, both reset/cancellation campaigns, extracted releases, eight Mechatron targets, and five matching archives pass without retries, preserving both local headers and ABI 14. (done 2026-11-03 08:21 EST; commit 4a5b781a; context: docs/plan_context/build_conformance.md)
	- [x] Qualify the unchanged Nix grammar pin: the actual Mac six-file identity gate, complete native Linux/Mac/Windows suites, both reset/cancellation campaigns, extracted releases, eight Mechatron targets, and five matching archives pass without retries, with ABI 13 unchanged. (done 2026-11-03 08:04 EST; commit 9c0b0ad0; context: docs/plan_context/build_conformance.md)

## Tabled (not actionable)

- [ ] Evaluate concise I/O wrappers without changing lifetime or concurrency semantics; tabled pending a concrete use case and renewed direction.
- [ ] Specify whole-file/hashline-targeted comment generation with model/language settings, existing-comment protection, dry runs, and explicit overwrite behavior; tabled pending a concrete use case and renewed direction.
- [ ] Establish a versioned relevance corpus with independently judged expected symbols/files and MRR, nDCG, and Recall@k; tabled until those judgments and renewed direction are available.
