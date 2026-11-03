---
description: "Renaming a multicall executable can change its behavior through argv zero, so a negative control must fail for its intended reason."
datetime: 2026-11-02T23:11:13-05:00 # EST
tags: [nix, coreutils, multicall, argv-zero, test-doubles, negative-controls, mfic]
---

A symlink from a fixture named `flock` to Nixpkgs' multicall `true` did not
produce an always-successful lock impostor. The executable dispatched on its
invocation name and reported an unknown program instead.

Use an explicit minimal script for the intended behavior, such as
`writeShellScriptBin "flock" "exit 0"`, or invoke the real utility under its
actual name. Require the negative test's specific causal diagnostic, alongside
a passing real-tool control. An unrelated nonzero exit is not evidence that
the intended defect was detected.

Codescan's publication integration control catches this mistake before
qualification: the renamed utility fails during startup, whereas the explicit
no-op reaches the competing publisher and is rejected for entering selection.
The independent native lease and real-wrapper controls both pass on Linux;
native Mac qualification remains separate.
