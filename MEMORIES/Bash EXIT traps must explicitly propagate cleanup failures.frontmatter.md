---
description: "Failed EXIT-trap commands do not automatically override Bash's original status, so cleanup failures must exit explicitly."
datetime: 2026-11-03T08:24:44-05:00 # EST
tags: [bash, shell, exit-trap, exit-status, cleanup, error-handling, testing]
---

A failing command in a Bash `EXIT` trap does not by itself replace the body's exit status. The pinned Bash controls `trap 'false' EXIT; true` and `trap 'exit 7' EXIT; true` return 0 and 7 respectively. A real private-Nix-store fixture similarly printed removal permission errors while its successful body still returned zero.

Capture the original status before cleanup, preserve it when cleanup succeeds, and explicitly report and exit nonzero when cleanup fails:

```bash
trap 'saved_status=$?; if ! cleanup_owned_fixture; then [ "$saved_status" -ne 0 ] || saved_status=1; fi; exit "$saved_status"' EXIT
```

Judge success by the process status, not an earlier success footer. A four-case control must cover successful/failed bodies crossed with successful/failed cleanup, preserving the original failure when both fail; an independent count must also reject an omitted case. Keep permission repair confined to the exact owned allocation, with physical traversal and separate symlink-target controls; see the existing copied-product permission lesson. The complete entry point must exercise the fatal-cleanup path as well as successful cleanup.

The cleanup helper itself must accumulate every failed operation. A later successful removal can otherwise hide an earlier error even from an explicit exit-status handler. Include a first-step failure followed by success, plus a real nonempty-directory control. If publication has already finished, report staging cleanup failure without undoing valid selected products; preserve the original failure when the body also failed.
