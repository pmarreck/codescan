---
description: "In Zig 0.16 tests, the selected compiler test runner owns standard-library options; a tested module's std_options export does not enable tracing."
datetime: 2026-11-03T06:14:31-05:00 # EST
tags: [zig, zig-0-16, test-runner, std-options, tracing, compile-time, verification]
---

A standalone transport test module exported `std_options` with unexpected-error tracing enabled. Its ReleaseSafe cancellation tests passed, but the declaration did not control the standard library: the compiler-selected test runner supplies the actual root options and its own logger.

A compile-time assertion in a copied, otherwise unchanged pinned runner fails with the original options even while the transport module requests tracing. Adding the option to the actual runner and selecting it explicitly through `std.Build.addTest.test_runner` passes the same assertion and complete Nix checks. Preserve the pinned runner's original log function, test protocol, and allocator accounting rather than replacing them with a simplified custom runner.

Verify configuration at the point of consumption. A passing runtime case that never takes an unexpected-status path cannot establish that diagnostic tracing is enabled. This compile-time control proves option selection, not native Windows behavior or the cause of a historical socket failure.
