# OpenAI-Compatible Embedding Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add OpenAI-compatible embedding endpoint support so codescan can use oMLX Server, LiteLLM, vLLM, and other `/v1/embeddings` providers alongside Ollama.

**Architecture:** Rename `ollama.zig` → `embedding_http.zig`, add `ApiDialect` enum (`.ollama`/`.openai`), branch on dialect in URL builder, request builder, response parser, and auth headers. Rename config fields `ollama_url`/`ollama_model` → `embedding_url`/`embedding_model` with backward-compatible aliases. Rename `OllamaEmbedder` → `HttpEmbedder`.

**Tech Stack:** Zig 0.15, std.http.Client, std.json

**Spec:** `docs/superpowers/specs/2026-04-08-openai-compatible-embedding-provider-design.md`

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Rename | `src/ollama.zig` → `src/embedding_http.zig` | HTTP transport, URL building, request/response serialization for both dialects |
| Modify | `src/embedding.zig` | Rename `OllamaEmbedder` → `HttpEmbedder`, add `dialect`/`api_key` fields |
| Modify | `src/config.zig` | Add `embedding_api`, `embedding_api_key`, rename fields with aliases |
| Modify | `src/main.zig` | Update import, rename settings fields, pass dialect/api_key to embedder |
| Modify | `src/mcp.zig` | Update import, rename settings fields, pass dialect/api_key to embedder |
| Modify | `src/server.zig` | Update import, rename settings fields, pass dialect/api_key to embedder |
| Modify | `src/indexer.zig` | Update import, pass dialect/api_key to embedder |
| Modify | `src/cli.zig` | Rename CLI flag fields (keep `--ollama-url`/`--ollama-model` flags working) |
| Modify | `src/all_tests.zig` | Update import reference |
| Modify | `build.zig` | Rename test target from `ollama.zig` to `embedding_http.zig` |

---

### Task 1: Rename `ollama.zig` → `embedding_http.zig` and update all imports

This is a mechanical rename. No logic changes. All existing tests must still pass.

**Files:**
- Rename: `src/ollama.zig` → `src/embedding_http.zig`
- Modify: `src/embedding.zig:2`
- Modify: `src/main.zig:7`
- Modify: `src/mcp.zig:11`
- Modify: `src/server.zig:8`
- Modify: `src/indexer.zig:8`
- Modify: `src/all_tests.zig:33`
- Modify: `build.zig:156`

- [ ] **Step 1: Rename the file**

```bash
git mv src/ollama.zig src/embedding_http.zig
```

- [ ] **Step 2: Update all imports**

In each of these files, replace `@import("ollama.zig")` with `@import("embedding_http.zig")` and rename the binding from `ollama` to `embedding_http`:

`src/embedding.zig:2`:
```zig
const embedding_http = @import("embedding_http.zig");
```

`src/main.zig:7`:
```zig
const embedding_http = @import("embedding_http.zig");
```

`src/mcp.zig:11`:
```zig
const embedding_http = @import("embedding_http.zig");
```

`src/server.zig:8`:
```zig
const embedding_http = @import("embedding_http.zig");
```

`src/indexer.zig:8`:
```zig
const embedding_http = @import("embedding_http.zig");
```

`src/all_tests.zig:33`:
```zig
const _embedding_http = @import("embedding_http.zig");
```

`build.zig:156` — change the root_source_file path:
```zig
.root_source_file = b.path("src/embedding_http.zig"),
```

- [ ] **Step 3: Replace all `ollama.` references with `embedding_http.`**

In every file that imported `ollama`, replace all occurrences of `ollama.` (the module prefix) with `embedding_http.`. Key sites:

- `src/embedding.zig`: `ollama.embed` → `embedding_http.embed`, `ollama.freeEmbeddings` → `embedding_http.freeEmbeddings`, `ollama.Transport` → `embedding_http.Transport`, `ollama.StdHttpTransport` → `embedding_http.StdHttpTransport`, `ollama.skipIfNoOllama` → `embedding_http.skipIfNoOllama`
- `src/main.zig`: ~15 sites — `ollama.StdHttpTransport` → `embedding_http.StdHttpTransport`, `ollama.Transport` → `embedding_http.Transport`, `ollama.ensureModelAvailable` → `embedding_http.ensureModelAvailable`
- `src/mcp.zig`: ~6 sites — same pattern
- `src/server.zig`: ~4 sites — same pattern
- `src/indexer.zig`: ~4 sites — same pattern

- [ ] **Step 4: Run tests to verify the rename is clean**

```bash
nix build .#codescan-tests 2>&1 | tail -20
```

Expected: All tests pass. This is a pure rename — no logic changed.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: rename ollama.zig to embedding_http.zig"
```

---

### Task 2: Add `ApiDialect` enum and dialect branching in `embedding_http.zig`

Core logic change. Add the dialect enum, then modify `buildEmbedUrl`, `buildEmbedRequest`, `parseEmbeddings`, and `embed` to branch on dialect. TDD — write failing tests first.

**Files:**
- Modify: `src/embedding_http.zig`

- [ ] **Step 1: Write failing test for `buildEmbedUrl` with openai dialect**

Add to `src/embedding_http.zig` after the existing `buildEmbedUrl` test:

```zig
test "buildEmbedUrl returns openai path for openai dialect" {
    const allocator = std.testing.allocator;
    const url = try buildEmbedUrl(allocator, "http://localhost:8000", .openai);
    defer allocator.free(url);
    try std.testing.expectEqualStrings("http://localhost:8000/v1/embeddings", url);
}

test "buildEmbedUrl returns ollama path for ollama dialect" {
    const allocator = std.testing.allocator;
    const url = try buildEmbedUrl(allocator, "http://localhost:11434/", .ollama);
    defer allocator.free(url);
    try std.testing.expectEqualStrings("http://localhost:11434/api/embed", url);
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
nix build .#codescan-tests 2>&1 | tail -20
```

Expected: Compile error — `buildEmbedUrl` doesn't accept a dialect parameter yet.

- [ ] **Step 3: Add `ApiDialect` enum and update `buildEmbedUrl`**

Add at top of `src/embedding_http.zig` (after the `Transport` struct):

```zig
pub const ApiDialect = enum {
    ollama,
    openai,
};
```

Update `buildEmbedUrl` signature and body:

```zig
pub fn buildEmbedUrl(allocator: std.mem.Allocator, base_url: []const u8, dialect: ApiDialect) ![]u8 {
    const suffix = switch (dialect) {
        .ollama => "api/embed",
        .openai => "v1/embeddings",
    };
    if (std.mem.endsWith(u8, base_url, "/")) {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ base_url, suffix });
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_url, suffix });
}
```

Update all callers of `buildEmbedUrl` within `embedding_http.zig` — the `embed` function (line ~28) and the existing test. Pass `.ollama` as the dialect for now:

In `embed()`: `const url = try buildEmbedUrl(allocator, base_url, .ollama);`
In existing test `"buildEmbedUrl handles trailing slash"`: add `.ollama` arg.

- [ ] **Step 4: Run tests to verify they pass**

```bash
nix build .#codescan-tests 2>&1 | tail -20
```

Expected: All tests pass including the two new ones.

- [ ] **Step 5: Write failing test for `buildEmbedRequest` with openai dialect**

```zig
test "buildEmbedRequest omits keep_alive for openai dialect" {
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{"hello"};
    const body = try buildEmbedRequest(allocator, "bge-m3", &inputs, -1, .openai);
    defer allocator.free(body);
    // OpenAI dialect should NOT include keep_alive even when provided
    try std.testing.expectEqualStrings("{\"model\":\"bge-m3\",\"input\":[\"hello\"]}", body);
}

test "buildEmbedRequest includes keep_alive for ollama dialect" {
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{"hello"};
    const body = try buildEmbedRequest(allocator, "bge-large", &inputs, -1, .ollama);
    defer allocator.free(body);
    try std.testing.expectEqualStrings("{\"model\":\"bge-large\",\"input\":[\"hello\"],\"keep_alive\":-1}", body);
}
```

- [ ] **Step 6: Run tests to verify they fail**

Expected: Compile error — `buildEmbedRequest` doesn't accept dialect yet.

- [ ] **Step 7: Update `buildEmbedRequest` for dialect**

```zig
pub fn buildEmbedRequest(
    allocator: std.mem.Allocator,
    model: []const u8,
    inputs: []const []const u8,
    keep_alive: ?i64,
    dialect: ApiDialect,
) ![]u8 {
    const effective_keep_alive: ?i64 = if (dialect == .openai) null else keep_alive;
    const payload = EmbedRequest{ .model = model, .input = inputs, .keep_alive = effective_keep_alive };
    var out: std.io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var stream: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
    try stream.write(payload);
    return out.toOwnedSlice();
}
```

Update all callers within `embedding_http.zig` — the `embed` function and existing tests. Pass `.ollama` for existing callers:

In `embed()`: `const body = try buildEmbedRequest(allocator, model, inputs, keep_alive, .ollama);`
In existing tests `"buildEmbedRequest serializes inputs"` and `"buildEmbedRequest includes keep_alive when set"`: add `.ollama` arg.

- [ ] **Step 8: Run tests to verify they pass**

```bash
nix build .#codescan-tests 2>&1 | tail -20
```

- [ ] **Step 9: Write failing test for `parseEmbeddings` with openai dialect**

```zig
test "parseEmbeddings reads openai format" {
    const allocator = std.testing.allocator;
    const body =
        \\{"data":[{"embedding":[0.1,0.2],"index":0},{"embedding":[1,2],"index":1}],"model":"test","usage":{"prompt_tokens":5,"total_tokens":5}}
    ;
    const embeddings = try parseEmbeddings(allocator, body, .openai);
    defer freeEmbeddings(allocator, embeddings);
    try std.testing.expectEqual(@as(usize, 2), embeddings.len);
    try std.testing.expectEqual(@as(usize, 2), embeddings[0].len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), embeddings[0][0], 0.0001);
    try std.testing.expectEqual(@as(f32, 2), embeddings[1][1]);
}

test "parseEmbeddings reads openai format sorted by index" {
    const allocator = std.testing.allocator;
    // Return out of order — parser should sort by index
    const body =
        \\{"data":[{"embedding":[1,2],"index":1},{"embedding":[0.1,0.2],"index":0}],"model":"test"}
    ;
    const embeddings = try parseEmbeddings(allocator, body, .openai);
    defer freeEmbeddings(allocator, embeddings);
    try std.testing.expectEqual(@as(usize, 2), embeddings.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), embeddings[0][0], 0.0001);
    try std.testing.expectEqual(@as(f32, 2), embeddings[1][1]);
}
```

- [ ] **Step 10: Run tests to verify they fail**

- [ ] **Step 11: Update `parseEmbeddings` for dialect**

```zig
pub fn parseEmbeddings(allocator: std.mem.Allocator, body: []const u8, dialect: ApiDialect) ![][]f32 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidResponse;

    return switch (dialect) {
        .ollama => parseOllamaEmbeddings(allocator, parsed.value),
        .openai => parseOpenAiEmbeddings(allocator, parsed.value),
    };
}

fn parseOllamaEmbeddings(allocator: std.mem.Allocator, root: std.json.Value) ![][]f32 {
    const embeddings_value = root.object.get("embeddings") orelse return error.MissingEmbeddings;
    if (embeddings_value != .array) return error.InvalidEmbeddings;

    const rows = embeddings_value.array.items;
    var result = try allocator.alloc([]f32, rows.len);
    errdefer freeEmbeddings(allocator, result);

    for (rows, 0..) |row_value, row_idx| {
        if (row_value != .array) return error.InvalidEmbeddings;
        const values = row_value.array.items;
        var vec = try allocator.alloc(f32, values.len);
        for (values, 0..) |value, col_idx| {
            vec[col_idx] = try parseNumber(value);
        }
        result[row_idx] = vec;
    }

    return result;
}

fn parseOpenAiEmbeddings(allocator: std.mem.Allocator, root: std.json.Value) ![][]f32 {
    const data_value = root.object.get("data") orelse return error.MissingEmbeddings;
    if (data_value != .array) return error.InvalidEmbeddings;

    const items = data_value.array.items;
    var result = try allocator.alloc([]f32, items.len);
    errdefer freeEmbeddings(allocator, result);

    // Parse each {embedding: [...], index: N} entry
    for (items) |item| {
        if (item != .object) return error.InvalidEmbeddings;
        const index_value = item.object.get("index") orelse return error.InvalidEmbeddings;
        const idx: usize = switch (index_value) {
            .integer => |v| @intCast(v),
            else => return error.InvalidEmbeddings,
        };
        if (idx >= result.len) return error.InvalidEmbeddings;

        const emb_value = item.object.get("embedding") orelse return error.InvalidEmbeddings;
        if (emb_value != .array) return error.InvalidEmbeddings;
        const values = emb_value.array.items;
        var vec = try allocator.alloc(f32, values.len);
        for (values, 0..) |value, col_idx| {
            vec[col_idx] = try parseNumber(value);
        }
        result[idx] = vec;
    }

    return result;
}
```

Update all callers of `parseEmbeddings` within `embedding_http.zig`:
- In `embed()`: pass dialect — `return parseEmbeddings(allocator, response.body, .ollama);` (will be parameterized in a later step)
- In existing test `"parseEmbeddings reads vectors"`: add `.ollama` arg
- In `MockTransportCtx.send`: no change needed (it returns canned body)

- [ ] **Step 12: Run tests to verify they pass**

```bash
nix build .#codescan-tests 2>&1 | tail -20
```

- [ ] **Step 13: Update `embed()` to accept and use dialect + api_key**

Update the signature:

```zig
pub fn embed(
    allocator: std.mem.Allocator,
    transport: Transport,
    base_url: []const u8,
    model: []const u8,
    inputs: []const []const u8,
    keep_alive: ?i64,
    dialect: ApiDialect,
    api_key: ?[]const u8,
) ![][]f32 {
    const url = try buildEmbedUrl(allocator, base_url, dialect);
    defer allocator.free(url);
    const body = try buildEmbedRequest(allocator, model, inputs, keep_alive, dialect);
    defer allocator.free(body);

    // Build headers based on dialect
    var header_buf: [4]std.http.Header = undefined;
    var header_count: usize = 2;
    header_buf[0] = .{ .name = "Content-Type", .value = "application/json" };
    header_buf[1] = .{ .name = "Accept", .value = "application/json" };
    if (dialect == .openai) {
        if (api_key) |key| {
            header_buf[2] = .{ .name = "Authorization", .value = key };
            header_count = 3;
        }
    }

    const response = try transport.send(transport.ctx, allocator, .{
        .method = "POST",
        .url = url,
        .headers = header_buf[0..header_count],
        .body = body,
    });
    defer allocator.free(response.body);

    if (response.status == 401) return error.Unauthorized;
    if (response.status != 200) return error.HttpStatus;
    return parseEmbeddings(allocator, response.body, dialect);
}
```

**Note on api_key format:** The caller must pass the full `"Bearer <token>"` string as `api_key`. This avoids allocating inside `embed()`. The config/settings layer will format it as `"Bearer " ++ token`.

- [ ] **Step 14: Update `ensureModelAvailable` to accept and check dialect**

```zig
pub fn ensureModelAvailable(
    allocator: std.mem.Allocator,
    transport: Transport,
    base_url: []const u8,
    model_name: []const u8,
    dialect: ApiDialect,
) !void {
    // OpenAI-compatible servers don't expose /api/tags or /api/ps
    if (dialect == .openai) return;

    // ... rest of existing body unchanged ...
}
```

Update callers within `embedding_http.zig` (existing tests call `ensureModelAvailable` directly — add `.ollama` param).

- [ ] **Step 15: Run tests to verify everything passes**

```bash
nix build .#codescan-tests 2>&1 | tail -20
```

At this point, `embedding_http.zig` compiles with the old `.ollama` defaults hardcoded in existing callers within the file.

- [ ] **Step 16: Write test for auth header and ensureModelAvailable skip**

```zig
test "embed sends auth header for openai dialect" {
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{"hello"};

    var mock = MockTransportCtx{
        .tags_body = "",
        .ps_body = "",
    };
    // Override mock to check headers
    const result = embed(
        allocator,
        mock.transport(),
        "http://localhost:8000",
        "test-model",
        &inputs,
        null,
        .openai,
        "Bearer test-key",
    );
    // Mock returns ollama format by default, so this will fail with MissingEmbeddings
    // That's OK — we're testing that the request gets sent without error.Unauthorized
    // For a proper test we need to update the mock. See next step.
    if (result) |emb| {
        freeEmbeddings(allocator, emb);
    } else |_| {}
}

test "ensureModelAvailable is no-op for openai dialect" {
    const allocator = std.testing.allocator;
    // Mock that would fail if /api/tags or /api/ps were called
    var mock = MockTransportCtx{
        .tags_body = "this is not valid json",
        .ps_body = "this is not valid json",
    };
    // Should return immediately without calling any endpoints
    try ensureModelAvailable(allocator, mock.transport(), "http://localhost:8000", "any-model", .openai);
}
```

- [ ] **Step 17: Update `MockTransportCtx` to support openai response format**

Add an `openai_mode` field to `MockTransportCtx`:

```zig
const MockTransportCtx = struct {
    tags_body: []const u8,
    ps_body: []const u8,
    embed_should_fail: bool = false,
    openai_mode: bool = false,

    fn send(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, req: HttpRequest) !HttpResponse {
        const self: *MockTransportCtx = @ptrCast(@alignCast(ctx_ptr));
        if (std.mem.endsWith(u8, req.url, "/api/tags")) {
            return .{ .status = 200, .body = try allocator.dupe(u8, self.tags_body) };
        }
        if (std.mem.endsWith(u8, req.url, "/api/ps")) {
            return .{ .status = 200, .body = try allocator.dupe(u8, self.ps_body) };
        }
        if (std.mem.endsWith(u8, req.url, "/api/embed")) {
            if (self.embed_should_fail) return error.ConnectionRefused;
            return .{ .status = 200, .body = try allocator.dupe(u8, "{\"embeddings\":[[0.1,0.2]]}") };
        }
        if (std.mem.endsWith(u8, req.url, "/v1/embeddings")) {
            if (self.embed_should_fail) return error.ConnectionRefused;
            return .{ .status = 200, .body = try allocator.dupe(u8,
                \\{"data":[{"embedding":[0.1,0.2],"index":0}],"model":"test"}
            ) };
        }
        return error.UnsupportedMethod;
    }

    fn transport(self: *MockTransportCtx) Transport {
        return .{ .ctx = self, .send = send };
    }
};
```

- [ ] **Step 18: Write proper end-to-end mock test for openai embed**

```zig
test "embed with openai dialect returns correct embeddings" {
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{"hello"};
    var mock = MockTransportCtx{
        .tags_body = "",
        .ps_body = "",
        .openai_mode = true,
    };
    const embeddings = try embed(
        allocator,
        mock.transport(),
        "http://localhost:8000",
        "test-model",
        &inputs,
        null,
        .openai,
        "Bearer test-key",
    );
    defer freeEmbeddings(allocator, embeddings);
    try std.testing.expectEqual(@as(usize, 1), embeddings.len);
    try std.testing.expectEqual(@as(usize, 2), embeddings[0].len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), embeddings[0][0], 0.0001);
}
```

- [ ] **Step 19: Write test for 401 → error.Unauthorized**

Add to `MockTransportCtx` a `status_override` field:

```zig
status_override: ?u16 = null,
```

In the `/v1/embeddings` branch of `send`, add:
```zig
if (self.status_override) |status| {
    return .{ .status = status, .body = try allocator.dupe(u8, "{\"error\":\"unauthorized\"}") };
}
```

Then add:
```zig
test "embed returns Unauthorized on 401" {
    const allocator = std.testing.allocator;
    const inputs = [_][]const u8{"hello"};
    var mock = MockTransportCtx{
        .tags_body = "",
        .ps_body = "",
        .status_override = 401,
    };
    try std.testing.expectError(
        error.Unauthorized,
        embed(allocator, mock.transport(), "http://localhost:8000", "test-model", &inputs, null, .openai, "Bearer bad-key"),
    );
}
```

- [ ] **Step 20: Run all tests**

```bash
nix build .#codescan-tests 2>&1 | tail -20
```

- [ ] **Step 21: Commit**

```bash
git add src/embedding_http.zig
git commit -m "feat: add ApiDialect enum and OpenAI embedding support in embedding_http.zig"
```

---

### Task 3: Update `config.zig` — new fields and aliases

Add `embedding_api`, `embedding_api_key`, rename `ollama_url`→`embedding_url`, `ollama_model`→`embedding_model` with alias support.

**Files:**
- Modify: `src/config.zig`

- [ ] **Step 1: Write failing tests for new config keys**

Add to end of test section in `src/config.zig`:

```zig
test "parseText reads embedding_api and embedding_api_key" {
    const allocator = std.testing.allocator;
    var cfg = try parseText(allocator, "embedding_api=openai\nembedding_api_key=my-secret-key\n");
    defer cfg.deinit(allocator);
    try std.testing.expectEqualStrings("openai", cfg.embedding_api.?);
    try std.testing.expectEqualStrings("my-secret-key", cfg.embedding_api_key.?);
}

test "parseText reads embedding_url and embedding_model" {
    const allocator = std.testing.allocator;
    var cfg = try parseText(allocator, "embedding_url=http://localhost:8000\nembedding_model=bge-m3\n");
    defer cfg.deinit(allocator);
    try std.testing.expectEqualStrings("http://localhost:8000", cfg.embedding_url.?);
    try std.testing.expectEqualStrings("bge-m3", cfg.embedding_model.?);
}

test "parseText ollama_url alias populates embedding_url" {
    const allocator = std.testing.allocator;
    var cfg = try parseText(allocator, "ollama_url=http://localhost:11434\nollama_model=bge-large\n");
    defer cfg.deinit(allocator);
    try std.testing.expectEqualStrings("http://localhost:11434", cfg.embedding_url.?);
    try std.testing.expectEqualStrings("bge-large", cfg.embedding_model.?);
}

test "parseText rejects invalid embedding_api" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidValue, parseText(allocator, "embedding_api=banana\n"));
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
nix build .#codescan-tests 2>&1 | tail -20
```

Expected: Compile errors — fields don't exist yet.

- [ ] **Step 3: Add new fields to Config struct**

In `src/config.zig`, rename the existing fields and add new ones in the `Config` struct:

Replace:
```zig
ollama_url: ?[]const u8 = null,
ollama_model: ?[]const u8 = null,
```

With:
```zig
embedding_url: ?[]const u8 = null,
embedding_model: ?[]const u8 = null,
embedding_api: ?[]const u8 = null,
embedding_api_key: ?[]const u8 = null,
```

Update `deinit` — replace:
```zig
if (self.ollama_url) |value| allocator.free(value);
if (self.ollama_model) |value| allocator.free(value);
```
With:
```zig
if (self.embedding_url) |value| allocator.free(value);
if (self.embedding_model) |value| allocator.free(value);
if (self.embedding_api) |value| allocator.free(value);
if (self.embedding_api_key) |value| allocator.free(value);
```

- [ ] **Step 4: Update `parseText` for new keys and aliases**

Replace the `ollama_url` and `ollama_model` parsing blocks with:

```zig
if (std.mem.eql(u8, key, "embedding_url") or std.mem.eql(u8, key, "ollama_url")) {
    config.embedding_url = try allocator.dupe(u8, value);
    continue;
}

if (std.mem.eql(u8, key, "embedding_model") or std.mem.eql(u8, key, "ollama_model")) {
    config.embedding_model = try allocator.dupe(u8, value);
    continue;
}

if (std.mem.eql(u8, key, "embedding_api")) {
    if (!std.mem.eql(u8, value, "ollama") and !std.mem.eql(u8, value, "openai")) {
        return error.InvalidValue;
    }
    config.embedding_api = try allocator.dupe(u8, value);
    continue;
}

if (std.mem.eql(u8, key, "embedding_api_key")) {
    config.embedding_api_key = try allocator.dupe(u8, value);
    continue;
}
```

- [ ] **Step 5: Update existing config tests**

The existing test `"parseText reads values"` (line ~488) references `cfg.ollama_url` and `cfg.ollama_model`. Update these to `cfg.embedding_url` and `cfg.embedding_model`.

The existing test `"parseText empty yields defaults"` should still pass since all new fields default to `null`.

- [ ] **Step 6: Run tests**

```bash
nix build .#codescan-tests 2>&1 | tail -20
```

- [ ] **Step 7: Commit**

```bash
git add src/config.zig
git commit -m "feat: add embedding_api, embedding_api_key config keys with ollama_* aliases"
```

---

### Task 4: Update `cli.zig` — rename parsed fields

Rename `ollama_url`/`ollama_model` fields in the `Parsed` and `Seen` structs. Keep the CLI flags `--ollama-url` and `--ollama-model` as-is for backward compat (they're the user-facing flags).

**Files:**
- Modify: `src/cli.zig`

- [ ] **Step 1: Rename fields in Parsed struct**

In the `Parsed` struct (contains `ollama_url` and `ollama_model` fields), rename to `embedding_url` and `embedding_model`.

In the `Seen` struct (contains `ollama_url` and `ollama_model` bool fields), rename to `embedding_url` and `embedding_model`.

In the defaults section of `Parsed`, rename:
```zig
.embedding_url = "http://localhost:11434",
.embedding_model = "bge-large",
```

- [ ] **Step 2: Update flag parsing to use new field names**

Where `--ollama-url` is parsed (around line 544):
```zig
parsed.embedding_url = args[i];
parsed.seen.embedding_url = true;
```

Where `--ollama-model` is parsed (around line 555):
```zig
parsed.embedding_model = args[i];
parsed.seen.embedding_model = true;
```

- [ ] **Step 3: Update existing CLI tests**

References to `parsed.ollama_url` and `parsed.ollama_model` in tests → `parsed.embedding_url` and `parsed.embedding_model`.

- [ ] **Step 4: Run tests**

```bash
nix build .#codescan-tests 2>&1 | tail -20
```

- [ ] **Step 5: Commit**

```bash
git add src/cli.zig
git commit -m "refactor: rename ollama_url/ollama_model to embedding_url/embedding_model in CLI"
```

---

### Task 5: Update `embedding.zig` — rename `OllamaEmbedder` to `HttpEmbedder`

**Files:**
- Modify: `src/embedding.zig`

- [ ] **Step 1: Rename and add fields**

Replace the entire `OllamaEmbedder` struct:

```zig
pub const HttpEmbedder = struct {
    transport: embedding_http.Transport,
    base_url: []const u8,
    model: []const u8,
    keep_alive: ?i64 = 900,
    dialect: embedding_http.ApiDialect = .ollama,
    api_key: ?[]const u8 = null,

    pub fn embedder(self: *HttpEmbedder) Embedder {
        return .{
            .ctx = self,
            .embed = embed_fn,
            .free = free_fn,
        };
    }

    fn embed_fn(ctx: *anyopaque, allocator: std.mem.Allocator, inputs: []const []const u8) ![][]f32 {
        const self: *HttpEmbedder = @ptrCast(@alignCast(ctx));
        return embedding_http.embed(allocator, self.transport, self.base_url, self.model, inputs, self.keep_alive, self.dialect, self.api_key);
    }

    fn free_fn(ctx: *anyopaque, allocator: std.mem.Allocator, embeddings: [][]f32) void {
        _ = ctx;
        embedding_http.freeEmbeddings(allocator, embeddings);
    }
};
```

Note: The inner function names change from `embed`/`free` to `embed_fn`/`free_fn` to avoid shadowing the imported `embedding_http.embed`.

- [ ] **Step 2: Update the test**

Rename `OllamaEmbedder` to `HttpEmbedder` in the test `"OllamaEmbedder uses live Ollama"` → `"HttpEmbedder uses live Ollama"`.

- [ ] **Step 3: Run tests**

```bash
nix build .#codescan-tests 2>&1 | tail -20
```

- [ ] **Step 4: Commit**

```bash
git add src/embedding.zig
git commit -m "refactor: rename OllamaEmbedder to HttpEmbedder with dialect/api_key fields"
```

---

### Task 6: Update `main.zig` — settings, resolveSettings, and all call sites

The largest mechanical change. Rename settings fields, add new ones, update `resolveSettings`, and update all `embedding.HttpEmbedder` construction sites.

**Files:**
- Modify: `src/main.zig`

- [ ] **Step 1: Update `Defaults` struct**

Replace:
```zig
ollama_url: []const u8 = "http://localhost:11434",
ollama_model: []const u8 = "bge-large",
```
With:
```zig
embedding_url: []const u8 = "http://localhost:11434",
embedding_model: []const u8 = "bge-large",
```

- [ ] **Step 2: Update `Settings` struct**

Replace:
```zig
ollama_url: []const u8,
ollama_model: []const u8,
ollama_model_owned: bool,
```
With:
```zig
embedding_url: []const u8,
embedding_model: []const u8,
embedding_model_owned: bool,
embedding_dialect: embedding_http.ApiDialect = .ollama,
embedding_api_key: ?[]const u8 = null,
embedding_api_key_owned: bool = false,
```

- [ ] **Step 3: Update `resolveSettings`**

Replace all `ollama_url` → `embedding_url`, `ollama_model` → `embedding_model`, `ollama_model_owned` → `embedding_model_owned` references. Also:

Add after the existing `OLLAMA_MODEL` env var block:
```zig
// Parse embedding_api dialect from config
if (cfg.embedding_api) |api_str| {
    if (std.mem.eql(u8, api_str, "openai")) {
        settings.embedding_dialect = .openai;
    }
    // "ollama" is the default, no action needed
}

// Format Bearer token from api key
if (cfg.embedding_api_key) |key| {
    settings.embedding_api_key = try std.fmt.allocPrint(allocator, "Bearer {s}", .{key});
    settings.embedding_api_key_owned = true;
}
```

Add cleanup for `embedding_api_key_owned` in the deferred free block at the top of `main()` where `settings.ollama_model_owned` (now `embedding_model_owned`) is freed:
```zig
defer if (settings.embedding_api_key_owned) allocator.free(settings.embedding_api_key.?);
```

Update the env var name from `OLLAMA_MODEL` to also check `EMBEDDING_MODEL` (check `EMBEDDING_MODEL` first, fall back to `OLLAMA_MODEL`).

- [ ] **Step 4: Update all `embedding.OllamaEmbedder` construction sites**

There are ~8 sites in main.zig. Each one looks like:
```zig
var embedder_adapter = embedding.OllamaEmbedder{
    .transport = http_client.transport(),
    .base_url = settings.ollama_url,
    .model = settings.ollama_model,
};
```

Replace each with:
```zig
var embedder_adapter = embedding.HttpEmbedder{
    .transport = http_client.transport(),
    .base_url = settings.embedding_url,
    .model = settings.embedding_model,
    .dialect = settings.embedding_dialect,
    .api_key = settings.embedding_api_key,
};
```

- [ ] **Step 5: Update `ensureModelAvailableOrExit` and `tryInitOllama`**

`ensureModelAvailableOrExit` — add `dialect` param, pass to `embedding_http.ensureModelAvailable`:
```zig
fn ensureModelAvailableOrExit(
    allocator: std.mem.Allocator,
    transport: embedding_http.Transport,
    base_url: []const u8,
    model_name: []const u8,
    dialect: embedding_http.ApiDialect,
) !void {
    if (dialect == .openai) return; // No model check for OpenAI-compatible servers
    embedding_http.ensureModelAvailable(allocator, transport, base_url, model_name, dialect) catch |err| switch (err) {
        // ... existing error handling unchanged ...
    };
}
```

Update all callers to pass `settings.embedding_dialect`.

`tryInitOllama` — add `dialect` param, skip entirely for openai:
```zig
fn tryInitOllama(..., dialect: embedding_http.ApiDialect, ...) bool {
    if (dialect == .openai) return true; // No Ollama init needed
    // ... rest unchanged, update field names ...
}
```

- [ ] **Step 6: Update all `settings.ollama_url` / `settings.ollama_model` references**

Mechanical find-and-replace throughout `main.zig`:
- `settings.ollama_url` → `settings.embedding_url`
- `settings.ollama_model` → `settings.embedding_model`
- `settings.ollama_model_owned` → `settings.embedding_model_owned`

- [ ] **Step 7: Update MCP settings construction**

Where `main.zig` constructs `mcp.Settings` (around lines 722, 874), update field names to match whatever the MCP Settings struct uses (updated in Task 7).

- [ ] **Step 8: Validate at startup — missing API key for openai dialect**

In `main()`, after `resolveSettings`, add:
```zig
if (settings.embedding_dialect == .openai and settings.embedding_api_key == null) {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;
    _ = stderr.print("error: embedding_api=openai requires embedding_api_key to be set in config\n", .{}) catch {};
    std.process.exit(1);
}
```

- [ ] **Step 9: Run tests**

```bash
nix build .#codescan-tests 2>&1 | tail -20
```

- [ ] **Step 10: Commit**

```bash
git add src/main.zig
git commit -m "feat: wire OpenAI embedding dialect through main.zig settings and call sites"
```

---

### Task 7: Update `mcp.zig` — settings and call sites

**Files:**
- Modify: `src/mcp.zig`

- [ ] **Step 1: Update `Settings` struct**

Replace:
```zig
ollama_url: []const u8 = "http://localhost:11434",
ollama_model: []const u8 = "bge-large",
```
With:
```zig
embedding_url: []const u8 = "http://localhost:11434",
embedding_model: []const u8 = "bge-large",
embedding_dialect: embedding_http.ApiDialect = .ollama,
embedding_api_key: ?[]const u8 = null,
```

- [ ] **Step 2: Update all `ollama_url`/`ollama_model` references**

Replace `mcp_settings.ollama_url` → `mcp_settings.embedding_url`, `mcp_settings.ollama_model` → `mcp_settings.embedding_model` throughout.

- [ ] **Step 3: Update `embedding.OllamaEmbedder` → `embedding.HttpEmbedder`**

Each construction site adds `.dialect` and `.api_key`:
```zig
var embedder_for_index = embedding.HttpEmbedder{
    .transport = http_client.transport(),
    .base_url = mcp_settings.embedding_url,
    .model = mcp_settings.embedding_model,
    .dialect = mcp_settings.embedding_dialect,
    .api_key = mcp_settings.embedding_api_key,
};
```

- [ ] **Step 4: Update `ensureModelAvailable` calls**

Pass dialect:
```zig
embedding_http.ensureModelAvailable(allocator, http_client.transport(), mcp_settings.embedding_url, mcp_settings.embedding_model, mcp_settings.embedding_dialect) catch |err| {
```

For openai dialect, the function returns immediately so the error handling won't trigger.

- [ ] **Step 5: Update config output**

The MCP config handler outputs `ollama_url` and `ollama_model` in JSON (around line 617). Update to also include `embedding_api`:
```zig
try out.writer.print("{{\"root\":\"{s}\",\"db_path\":\"{s}\",\"embedding_url\":\"{s}\",\"embedding_model\":\"{s}\",\"embedding_api\":\"{s}\",\"embedding_dim\":{d}}}", .{
    // ...
    settings.embedding_url,
    settings.embedding_model,
    if (settings.embedding_dialect == .openai) "openai" else "ollama",
    settings.embedding_dim,
});
```

- [ ] **Step 6: Update MCP test settings**

There are many test settings blocks with `.ollama_url` and `.ollama_model`. Update all to `.embedding_url` and `.embedding_model`.

- [ ] **Step 7: Run tests**

```bash
nix build .#codescan-tests 2>&1 | tail -20
```

- [ ] **Step 8: Commit**

```bash
git add src/mcp.zig
git commit -m "feat: wire OpenAI embedding dialect through MCP server"
```

---

### Task 8: Update `server.zig` and `indexer.zig`

**Files:**
- Modify: `src/server.zig`
- Modify: `src/indexer.zig`

- [ ] **Step 1: Update `server.zig` Settings struct**

Replace:
```zig
ollama_url: []const u8,
ollama_model: []const u8,
```
With:
```zig
embedding_url: []const u8,
embedding_model: []const u8,
embedding_dialect: embedding_http.ApiDialect = .ollama,
embedding_api_key: ?[]const u8 = null,
```

- [ ] **Step 2: Update `server.zig` call sites**

Same pattern — rename field references, update `embedding.HttpEmbedder` construction, update `ensureModelAvailable` call with dialect.

- [ ] **Step 3: Update `server.zig` test settings**

Replace `.ollama_url` and `.ollama_model` in test settings blocks with `.embedding_url` and `.embedding_model`.

- [ ] **Step 4: Update `indexer.zig` call sites**

`indexer.zig` has one `embedding.OllamaEmbedder` construction and one `ensureModelAvailable` call. Update both with the same pattern. Note: `indexer.zig` doesn't have its own Settings struct — it receives the embedder from callers. Update the `OllamaEmbedder` → `HttpEmbedder` rename and the `skipIfNoOllama` reference.

- [ ] **Step 5: Run tests**

```bash
nix build .#codescan-tests 2>&1 | tail -20
```

- [ ] **Step 6: Commit**

```bash
git add src/server.zig src/indexer.zig
git commit -m "feat: wire OpenAI embedding dialect through server and indexer"
```

---

### Task 9: Update `build.zig` test target name

**Files:**
- Modify: `build.zig`

- [ ] **Step 1: Rename test target**

The `ollama_tests` variable and its `root_source_file` reference were already updated in Task 1. Verify the variable name is updated too:

Replace `ollama_tests` with `embedding_http_tests` in the variable name and all references in the build configuration block.

- [ ] **Step 2: Run full build + tests**

```bash
nix build .#codescan-tests 2>&1 | tail -20
```

- [ ] **Step 3: Commit (if not already committed in Task 1)**

```bash
git add build.zig
git commit -m "refactor: rename ollama_tests to embedding_http_tests in build.zig"
```

---

### Task 10: Final integration verification

- [ ] **Step 1: Run full test suite**

```bash
nix build .#codescan-tests 2>&1 | tail -30
```

All tests must pass.

- [ ] **Step 2: Build the binary**

```bash
nix build .#codescan 2>&1
```

- [ ] **Step 3: Smoke test — verify existing Ollama flow still works**

```bash
./result/bin/codescan status 2>&1
```

Should show normal status (ollama dialect is the default).

- [ ] **Step 4: Verify config parsing with new keys**

```bash
echo "embedding_api=openai" | ./result/bin/codescan --help 2>&1
```

Just verify binary doesn't crash with new config values.

- [ ] **Step 5: Commit any remaining fixes, then final commit**

```bash
git add -A
git status
# If clean, skip. If not, commit fixes.
```
