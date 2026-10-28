# Build conformance inventory

The project has one executable implementation: Zig with linked C libraries and grammars. A canonical-implementation selector would add no choice. Release packages target the five declared platform/ABI combinations; compiled unit prerequisites use ReleaseSafe, the default CLI uses ReleaseFast, and the debug package uses Debug.

| Entry or product | Current behavior | Remaining migration |
| --- | --- | --- |
| `./build` | Required Nix build for native release/debug or prepared tests; CLI copied atomically into `zig-out/bin/codescan` | Independent scope flags; verified target/profile products; serialized publication into `bin/<PF>/` |
| `./build_all` | Five release outputs retained under `.nix-out/<PF>/[<VARIANT>/]ReleaseFast`, then native `./build` | Consolidate into `./build --all` and update callers without delegation loops |
| `./test` | Exact Nix-built CLI and ReleaseSafe unit artifacts; complete available runner in a qualified Linux boundary | Preserve exact-product selection while migrating publication; native macOS/Windows full-suite boundaries remain unqualified |
| `./run` | Absent | Build current source through Nix and execute the exact selected host output |
| Public command discovery | Legacy raw output directories still resolve commands | Coordinate PATH cutover separately; no global shell edits are authorized by this inventory |
| CI packaging | Nix release packages with native macOS header/about smoke checks | Canonical PF release namespaces, owned staging validation, and native Windows qualification |

The selected release variants are musl for Linux, GNU for Windows, and no variant directory for macOS. Compiler triples and Nix system names remain their tool-native identifiers. These are the existing products, not a request to add another ABI or an unsupported platform.

No tracked generic `bin/` tree or implementation selector exists. The checkout contains a legacy native executable and an older retained Nix result. Neither was run, moved, replaced, or deleted during inventory. Existing products and their command resolutions must remain recoverable through a coordinated cutover. Nix output retention, writable staging, and published entrypoints need separate ownership; publication must never write through an immutable store link.

The current build adapter's private publication tests preserve the old command on builder failure and exercise a real prepared binary. Extend those tests with actual header/ABI verification, scope-set controls, foreign/profile coexistence, path-escape rejection, and deterministic concurrent publisher barriers before replacing publication. Stage directory validation also needs a regression before the packager can accept arbitrary caller-supplied paths safely. Retain complete product trees rather than assuming future resources can always be reduced to one executable.

This is an inventory checkpoint. No live publication, PATH cutover, native Windows execution, bundle qualification, or full convention conformance is claimed.
