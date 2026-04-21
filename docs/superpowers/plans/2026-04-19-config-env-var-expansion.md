# Env-Var Expansion in `.codescan/config` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users reference environment variables inside `.codescan/config` values using `$VAR` / `${VAR}` / `${VAR:-default}` / `${VAR-default}` / `$$` forms, with nested defaults up to depth 10 and raw-preservation for `embedding_api_key` so the placeholder survives config write-back.

**Architecture:** A new pure module `src/env_expand.zig` implements the expansion state machine (with a hermetic `expandWith(env_map)` seam for tests). `src/config.zig` calls it during `parseText` for all string-valued fields; adds a parallel `embedding_api_key_raw` field tracked when the raw value contained a reference. `writeConfigValues` stays agnostic — raw-preservation is coordinated at call sites via a `Config.writeValueFor(key)` helper.

**Tech Stack:** Zig 0.15 (`std.ArrayListUnmanaged`, `std.process.getEnvVarOwned`, `std.process.EnvMap`), POSIX env-var conventions matching docscan's C reference impl.

**Spec:** [`docs/superpowers/specs/2026-04-19-config-env-var-expansion-design.md`](../specs/2026-04-19-config-env-var-expansion-design.md)

**Source request:** [`inbox/2026-04-18-config-env-var-expansion.md`](../../../inbox/2026-04-18-config-env-var-expansion.md) — delete this file in the final task once tests pass.

**Target branch:** `yolo` (project's main).

**TDD discipline:** every task writes the failing test first, confirms failure, then implements. Run tests with `nix develop --command zig build test`.

---

## File Structure

- **Create:** `src/env_expand.zig` — pure expansion logic, inline tests, env-map seam for hermetic testing.
- **Modify:** `src/config.zig`:
  - `parseText`: apply `env_expand.expand` to every string-valued field (insert `const expanded = try env_expand.expand(allocator, value); defer allocator.free(expanded);` pattern and dupe from `expanded` instead of `value`).
  - `Config` struct: add `embedding_api_key_raw: ?[]const u8 = null` field.
  - `Config.deinit`: free `embedding_api_key_raw` if non-null.
  - Add `pub fn writeValueFor(self: *const Config, key: []const u8) []const u8` — returns raw placeholder for secret fields when set, else expanded value.
  - Add `pub fn setApiKeyLiteral(self: *Config, allocator: std.mem.Allocator, new_value: []const u8) !void` — clears raw, replaces expanded with duped literal.
- **Modify:** `src/all_tests.zig` — add `const _env_expand = @import("env_expand.zig");` plus reference.
- **Delete:** `inbox/2026-04-18-config-env-var-expansion.md` in the final task.

No changes needed for `src/main.zig` writeConfigValues call sites — they don't currently write `embedding_api_key`.

---

## Task 1: Create `src/env_expand.zig` with core forms ($VAR, ${VAR}, ${VAR:-DEF}, ${VAR-DEF})

**Files:**
- Create: `src/env_expand.zig`
- Modify: `src/all_tests.zig`

- [ ] **Step 1: Write the failing tests (module doesn't exist yet)**

Full contents of `src/env_expand.zig` — tests FIRST, impl below them:

```zig
const std = @import("std");

// --- Public API ---

/// Returns true if `input` contains at least one un-escaped `$` reference.
/// `$$` is treated as an escape and does NOT count as a reference.
pub fn hasRef(input: []const u8) bool {
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] != '$') continue;
        if (i + 1 < input.len and input[i + 1] == '$') {
            i += 1; // skip escape
            continue;
        }
        return true;
    }
    return false;
}

const max_depth: u8 = 10;

/// Expand `$VAR` / `${VAR}` / `${VAR:-DEF}` / `${VAR-DEF}` / `$$` references
/// against the process environment. Caller owns the returned slice.
pub fn expand(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    return expandWith(allocator, input, &env);
}

/// Hermetic variant used by tests — pass an explicit EnvMap.
pub fn expandWith(
    allocator: std.mem.Allocator,
    input: []const u8,
    env: *const std.process.EnvMap,
) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);
    try expandInto(allocator, &out, input, env, 0);
    return out.toOwnedSlice(allocator);
}

// --- Internals (file-private) ---

fn isNameStart(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_';
}

fn isNameCont(c: u8) bool {
    return isNameStart(c) or (c >= '0' and c <= '9');
}

/// Scan a variable name starting at `start`; return end index.
fn scanVarName(input: []const u8, start: usize) usize {
    var i = start;
    while (i < input.len and isNameCont(input[i])) : (i += 1) {}
    return i;
}

/// Given `${` begins at `open_dollar` (i.e. input[open_dollar]=='$' and input[open_dollar+1]=='{'),
/// find the index of the matching `}`. Respects nested `${...}`. Returns null if unterminated.
fn findMatchingBrace(input: []const u8, open_dollar: usize) ?usize {
    var depth: usize = 1;
    var j = open_dollar + 2;
    while (j < input.len) : (j += 1) {
        if (input[j] == '$' and j + 1 < input.len and input[j + 1] == '{') {
            depth += 1;
            j += 1;
        } else if (input[j] == '}') {
            depth -= 1;
            if (depth == 0) return j;
        }
    }
    return null;
}

fn expandInto(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    input: []const u8,
    env: *const std.process.EnvMap,
    depth: u8,
) !void {
    if (depth > max_depth) {
        try out.appendSlice(allocator, input);
        return;
    }
    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c != '$') {
            try out.append(allocator, c);
            i += 1;
            continue;
        }

        // '$' at end of input — pass literally
        if (i + 1 >= input.len) {
            try out.append(allocator, '$');
            i += 1;
            continue;
        }

        const next = input[i + 1];

        // '$$' → literal '$'
        if (next == '$') {
            try out.append(allocator, '$');
            i += 2;
            continue;
        }

        // '${...}' branched form
        if (next == '{') {
            const close = findMatchingBrace(input, i) orelse {
                // unterminated — pass through literally
                try out.append(allocator, '$');
                i += 1;
                continue;
            };
            const body = input[i + 2 .. close];
            try expandBracedBody(allocator, out, body, env, depth);
            i = close + 1;
            continue;
        }

        // '$VAR' simple form
        if (isNameStart(next)) {
            const name_end = scanVarName(input, i + 1);
            const name = input[i + 1 .. name_end];
            if (env.get(name)) |val| {
                try out.appendSlice(allocator, val);
            }
            // unset → empty
            i = name_end;
            continue;
        }

        // '$' followed by something else (digit, punctuation) → literal '$'
        try out.append(allocator, '$');
        i += 1;
    }
}

/// Handle the body of `${...}`: plain var, `${VAR:-DEF}`, `${VAR-DEF}`.
fn expandBracedBody(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    body: []const u8,
    env: *const std.process.EnvMap,
    depth: u8,
) !void {
    if (body.len == 0) return; // `${}` → empty

    // Walk body at brace-depth 0 to find `:-` or `-` separator.
    const name_end = scanVarName(body, 0);
    const name = body[0..name_end];

    if (name_end == body.len) {
        // `${VAR}` — simple
        if (env.get(name)) |val| try out.appendSlice(allocator, val);
        return;
    }

    // Check separator at name_end: `:-` (unset or empty), `-` (unset only)
    var use_empty_trigger = false;
    var def_start: usize = 0;
    if (body[name_end] == ':' and name_end + 1 < body.len and body[name_end + 1] == '-') {
        use_empty_trigger = true;
        def_start = name_end + 2;
    } else if (body[name_end] == '-') {
        use_empty_trigger = false;
        def_start = name_end + 1;
    } else {
        // Unknown shape — treat body as a simple var-name expression;
        // if no env match, emit nothing (matches docscan behavior for malformed bodies).
        if (env.get(name)) |val| try out.appendSlice(allocator, val);
        return;
    }

    const default_slice = body[def_start..];
    const val_opt = env.get(name);
    const use_default = blk: {
        if (val_opt) |v| {
            if (use_empty_trigger and v.len == 0) break :blk true;
            break :blk false;
        }
        break :blk true; // unset
    };

    if (use_default) {
        // Default may contain nested references — recurse.
        try expandInto(allocator, out, default_slice, env, depth + 1);
    } else {
        try out.appendSlice(allocator, val_opt.?);
    }
}

// ---- Tests ----

fn makeEnv(allocator: std.mem.Allocator, pairs: []const [2][]const u8) !std.process.EnvMap {
    var env = std.process.EnvMap.init(allocator);
    errdefer env.deinit();
    for (pairs) |p| try env.put(p[0], p[1]);
    return env;
}

test "hasRef: plain text has no ref" {
    try std.testing.expect(!hasRef("hello"));
    try std.testing.expect(!hasRef(""));
}

test "hasRef: $VAR is a ref" {
    try std.testing.expect(hasRef("$FOO"));
    try std.testing.expect(hasRef("prefix $X suffix"));
}

test "hasRef: ${VAR} is a ref" {
    try std.testing.expect(hasRef("${FOO}"));
}

test "hasRef: $$ escape is NOT a ref" {
    try std.testing.expect(!hasRef("$$"));
    try std.testing.expect(!hasRef("before$$after"));
}

test "hasRef: $$ followed by ref IS a ref" {
    try std.testing.expect(hasRef("$$literal then $REAL"));
}

test "expandWith: $VAR set" {
    const allocator = std.testing.allocator;
    var env = try makeEnv(allocator, &.{.{ "VAR", "value" }});
    defer env.deinit();
    const out = try expandWith(allocator, "$VAR", &env);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("value", out);
}

test "expandWith: ${VAR} set" {
    const allocator = std.testing.allocator;
    var env = try makeEnv(allocator, &.{.{ "VAR", "value" }});
    defer env.deinit();
    const out = try expandWith(allocator, "${VAR}", &env);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("value", out);
}

test "expandWith: ${VAR} unset → empty" {
    const allocator = std.testing.allocator;
    var env = try makeEnv(allocator, &.{});
    defer env.deinit();
    const out = try expandWith(allocator, "prefix-${UNSET}-suffix", &env);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("prefix--suffix", out);
}

test "expandWith: ${VAR:-default} unset uses default" {
    const allocator = std.testing.allocator;
    var env = try makeEnv(allocator, &.{});
    defer env.deinit();
    const out = try expandWith(allocator, "${UNSET:-fallback}", &env);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("fallback", out);
}

test "expandWith: ${VAR:-default} set uses VAR" {
    const allocator = std.testing.allocator;
    var env = try makeEnv(allocator, &.{.{ "VAR", "real" }});
    defer env.deinit();
    const out = try expandWith(allocator, "${VAR:-fallback}", &env);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("real", out);
}

test "expandWith: ${VAR:-default} empty VAR triggers default (colon form)" {
    const allocator = std.testing.allocator;
    var env = try makeEnv(allocator, &.{.{ "VAR", "" }});
    defer env.deinit();
    const out = try expandWith(allocator, "${VAR:-fallback}", &env);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("fallback", out);
}

test "expandWith: ${VAR-default} empty VAR keeps empty (colonless form)" {
    const allocator = std.testing.allocator;
    var env = try makeEnv(allocator, &.{.{ "VAR", "" }});
    defer env.deinit();
    const out = try expandWith(allocator, "${VAR-fallback}", &env);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "expandWith: ${VAR-default} unset uses default" {
    const allocator = std.testing.allocator;
    var env = try makeEnv(allocator, &.{});
    defer env.deinit();
    const out = try expandWith(allocator, "${UNSET-fallback}", &env);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("fallback", out);
}

test "expandWith: no refs, plain passthrough" {
    const allocator = std.testing.allocator;
    var env = try makeEnv(allocator, &.{});
    defer env.deinit();
    const out = try expandWith(allocator, "no refs here", &env);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("no refs here", out);
}
```

- [ ] **Step 2: Wire the module into the test aggregator**

Read `src/all_tests.zig` first. Add, preserving alphabetical order (after `_diff`, before `_filter` — i.e. near the `_extract_*` region, alphabetical on module name):

```zig
const _env_expand = @import("env_expand.zig");
```

And in the `comptime` / reference block (or wherever the references live), add `_ = _env_expand;` in the same style as neighbors.

- [ ] **Step 3: Run the test suite to confirm it compiles and tests pass**

Run: `nix develop --command zig build test 2>&1 | tail -5`
Expected: exit 0. 14 new tests pass (the file's own inline block).

- [ ] **Step 4: Commit**

```bash
git add src/env_expand.zig src/all_tests.zig
git commit -m "feat(env_expand): core expansion forms (\$VAR, \${VAR}, \${VAR:-DEF}, \${VAR-DEF})"
```

---

## Task 2: Nested defaults (depth > 0)

**Files:**
- Modify: `src/env_expand.zig` (tests only — nested support already exists from Task 1 via `expandInto` recursion in the default-slice branch)

This task is really a verification that Task 1's recursion actually works end-to-end with realistic nested inputs.

- [ ] **Step 1: Write the failing tests (should pass immediately if Task 1 is correct; if not, debug)**

Append to the tests block in `src/env_expand.zig`:

```zig
test "expandWith: nested ${A:-${B:-${C:-bottom}}} all unset → bottom" {
    const allocator = std.testing.allocator;
    var env = try makeEnv(allocator, &.{});
    defer env.deinit();
    const out = try expandWith(allocator, "${A:-${B:-${C:-bottom}}}", &env);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("bottom", out);
}

test "expandWith: nested ${A:-${B:-default}} B set → B's value" {
    const allocator = std.testing.allocator;
    var env = try makeEnv(allocator, &.{.{ "B", "middle" }});
    defer env.deinit();
    const out = try expandWith(allocator, "${A:-${B:-default}}", &env);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("middle", out);
}

test "expandWith: nested ${A:-${B:-default}} A set → A's value (short-circuit)" {
    const allocator = std.testing.allocator;
    var env = try makeEnv(allocator, &.{ .{ "A", "top" }, .{ "B", "middle" } });
    defer env.deinit();
    const out = try expandWith(allocator, "${A:-${B:-default}}", &env);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("top", out);
}

test "expandWith: default slice can contain literal text around nested ref" {
    const allocator = std.testing.allocator;
    var env = try makeEnv(allocator, &.{.{ "INNER", "inside" }});
    defer env.deinit();
    const out = try expandWith(allocator, "${OUTER:-pre-${INNER}-post}", &env);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("pre-inside-post", out);
}
```

- [ ] **Step 2: Run tests and confirm they pass**

Run: `nix develop --command zig build test 2>&1 | tail -5`
Expected: exit 0. Task 1's impl should already handle nesting; if any test fails, fix `expandBracedBody` (most likely a bug in how the default slice is recursively expanded).

- [ ] **Step 3: Commit**

```bash
git add src/env_expand.zig
git commit -m "test(env_expand): nested default expansion coverage"
```

---

## Task 3: Edge cases — `$$` escape, unterminated `${`, recursion cap

**Files:**
- Modify: `src/env_expand.zig` (tests only — Task 1's impl already handles these; verify)

- [ ] **Step 1: Write the failing tests**

Append:

```zig
test "expandWith: $$ escapes to literal $" {
    const allocator = std.testing.allocator;
    var env = try makeEnv(allocator, &.{});
    defer env.deinit();
    const out = try expandWith(allocator, "price: $$100", &env);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("price: $100", out);
}

test "expandWith: $$ followed by real ref works" {
    const allocator = std.testing.allocator;
    var env = try makeEnv(allocator, &.{.{ "X", "hi" }});
    defer env.deinit();
    const out = try expandWith(allocator, "$$literal $X", &env);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("$literal hi", out);
}

test "expandWith: unterminated \${ passes through literally" {
    const allocator = std.testing.allocator;
    var env = try makeEnv(allocator, &.{});
    defer env.deinit();
    const out = try expandWith(allocator, "abc${DEF", &env);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("abc${DEF", out);
}

test "expandWith: bare $ at end of input passes through" {
    const allocator = std.testing.allocator;
    var env = try makeEnv(allocator, &.{});
    defer env.deinit();
    const out = try expandWith(allocator, "trailing $", &env);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("trailing $", out);
}

test "expandWith: $ followed by digit passes through" {
    const allocator = std.testing.allocator;
    var env = try makeEnv(allocator, &.{});
    defer env.deinit();
    const out = try expandWith(allocator, "price: $5", &env);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("price: $5", out);
}

test "expandWith: recursion cap — A=\${A} does not loop" {
    const allocator = std.testing.allocator;
    var env = try makeEnv(allocator, &.{.{ "A", "${A}" }});
    defer env.deinit();
    // Should terminate and produce some bounded output, not hang or crash.
    const out = try expandWith(allocator, "${A}", &env);
    defer allocator.free(out);
    // We don't assert exact output; just that it terminated.
    _ = out;
}
```

Note: the recursion cap test currently has a subtle issue — `expandWith` resolves `${A}` to the value of A (`${A}`), but since the value is emitted directly via `out.appendSlice(allocator, val)` rather than recursively expanded, there's no runaway. The cap guards against nested-DEFAULT recursion (`${A:-${B:-${A:-...}}}`), not against env-value-containing-refs. Update the test to exercise the real cap path:

```zig
test "expandWith: recursion cap on deeply nested defaults" {
    const allocator = std.testing.allocator;
    var env = try makeEnv(allocator, &.{});
    defer env.deinit();
    // 15 levels of defaults, all unset — we cap at depth 10.
    const input = "${A1:-${A2:-${A3:-${A4:-${A5:-${A6:-${A7:-${A8:-${A9:-${A10:-${A11:-${A12:-${A13:-${A14:-bottom}}}}}}}}}}}}}}";
    const out = try expandWith(allocator, input, &env);
    defer allocator.free(out);
    // Whatever the exact output, it must NOT contain `${A12` or deeper expanded —
    // the cap kicks in before then. At minimum, the call terminates.
    _ = out;
}
```

Replace the `A=${A}` recursion test with this deeper-default-nesting test.

- [ ] **Step 2: Run the tests**

Run: `nix develop --command zig build test 2>&1 | tail -5`
Expected: exit 0. All tests pass.

- [ ] **Step 3: Commit**

```bash
git add src/env_expand.zig
git commit -m "test(env_expand): escapes, unterminated refs, recursion cap"
```

---

## Task 4: Wire `env_expand.expand` into `config.zig` string fields (no raw-preservation yet)

**Files:**
- Modify: `src/config.zig` — `parseText`

Every branch of the form `config.FIELD = try allocator.dupe(u8, value);` becomes:

```zig
const expanded = try env_expand.expand(allocator, value);
config.FIELD = expanded; // transfer ownership; do NOT dupe again
```

Fields to update (grep `allocator.dupe(u8, value)` inside `parseText`):
- `embedding_url`
- `embedding_model`
- `embedding_api` (validate BEFORE expand so invalid shell refs don't become "openai"/"ollama" by accident — actually: expand first, then validate)
- `embedding_api_key`
- `search_mode`, `fusion`, `fts_mode` (validate after expand)
- `index_ext`, `index_type`, `search_ext`, `search_type`, `search_lang`, `primary_lang`
- `http_host`
- `ignore_global` / `always_include` / `ignore_lang` patterns (split then expand each comma-separated entry — see below)
- `lsp_overrides` binary_path

Validation functions (`validMode`, `validFusion`, `validFtsMode`) run on the EXPANDED value.

**For list/glob fields** (`ignore_global`, `always_include`, per-language ignores, etc.) — expand the entire value string BEFORE splitting by comma. This way `${IGNORE_LIST:-node_modules,dist}` works naturally.

- [ ] **Step 1: Add `const env_expand = @import("env_expand.zig");` at the top of `src/config.zig`**

- [ ] **Step 2: Write the failing test (config uses expansion)**

Append to the tests section of `src/config.zig`:

```zig
test "parseText expands ${VAR} in embedding_api_key when set via env" {
    const allocator = std.testing.allocator;
    // Point HOME/PATH at the test; we need a way to set env for env_expand.expand
    // which reads real env. For a hermetic test, we rely on the fact that
    // env_expand.expand uses getEnvMap and this process's env includes PATH.
    // We'll use a real env var that exists in the test runner.
    // SHELL is commonly set in the nix dev shell; check for PATH which is guaranteed.
    var cfg = try parseText(allocator, "embedding_api_key=${PATH}\n");
    defer cfg.deinit(allocator);
    try std.testing.expect(cfg.embedding_api_key != null);
    try std.testing.expect(cfg.embedding_api_key.?.len > 0);
    try std.testing.expect(!std.mem.eql(u8, cfg.embedding_api_key.?, "${PATH}"));
}

test "parseText expands \${UNSET:-default} to default when unset" {
    const allocator = std.testing.allocator;
    // Use a var name unlikely to be set in any environment.
    var cfg = try parseText(allocator, "embedding_model=${CODESCAN_DEFINITELY_UNSET_123XYZ:-fallback-model}\n");
    defer cfg.deinit(allocator);
    try std.testing.expectEqualStrings("fallback-model", cfg.embedding_model.?);
}

test "parseText passes plain values through unchanged" {
    const allocator = std.testing.allocator;
    var cfg = try parseText(allocator, "embedding_model=bge-large\n");
    defer cfg.deinit(allocator);
    try std.testing.expectEqualStrings("bge-large", cfg.embedding_model.?);
}
```

- [ ] **Step 3: Run to confirm these fail (they reference env-var behavior not yet wired)**

Run: `nix develop --command zig build test 2>&1 | grep -E "parseText expands|error:" | head -10`
Expected: FAIL — for example, the `${PATH}` test either returns the literal `${PATH}` string (assertion fires) or the `${UNSET:-fallback}` test returns the literal placeholder.

- [ ] **Step 4: Rewire `parseText` to apply expansion**

For every string-valued field parse branch, wrap the value in `env_expand.expand(allocator, value)`. The owning slice returned by expand is stored directly (no second dupe). Example for `embedding_url`:

```zig
if (std.mem.eql(u8, key, "embedding_url") or std.mem.eql(u8, key, "ollama_url")) {
    config.embedding_url = try env_expand.expand(allocator, value);
    continue;
}
```

Apply the same pattern to: `embedding_model`/`ollama_model`, `embedding_api`, `embedding_api_key`, `search_mode`, `fusion`, `fts_mode`, `index_ext`, `index_type`, `search_ext`, `search_type`, `search_lang`, `primary_lang`, `http_host`.

For `embedding_api`, expand first THEN validate:

```zig
if (std.mem.eql(u8, key, "embedding_api")) {
    const expanded = try env_expand.expand(allocator, value);
    errdefer allocator.free(expanded);
    if (!std.mem.eql(u8, expanded, "ollama") and !std.mem.eql(u8, expanded, "openai")) {
        return error.InvalidValue;
    }
    config.embedding_api = expanded;
    continue;
}
```

Apply the same expand-then-validate shape to `search_mode`, `fusion`, `fts_mode`.

For comma-separated list fields (ignore patterns, always_include, index_ext, etc.) that get SPLIT after storage — expand the whole comma-string first and store the expanded form:

```zig
if (std.mem.eql(u8, key, "always_include")) {
    // split+store pattern (find existing code, adapt)
    const expanded = try env_expand.expand(allocator, value);
    defer allocator.free(expanded);
    // then split `expanded` instead of `value` using the existing logic
    ...
}
```

**Note:** there's complexity here — the existing `parseText` has many split-then-dupe loops. The minimal change is: replace `value` with `expanded` in each split loop, and remember to free `expanded` once at the end of the loop (since the split produces its own dupes). Read the existing code and adapt carefully.

- [ ] **Step 5: Run tests to confirm they pass**

Run: `nix develop --command zig build test 2>&1 | tail -5`
Expected: exit 0. All previous tests + 3 new tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/config.zig
git commit -m "feat(config): apply env-var expansion to all string-valued config fields"
```

---

## Task 5: Add `embedding_api_key_raw` field + raw-preservation at parse time

**Files:**
- Modify: `src/config.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/config.zig` tests:

```zig
test "parseText preserves raw ${VAR} for embedding_api_key when reference present" {
    const allocator = std.testing.allocator;
    var cfg = try parseText(allocator, "embedding_api_key=${PATH}\n");
    defer cfg.deinit(allocator);
    // _raw is set verbatim to the pre-expansion string.
    try std.testing.expect(cfg.embedding_api_key_raw != null);
    try std.testing.expectEqualStrings("${PATH}", cfg.embedding_api_key_raw.?);
    // expanded value is distinct.
    try std.testing.expect(!std.mem.eql(u8, cfg.embedding_api_key.?, "${PATH}"));
}

test "parseText leaves _raw null for plain embedding_api_key value" {
    const allocator = std.testing.allocator;
    var cfg = try parseText(allocator, "embedding_api_key=plain-literal-key\n");
    defer cfg.deinit(allocator);
    try std.testing.expect(cfg.embedding_api_key_raw == null);
    try std.testing.expectEqualStrings("plain-literal-key", cfg.embedding_api_key.?);
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `nix develop --command zig build test 2>&1 | grep -E "raw|error:" | head -10`
Expected: compile errors — `embedding_api_key_raw` field does not exist.

- [ ] **Step 3: Add the field**

In `pub const Config = struct`, right below `embedding_api_key`:

```zig
embedding_api_key: ?[]const u8 = null,
/// Pre-expansion verbatim string when `embedding_api_key` was loaded from a
/// reference-containing literal (e.g. `${OMLX_API_KEY}`). Used for
/// write-back to avoid baking the resolved secret into the file.
/// Null if the config value contained no references.
embedding_api_key_raw: ?[]const u8 = null,
```

In `Config.deinit`, free it:

```zig
if (self.embedding_api_key) |value| allocator.free(value);
if (self.embedding_api_key_raw) |value| allocator.free(value);
```

- [ ] **Step 4: Wire raw-preservation in `parseText`**

Replace the `embedding_api_key` branch with:

```zig
if (std.mem.eql(u8, key, "embedding_api_key")) {
    if (env_expand.hasRef(value)) {
        config.embedding_api_key_raw = try allocator.dupe(u8, value);
        config.embedding_api_key = try env_expand.expand(allocator, value);
    } else {
        config.embedding_api_key = try allocator.dupe(u8, value);
    }
    continue;
}
```

- [ ] **Step 5: Run tests to confirm pass**

Run: `nix develop --command zig build test 2>&1 | tail -5`
Expected: exit 0. New tests pass; existing tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/config.zig
git commit -m "feat(config): raw-preservation for embedding_api_key env-var references"
```

---

## Task 6: Helpers — `Config.writeValueFor` + `Config.setApiKeyLiteral`

**Files:**
- Modify: `src/config.zig`

- [ ] **Step 1: Write the failing tests**

Append:

```zig
test "writeValueFor returns raw placeholder for embedding_api_key when _raw is set" {
    const allocator = std.testing.allocator;
    var cfg = try parseText(allocator, "embedding_api_key=${PATH}\n");
    defer cfg.deinit(allocator);
    const v = cfg.writeValueFor("embedding_api_key");
    try std.testing.expectEqualStrings("${PATH}", v);
}

test "writeValueFor returns expanded value for embedding_api_key when _raw is null" {
    const allocator = std.testing.allocator;
    var cfg = try parseText(allocator, "embedding_api_key=plain-key\n");
    defer cfg.deinit(allocator);
    const v = cfg.writeValueFor("embedding_api_key");
    try std.testing.expectEqualStrings("plain-key", v);
}

test "writeValueFor returns expanded value for non-secret fields" {
    const allocator = std.testing.allocator;
    var cfg = try parseText(allocator, "embedding_url=http://host\n");
    defer cfg.deinit(allocator);
    const v = cfg.writeValueFor("embedding_url");
    try std.testing.expectEqualStrings("http://host", v);
}

test "writeValueFor returns empty string for unset fields" {
    const allocator = std.testing.allocator;
    var cfg = try parseText(allocator, "\n");
    defer cfg.deinit(allocator);
    try std.testing.expectEqualStrings("", cfg.writeValueFor("embedding_api_key"));
    try std.testing.expectEqualStrings("", cfg.writeValueFor("embedding_url"));
}

test "setApiKeyLiteral clears _raw and replaces expanded with new literal" {
    const allocator = std.testing.allocator;
    var cfg = try parseText(allocator, "embedding_api_key=${PATH}\n");
    defer cfg.deinit(allocator);
    try std.testing.expect(cfg.embedding_api_key_raw != null);
    try cfg.setApiKeyLiteral(allocator, "new-literal");
    try std.testing.expect(cfg.embedding_api_key_raw == null);
    try std.testing.expectEqualStrings("new-literal", cfg.embedding_api_key.?);
    // Subsequent writeValueFor returns the new literal.
    try std.testing.expectEqualStrings("new-literal", cfg.writeValueFor("embedding_api_key"));
}

test "writeConfigValues roundtrip preserves \${VAR} placeholder via writeValueFor" {
    const allocator = std.testing.allocator;
    const original =
        \\#embedding_url=http://localhost:11434
        \\embedding_api_key=${PATH}
        \\
    ;
    var cfg = try parseText(allocator, original);
    defer cfg.deinit(allocator);

    const kvs = [_]KV{
        .{ .key = "embedding_api_key", .value = cfg.writeValueFor("embedding_api_key") },
    };
    const updated = try writeConfigValues(allocator, original, &kvs);
    defer allocator.free(updated);

    try std.testing.expect(std.mem.indexOf(u8, updated, "embedding_api_key=${PATH}") != null);
    // Must NOT contain the resolved PATH value:
    try std.testing.expect(std.mem.indexOf(u8, updated, cfg.embedding_api_key.?) == null);
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `nix develop --command zig build test 2>&1 | grep -E "writeValueFor|setApiKeyLiteral|error:" | head -10`
Expected: compile errors — helpers don't exist.

- [ ] **Step 3: Add the helpers inside `pub const Config = struct`**

```zig
/// Returns the value to write to disk for `key`. For secret fields with a
/// raw placeholder, returns the placeholder. Otherwise returns the current
/// expanded value. Returns empty string for unset/unknown fields.
pub fn writeValueFor(self: *const Config, key: []const u8) []const u8 {
    if (std.mem.eql(u8, key, "embedding_api_key")) {
        if (self.embedding_api_key_raw) |raw| return raw;
        if (self.embedding_api_key) |v| return v;
        return "";
    }
    // Non-secret fields: return the stored (expanded) value.
    if (std.mem.eql(u8, key, "embedding_url")) return self.embedding_url orelse "";
    if (std.mem.eql(u8, key, "embedding_model")) return self.embedding_model orelse "";
    if (std.mem.eql(u8, key, "embedding_api")) return self.embedding_api orelse "";
    if (std.mem.eql(u8, key, "http_host")) return self.http_host orelse "";
    // Fields not enumerated here don't currently have a write-back use case.
    return "";
}

/// Replace `embedding_api_key` with an explicit literal value, clearing any
/// raw placeholder that was tracked. Use when code writes a NEW literal
/// (e.g. first-time auto-detection) that should be persisted as-is.
pub fn setApiKeyLiteral(self: *Config, allocator: std.mem.Allocator, new_value: []const u8) !void {
    if (self.embedding_api_key) |old| allocator.free(old);
    if (self.embedding_api_key_raw) |raw| {
        allocator.free(raw);
        self.embedding_api_key_raw = null;
    }
    self.embedding_api_key = try allocator.dupe(u8, new_value);
}
```

- [ ] **Step 4: Run tests to confirm pass**

Run: `nix develop --command zig build test 2>&1 | tail -5`
Expected: exit 0. All tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/config.zig
git commit -m "feat(config): writeValueFor and setApiKeyLiteral helpers for raw-preserving saves"
```

---

## Task 7: Regression sweep + delete inbox note

- [ ] **Step 1: Run full test suite**

Run: `nix develop --command zig build test 2>&1 | tail -5`
Expected: exit 0.

- [ ] **Step 2: Build the binary**

Run: `nix develop --command zig build 2>&1 | tail -3`
Expected: clean build.

- [ ] **Step 3: End-to-end CLI sanity check**

Create a throwaway project with a config containing `${PATH}`:

```bash
mkdir -p /tmp/codescan-envref
cd /tmp/codescan-envref
mkdir -p .codescan
cat > .codescan/config <<'EOF'
embedding_url=http://localhost:11434
embedding_api_key=${PATH}
EOF
/Users/pmarreck/Documents-CloudManaged/codescan/zig-out/bin/codescan config --root .
cd -
```

Expected: `codescan config` prints the config with `embedding_api_key` showing the EXPANDED PATH value (as consumed by the binary). The on-disk file must still contain the literal `${PATH}` — verify:

```bash
grep 'embedding_api_key' /tmp/codescan-envref/.codescan/config
```

Expected: `embedding_api_key=${PATH}` unchanged.

- [ ] **Step 4: Delete the inbox note**

```bash
rm-safe /Users/pmarreck/Documents-CloudManaged/codescan/inbox/2026-04-18-config-env-var-expansion.md
```

- [ ] **Step 5: Update PLAN.md — mark the item complete**

Edit the line in `PLAN.md` that reads:
```
- [ ] Env-var expansion in config file values ...
```
Change `[ ]` to `[x]` and append ` (completed 2026-04-19 EST)`.

- [ ] **Step 6: Commit**

```bash
git add PLAN.md inbox/
git commit -m "chore: mark env-var-expansion feature complete; clear inbox note"
```

---

## Self-Review Notes

1. **Spec coverage:**
   - Spec §1 (grammar: 5 forms) → Task 1.
   - Spec §2 (env_expand module API) → Task 1.
   - Spec §3 (raw-preservation for embedding_api_key) → Task 5.
   - Spec §4 (writeConfigValues integration via helper) → Task 6.
   - Spec §5 (hermetic test env maps via `expandWith`) → Task 1.
   - Spec §6 tests 1-10 (grammar) → Tasks 1-3.
   - Spec §6 test 11 (save roundtrip) → Task 6 (the last test of that task).
   - Spec §6 tests 12-14 (escapes, unterminated, recursion cap) → Task 3.
   - Spec §7 (unchanged env-var override) → no task needed; main.zig's override logic is untouched and the spec's behavior is preserved.
   - Spec §8 (module boundaries) → Task 1 (env_expand), Task 4 (config integration), Task 6 (helpers).
   - Inbox note deletion → Task 7.

2. **Placeholder scan:** no "TBD"/"TODO"/"implement later". All code steps show full code.

3. **Type consistency:**
   - `env_expand.expand` and `env_expand.expandWith` signatures consistent across Tasks 1-3.
   - `env_expand.hasRef` consistent.
   - `Config` field names (`embedding_api_key`, `embedding_api_key_raw`) consistent across Tasks 4-6.
   - `Config.writeValueFor(key)` returns `[]const u8` (not optional) — empty string for unset.
   - `Config.setApiKeyLiteral(allocator, new_value) !void` — can fail via dupe OOM.

4. **Known approximations:**
   - Task 4 Step 4's pattern for list/glob fields ("Read the existing code and adapt carefully") defers detail to read-time. This is because the existing split loops in `parseText` are verbose and context-dependent; a blind copy-paste in the plan would be more fragile than a read-and-adapt instruction.
   - The "recursion cap" behavior in Task 3's final test asserts termination only, not exact output — this matches the spec's "match docscan's silent-truncation" direction and gives impl flexibility.
