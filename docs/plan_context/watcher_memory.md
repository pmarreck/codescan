# Incremental indexing ownership characterization

The watcher invokes the shared incremental indexing service. A deterministic characterization now repeats three add/modify/no-op/delete cycles through each of an absolute and a relative project-root path: 24 completed passes in one unit case. Changed source sizes force modification detection without sleeps or assumptions about filesystem timestamp resolution. The no-op pass does not rewrite its input.

Every pass checks independently declared file/symbol statistics, exact symbol/code-vector/comment-vector row counts, and recorded embedding-attempt counts. The fixture uses the real indexing service and HTTP embedding adapter with an injected responding transport, one input per batch, and fixed valid two-dimensional vectors. All filesystem state is test-owned; no live provider, index, watcher, or installed product is involved.

A standard-library accounting allocator wraps the caller allocator. After every service call, cumulative requested allocated bytes equal requested freed bytes, rather than waiting until database or fixture teardown to check. The characterization passes without a production change. It does not reproduce retained caller-allocator objects for this fixed workload or establish the historical incident's cause.

Coverage is deliberately narrower than whole-process memory: PCRE2/tree-sitter allocations, direct allocations inside SQLite extensions, real transport connection caches, OS watcher backends, peak usage, and process RSS are not measured here. Absolute and relative explicit root arguments are not proof of implicit-root CLI startup. The parent PLAN item remains open for a shared-engine growth probe, explicit/implicit startup paths, native ownership, and complete cleanup evidence. RSS alone must not be labeled a leak.

Complete Nix and the fresh confined host entry point pass 775 unit cases, with one optional OS-log skip and the unchanged two live-provider suite exclusions. No allocator implementation or production indexing behavior changes in this increment.

## Native SQLite ownership

The next characterization extends that same 24-pass fixture with SQLite's actual `sqlite3_memory_used` counter. A held 64-byte allocation must increase the counter by at least 64 bytes and freeing it must restore the initial value. Disabled or disconnected statistics therefore cannot produce a false cleanup pass. This checks the linked SQLite allocator, not the caller accounting allocator or a replacement database implementation.

For each absolute/relative root, native usage is recorded before opening the fixture database and must match after both schema teardown and database close. The database remains intentionally open during its twelve event passes, so owned connection caches are not mislabeled leaks. All original exact statistics, row/vector counts, embedding attempts, and per-call caller-allocation assertions remain. Disposable-worktree and integrated complete Nix runs pass all 812 available unit cases and every available adapter without a production change. Integrated CLI and aggregate compilation take 3 minutes 40 seconds and 3 minutes 45 seconds; the complete check's 31-second build phase includes setup and execution, not a fresh host runtime measurement. Native-platform qualification remains required.

This does not measure allocations that bypass SQLite's allocator, including direct allocations in its vector extension. It does not reproduce the historical watcher's whole-process growth, qualify an implicit-root launch, or establish a shared-engine memory budget. No live provider, index, watcher, installed product, or service is touched.
