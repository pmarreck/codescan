---
description: "The pinned latency engine fingerprints the real configuration file's parent, not the command's working directory."
datetime: 2026-11-02T23:11:13-05:00 # EST
tags: [profiling, latency, provenance, configuration, source-identity, worktrees, test-isolation]
---

At performance_profiling commit `ecf713b81a74a51f76719bf9debc44fe23a0b331`,
`load_config` resolves the configuration's real path and returns its parent
directory; `begin` fingerprints that directory. Executing tests in a different
working directory does not change the recorded source root.

Give each disposable worktree its own ignored regular private configuration
file. Reusing an external configuration, including through a symlink, can
record the wrong tree even when every configuration value is identical.
Before recording, require the configuration's real parent to equal the
intended checkout. Keep history outside the project and private URLs out of Git.

This mismatch was found in a queued codescan serialization run. The job was
canceled before admission, without executing tests or creating a measurement,
then resubmitted with a private local copy and a root-location guard.
