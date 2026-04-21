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

        // '${...}' braced form
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
        // Unknown shape — treat as a simple var-name expression.
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
