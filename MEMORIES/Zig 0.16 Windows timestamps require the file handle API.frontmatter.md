---
description: "Zig 0.16 Windows Dir.setTimestamps panics, while File.setTimestamps is implemented; open the file, set its timestamps, then close it before subsequent work."
datetime: 2026-11-02T21:08:00-05:00 # EST
tags: [zig, zig-0-16, windows, std-io, timestamps, file-handle, cross-platform, testing]
---

In the pinned Zig 0.16 threaded backend, `dirSetTimestamps` explicitly panics
on Windows. `fileSetTimestamps` implements the Windows operation. This is a
version-specific backend distinction, not evidence that Windows lacks timestamp
support or that a later Zig version has the same limitation.

Open the existing file with read/write access, call `File.setTimestamps`, and
close the handle before indexing or other subsequent operations. Keep the
original assertions; an additional Windows skip is unnecessary.

Evidence: commit `9209c2c6` aborts in native Windows case 277 at the directory
operation. Commit `08865fbb` changes both indexer marker fixtures to the file
operation. In [its native run](https://github.com/pmarreck/codescan/actions/runs/41558856964),
cases 277 and 282 pass on both x64 and ARM64. That complete run still reports
eighteen other fixture failures per architecture; these passing cases do not
establish an overall passing Windows qualification.
