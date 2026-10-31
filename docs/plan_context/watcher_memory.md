# Incremental indexing ownership characterization

The watcher invokes the shared incremental indexing service. A deterministic characterization now repeats three add/modify/no-op/delete cycles through each of an absolute and a relative project-root path: 24 completed passes in one unit case. Changed source sizes force modification detection without sleeps or assumptions about filesystem timestamp resolution. The no-op pass does not rewrite its input.

Every pass checks independently declared file/symbol statistics, exact symbol/code-vector/comment-vector row counts, and recorded embedding-attempt counts. The fixture uses the real indexing service and HTTP embedding adapter with an injected responding transport, one input per batch, and fixed valid two-dimensional vectors. All filesystem state is test-owned; no live provider, index, watcher, or installed product is involved.

A standard-library accounting allocator wraps the caller allocator. After every service call, cumulative requested allocated bytes equal requested freed bytes, rather than waiting until database or fixture teardown to check. The characterization passes without a production change. It does not reproduce retained caller-allocator objects for this fixed workload or establish the historical incident's cause.

Coverage is deliberately narrower than whole-process memory: native SQLite, PCRE2/tree-sitter allocations, real transport connection caches, OS watcher backends, peak usage, and process RSS are not measured here. Absolute and relative explicit root arguments are not proof of implicit-root CLI startup. The parent PLAN item remains open for a shared-engine growth probe, explicit/implicit startup paths, native ownership, and complete cleanup evidence. RSS alone must not be labeled a leak.

Complete Nix and the fresh confined host entry point pass 775 unit cases, with one optional OS-log skip and the unchanged two live-provider suite exclusions. No allocator implementation or production indexing behavior changes in this increment.
