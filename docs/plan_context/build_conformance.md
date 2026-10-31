# Build conformance inventory

The project has one executable implementation: Zig with linked C libraries and grammars. A canonical-implementation selector would add no choice. Release packages target the five declared platform/ABI combinations; compiled unit prerequisites use ReleaseSafe, the default CLI uses ReleaseFast, and the debug package uses Debug.

| Entry or product | Current behavior | Remaining migration |
| --- | --- | --- |
| `./build` | Required Nix build for native release/debug or prepared tests; independent implementation/platform scope flags; CLI copied atomically into `zig-out/bin/codescan` | Verified target/profile products; serialized publication into `bin/<PF>/` |
| `./build --all` | Five release outputs retained under `.nix-out/<PF>/[<VARIANT>/]ReleaseFast`, then native publication; replaces the retired `build_all` script | Preserve this scope contract during publication migration |
| `./test` | Exact Nix-built CLI and ReleaseSafe unit artifacts; complete available runner in a qualified Linux boundary | Preserve exact-product selection while migrating publication; native macOS/Windows full-suite boundaries remain unqualified |
| `./run` | Build current source through Nix and exec the exact selected host output without publication | Retain this contract during output-layout migration |
| Public command discovery | Legacy raw output directories still resolve commands | Coordinate PATH cutover separately; no global shell edits are authorized by this inventory |
| CI packaging | Nix release packages, owned staging, tar/ZIP payload controls, and native macOS header/about smoke checks | Canonical PF release namespaces and native Windows qualification |

The selected release variants are musl for Linux, GNU for Windows, and no variant directory for macOS. Compiler triples and Nix system names remain their tool-native identifiers. These are the existing products, not a request to add another ABI or an unsupported platform.

No tracked generic `bin/` tree or implementation selector exists. The checkout contains a legacy native executable and an older retained Nix result. Neither was run, moved, replaced, or deleted during inventory. Existing products and their command resolutions must remain recoverable through a coordinated cutover. Nix output retention, writable staging, and published entrypoints need separate ownership; publication must never write through an immutable store link.

The current build adapter's private publication tests preserve the old command on builder failure and exercise a real prepared binary. Extend those tests with actual header/ABI verification, scope-set controls, foreign/profile coexistence, path-escape rejection, and deterministic concurrent publisher barriers before replacing publication. Archive staging ownership is now covered below; package labels no longer select caller-owned filesystem paths. Retain complete product trees rather than assuming future resources can always be reduced to one executable.

This is not full build-convention conformance. No live publication, PATH cutover, native Windows execution, or bundle qualification is claimed.

## Packaging staging ownership

The October 30 confined regression reproduced caller-data loss: a successful native-runner fixture deleted an existing package directory and its sentinel. The packager used the caller's package label as the target of recursive deletion. The revised design treats that argument only as an archive-directory label, stages in a unique owned workspace, and publishes a completed archive from the destination filesystem. Package/archive names and target-specific executable extensions are validated before the builder runs. Existing archive symlinks and directories are rejected.

Behavioral controls cover unchanged caller staging, exact archive members/executable bytes/permissions, 17 rejected argument/output cases, and a controlled archive writer that writes partial bytes before failing. A further acceptance control first failed because a valid package label collided with an internal archive filename. Internal archive names now begin with a dot, which accepted package labels cannot use.

Exercising the actual ZIP branch then failed with `zip: command not found`. ZIP and unzip are now explicit tools from the existing pinned Nixpkgs input in both the development and hermetic runtime environments. Tar and ZIP payloads pass, including synthetic Windows executable filenames and exact Nix output selection for all five declared targets. These adapter fixtures do not execute native Windows binaries.

The complete Nix check and fresh confined host runner pass all available checks, including 759 unit cases, one optional OS-log skip, and the unchanged two live-provider suite exclusions. The workflow still consumes the archive, not the temporary staging directory. Archive payload layout and target namespaces are unchanged; this increment does not claim full build-convention migration or concurrent-publisher qualification.

## Build-scope consolidation

The behavioral scope regression first fails against the real old wrapper: `./build --all` exits 64 instead of requesting the declared release matrix. It replaces the former source-text presence check with complete request-set assertions, including duplicate and unexpected requests. The implementation now accepts independent implementation/platform flags, both alias spellings, reversed order, and repeated flags. With one executable implementation, implementation scope needs no selector file. All-platform mode retains the five release products and performs existing native publication last. A failed cross-build returns its original failure status before replacing the native command.

Debug and prepared-test products remain native-only because cross-platform packages for those profiles are not declared. Unsupported combinations fail before requesting a builder. Eighteen private scenarios cover these scopes, defaults, aliases, failures, paths with spaces, and symlink escapes at retained-output root/platform/variant parents. All retained parents are checked before the first build. The request adapter records actual wrapper calls; it does not compile foreign binaries or establish native Windows execution. Existing real prepared-native publication coverage remains in the complete suite.

Complete Nix and the fresh confined host entry point pass 775 unit cases and all 18 scope scenarios with unchanged exclusions. CLI/unit artifact identities are unchanged. The standalone `build_all` script is retired in Git, and documentation/file notes point to `./build --all`; earlier commits retain it recoverably. No live product or PATH setting is changed by validation. Exact-product `./run`, namespaced native products, independently verified/serialized publication, resource retention, and native Windows qualification remain open. This is a bounded interface migration, not full build-architecture conformance.

## Exact-product source execution

The new launcher regression first fails because `./run` is missing. The eight-line entrypoint now requests the checkout's default native Nix package with no output link, verifies its executable, and replaces itself with that exact output. It never invokes `./build`, a PATH-installed codescan, or a published product. Nix reads from `/dev/null` so build preparation cannot consume the command's stdin; the caller's directory is preserved.

Eight private scenarios extend the existing seven build controls. They verify the exact NUL-delimited builder arguments, spaced and empty CLI arguments, unchanged stdin/stdout/stderr, caller directory, unchanged process identity after exec, child status 37, builder status 19, missing Nix status 127, missing/nonexecutable/multiple outputs, and an actual prepared CLI's about result. Stale PATH and legacy product fixtures cannot satisfy the tests. Every case checks that publication paths remain untouched. All mutation stays inside the qualified boundary, with no real checkout publication or PATH cutover.

Complete Nix and the fresh confined host entry point pass all available checks and 776 unit cases, retaining one optional OS-log case and two live-provider suite exclusions. Compiled artifact identities are unchanged. The flake patches the new script's shebang for hermetic execution. This completes explicit source execution, not namespaced/serialized publication, native Windows runtime qualification, or full build-convention conformance.
