---
description: "Matching-only allocation fixtures can miss owned status fields that exist only on mismatch or error paths."
datetime: 2026-11-03T04:25:21-05:00 # EST
tags: [zig, allocators, ownership, conditional-allocation, error-paths, sqlite, indexing, model-mismatch]
---

The 24-pass matching-model indexing fixture released every caller allocation, but did not exercise `InitSchemaResult.stored_embedding_model`: that field owns an allocated copy only when a populated index's stored model differs from the requested model. Discarding the schema result in incremental indexing therefore leaked only on that branch.

A separate regression primes a populated index under `stored-model`, then varies matching/mismatching models, absolute/relative roots, and unchanged-file success/missing-root failure. The original implementation retains exactly 12 bytes on the first mismatched error path; the standard allocator trace independently identifies the schema initialization allocation. Binding the result and deferring its cleanup passes all 24 attempts while preserving exact rows, vectors, embedding calls, and stored metadata.

Exercise conditional ownership and both successful and failed returns, not only repeated steady-state work. This reproduces a service cleanup bug, not the historical watcher incident; watcher startup normally rejects a model mismatch before entering its event loop.
