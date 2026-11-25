# PLAN

Completed work is recorded in docs/PLAN_LOG.md. Earlier planning history remains recoverable in Git; private operational context is retained outside the repository. Execution resumed on 2026-10-30; open items remain ordered below.

## CI completion and maintenance

- [ ] Investigate the retained Linux x64 Nix bootstrap evaluation failure at watcher tip dbc859ca; tests never started, no retry was performed, and infrastructure contact approval is pending. (context: docs/plan_context/ci_bootstrap.md)
- [ ] Attribute the retained Windows peer-read incident at 4a4d6048 only if fresh underlying native evidence becomes available; its original status was not recorded, while the controlled reset defect is repaired and qualified independently. (context: docs/plan_context/inference_availability.md)
- [ ] Report the shared profiler's failed-run WITHIN_BUDGET label and verify its repair; contact approval is pending and the failed diagnostic remains ineligible for compliance. (context: docs/plan_context/test_latency.md)
- [ ] Verify the infrastructure owner's build-budget literal-argument repair; the owner acknowledged the request and confirmed the source/installed-helper defect, but implementation remains queued, with the resource envelope and equivalent-syntax workaround unchanged.

## Watcher reliability

- [x] Make doctor compare stored embedding identity with effective settings without mutating the index; independently reproduce a preexisting legacy-vector mismatch instead of reporting healthy settings alone. (done 2026-11-25 16:20 EST; commit 40d2cffd; context: docs/plan_context/inference_availability.md)
- [x] Reload file settings for each MCP tool call and preserve actionable schema errors in valid protocol responses; fresh real sessions and native suites pass. (done 2026-11-25 17:18 EST; implementation a55755ee; qualified f9ef76d4; context: docs/plan_context/inference_availability.md)
- [x] Coordinate the reporting agent's one-time old-MCP reconnect; its exact conversation resumed and independently verified positive MCP vector scores, watcher authority and zero pending paths. (done 2026-11-25 17:35 EST; implementation a55755ee; context: docs/plan_context/inference_availability.md)
- [x] Resolve the exceptional legacy-vector mismatch. Answer: The owner approved replacing and discarding the regeneratable original; the rebuilt index has 10 files, 99 symbols, compatible Jina/1536 metadata and passing doctor checks. (done 2026-11-25 17:27 EST; implementation 40d2cffd; context: docs/plan_context/inference_availability.md)
- [ ] Attribute the original watcher WriteFailed only if new underlying evidence becomes available; the generic label and suppressed journal cannot establish its cause, while confirmed descriptor and diagnostic defects are repaired. (context: docs/plan_context/inference_availability.md)
- [x] Qualify owner-aware PID/ready cleanup and kernel-confirmed stop/restart; native suites and a controlled live restart retain correct status and watcher authority without erasing replacement ownership. (done 2026-11-25 17:18 EST; commit f9ef76d4; context: docs/plan_context/inference_availability.md)
- [x] Correct C type-reference extraction in indexing and symbol listing while preserving definitions, typedefs and forward declarations; the rebuilt reporting index has zero orphan vectors. (done 2026-11-25 16:30 EST; commit 8792845e; context: docs/plan_context/inference_availability.md)
- [x] Complete native qualification and deployment of doctor, watcher and MCP corrections, including repair of the Windows-only environment-map test compile error; all declared architectures and five release archives pass. (done 2026-11-25 17:18 EST; qualified f9ef76d4; context: docs/plan_context/inference_availability.md)
- [ ] Verify remediation of noisy inference-worker runtime logs while preserving startup scheduler accounting; approved scoped requests are delivered to the provider and infrastructure inboxes, with no restart or activation authorized. (context: docs/plan_context/inference_availability.md)
- [x] Characterize blocked MCP freshness reconciliation. Answer: A real pending-file POST holds the synchronous search handler until rejection, then lexical fallback and file access work; the historical incident's cause remains unestablished. (done 2026-11-25 16:57 EST; implementation f3cad46c; qualified 20a0a32c; context: docs/plan_context/inference_availability.md)
- [ ] Choose search wait-budget and incremental-failure policies before changing the characterized freshness behavior; the two owner decisions remain open. (context: docs/plan_context/inference_availability.md)
	- [ ] Decide whether pre-search reconciliation should have a total wait budget with lexical fallback while explicit indexing retains cold-model waits; no budget or request-policy change has been selected. (context: docs/plan_context/inference_availability.md)
	- [ ] Decide whether failed incremental embedding should retain new lexical rows as pending work or roll them back; the private fixture grew from four symbols/four vectors to five/four while retaining working search and file reads. (context: docs/plan_context/inference_availability.md)
- [ ] Identify the historical watcher cause only if a new reproducer or underlying SQLite record becomes available; currently blocked on evidence and not on further recollection. (context: docs/plan_context/watcher_sqlite_failures.md)

## Validation and performance

- [ ] Investigate measured publisher overhead in the 64-case rollback matrix: current diagnostics identify 11.05 seconds in publication and 5,297 child commands; retain prior observations without claiming a historical cause, accepting a baseline, or changing coverage/exclusions/budgets. (context: docs/plan_context/test_latency.md)
	- [x] Make owned publisher staging-cleanup failures fatal and visible without reverting selected products or masking original build errors; the real-wrapper failure matrix now passes. (done 2026-11-25 16:55 EST; implementation e05906e8; qualified 20a0a32c; context: docs/plan_context/test_latency.md)
- [ ] Add controlled TCP-blackhole/TLS-cancellation fixtures and run request-deadline checks on qualified native macOS/Windows runners; native execution depends on runner availability, not cross-build success.
	- [ ] Qualify a Linux SYN-connect cancellation fixture using an owned saturated listener, independent kernel state/descriptor checks, and a retained-descriptor negative control; queue-full refusal on other platforms is not equivalent blackhole coverage. (context: docs/plan_context/inference_availability.md)
- [ ] Reproduce watcher heap growth with deterministic event batches and explicit/implicit roots using the shared profiling engine; bounded per-call caller and native SQLite ownership checks are clean, while native watcher, transport, implicit-root, and whole-process profiling remain open. (context: docs/plan_context/watcher_memory.md)
- [ ] Recover the interrupted reindex sweep's private completion ledger and exact remaining project set before resuming live writes; bounded archived evidence and retained-journal recovery cannot establish later completion, so later result records are required and live writes remain held.

## Architecture and features

- [x] Add CLI search --all for terminal stdin/stdout only, retaining query filters and relevance thresholds while removing count/body caps; 27-result, regex, browse, 4105-vector and bounded-MCP regressions pass in the complete suite. (done 2026-11-25 17:42 EST; commit 343f4276)
- [ ] Bring project builds and publication into conformance with the `cross-platform-project-build-arch` convention; preserve existing products and coordinate PATH cutover separately. (context: docs/plan_context/build_conformance.md)
	- [ ] Publish verified commands in `bin/<PF>/` without runtime selector wrappers; preserve previous selections on failure, serialize publishers, retain runtime resources, support native Windows entrypoints, and coordinate PATH changes separately.
		- [ ] Obtain approval for a proposal-only PATH coordination request to the shell-configuration maintainer; contacting the maintainer and activating PATH remain separate from the qualified Nix-host publisher. (context: docs/plan_context/build_conformance.md)
		- [ ] Decide whether native Windows scope remains extracted releases for now or also needs a checkout `bin/mswin-<arch>/` publisher from a Nix-built product; the owner question is pending and does not authorize installation. (context: docs/plan_context/build_conformance.md)
	- [ ] Prove conformance through failing behavioral regressions in `./test`, real binary-header/ABI checks, host/foreign/profile coexistence, and native execution where available; report unavailable target checks without claiming full conformance.
- [ ] Migrate one remaining vendored grammar at a time to an exact reproducible source pin, retaining local patches and symbol/range regressions.

## Tabled (not actionable)

- [ ] Evaluate concise I/O wrappers without changing lifetime or concurrency semantics; tabled pending a concrete use case and renewed direction.
- [ ] Specify whole-file/hashline-targeted comment generation with model/language settings, existing-comment protection, dry runs, and explicit overwrite behavior; tabled pending a concrete use case and renewed direction.
- [ ] Establish a versioned relevance corpus with independently judged expected symbols/files and MRR, nDCG, and Recall@k; tabled until those judgments and renewed direction are available.
