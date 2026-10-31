# PLAN

Completed work is recorded in docs/PLAN_LOG.md. Earlier planning history remains recoverable in Git; private operational context is retained outside the repository. Execution resumed on 2026-10-30; open items remain ordered below.

## CI completion and maintenance

- [x] Verify Nix-declared Zig build-job forwarding on exact-commit Mechatron Prime CI and GitHub Actions; all five release targets and native macOS smoke checks pass for d750e0a8, following six real-phase controls, all 778 passing unit cases, and three byte-identical executables. (done 2026-10-31 07:30 EDT; commit d750e0a8)
- [x] Verify batched immutable Nix gates on exact-commit Mechatron Prime CI and GitHub Actions; all five release targets and native macOS smoke checks pass for 472e443a, following 778 passing unit cases, both gate targets, and failure-continuation controls. (done 2026-10-31 07:34 EDT; commit 472e443a)
- [x] Verify complete native retained products on exact-commit Mechatron Prime CI and GitHub Actions; all five release targets and native macOS smoke checks pass for 1fc7f994, following 778 passing unit cases, mapped profiles, resources, foreign coexistence, retries, and refusal controls. (done 2026-10-31 07:52 EDT; commit 1fc7f994)
- [x] Verify doctor-report allocation ownership on exact-commit Mechatron Prime CI and GitHub Actions; all five release targets and native macOS smoke checks pass for 7f5200b4, following the original seven-byte allocator failure, all 24 failure boundaries, and 779 passing unit cases. (done 2026-10-31 08:05 EDT; commit 7f5200b4)
- [x] Verify root-command extraction on exact-commit Mechatron Prime CI and GitHub Actions; all five release targets and native macOS smoke checks pass for b1d5fc34, following 779 passing unit cases and unchanged handler behavior in all existing actual-adapter controls. (done 2026-10-31 08:18 EDT; commit b1d5fc34)
- [ ] Verify read-file orchestration extraction on exact-commit Mechatron Prime CI and GitHub Actions; complete Nix/fresh host checks pass 779 unit cases, both hashline read cases, and all existing actual CLI/MCP controls.
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

- [ ] Reduce the latest ReleaseSafe host runner's 6.36-second execution lower bound and 4.17-second flake-evaluation span; retain prior broad variation and the delayed diagnostic finalization without accepting a baseline or changing coverage, exclusions, or the five-second budget. (context: docs/plan_context/test_latency.md)
	- [x] Test sharing the pure source fileset across Nix systems; Answer: all 24 package derivations remain identical, but paired one-/twelve-CPU times overlap and vary, so the candidate is reverted and measurements retained without a speedup or baseline claim. (done 2026-10-31 08:05 EDT; context: docs/plan_context/test_latency.md)
- [ ] Add controlled TCP-blackhole/TLS-cancellation fixtures and run request-deadline checks on qualified native macOS/Windows runners; native execution depends on runner availability, not cross-build success.
- [ ] Reproduce watcher heap growth with deterministic event batches and explicit/implicit roots using the shared profiling engine; shared-service caller-allocator ownership is clean in the bounded fixture, while native watcher, transport, and implicit-root profiling remain open. (context: docs/plan_context/watcher_memory.md)
- [ ] Recover the interrupted reindex sweep's private completion ledger and exact remaining project set before resuming live writes; the available July handoff/static bookkeeping cannot establish the later completion state or authorize a new all-project sweep.

## Architecture and features

- [ ] Bring project builds and publication into conformance with the `cross-platform-project-build-arch` convention; preserve existing products and coordinate PATH cutover separately. (context: docs/plan_context/build_conformance.md)
	- [ ] Use `macos-arm64`, `linux-amd64`, `linux-arm64`, `mswin-amd64`, and `mswin-arm64` namespaces with separate ABI/profile products; preserve native compiler/Nix identifiers and keep writable outputs separate from retained Nix outputs.
		- [ ] Align the GitHub archive/release matrix with all five declared targets and canonical PF names after failing full-set controls; add both Windows ZIP builds without claiming native Windows execution.
		- [x] Retain complete native release/debug products after a failing namespaced-product regression; all three declared Nix-host mappings, two profiles, resources, foreign coexistence, retries, eight path refusals, and four unsupported-host cases pass complete Nix/fresh confined host checks without live publication or PATH changes. (done 2026-10-31 07:29 EDT; context: docs/plan_context/build_conformance.md)
	- [ ] Publish verified commands in `bin/<PF>/` without runtime selector wrappers; preserve previous selections on failure, serialize publishers, retain runtime resources, support native Windows entrypoints, and coordinate PATH changes separately.
	- [ ] Prove conformance through failing behavioral regressions in `./test`, real binary-header/ABI checks, host/foreign/profile coexistence, and native execution where available; report unavailable target checks without claiming full conformance.
- [ ] Move update database preparation/freshness into the shared service after characterization tests prove CLI/MCP/HTTP behavior remains identical.
- [ ] Extract one CLI command/scorer component at a time behind existing behavioral tests; begin with command orchestration rather than rewriting scoring policy.
	- [ ] Resolve the remaining extraction scope: finish after tested root/read-file components and extract further only for concrete needs, or move every remaining CLI/scorer component out now; generic further extraction awaits this decision while independent work continues.
	- [x] Extract read-file orchestration behind the full/partial hashline tests and actual CLI/MCP controls; the body is byte-preserved apart from read/JSON ports, and complete Nix/fresh host checks pass 779 unit cases without changing paths, ranges, hashes, output, or errors. (done 2026-10-31 08:18 EDT; context: docs/plan_context/inference_availability.md)
	- [x] Extract root-command orchestration behind the existing repository-boundary and 20 actual CLI/MCP controls; the handler body is byte-preserved apart from its injected lookup port, and complete Nix/fresh host checks pass 779 unit cases without changing CWD, output, watcher observations, or exit policy. (done 2026-10-31 07:52 EDT; context: docs/plan_context/inference_availability.md)
	- [x] Repair doctor report message ownership after the standard allocator exposes a seven-byte leak on failed array growth; all 24 allocation boundaries preserve earlier entries and pass complete Nix/fresh host checks with 779 passing unit cases and unchanged healthy output. (done 2026-10-31 07:39 EDT; context: docs/plan_context/inference_availability.md)
- [ ] Add `codescan symbols --depth N` with explicit root-depth, invalid-value, and JSON/human truncation tests.
	- [ ] Resolve whether depth is relative to matched symbols with child expansion or an absolute file-root limit that also excludes deeper name matches; existing design text lists the flag without defining its semantics, and independent work continues pending the answer.
- [ ] Migrate one remaining vendored grammar at a time to an exact reproducible source pin, retaining local patches and symbol/range regressions.

## Tabled (not actionable)

- [ ] Evaluate concise I/O wrappers without changing lifetime or concurrency semantics; tabled pending a concrete use case and renewed direction.
- [ ] Specify whole-file/hashline-targeted comment generation with model/language settings, existing-comment protection, dry runs, and explicit overwrite behavior; tabled pending a concrete use case and renewed direction.
- [ ] Establish a versioned relevance corpus with independently judged expected symbols/files and MRR, nDCG, and Recall@k; tabled until those judgments and renewed direction are available.
