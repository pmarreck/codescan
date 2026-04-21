# Env-Var Expansion Inside `.codescan/config`

Date: 2026-04-19
Source: `inbox/2026-04-18-config-env-var-expansion.md` (from docscan, via Peter)

## Problem

`codescan` stores `embedding_api_key` in `.codescan/config` (`src/config.zig:107, :229`). The only way to commit that config without leaking the secret is today's `CODESCAN_EMBEDDING_SERVER_API_KEY` env-var override, which forces users to keep all secret knowledge in their shell rc. Users want the common `${VAR}` / `${VAR:-default}` pattern inside config files so a committed config can reference env vars directly while the raw placeholder stays on disk.

`docscan` shipped this behavior and validated it via `tests/cli/test-cli` (behaviors 69–78). Reference impl: `docscan/cli/main.c:1344-1509` (`expand_env_vars_depth`, `find_matching_brace`, `str_has_env_ref`).

## Goals

1. Support `$VAR`, `${VAR}`, `${VAR:-DEF}`, `${VAR-DEF}`, `$$` forms in config values.
2. Support nested defaults up to at least 10 levels deep; cap recursion to prevent infinite loops (e.g. `A=${A}`).
3. On load, resolve references against the environment; missing references without a default expand to empty string.
4. Preserve the raw pre-expansion string for `embedding_api_key` so any config write-back re-emits the placeholder, not the resolved secret.
5. Test isolation: config-parsing tests must never read the developer's real environment for `CODESCAN_*`, `OMLX_*`, or any other variable the project actually uses.

## Non-Goals

- `${VAR:=default}` (assigns into env), `${VAR:?error}`, `${VAR:+replacement}`, command substitution `$(cmd)`.
- Raw-preservation for non-secret fields (URL, model, search weights, etc.). They expand on load and never need the placeholder back.
- Adding a `codescan config set` CLI surface. Only automatic/internal write paths (`writeConfigValues` call sites) need raw-preservation behavior.

## Approach

Single Zig module for the expansion state machine, wired in at the value-parse step of `config.zig`. Raw-preservation is a dedicated optional field (`embedding_api_key_raw`) tracked on `Config`; `writeConfigValues` gets a seam that consults that field before writing.

Rejected alternatives:
- **Do expansion only at final use-site in `main.zig`.** Scatters expansion logic across call sites and makes raw-preservation awkward. Load-time expansion localizes everything in `config.zig`.
- **Universal raw-preservation for every string field.** Adds complexity to every write path for zero realized benefit today; not justified by YAGNI.

## Design

### 1. Grammar

| Form | Semantics |
|---|---|
| `$$` | literal `$` (escape) |
| `$VAR` | simple reference; name = `[A-Za-z_][A-Za-z0-9_]*` |
| `${VAR}` | braced reference |
| `${VAR:-DEF}` | use `DEF` if `VAR` is **unset OR empty** |
| `${VAR-DEF}` | use `DEF` if `VAR` is **unset only** (empty is kept) |

- `DEF` may contain nested references.
- Undefined references (no default) → empty string.
- Unterminated `${` → pass through literally (e.g. `abc${def` stays `abc${def`).
- `$` followed by a non-`$`, non-brace, non-name-start character → pass through literally (e.g. `$1` or `$-` stays as-is).
- Recursion depth cap: **10** (deeper → stop expansion of that branch, emit what we have).

### 2. New module: `src/env_expand.zig`

Exposes:

- `pub fn hasRef(input: []const u8) bool` — fast scan for `$` that's not part of `$$`; used by the caller to decide whether to keep a raw copy.
- `pub fn expand(allocator, input) ![]u8` — top-level entry; caller owns the returned slice. Internally calls `expandInto` with `depth=0, max_depth=10`.
- Internal: `expandInto(out: *ArrayListUnmanaged(u8), input: []const u8, max_depth: u8, depth: u8, allocator) !void`.
- Internal: `findMatchingBrace(input, start) ?usize` — returns index of the `}` matching `${` at `start`, counting nested `${...}`; returns null if unterminated.
- Internal: `scanVarName(input, start) usize` — returns end index of `[A-Za-z_][A-Za-z0-9_]*`.
- Error: `error.ExpansionDepthExceeded` is NOT thrown — depth cap is silent truncation, matching the docscan behavior of emitting partial output.

Design rationale: the module is pure (no file I/O), takes `std.process.getEnvVarOwned` results internally and frees them. This lets tests override via a separate seam if needed (see §5).

### 3. Raw-preservation for `embedding_api_key`

Add to `pub const Config`:

```zig
embedding_api_key: ?[]const u8 = null,       // expanded/resolved value
embedding_api_key_raw: ?[]const u8 = null,   // pre-expansion verbatim (only if hasRef was true)
```

On `parseText`:

```zig
if (std.mem.eql(u8, key, "embedding_api_key")) {
    if (env_expand.hasRef(value)) {
        config.embedding_api_key_raw = try allocator.dupe(u8, value);
        config.embedding_api_key = try env_expand.expand(allocator, value);
    } else {
        config.embedding_api_key = try allocator.dupe(u8, value);
        // embedding_api_key_raw stays null
    }
}
```

`deinit` frees both fields if non-null.

Other reference-capable fields (`embedding_url`, `embedding_model`, `ollama_url`, `ollama_model`, ignore patterns, weights) also get `env_expand.expand(...)` applied but **do not** track a raw copy — they expand on load and are written back as their resolved value (matches today's behavior, since these aren't secrets).

### 4. `writeConfigValues` integration

`writeConfigValues` (src/config.zig:490) is a text-level merge: it takes `[]const KV` pairs and the existing file content, returns an updated content string.

**The raw-preservation seam is at the call site, not in `writeConfigValues`.** Callers that supply `key=embedding_api_key` should first check `cfg.embedding_api_key_raw`:

```zig
const api_key_write_value: []const u8 = cfg.embedding_api_key_raw orelse cfg.embedding_api_key orelse "";
const kvs = [_]KV{
    .{ .key = "embedding_api_key", .value = api_key_write_value },
    // ...
};
```

Rationale: `writeConfigValues` has no knowledge of which keys are secret-bearing; keeping it agnostic preserves its single responsibility (text-level merge). A helper `cfg.writeValueFor("embedding_api_key")` is introduced to keep the call sites tidy.

When code writes a NEW literal value for `embedding_api_key` (e.g. first-time auto-detection in a fresh config), the caller should also clear `cfg.embedding_api_key_raw` so subsequent saves use the new literal. A small helper `cfg.setApiKeyLiteral(allocator, new_value)` frees the old raw (if any) and sets the new expanded value.

### 5. Test isolation

Config tests must not read the developer's real environment. Two options, pick one:

- **A)** Each test sets `PATH`, `CODESCAN_*`, `OMLX_*`, etc. via `std.process.EnvMap` and uses a seam on `env_expand` that accepts an explicit env-map.
- **B)** Tests unset variables they care about via `std.c.unsetenv` before running, and set explicit values.

Recommendation: **A**, because it's hermetic and parallel-safe. The `env_expand.expand` function remains the public API (reading real env); add `env_expand.expandWith(allocator, input, env_map) ![]u8` for tests.

### 6. Test behaviors to port

From `docscan/tests/cli/test-cli` 69–78 (paraphrased):

1. `${VAR}` expands when set.
2. `${VAR}` raw reference survives a save roundtrip (secret not baked in).
3. `$VAR` (no-braces) form works.
4. Unset `${VAR}` → empty string.
5. `${VAR:-default}` fallback when VAR is unset.
6. `${VAR:-default}` uses VAR when set.
7. Nested `${A:-${B:-${C:-bottom}}}` resolves innermost when all unset.
8. Nested `${A:-${B:-default}}` — middle layer wins when B is set.
9. `${VAR-default}` — colonless form: empty VAR suppresses fallback (keeps empty).
10. `${VAR:-default}` — colon form: empty VAR triggers fallback.

Plus codescan-specific:

11. `embedding_api_key=${OMLX_API_KEY}` — `parseText` sets both `_raw` and expanded; `writeConfigValues` at a call site that uses the helper emits `${OMLX_API_KEY}`, not the resolved value.
12. `$$` escapes to literal `$` (e.g. `embedding_model=foo$$bar` → `foo$bar`).
13. Unterminated `${abc` passes through literally.
14. Recursion cap: a pathological `A=${A}` (env has `A=${A}`) doesn't loop; when `depth > 10` we stop expanding and emit what we've built so far. The test asserts the call returns in bounded time and the output equals the partial string accumulated up to the cap (specifically: at depth 10, the inner `${A}` is emitted verbatim rather than re-expanded). We match the silent-truncation behavior of the docscan C reference.

### 7. Interaction with existing `CODESCAN_EMBEDDING_SERVER_API_KEY` override

Unchanged. The override (src/main.zig:1487-1489, 1600) still wins over `cfg.embedding_api_key`. Expansion happens at config-load; override happens at use-site. They're orthogonal.

### 8. Module boundaries

- `src/env_expand.zig` (new) — pure expansion logic, takes an env lookup (real env by default, map-backed for tests). No config knowledge.
- `src/config.zig` — calls `env_expand.expand` on string values at parse time; tracks `_raw` for `embedding_api_key`; provides helpers `writeValueFor(key)` and `setApiKeyLiteral(alloc, value)`.
- Call sites in `src/main.zig` that write config use `writeValueFor("embedding_api_key")` when constructing KV pairs.

## Risks and Mitigations

- **Raw-preservation correctness under concurrent overwrites.** Only one process writes `.codescan/config` at a time (no locking today). Not a regression.
- **Env-var leakage via error messages.** Don't include expanded values in error text.
- **Test environment cross-contamination.** Mitigated by hermetic env maps (§5A).
- **Behavior divergence from docscan.** When in doubt, match the C reference at `docscan/cli/main.c:1344-1509`.

## Rollout

Single PR on `yolo`. No config migration needed — existing configs without references continue to work as plain strings (expand is a no-op on ref-free input).

After implementation is complete and tests pass, delete the inbox note at `inbox/2026-04-18-config-env-var-expansion.md`.
