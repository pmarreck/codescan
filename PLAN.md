# PLAN

Completed work is recorded in docs/PLAN_LOG.md. Earlier planning history remains recoverable in Git; private operational context is retained outside the repository.

## CI completion and maintenance

- [x] Resolve the staged-dependency rejection locally with equivalent double-quoted Nix shell syntax; cache inheritance/default tests and the real staged gate pass without an override. (done 2026-10-27 22:14 EDT; context: docs/plan_context/staged_dependency_parser.md)
- [ ] Ship the validated changes and verify exact-commit Mechatron Prime CI and GitHub Actions, including native macOS ARM64 execution.
	- [x] Move source-closure validation to declared build inputs and require its positive/negative controls in CI and the complete runner; local checks pass, with cold GitHub verification pending after run 40620285707 failed. (done 2026-10-27 22:28 EDT)
- [ ] Report the shared Nix tokenizer's escaped-interpolation false positive; blocked only on approval to contact the additional recipient. (context: docs/plan_context/staged_dependency_parser.md)
- [x] Prepare exact test binaries through Nix once and run mutation tests in a qualified disposable boundary; the complete local runner passed executed checks, with four unit and two live-provider exclusions reported explicitly. (done 2026-10-27 21:12 EDT)
- [x] Make Git-discovery prerequisites hard failures, inject process-aware test I/O, and force-add the deliberately ignored tracked fixture; all three regressions execute successfully in the full native and Nix runners. (done 2026-10-27 22:09 EDT)
- [ ] Attribute and reduce the prepared runtime's 13.43-second lower bound against the five-second budget using shared per-phase measurements; keep compilation, Nix setup, queue waiting, and live-provider exclusions separate.

## Watcher reliability

- [ ] Reproduce slow MCP semantic search in a disposable fixture with pending freshness work and bounded requests; live root/status calls respond, the watcher is stopped, and pre-search reconciliation is a candidate for the October 27 delay, not an established cause.
- [ ] Finish SQLite watcher diagnostics across remaining read/cursor failures, including controlled I/O faults, without broadening retry policy. (context: docs/plan_context/watcher_sqlite_failures.md)
	- [x] Preserve connection-local startup/write error operation, primary/extended codes, message, command, and version through cleanup; controlled busy/constraint/schema/read-only/open-failure tests and the real preservation CLI regression pass. (done 2026-10-27 22:09 EDT)
- [ ] Identify the historical watcher cause only if a new reproducer or underlying SQLite record becomes available; currently blocked on evidence and not on further recollection. (context: docs/plan_context/watcher_sqlite_failures.md)

## After shipping

- [ ] Extend partial signature queries in the selected language order, beginning with the existing partial-signature acceptance example. (decision 2026-10-20)
	- [ ] Add Zig signature-query matching and negative cases, then exercise the actual CLI against indexed Zig fixtures.
	- [ ] Add Rust signature-query matching for functions/methods with type constraints and actual CLI coverage.
	- [ ] Add TypeScript signature-query matching for typed functions/methods with actual CLI coverage.
- [ ] Require FTS5 availability in behavioral regressions instead of silent early returns; current Nix artifacts execute the three formerly skipped scoring cases, and the pinned SQLite build already enables FTS5.

## Validation and performance

- [ ] Add controlled TCP-blackhole/TLS-cancellation fixtures and run request-deadline checks on qualified native macOS/Windows runners; native execution depends on runner availability, not cross-build success.
- [ ] Reproduce watcher heap growth with deterministic event batches and explicit/implicit roots using the shared profiling engine; record allocation ownership before changing it.
- [ ] Test provider-model failure paths for index/provider compatibility and preserved lexical/file operations; ranking-quality comparisons depend on the tabled independently judged corpus.
	- [x] Prove real stdio MCP initialization, lexical/hybrid fallback search with agent-visible advice, create/read/versioned edits, and non-destructive indexing refusal with a stopped provider; verify subsequent file requests still succeed. (done 2026-10-27 21:53 EDT)
- [ ] Recover the interrupted reindex sweep's private completion ledger and exact remaining project set before resuming live index writes; do not infer a new all-project sweep.
- [ ] Inventory discovery/search filters lacking set-level tests and add one bounded classifier suite at a time.

## Architecture and features

- [ ] Bring project builds and publication into conformance with the `cross-platform-project-build-arch` convention; inventory products, callers, profiles, and rollback before migration.
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
