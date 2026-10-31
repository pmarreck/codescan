# PLAN

Completed work is recorded in docs/PLAN_LOG.md. Earlier planning history remains recoverable in Git; private operational context is retained outside the repository. Execution resumed on 2026-10-30; open items remain ordered below.

## CI completion and maintenance

- [ ] Verify embedding-cardinality guards on exact-commit Mechatron Prime CI and GitHub Actions; complete Nix and fresh confined host checks pass 764 unit cases with unchanged exclusions.
- [ ] Verify HTTP embedding-rejection preservation on exact-commit Mechatron Prime CI and GitHub Actions; complete Nix and fresh confined host checks pass 761 unit cases, retained rows/vectors, HTTP 503 advice, health, and lexical fallback.
- [x] Verify freed-unit-lane scheduling on exact-commit Mechatron Prime CI and GitHub Actions; all five release targets and native macOS smoke checks pass for fa8630cd, following 759 passing local unit cases. (done 2026-10-31 00:59 EDT; commit fa8630cd)
- [x] Verify provider-response cleanup and rejected-replacement preservation on exact-commit Mechatron Prime CI and GitHub Actions; all five release targets and native macOS smoke checks pass for f1211cf8, following 761 passing local unit cases. (done 2026-10-31 01:21 EDT; commit f1211cf8)
- [x] Verify the orchestration-fixture optimization on exact-commit Mechatron Prime CI and GitHub Actions; all five release targets and native macOS smoke checks pass for 134812b3, following 759 passing local unit cases. (done 2026-10-31 00:59 EDT; commit 134812b3)
- [x] Verify isolated component timing on exact-commit Mechatron Prime CI and GitHub Actions; all five release targets and native macOS smoke checks pass for 07ff0838, following 759 passing local unit cases. (done 2026-10-31 00:40 EDT; commit 07ff0838)
- [ ] Report the shared profiler's failed-run WITHIN_BUDGET label and verify its repair; contact approval is pending and the failed diagnostic remains ineligible for compliance. (context: docs/plan_context/test_latency.md)

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

- [ ] Reduce the latest ReleaseSafe host runner's 7.46-second execution lower bound and 10.95-second flake-evaluation span; retain safety, coverage, exclusions, and the five-second budget. (context: docs/plan_context/test_latency.md)
	- [x] Reduce redundant orchestration-fixture processes while retaining all ten barrier/failure scenarios and real source-copy coverage; the component fell from 2.22 to 1.46 seconds, without establishing an overall budget improvement. (done 2026-10-31 00:40 EDT; context: docs/plan_context/test_latency.md)
	- [x] Reuse the freed unit lane for independent harness checks; a FIFO regression failed on the old runner, and fourteen scenarios now cover two-suite concurrency, source-copy ordering, lane failures, and joins; fresh component execution fell from 7.77 to 4.83 seconds. (done 2026-10-31 00:47 EDT; context: docs/plan_context/test_latency.md)
- [ ] Add controlled TCP-blackhole/TLS-cancellation fixtures and run request-deadline checks on qualified native macOS/Windows runners; native execution depends on runner availability, not cross-build success.
- [ ] Reproduce watcher heap growth with deterministic event batches and explicit/implicit roots using the shared profiling engine; record allocation ownership before changing it.
- [ ] Test provider-model failure paths for index/provider compatibility and preserved lexical/file operations; ranking-quality comparisons depend on the tabled independently judged corpus.
	- [x] Reject malformed embedding rows and invalid OpenAI index mappings without trapping or leaking; the ReleaseSafe regression first aborted during cleanup, and ten malformed-response cases plus allocation-failure sweeps now pass. (done 2026-10-31 00:59 EDT; context: docs/plan_context/inference_availability.md)
	- [x] Preserve the index when a responding provider rejects full-index embeddings; CLI and MCP regressions first lost all six vectors, then passed exact symbol-row/vector-count checks, actionable advice, and continued lexical/file operations. (done 2026-10-31 00:59 EDT; context: docs/plan_context/inference_availability.md)
	- [x] Preserve HTTP `/index` and `/update` against responding-provider embedding rejection; both regressions first returned 500 and lost all six vectors, then passed 503 advice, exact retained rows/counts, health, and lexical fallback. (done 2026-10-31 01:12 EDT; context: docs/plan_context/inference_availability.md)
	- [x] Validate response cardinality before accepting embeddings or dimension probes; three regressions failed first, then 18 wire-count combinations, eight HTTP-embedder/search controls, six probe controls, and 764 unit cases passed in complete Nix and fresh confined host runs. (done 2026-10-31 01:28 EDT; context: docs/plan_context/inference_availability.md)
	- [ ] Characterize empty-vector and stored-index/provider-width mismatches through actual HTTP embedding and search; preserve lexical fallback without misclassifying genuine SQLite failures as provider outages.
- [ ] Recover the interrupted reindex sweep's private completion ledger and exact remaining project set before resuming live writes; the available July handoff/static bookkeeping cannot establish the later completion state or authorize a new all-project sweep.

## Architecture and features

- [ ] Bring project builds and publication into conformance with the `cross-platform-project-build-arch` convention; preserve existing products and coordinate PATH cutover separately. (context: docs/plan_context/build_conformance.md)
	- [ ] Use `macos-arm64`, `linux-amd64`, `linux-arm64`, `mswin-amd64`, and `mswin-arm64` namespaces with separate ABI/profile products; preserve native compiler/Nix identifiers and keep writable outputs separate from retained Nix outputs.
	- [ ] Consolidate legacy `build_all` into thin Nix-required `./build` scope flags/aliases and exact-product `./run`/`./test`; remove direct-build fallbacks and prepare compiled tests through Nix; add canonical-implementation selection only if multiple executable implementations exist.
	- [ ] Publish verified commands in `bin/<PF>/` without runtime selector wrappers; preserve previous selections on failure, serialize publishers, retain runtime resources, support native Windows entrypoints, and coordinate PATH changes separately.
	- [ ] Prove conformance through failing behavioral regressions in `./test`, real binary-header/ABI checks, host/foreign/profile coexistence, and native execution where available; report unavailable target checks without claiming full conformance.
- [ ] Move update database preparation/freshness into the shared service after characterization tests prove CLI/MCP/HTTP behavior remains identical.
- [ ] Extract one CLI command/scorer component at a time behind existing behavioral tests; begin with command orchestration rather than rewriting scoring policy.
- [ ] Add `codescan symbols --depth N` with explicit root-depth, invalid-value, and JSON/human truncation tests.
- [ ] Add lexical fixtures proving camelCase/snake_case cross-matching without unrelated matches, then normalize at the candidate-selection boundary.
- [ ] Migrate one remaining vendored grammar at a time to an exact reproducible source pin, retaining local patches and symbol/range regressions.

## Tabled (not actionable)

- [ ] Evaluate concise I/O wrappers without changing lifetime or concurrency semantics; tabled pending a concrete use case and renewed direction.
- [ ] Specify whole-file/hashline-targeted comment generation with model/language settings, existing-comment protection, dry runs, and explicit overwrite behavior; tabled pending a concrete use case and renewed direction.
- [ ] Establish a versioned relevance corpus with independently judged expected symbols/files and MRR, nDCG, and Recall@k; tabled until those judgments and renewed direction are available.
