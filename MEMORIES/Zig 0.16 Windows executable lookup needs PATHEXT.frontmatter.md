---
description: "A cleared Windows environment needs PATHEXT as well as PATH for Zig 0.16 to resolve an extensionless subprocess name such as git to git.exe."
datetime: 2026-11-02T21:13:02-05:00 # EST
tags: [zig, zig-0-16, windows, std-io, process-spawn, subprocess, environment, path, pathext, git, test-isolation]
---

The pinned Zig 0.16 threaded Windows process backend scans the parent's `PATH`
and `PATHEXT`. A missing `PATHEXT` becomes an empty extension list. Setting
`PATH` to a directory containing `git.exe` therefore does not suffice for
`std.process.spawn` with argument zero `git` in a cleared environment.

Preserve isolation instead of inheriting the ambient runner's environment.
Provide the exact approved executable directory and a controlled `.EXE`
extension list. Retain private Git configuration and user/application paths.
This is a version-specific subprocess-discovery requirement, not evidence that
Git is uninstalled or that arbitrary shell command lookup is needed.

Evidence: native Windows commit `08865fbb` reports `FileNotFound` in both Git
setup fixtures on x64 and ARM64 despite the pinned Git products being present.
Commit `4081fc92` supplies `.EXE` and asserts that it replaces an ambient `.BAT`
value. [Its native qualification](https://github.com/pmarreck/codescan/actions/runs/41563565042)
validates each complete 813-case report with 806 passes, seven existing skips,
and zero failures, plus both twenty-process cancellation campaigns.
