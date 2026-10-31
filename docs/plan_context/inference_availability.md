# Embedding failures during search freshness

A responding HTTP endpoint does not establish that embedding requests work. A private MCP regression uses the actual HTTP adapter as an unrelated server: probes receive an HTTP reply, but embedding requests receive 404. The original MCP session returned stale lexical results and successfully read a subsequent file, yet reported `inference_unavailable=false` without repair advice.

The HTTP embedder now optionally records each attempt's original error in caller-owned diagnostic state. A successful retry clears it. Pre-search reconciliation uses that state to retain provider-failure advice when falling back to an existing index. Error codes and retry behavior are unchanged. The observer does not capture SQLite failures, and local allocation failure is not classified as a provider outage.

The real stdio regression requires lexical results, inference advice, continued file access, unchanged original symbol rows, and retained code/comment vector counts. Unit coverage checks original HTTP/connection/allocation errors and recovery. Readiness uses an actual listening notification with a bounded hang guard, not sleeps. The fixture owns its server, database, and process cleanup inside the qualified test boundary; no live provider or index is used.

A separate policy choice remains open. Failed incremental work currently can leave a new lexical row without a vector: the fixture changed from four symbols/four vectors to five/four. The preservation regression permits either retaining such partial work or rolling it back; it does not require a new row to remain. Full rollback remains an undecided policy change.

The complete Nix check and fresh host runner pass 754 unit cases, with one optional unit skip and two live-provider suite exclusions. The diagnostic slot is borrowed for synchronous adapter calls and remains valid until those calls finish; it does not retain the caller's allocator or response buffers.

The fast rejection case does not reproduce the historical slow semantic request. No request deadline, retry policy, or index-replacement policy is changed by that diagnostic fix.

## Held pre-search embedding

An October 30 characterization uses the real MCP search handler and standard HTTP transport with a private, ephemeral loopback provider. Its model endpoint answers successfully. The embedding endpoint records a complete POST, then waits on a test-owned event. The recorded input contains the pending source symbol rather than the search query, identifying freshness reconciliation as the blocked operation. The handler's completion flag remains false at that barrier. Releasing the provider returns HTTP 404; the handler then returns the retained lexical symbol with inference-unavailable advice.

The fixture uses no sleeps or elapsed-time thresholds. Every task is joined before its request, settings, response, database, or listener storage is released. The independent unit-process hang guard bounds a broken fixture. The complete Linux Nix check and fresh confined host runner pass 757 unit cases, with the existing optional OS-log skip and two live-provider exclusions. This characterization covers the actual tool handler, not a separately instrumented stdio dispatch loop. Code inspection shows that the current loop waits synchronously for each handler before reading the next message.

This establishes one controlled blocking path, not the cause or duration of the historical incident. A total pre-search wait budget remains a policy choice: should search fall back to the existing index after a bounded reconciliation attempt while explicit index/update commands retain cold-model waits? No budget, concurrency policy, retry behavior, or partial-update rollback policy changed in this increment. Native cancellation qualification remains separate.
