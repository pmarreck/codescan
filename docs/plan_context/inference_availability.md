# Embedding failures during search freshness

A responding HTTP endpoint does not establish that embedding requests work. A private MCP regression uses the actual HTTP adapter as an unrelated server: probes receive an HTTP reply, but embedding requests receive 404. The original MCP session returned stale lexical results and successfully read a subsequent file, yet reported `inference_unavailable=false` without repair advice.

The HTTP embedder now optionally records each attempt's original error in caller-owned diagnostic state. A successful retry clears it. Pre-search reconciliation uses that state to retain provider-failure advice when falling back to an existing index. Error codes and retry behavior are unchanged. The observer does not capture SQLite failures, and local allocation failure is not classified as a provider outage.

The real stdio regression requires lexical results, inference advice, continued file access, unchanged original symbol rows, and retained code/comment vector counts. Unit coverage checks original HTTP/connection/allocation errors and recovery. Readiness uses an actual listening notification with a bounded hang guard, not sleeps. The fixture owns its server, database, and process cleanup inside the qualified test boundary; no live provider or index is used.

A separate policy choice remains open. Failed incremental work currently can leave a new lexical row without a vector: the fixture changed from four symbols/four vectors to five/four. The preservation regression permits either retaining such partial work or rolling it back; it does not require a new row to remain. Full rollback remains an undecided policy change.

The complete Nix check and fresh host runner pass 754 unit cases, with one optional unit skip and two live-provider suite exclusions. The diagnostic slot is borrowed for synchronous adapter calls and remains valid until those calls finish; it does not retain the caller's allocator or response buffers.

This fast rejection case does not reproduce the historical slow semantic request. Held embedding requests and native deadline qualification remain separate work. No request deadline, retry policy, or index-replacement policy is changed by this diagnostic fix.
