---
description: "A fake native function table does not isolate a Zig fixture when a callback argument still retains platform-specific linker dependencies."
datetime: 2026-11-03T06:55:40-05:00 # EST
tags: [zig, zig-0-16, callbacks, function-pointers, linker, ffi, test-isolation, cross-platform]
---

A fake FSEvents function table still received the real event callback. Taking that callback's address retained its reference to `dispatch_semaphore_signal`, so the Linux ReleaseSafe test artifact failed to link even though the fake framework never invoked the callback. This was a fixture setup failure, not a reproducer of the startup defects.

The private implementation now borrows its event callback as a parameter. The production wrapper supplies the unchanged real callback; fixtures supply a callback that fails immediately if unexpectedly invoked. A guarded, nonempty comparison confirms that the original 1,320-byte startup body is otherwise identical before behavior changes. The tests then reach the actual creation/start failures and allocation leak without framework calls or new platform skips; complete Nix checks pass after those defects are corrected.

At native boundaries, isolate callback arguments as well as the function table. Keep separate real native event tests: passing a fake-framework fixture does not qualify event delivery, framework ABI, or concurrency behavior.
