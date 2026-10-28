# sqlite-vec cleanup callback compatibility

The pinned sqlite-vec revision `c9d3630f56637276829d9ab0c54b1116c6d3e2ef` defines `vector_cleanup` as `void (*)(void *)` and `fvec_cleanup` as `void (*)(float *)`. Its float decoder writes the latter through a cast into the generic cleanup slot. Calling the borrowed float-vector callback through the generic slot has an incompatible function type, even when the platform ABI passes both pointer arguments the same way.

Switching correctness artifacts to ReleaseSafe reproduced an illegal-instruction trap at `cleanups[i](vectorDatas[i])` in `vec0Update_Insert`. The existing unit suite reached it during vector insertion, and the actual fixture generator also crashed. These are real-adapter RED controls; runtime checking remains enabled.

The project owns `patches/sqlite-vec-cleanup-callbacks.patch`. It aliases the float cleanup type to the generic type and gives the no-op callback the matching `void *` parameter. Nix applies this patch to the exact fetched revision before constructing Zig's offline system-package tree. No store file, neighboring checkout, dependency hash, or upstream repository is modified.

Remove the patch only after a pinned dependency revision supplies compatible cleanup callbacks and the unpatched ReleaseSafe unit suite plus fixture-generator/CLI checks pass. Upstream reporting remains pending; no external issue or message has been sent. Native callback verification on other operating systems remains separate from successful cross-compilation.

## Scanner callback declarations

With the sqlite-vec patch applied, the ReleaseSafe fixture generator and CLI checks pass. The unit suite then reaches the Bash scanner and traps in a shared callback-type failure block. The optimized stack trace points at an unrelated inlined stack helper; disassembly instead shows Clang's function-type metadata checks. The scanner's creation definition uses an empty C parameter list while its generated declaration and tree-sitter callback use `(void)`; the compiled type hashes differ.

The grammar builder now emits a C translation-unit wrapper that declares the creation callback with `(void)` before including the original scanner. This applies the declared callback contract to both vendored and pinned scanner sources without modifying their contents or disabling checks. A forced-include header attempt failed Zig's dependency-cache preflight, so the wrapper is an explicit generated compiler input instead. Complete Nix and fresh host verification now pass under ReleaseSafe: 752 unit cases passed, one optional unit case was skipped, and the available CLI/MCP/watcher checks passed. Two live-provider suites remain excluded.
