# PLAN

Completed work is recorded in docs/PLAN_LOG.md. Earlier planning history remains recoverable in Git; private operational context is retained outside the repository. Execution resumed on 2026-10-30; open items remain ordered below.

## CI completion and maintenance

- [ ] Verify automatic symbol-discovery root handling on exact-commit Mechatron Prime CI and GitHub Actions; complete Nix and fresh confined host checks pass 772 unit cases and the CLI/MCP root regressions.
- [x] Verify shared scanner ignore preparation and allocation-failure cleanup on exact-commit Mechatron Prime CI and GitHub Actions; all five release targets and native macOS smoke checks pass for aef038b1, following 771 passing local unit cases and 2,050 paired CLI output checks. (done 2026-10-31 04:07 EDT; commit aef038b1)
- [x] Verify MCP project-relative file targeting on exact-commit Mechatron Prime CI and GitHub Actions; all five release targets and native macOS smoke checks pass for 0df165c1, following all 18 local file-operation cases and 769 passing unit cases. (done 2026-10-31 03:11 EDT; commit 0df165c1)
- [x] Verify pending-file vector incompatibility advice on exact-commit Mechatron Prime CI and GitHub Actions; all five release targets and native macOS smoke checks pass for fb68fa55, following 769 passing local unit cases and the independent SQLite-failure control. (done 2026-10-31 03:11 EDT; commit fb68fa55)
- [x] Verify atomic full-index schema replacement on exact-commit Mechatron Prime CI and GitHub Actions; all five release targets and native macOS smoke checks pass for b12c183b, following 767 passing local unit cases plus rollback, retained semantic search, and retry controls. (done 2026-10-31 02:40 EDT; commit b12c183b)
- [x] Verify shared Nix source evaluation on exact-commit Mechatron Prime CI and GitHub Actions; all five release targets and native macOS smoke checks pass for e1f04179, with all 24 package identities unchanged and 765 passing local unit cases. (done 2026-10-31 02:20 EDT; commit e1f04179)
- [x] Verify query-vector compatibility guards on exact-commit Mechatron Prime CI and GitHub Actions; all five release targets and native macOS smoke checks pass for 8aa45c33, following 765 passing local unit cases and genuine database-failure controls. (done 2026-10-31 02:20 EDT; commit 8aa45c33)
- [ ] Report the shared profiler's failed-run WITHIN_BUDGET label and verify its repair; contact approval is pending and the failed diagnostic remains ineligible for compliance. (context: docs/plan_context/test_latency.md)
- [ ] Report shared build-budget literal-argument expansion to its owner once contact is approved; systemd-run expands Bash parameter expressions before launch, and diagnostic commands currently avoid those expressions without bypassing resource limits.

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

- [ ] Reduce the latest ReleaseSafe host runner's 5.98-second execution lower bound and 4.52-second flake-evaluation span; retain safety, coverage, exclusions, and the five-second budget despite substantial host timing variation. (context: docs/plan_context/test_latency.md)
	- [x] Compile shared scanner ignore rules once per discovery; a leaking allocation-failure sweep failed first, then 771 unit cases, 136 classifier decisions, and 2,050 paired CLI checks passed; identical one-file discovery batches improved in both CPU-affinity modes. (done 2026-10-31 03:50 EDT; context: docs/plan_context/test_latency.md)
- [ ] Add controlled TCP-blackhole/TLS-cancellation fixtures and run request-deadline checks on qualified native macOS/Windows runners; native execution depends on runner availability, not cross-build success.
- [ ] Reproduce watcher heap growth with deterministic event batches and explicit/implicit roots using the shared profiling engine; record allocation ownership before changing it.
- [x] Test controlled provider-model failure paths for compatibility and preserved lexical/file operations; rejected replacements, malformed/count/width responses, pending-file advice, and independent SQLite controls pass with 769 unit cases; ranking-quality comparisons remain tabled. (done 2026-10-31 02:49 EDT; context: docs/plan_context/inference_availability.md)
	- [x] Preserve lexical fallback for empty/narrow/wide query vectors in both HTTP dialects; six cases first failed with SQL errors, then all 765 unit cases and genuine SQLite/metadata failure controls passed in complete Nix and fresh confined host runs. (done 2026-10-31 01:49 EDT; context: docs/plan_context/inference_availability.md)
	- [x] Rebuild full-index vector schemas at the detected width and roll back failed preparation; two regressions first failed with stale table widths, lost symbols, and a leak, then complete Nix and fresh confined host checks passed 767 unit cases plus restored semantic search and retry. (done 2026-10-31 02:25 EDT; context: docs/plan_context/inference_availability.md)
	- [x] Preserve pending-file inference advice for incompatible vector widths; all three valid wrong-width responses first omitted the warning, then complete Nix and fresh confined host checks passed 769 unit cases, retained vectors/file reads, pending markers, and a real SQLite-trigger control. (done 2026-10-31 02:40 EDT; context: docs/plan_context/inference_availability.md)
- [ ] Recover the interrupted reindex sweep's private completion ledger and exact remaining project set before resuming live writes; the available July handoff/static bookkeeping cannot establish the later completion state or authorize a new all-project sweep.

## Architecture and features

- [x] Resolve automatically discovered symbol files against the supplied root; CLI and MCP regressions first returned empty results outside that root, then complete Nix and fresh confined host checks passed 772 unit cases and absolute/relative root controls. (done 2026-10-31 04:07 EDT; context: docs/plan_context/inference_availability.md)
- [x] Resolve MCP relative file-operation arguments against the configured project root; nine relative cases first failed while nine absolute controls passed, then all 18 passed complete Nix and fresh confined host checks with unchanged launch-directory files. (done 2026-10-31 02:49 EDT; context: docs/plan_context/inference_availability.md)
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
