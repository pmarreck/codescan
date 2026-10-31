# PLAN

Completed work is recorded in docs/PLAN_LOG.md. Earlier planning history remains recoverable in Git; private operational context is retained outside the repository. Execution resumed on 2026-10-30; open items remain ordered below.

## CI completion and maintenance

- [ ] Verify the empty language/type intersection fix on exact-commit Mechatron Prime CI and GitHub Actions; complete Nix and fresh confined host checks pass 758 unit cases.
- [x] Verify the held-MCP characterization shipment on exact-commit Mechatron Prime CI and GitHub Actions; all five release builds and native macOS smoke checks pass for f3cad46c, following 757 passing local unit cases. (done 2026-10-30 22:46 EDT)
- [x] Verify the FTS prerequisite and real-socket cancellation shipments on exact-commit Mechatron Prime CI and GitHub Actions, including native macOS CLI smoke checks; all pass for 591c07a8 and b2d2ebd9. (done 2026-10-28 12:32 EDT)
- [x] Verify the shared tokenizer repair in 9c935fb: the exact installed blob accepts escaped cache interpolation, rejects unsafe dependencies, and honors staged content in both disagreement directions inside a disposable consumer fixture. (done 2026-10-28 02:36 EDT; context: docs/plan_context/staged_dependency_parser.md)
- [ ] Report the shared profiler's failed-run WITHIN_BUDGET label and verify its repair; contact approval is pending and the failed diagnostic remains ineligible for compliance. (context: docs/plan_context/test_latency.md)

## Watcher reliability

- [ ] Reproduce slow MCP semantic search in a disposable fixture with pending freshness work and bounded requests; October 27 root/status calls responded with the watcher stopped, but the historical cause remains unestablished. (context: docs/plan_context/inference_availability.md)
	- [x] Characterize a held pending-file embedding through the real MCP handler and HTTP transport; wire input identifies reconciliation, search remains pending until release, and rejection restores lexical results plus provider advice; complete Nix and fresh confined host checks pass 757 unit cases. (done 2026-10-30 22:28 EDT; context: docs/plan_context/inference_availability.md)
	- [ ] Decide whether pre-search reconciliation should have a total wait budget with lexical fallback while explicit indexing retains cold-model waits; no budget or request-policy change has been selected. (context: docs/plan_context/inference_availability.md)
	- [x] Preserve inference-unavailable advice after a reachable server rejects embeddings; complete Nix/fresh host checks pass 754 unit cases, and exact-commit Mechatron Prime CI plus GitHub Actions run 40644259465 pass, including native macOS CLI smoke checks. (done 2026-10-28 02:49 EDT; commit 28602f00; context: docs/plan_context/inference_availability.md)
	- [ ] Decide whether failed incremental embedding should retain new lexical rows as pending work or roll them back; the private fixture grew from four symbols/four vectors to five/four while retaining working search and file reads. (context: docs/plan_context/inference_availability.md)
- [ ] Identify the historical watcher cause only if a new reproducer or underlying SQLite record becomes available; currently blocked on evidence and not on further recollection. (context: docs/plan_context/watcher_sqlite_failures.md)

## After shipping

- [ ] Extend partial signature queries in the selected language order, beginning with the existing partial-signature acceptance example. (decision 2026-10-20)
	- [ ] Resolve the query-syntax choice: native signatures such as Zig `fn ceil(...) f64`, the shared `ceil : -> f64` form, or both; language order is already approved and independent work continues meanwhile.
	- [ ] Add Zig signature-query matching and negative cases, then exercise the actual CLI against indexed Zig fixtures.
	- [ ] Add Rust signature-query matching for functions/methods with type constraints and actual CLI coverage.
	- [ ] Add TypeScript signature-query matching for typed functions/methods with actual CLI coverage.
- [x] Require FTS5 in all seven dependent scoring regressions instead of silently returning or skipping; the complete Nix check passes 754 unit cases with the pinned FTS5-enabled SQLite. (done 2026-10-28 03:04 EDT)

## Validation and performance

- [ ] Attribute and reduce the ReleaseSafe prepared runtime's 6.23-second lower bound, pin the shared profiling adapter, and separate Nix evaluation/setup from execution; retain safety checks and exclusions without widening the five-second budget. (context: docs/plan_context/test_latency.md)
- [ ] Add controlled TCP-blackhole/TLS-cancellation fixtures and run request-deadline checks on qualified native macOS/Windows runners; native execution depends on runner availability, not cross-build success.
	- [x] Bound the unit process independently and verify real held HTTP/TLS exchanges close and join on cancellation; the complete Linux Nix check passes 755 unit cases without changing cold-model request policy. (done 2026-10-28 03:15 EDT; context: docs/plan_context/request_deadlines.md)
- [ ] Reproduce watcher heap growth with deterministic event batches and explicit/implicit roots using the shared profiling engine; record allocation ownership before changing it.
- [ ] Test provider-model failure paths for index/provider compatibility and preserved lexical/file operations; ranking-quality comparisons depend on the tabled independently judged corpus.
- [ ] Recover the interrupted reindex sweep's private completion ledger and exact remaining project set before resuming live index writes; do not infer a new all-project sweep.
- [ ] Cover the remaining inventoried discovery/search classifiers one bounded suite at a time, continuing with ignored-directory boundaries and similarly named allowed neighbors. (context: docs/plan_context/filter_classifiers.md)
	- [x] Preserve empty language/type intersections without bypassing existing validation; 48 search-mode/filter combinations, weight controls, and six real-CLI checks pass in complete Nix and fresh confined host runs with 758 passing unit cases. (done 2026-10-30 23:00 EDT; context: docs/plan_context/filter_classifiers.md)
	- [x] Repair standalone path filtering after the vector regression returned four candidates instead of two; all 16 path-set/search-mode combinations and 756 unit cases pass in the complete Nix check and fresh confined host runner. (done 2026-10-28 12:33 EDT; context: docs/plan_context/filter_classifiers.md)

## Architecture and features

- [ ] Bring project builds and publication into conformance with the `cross-platform-project-build-arch` convention; preserve existing products and coordinate PATH cutover separately. (context: docs/plan_context/build_conformance.md)
	- [x] Inventory the single Zig implementation, Nix profiles, five release targets, legacy publication/callers, exact test artifacts, and rollback boundary without moving live products. (done 2026-10-28 03:24 EDT; context: docs/plan_context/build_conformance.md)
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
