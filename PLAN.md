# PLAN

Completed work is recorded in docs/PLAN_LOG.md. Earlier planning history remains recoverable in Git; private operational context is retained outside the repository. Execution resumed on 2026-10-30; open items remain ordered below.

## CI completion and maintenance

- [ ] Verify native/shared Rust signature queries on exact-commit Mechatron Prime CI and GitHub Actions; complete Nix/fresh confined host checks pass 790 unit cases and ten actual CLI query forms after recognition, empty-result, grouped-input, and malformed-tail failures.
- [x] Verify native/shared Zig signature queries on exact-commit Mechatron Prime CI and GitHub Actions; both pass for 5fe609d2, including all five release targets, native macOS smoke checks, and five nonempty canonical archives after 784 passing local unit cases and the original CLI failure. (done 2026-10-31 09:23 EDT; commit 5fe609d2)
- [x] Verify read-file orchestration extraction on exact-commit Mechatron Prime CI and GitHub Actions; both pass for 9b2b1cfb, following 779 passing unit cases and the existing actual CLI/MCP controls. (done 2026-10-31 08:54 EDT; commit 9b2b1cfb)
- [x] Verify all five canonical archive jobs and uploaded artifacts on exact-commit GitHub Actions plus all five Mechatron Prime release builds; bc6b35b9 passes both services with exactly five nonempty, unexpired canonical archives, without creating a tag or release. (done 2026-10-31 08:54 EDT; commit bc6b35b9)
- [ ] Report the shared profiler's failed-run WITHIN_BUDGET label and verify its repair; contact approval is pending and the failed diagnostic remains ineligible for compliance. (context: docs/plan_context/test_latency.md)
- [ ] Verify the infrastructure owner's build-budget literal-argument repair; the owner acknowledged the request and confirmed the source/installed-helper defect, but implementation remains queued, with the resource envelope and equivalent-syntax workaround unchanged.
	- [x] May the infrastructure owner receive the build-budget fix request? Answer: yes; send the request for literal Bash argument preservation without changing resource policy here. (done 2026-10-31 08:41 EDT)

## Watcher reliability

- [ ] Reproduce slow MCP semantic search in a disposable fixture with pending freshness work and bounded requests; October 27 root/status calls responded with the watcher stopped, but the historical cause remains unestablished. (context: docs/plan_context/inference_availability.md)
	- [ ] Decide whether pre-search reconciliation should have a total wait budget with lexical fallback while explicit indexing retains cold-model waits; no budget or request-policy change has been selected. (context: docs/plan_context/inference_availability.md)
	- [ ] Decide whether failed incremental embedding should retain new lexical rows as pending work or roll them back; the private fixture grew from four symbols/four vectors to five/four while retaining working search and file reads. (context: docs/plan_context/inference_availability.md)
- [ ] Identify the historical watcher cause only if a new reproducer or underlying SQLite record becomes available; currently blocked on evidence and not on further recollection. (context: docs/plan_context/watcher_sqlite_failures.md)

## After shipping

- [ ] Extend partial signature queries in the selected language order, beginning with the existing partial-signature acceptance example. (decision 2026-10-20)
	- [x] Resolve the signature-query syntax choice; Answer: accept both native language signatures and the shared Roc-style form, preserving the approved Zig, Rust, then TypeScript implementation order. (done 2026-10-31 08:41 EDT)
	- [x] Add native/shared Zig signature queries after failing recognition and actual CLI regressions; complete Nix/fresh confined host checks pass 784 unit cases, exact declaration sets, nested types, qualifiers, name boundaries, and seven actual CLI query forms without inference or live-index changes. (done 2026-10-31 09:10 EDT)
	- [x] Add native/shared Rust signature queries for functions/methods with explicit generic/where constraints, receivers, lifetimes, nested types, and actual CLI coverage after failing regressions; complete Nix/fresh confined host checks pass 790 unit cases without inference or live-index changes. (done 2026-10-31 09:31 EDT)
	- [ ] Add TypeScript signature-query matching for typed functions/methods with actual CLI coverage, including mixed-language shared matches and native-syntax isolation.

## Validation and performance

- [ ] Reduce the latest ReleaseSafe host runner's 6.36-second execution lower bound and 4.01-second flake-evaluation span; retain prior broad variation and the delayed diagnostic finalization without accepting a baseline or changing coverage, exclusions, or the five-second budget. (context: docs/plan_context/test_latency.md)
- [ ] Add controlled TCP-blackhole/TLS-cancellation fixtures and run request-deadline checks on qualified native macOS/Windows runners; native execution depends on runner availability, not cross-build success.
- [ ] Reproduce watcher heap growth with deterministic event batches and explicit/implicit roots using the shared profiling engine; shared-service caller-allocator ownership is clean in the bounded fixture, while native watcher, transport, and implicit-root profiling remain open. (context: docs/plan_context/watcher_memory.md)
- [ ] Recover the interrupted reindex sweep's private completion ledger and exact remaining project set before resuming live writes; the available July handoff/static bookkeeping cannot establish the later completion state or authorize a new all-project sweep.

## Architecture and features

- [ ] Bring project builds and publication into conformance with the `cross-platform-project-build-arch` convention; preserve existing products and coordinate PATH cutover separately. (context: docs/plan_context/build_conformance.md)
	- [ ] Use `macos-arm64`, `linux-amd64`, `linux-arm64`, `mswin-amd64`, and `mswin-arm64` namespaces with separate ABI/profile products; preserve native compiler/Nix identifiers and keep writable outputs separate from retained Nix outputs.
		- [x] Align GitHub's archive/release matrix with all five canonical PF targets after independent matrix, asset-list, and packaging-environment failures; complete Nix/fresh host checks pass 779 unit cases and tar/ZIP controls, with both Windows jobs cross-building on Linux and live CI verification pending. (done 2026-10-31 08:30 EDT; context: docs/plan_context/build_conformance.md)
	- [ ] Publish verified commands in `bin/<PF>/` without runtime selector wrappers; preserve previous selections on failure, serialize publishers, retain runtime resources, support native Windows entrypoints, and coordinate PATH changes separately.
	- [ ] Prove conformance through failing behavioral regressions in `./test`, real binary-header/ABI checks, host/foreign/profile coexistence, and native execution where available; report unavailable target checks without claiming full conformance.
- [ ] Move update database preparation/freshness into the shared service after characterization tests prove CLI/MCP/HTTP behavior remains identical.
- [x] Complete the bounded CLI command extraction; Answer: stop with the tested root/read-file components, with any further extraction tied to a concrete feature or bug rather than a full CLI/scorer rewrite. (done 2026-10-31 08:41 EDT; context: docs/plan_context/inference_availability.md)
	- [x] Resolve the remaining extraction scope; Answer: further extraction only as needed, not every remaining CLI/scorer component. (done 2026-10-31 08:41 EDT)
	- [x] Extract read-file orchestration behind the full/partial hashline tests and actual CLI/MCP controls; the body is byte-preserved apart from read/JSON ports, and complete Nix/fresh host checks pass 779 unit cases without changing paths, ranges, hashes, output, or errors. (done 2026-10-31 08:18 EDT; context: docs/plan_context/inference_availability.md)
	- [x] Extract root-command orchestration behind the existing repository-boundary and 20 actual CLI/MCP controls; the handler body is byte-preserved apart from its injected lookup port, and complete Nix/fresh host checks pass 779 unit cases without changing CWD, output, watcher observations, or exit policy. (done 2026-10-31 07:52 EDT; context: docs/plan_context/inference_availability.md)
	- [x] Repair doctor report message ownership after the standard allocator exposes a seven-byte leak on failed array growth; all 24 allocation boundaries preserve earlier entries and pass complete Nix/fresh host checks with 779 passing unit cases and unchanged healthy output. (done 2026-10-31 07:39 EDT; context: docs/plan_context/inference_availability.md)
- [ ] Add `codescan symbols --depth N` with match-relative child expansion, root-depth behavior when no pattern is supplied, invalid-value checks, and JSON/human truncation tests.
	- [x] Resolve symbols depth semantics; Answer: match-relative depth preserves deep name lookup, depth 0 returns a matched symbol without children, and depth 1 includes its immediate children. (done 2026-10-31 08:41 EDT)
- [ ] Migrate one remaining vendored grammar at a time to an exact reproducible source pin, retaining local patches and symbol/range regressions.

## Tabled (not actionable)

- [ ] Evaluate concise I/O wrappers without changing lifetime or concurrency semantics; tabled pending a concrete use case and renewed direction.
- [ ] Specify whole-file/hashline-targeted comment generation with model/language settings, existing-comment protection, dry runs, and explicit overwrite behavior; tabled pending a concrete use case and renewed direction.
- [ ] Establish a versioned relevance corpus with independently judged expected symbols/files and MRR, nDCG, and Recall@k; tabled until those judgments and renewed direction are available.
