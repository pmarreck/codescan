# Staged dependency parser interoperability

The shared `git-dependency-portability-gate` rejected an unchanged runtime Zig cache default in `flake.nix` as a dependency on `/.cache/zig`. Inspection of its `nix_tokens` function found that it ends an indented string at the first pair of single quotes, including the valid escaped shell interpolation prefix `''${`. It then interprets part of the shell string as a Nix path.

The rejection was reproduced by the actual pre-commit hook. The project uses an equivalent double-quoted Nix shell string now. The existing cache inheritance/default tests pass, and the real staged gate passes without an override. All five sandboxed release builds use the same declared source inputs; runtime cache defaults are not dependency sources.

The shared parser still needs a regression for escaped interpolation in indented strings, including nested quoting and ordinary runtime paths. Its eventual fix must retain rejection controls for actual host-local dependency declarations. Contacting that project's agent awaits approval for the additional recipient; no hook change or bypass was made here.
