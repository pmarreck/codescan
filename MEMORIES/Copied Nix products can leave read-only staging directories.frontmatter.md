---
description: "Copied Nix product directories can remain read-only, so cleanup must change only owned copies after archiving and must not follow product links."
datetime: 2026-11-03T01:55:01-05:00 # EST
tags: [nix, packaging, archives, permissions, read-only, cleanup, symlinks, test-isolation]
---

A complete-product packaging regression succeeds at creating its archive but leaves staging behind because copied directories remain read-only. A successful archive is not proof that cleanup succeeded.

Preserve source and archive permissions. Only after archiving, make the unique owned staging-directory copies writable before removing them. A non-link-following directory walk avoids changing linked source products. Never apply the permission repair to the producer's output or caller-owned trees. Preserve an existing failure status; a cleanup-only failure must itself fail and report the retained staging path.

The persistent controls in `tests/unit/test-ci-architecture` require no staging leak, unchanged original read-only directories, preserved extracted directory permissions, and unchanged caller data. Both tar and ZIP branches exercise the real packager.
