---
description: "On Linux, a piped core collector can ignore RLIMIT_CORE, so a deliberate crash regression must disable dumpability inside the test process before the dangerous call."
datetime: 2026-11-03T09:14:28-05:00 # EST
tags: [linux, coredump, core-dump, rlimit-core, prctl, dumpable, test-isolation, stack-overflow, zig]
---

An OCaml scanner regression deliberately overflows the old recursive implementation with 262,144 nested comments. A zero core-size limit alone does not confine that experiment when the host's core pattern invokes a collector: Linux ignores that limit for piped dumps. Do not change global core policy or invoke the unsafe parser directly from an ordinary host process.

The Linux test process reads its current dumpability, sets it to zero, checks the change before entering the C scanner, and restores the previous setting on normal return. The original code then fails at the recursive scanner call with an ordinary captured crash trace, without requesting a host core dump. This isolates the intended negative control while retaining the test on other platforms after the repair. It does not suppress stderr traces or establish crash-collector isolation on other operating systems.

See [core dump behavior](https://man7.org/linux/man-pages/man5/core.5.html) and [process dumpability](https://man7.org/linux/man-pages/man2/PR_SET_DUMPABLE.2const.html). Keep the suppression in the actual crashing process, not merely its launcher, and verify the parser result and following declaration after the fix rather than treating survival alone as success.
