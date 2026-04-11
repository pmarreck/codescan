# Embedding Auto-Detect & Graceful Degradation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-detect embedding servers during init, add lexical-only fallback that doesn't crash, and add `--lexical-only` flag for explicit opt-in.

**Architecture:** Add `NullEmbedder` to `embedding.zig` that returns empty results. Add `detectEmbeddingServer` to `main.zig` that probes Ollama then oMLX. Modify `flushBatch`/`flushCommentBatch` in `indexer.zig` to skip vector insertion when embedder returns empty. Update `init`, `index`, `update`, and auto-index paths to use detection and fallback. Add config-writing helper to `config.zig`.

**Tech Stack:** Zig 0.15, existing `embedding_http.zig` Transport/MockTransportCtx infrastructure.

---

### Task 1: Add NullEmbedder

**Files:**
- Modify: `src/embedding.zig:35` (after `HttpEmbedder`)
- Modify: `src/indexer.zig:860-902` (`flushBatch` and `flushCommentBatch`)

- [ ] **Step 1: Write failing test for NullEmbedder**

Add at the end of `src/embedding.zig`, before the closing `envOrDefault` function (before line 67):

```zig
test "NullEmbedder returns empty embeddings and free is safe" {
    const allocator = std.testing.allocator;
    const null_embedder = NullEmbedder.embedder();
    const inputs = [_][]const u8{ "hello", "world" };
    const embeddings = try null_embedder.embed(null_embedder.ctx, allocator, &inputs);
    defer null_embedder.free(null_embedder.ctx, allocator, embeddings);
    try std.testing.expectEqual(@as(usize, 0), embeddings.len);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/pmarreck/Documents-CloudManaged/codescan && nix develop -c zig build test-unit 2>&1 | grep -A2 "NullEmbedder"`
Expected: Compilation error — `NullEmbedder` not defined.

- [ ] **Step 3: Implement NullEmbedder**

Add after `HttpEmbedder` (after line 35) in `src/embedding.zig`:

```zig
pub const NullEmbedder = struct {
    pub fn embedder() Embedder {
        return .{ .ctx = @ptrFromInt(1), .embed = embed_fn, .free = free_fn };
    }

    fn embed_fn(_: *anyopaque, allocator: std.mem.Allocator, _: []const []const u8) ![][]f32 {
        return try allocator.alloc([]f32, 0);
    }

    fn free_fn(_: *anyopaque, allocator: std.mem.Allocator, embeddings: [][]f32) void {
        allocator.free(embeddings);
    }
};
```

Note: `@ptrFromInt(1)` is used because `ctx` is `*anyopaque` (non-nullable) but NullEmbedder never dereferences it. This is a standard Zig pattern for sentinel non-null opaque pointers.

- [ ] **Step 4: Update flushBatch to handle empty embeddings**

In `src/indexer.zig`, modify `flushBatch` (line 860). After `const embeddings = try embedder.embed(...)` (line 868) and `defer embedder.free(...)` (line 869), add an early return:

```zig
    const embeddings = try embedder.embed(embedder.ctx, allocator, batch_texts.items);
    defer embedder.free(embedder.ctx, allocator, embeddings);

    // NullEmbedder returns empty — skip vector insertion, just clean up texts
    if (embeddings.len == 0) {
        for (batch_texts.items) |text| allocator.free(text);
        batch_texts.clearRetainingCapacity();
        batch_rowids.clearRetainingCapacity();
        return;
    }

    if (embeddings.len != batch_texts.items.len) return error.EmbeddingCountMismatch;
```

Apply the same change to `flushCommentBatch` (line 882) — identical early-return after the embed call at line 890.

- [ ] **Step 5: Run test to verify it passes**

Run: `cd /Users/pmarreck/Documents-CloudManaged/codescan && nix develop -c zig build test-unit 2>&1 | tail -5`
Expected: All tests pass including "NullEmbedder returns empty embeddings and free is safe".

- [ ] **Step 6: Commit**

```bash
git add src/embedding.zig src/indexer.zig
git commit -m "feat: add NullEmbedder for lexical-only indexing

NullEmbedder implements the Embedder interface but returns empty results.
flushBatch/flushCommentBatch skip vector insertion when embeddings are
empty, enabling full file/symbol indexing without an embedding server."
```

---

### Task 2: Add `--lexical-only` CLI flag

**Files:**
- Modify: `src/cli.zig:84-85` (Seen struct), `src/cli.zig:143-145` (Parsed struct), `src/cli.zig:815-826` (flag parsing)

- [ ] **Step 1: Write failing test for --lexical-only parsing**

Add at the end of the test block in `src/cli.zig` (find the last test, add after it):

```zig
test "parse --lexical-only flag" {
    const args = [_][]const u8{ "codescan", "index", "--lexical-only" };
    var parsed = try parse(std.testing.allocator, &args);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(parsed.lexical_only);
    try std.testing.expect(parsed.seen.lexical_only);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/pmarreck/Documents-CloudManaged/codescan && nix develop -c zig build test-unit 2>&1 | grep -A2 "lexical_only"`
Expected: Compilation error — `lexical_only` field not found.

- [ ] **Step 3: Add lexical_only to Seen struct**

In `src/cli.zig`, add after line 85 (`confirm: bool = false,`):

```zig
    lexical_only: bool = false,
```

- [ ] **Step 4: Add lexical_only to Parsed struct**

In `src/cli.zig`, add after line 145 (`confirm: bool,`):

```zig
    lexical_only: bool,
```

- [ ] **Step 5: Add default value in parse function**

Find where `Parsed` is initialized in `parse()` (around line 157-200 — look for the `var parsed = Parsed{...}` block). Add:

```zig
    .lexical_only = false,
```

- [ ] **Step 6: Parse the --lexical-only flag**

In `src/cli.zig`, add after the `--force` / `-f` block (after line 820):

```zig
        if (std.mem.eql(u8, arg, "--lexical-only")) {
            parsed.lexical_only = true;
            parsed.seen.lexical_only = true;
            i += 1;
            continue;
        }
```

- [ ] **Step 7: Run test to verify it passes**

Run: `cd /Users/pmarreck/Documents-CloudManaged/codescan && nix develop -c zig build test-unit 2>&1 | tail -5`
Expected: All tests pass including "parse --lexical-only flag".

- [ ] **Step 8: Commit**

```bash
git add src/cli.zig
git commit -m "feat: add --lexical-only CLI flag for index/update commands"
```

---

### Task 3: Add config-writing helper

**Files:**
- Modify: `src/config.zig` (add `writeConfigValues` function)

- [ ] **Step 1: Write failing test for config writing**

Add at the end of `src/config.zig`:

```zig
test "writeConfigValues updates commented keys" {
    const allocator = std.testing.allocator;
    const input =
        \\# codescan config
        \\#embedding_url=http://localhost:11434
        \\#embedding_api=ollama
        \\#embedding_model=bge-large
        \\#search_mode=hybrid
        \\
    ;
    const kvs = [_]KV{
        .{ .key = "embedding_url", .value = "http://localhost:8000" },
        .{ .key = "embedding_api", .value = "openai" },
        .{ .key = "embedding_model", .value = "jina-code" },
    };
    const result = try writeConfigValues(allocator, input, &kvs);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "embedding_url=http://localhost:8000") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "embedding_api=openai") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "embedding_model=jina-code") != null);
    // search_mode should remain commented
    try std.testing.expect(std.mem.indexOf(u8, result, "#search_mode=hybrid") != null);
}

test "writeConfigValues updates uncommented keys" {
    const allocator = std.testing.allocator;
    const input =
        \\embedding_url=http://localhost:11434
        \\embedding_model=bge-large
        \\
    ;
    const kvs = [_]KV{
        .{ .key = "embedding_url", .value = "http://localhost:8000" },
    };
    const result = try writeConfigValues(allocator, input, &kvs);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "embedding_url=http://localhost:8000") != null);
    // embedding_model should be unchanged
    try std.testing.expect(std.mem.indexOf(u8, result, "embedding_model=bge-large") != null);
}

test "writeConfigValues appends missing keys" {
    const allocator = std.testing.allocator;
    const input =
        \\# codescan config
        \\#embedding_url=http://localhost:11434
        \\
    ;
    const kvs = [_]KV{
        .{ .key = "embedding_url", .value = "http://localhost:8000" },
        .{ .key = "search_mode", .value = "lexical" },
    };
    const result = try writeConfigValues(allocator, input, &kvs);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "embedding_url=http://localhost:8000") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "search_mode=lexical") != null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/pmarreck/Documents-CloudManaged/codescan && nix develop -c zig build test-unit 2>&1 | grep -A2 "writeConfigValues"`
Expected: Compilation error — `writeConfigValues` and `KV` not defined.

- [ ] **Step 3: Implement KV and writeConfigValues**

Add before the tests in `src/config.zig`:

```zig
pub const KV = struct {
    key: []const u8,
    value: []const u8,
};

/// Rewrites config content, uncommenting and updating keys that match `kvs`.
/// Keys not found in the original content are appended at the end.
/// Returns a new allocated string with the updated content.
pub fn writeConfigValues(allocator: std.mem.Allocator, content: []const u8, kvs: []const KV) ![]u8 {
    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(allocator);

    // Track which kvs were matched
    var matched = try allocator.alloc(bool, kvs.len);
    defer allocator.free(matched);
    @memset(matched, false);

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    var first_line = true;
    while (line_iter.next()) |line| {
        if (!first_line) try output.append(allocator, '\n');
        first_line = false;

        // Check if this line matches any key (commented or uncommented)
        var was_matched = false;
        for (kvs, 0..) |kv, idx| {
            // Match "#key=..." or "# key=..." or "key=..."
            const trimmed = std.mem.trimLeft(u8, line, " \t");
            const after_hash = if (std.mem.startsWith(u8, trimmed, "#"))
                std.mem.trimLeft(u8, trimmed[1..], " \t")
            else
                trimmed;

            if (std.mem.startsWith(u8, after_hash, kv.key)) {
                const rest = after_hash[kv.key.len..];
                if (rest.len > 0 and rest[0] == '=') {
                    // This line matches — write the uncommented updated value
                    try output.appendSlice(allocator, kv.key);
                    try output.append(allocator, '=');
                    try output.appendSlice(allocator, kv.value);
                    matched[idx] = true;
                    was_matched = true;
                    break;
                }
            }
        }

        if (!was_matched) {
            try output.appendSlice(allocator, line);
        }
    }

    // Append any unmatched keys at the end
    for (kvs, 0..) |kv, idx| {
        if (!matched[idx]) {
            try output.append(allocator, '\n');
            try output.appendSlice(allocator, kv.key);
            try output.append(allocator, '=');
            try output.appendSlice(allocator, kv.value);
        }
    }

    return try output.toOwnedSlice(allocator);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/pmarreck/Documents-CloudManaged/codescan && nix develop -c zig build test-unit 2>&1 | tail -5`
Expected: All tests pass including the three writeConfigValues tests.

- [ ] **Step 5: Commit**

```bash
git add src/config.zig
git commit -m "feat: add config.writeConfigValues for updating INI keys

Handles commented (#key=val) and uncommented (key=val) lines.
Unmatched keys are appended. Used by auto-detect to persist discovered
embedding server settings."
```

---

### Task 4: Add promptYesNo helper and detectEmbeddingServer

**Files:**
- Modify: `src/main.zig` (add `promptYesNo`, `DetectedServer`, `detectEmbeddingServer`)

- [ ] **Step 1: Write failing test for detectEmbeddingServer with Ollama available**

In `src/main.zig`, find the test block area (around line 5500+). Add:

```zig
test "detectEmbeddingServer finds Ollama" {
    const allocator = std.testing.allocator;
    var mock = embedding_http.MockTransportCtx{
        .tags_body =
            \\{"models":[{"name":"bge-large:latest"}]}
        ,
        .ps_body =
            \\{"models":[]}
        ,
    };
    const result = detectEmbeddingServer(
        allocator,
        mock.transport(),
        "http://localhost:11434",
        "bge-large",
    );
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("http://localhost:11434", result.?.url);
    try std.testing.expectEqual(embedding_http.ApiDialect.ollama, result.?.dialect);
    try std.testing.expect(result.?.model_available);
}
```

Note: `MockTransportCtx` is currently private in `embedding_http.zig`. We'll need to make it `pub` first.

- [ ] **Step 2: Make MockTransportCtx public**

In `src/embedding_http.zig`, line 340, change:

```zig
const MockTransportCtx = struct {
```
to:
```zig
pub const MockTransportCtx = struct {
```

Also make its `transport` function and `send` function public:
- Line 347: change `fn send(` to `pub fn send(`
- Line 380: change `fn transport(` to `pub fn transport(`

- [ ] **Step 3: Add DetectedServer struct and detectEmbeddingServer**

Add after `tryInitOllama` (after line 1555) in `src/main.zig`:

```zig
const DetectedServer = struct {
    url: []const u8,
    dialect: embedding_http.ApiDialect,
    model_available: bool,
};

/// Probes well-known embedding server ports and returns the first that responds.
/// Tries Ollama on the configured URL first, then oMLX on :8000.
/// Returns null if no server responds.
fn detectEmbeddingServer(
    allocator: std.mem.Allocator,
    transport: embedding_http.Transport,
    configured_url: []const u8,
    model_name: []const u8,
) ?DetectedServer {
    // Try 1: Ollama at configured URL (default http://localhost:11434)
    if (probeOllama(allocator, transport, configured_url, model_name)) |result| {
        return result;
    }

    // Try 2: oMLX at http://localhost:8000 (OpenAI-compatible)
    if (probeOpenAI(allocator, transport, "http://localhost:8000")) |result| {
        return result;
    }

    return null;
}

fn probeOllama(
    allocator: std.mem.Allocator,
    transport: embedding_http.Transport,
    base_url: []const u8,
    model_name: []const u8,
) ?DetectedServer {
    embedding_http.ensureModelAvailable(allocator, transport, base_url, model_name, .ollama) catch |err| {
        switch (err) {
            error.ModelNotFound => return .{
                .url = base_url,
                .dialect = .ollama,
                .model_available = false,
            },
            error.ModelLoading => return .{
                .url = base_url,
                .dialect = .ollama,
                .model_available = true,
            },
            else => return null, // Server not reachable
        }
    };
    return .{
        .url = base_url,
        .dialect = .ollama,
        .model_available = true,
    };
}

fn probeOpenAI(
    allocator: std.mem.Allocator,
    transport: embedding_http.Transport,
    base_url: []const u8,
) ?DetectedServer {
    const url = buildOpenAIModelsUrl(allocator, base_url) catch return null;
    defer allocator.free(url);

    const headers = [_]std.http.Header{
        .{ .name = "Accept", .value = "application/json" },
    };

    const response = transport.send(transport.ctx, allocator, .{
        .method = "GET",
        .url = url,
        .headers = &headers,
        .body = "",
    }) catch return null;
    defer allocator.free(response.body);

    if (response.status != 200) return null;

    return .{
        .url = base_url,
        .dialect = .openai,
        .model_available = true, // oMLX serves whatever models it has loaded
    };
}

fn buildOpenAIModelsUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    const trimmed = std.mem.trimRight(u8, base_url, "/");
    return std.fmt.allocPrint(allocator, "{s}/v1/models", .{trimmed});
}
```

- [ ] **Step 4: Add promptYesNo helper**

Add near `detectEmbeddingServer` in `src/main.zig`:

```zig
/// Prompts the user with a yes/no question. Returns true for yes.
/// In non-TTY mode, returns `non_tty_default`.
fn promptYesNo(stderr: *std.Io.Writer, non_tty_default: bool) bool {
    _ = stderr.flush() catch {};
    if (!std.fs.File.stdin().isTty()) return non_tty_default;
    var input_buf: [16]u8 = undefined;
    const stdin = std.fs.File.stdin();
    const n = stdin.read(&input_buf) catch return false;
    if (n == 0) return false;
    return input_buf[0] == 'y' or input_buf[0] == 'Y';
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd /Users/pmarreck/Documents-CloudManaged/codescan && nix develop -c zig build test-unit 2>&1 | tail -5`
Expected: All tests pass including "detectEmbeddingServer finds Ollama".

- [ ] **Step 6: Write additional tests**

Add after the first test:

```zig
test "detectEmbeddingServer finds oMLX when Ollama unavailable" {
    const allocator = std.testing.allocator;
    // Mock that fails on /api/tags (Ollama down) but succeeds on /v1/models
    var mock = OpenAIFallbackMock{};
    const result = detectEmbeddingServer(
        allocator,
        mock.transport(),
        "http://localhost:11434",
        "bge-large",
    );
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("http://localhost:8000", result.?.url);
    try std.testing.expectEqual(embedding_http.ApiDialect.openai, result.?.dialect);
}

test "detectEmbeddingServer returns null when nothing available" {
    const allocator = std.testing.allocator;
    var mock = AllFailMock{};
    const result = detectEmbeddingServer(
        allocator,
        mock.transport(),
        "http://localhost:11434",
        "bge-large",
    );
    try std.testing.expect(result == null);
}

test "detectEmbeddingServer Ollama up but model missing" {
    const allocator = std.testing.allocator;
    var mock = embedding_http.MockTransportCtx{
        .tags_body =
            \\{"models":[{"name":"llama3:latest"}]}
        ,
        .ps_body =
            \\{"models":[]}
        ,
    };
    const result = detectEmbeddingServer(
        allocator,
        mock.transport(),
        "http://localhost:11434",
        "bge-large",
    );
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("http://localhost:11434", result.?.url);
    try std.testing.expect(!result.?.model_available);
}
```

These tests require two small mock structs. Add them near the tests:

```zig
const OpenAIFallbackMock = struct {
    fn send(_: *anyopaque, allocator: std.mem.Allocator, req: embedding_http.HttpRequest) !embedding_http.HttpResponse {
        if (std.mem.endsWith(u8, req.url, "/v1/models")) {
            return .{ .status = 200, .body = try allocator.dupe(u8, "{\"data\":[]}") };
        }
        return error.ConnectionRefused;
    }
    fn transport(self: *OpenAIFallbackMock) embedding_http.Transport {
        return .{ .ctx = self, .send = send };
    }
};

const AllFailMock = struct {
    fn send(_: *anyopaque, _: std.mem.Allocator, _: embedding_http.HttpRequest) !embedding_http.HttpResponse {
        return error.ConnectionRefused;
    }
    fn transport(self: *AllFailMock) embedding_http.Transport {
        return .{ .ctx = self, .send = send };
    }
};
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `cd /Users/pmarreck/Documents-CloudManaged/codescan && nix develop -c zig build test-unit 2>&1 | tail -5`
Expected: All tests pass.

- [ ] **Step 8: Commit**

```bash
git add src/main.zig src/embedding_http.zig
git commit -m "feat: add detectEmbeddingServer and promptYesNo helpers

detectEmbeddingServer probes Ollama then oMLX, returns first responder.
promptYesNo handles TTY/non-TTY input for interactive fallback prompts.
MockTransportCtx made pub for cross-module test use."
```

---

### Task 5: Fix auto-index crash (the bug)

**Files:**
- Modify: `src/main.zig:560-588` (auto-index path in search command)

- [ ] **Step 1: Write failing test that reproduces the crash**

This is the core bug: when Ollama is unreachable and auto-index triggers, `performFullIndex` is called with a dead `HttpEmbedder`. The fix is to use `NullEmbedder` when detection fails.

Since this is deep in the CLI flow, we'll verify via the existing test infrastructure after fixing. First, apply the fix:

- [ ] **Step 2: Replace auto-index embedding logic**

In `src/main.zig`, replace lines 565-587 (the `// Try Ollama; fall back to lexical if unavailable` block inside the `if (!storage.isIndexPopulated(db))` branch):

Old code (lines 565-587):
```zig
                // Try Ollama; fall back to lexical if unavailable
                const ollama_ok = tryInitOllama(allocator, &http_client, settings.embedding_url, settings.embedding_model, settings.embedding_dialect, stderr);
                if (!ollama_ok) {
                    effective_search_mode = .lexical;
                }

                var embedder_adapter = embedding.HttpEmbedder{
                    .transport = http_client.transport(),
                    .base_url = settings.embedding_url,
                    .model = settings.embedding_model,
                    .dialect = settings.embedding_dialect,
                    .auth_header = settings.embedding_auth_header,
                };

                _ = try performFullIndex(
                    allocator,
                    db,
                    settings,
                    registry,
                    embedder_adapter.embedder(),
                    stderr,
                    shouldShowProgress(std.fs.File.stderr().isTty(), settings.output),
                );
```

New code:
```zig
                // Auto-detect embedding server; use NullEmbedder if unavailable
                const detected = detectEmbeddingServer(allocator, http_client.transport(), settings.embedding_url, settings.embedding_model);
                const use_embeddings = detected != null and detected.?.model_available;

                if (!use_embeddings) {
                    effective_search_mode = .lexical;
                    if (detected) |d| {
                        if (!d.model_available) {
                            _ = stderr.print("  note: Embedding server found at {s} but model '{s}' not installed.\n" ++
                                "  Run 'codescan setup-model' then 'codescan update' for semantic search.\n", .{ d.url, settings.embedding_model }) catch {};
                        }
                    } else {
                        _ = stderr.print("  note: No embedding server found. Using lexical-only search.\n" ++
                            "  Run 'codescan setup-model' for semantic search.\n", .{}) catch {};
                    }
                    _ = stderr.flush() catch {};
                }

                var embedder_adapter = embedding.HttpEmbedder{
                    .transport = http_client.transport(),
                    .base_url = settings.embedding_url,
                    .model = settings.embedding_model,
                    .dialect = settings.embedding_dialect,
                    .auth_header = settings.embedding_auth_header,
                };
                const active_embedder = if (use_embeddings)
                    embedder_adapter.embedder()
                else
                    embedding.NullEmbedder.embedder();

                _ = try performFullIndex(
                    allocator,
                    db,
                    settings,
                    registry,
                    active_embedder,
                    stderr,
                    shouldShowProgress(std.fs.File.stderr().isTty(), settings.output),
                );
```

- [ ] **Step 3: Build and verify compilation**

Run: `cd /Users/pmarreck/Documents-CloudManaged/codescan && nix develop -c zig build 2>&1 | tail -10`
Expected: Clean build, no errors.

- [ ] **Step 4: Run full test suite**

Run: `cd /Users/pmarreck/Documents-CloudManaged/codescan && nix develop -c zig build test-unit 2>&1 | tail -5`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/main.zig
git commit -m "fix: auto-index uses NullEmbedder when server unavailable

Fixes ConnectionRefused crash when auto-index triggers during search
with no embedding server running. Now uses detectEmbeddingServer and
falls back to NullEmbedder for lexical-only indexing."
```

---

### Task 6: Update `codescan init` with auto-detect and prompts

**Files:**
- Modify: `src/main.zig:275-314` (init command)

- [ ] **Step 1: Update init command flow**

Replace lines 275-313 (from `// Try Ollama; fall back to lexical-only if unavailable` through the summary print) in the `.init` branch:

Old code:
```zig
            // Try Ollama; fall back to lexical-only if unavailable
            var http_client = embedding_http.StdHttpTransport.init(allocator);
            defer http_client.deinit();
            const ollama_ok = tryInitOllama(allocator, &http_client, settings.embedding_url, settings.embedding_model, settings.embedding_dialect, stderr);

            var embedder_adapter = embedding.HttpEmbedder{
                .transport = http_client.transport(),
                .base_url = settings.embedding_url,
                .model = settings.embedding_model,
                .dialect = settings.embedding_dialect,
                .auth_header = settings.embedding_auth_header,
            };

            const show_progress = shouldShowProgress(std.fs.File.stderr().isTty(), settings.output);

            // Perform full index
            const stats = try performFullIndex(
                allocator,
                db,
                settings,
                registry,
                embedder_adapter.embedder(),
                stderr,
                show_progress,
            );

            // Print summary
            if (settings.output == .json) {
                try stdout.print("{{\"status\":\"ok\",\"files\":{d},\"symbols\":{d},\"semantic\":{s}}}\n", .{
                    stats.files, stats.symbols, if (ollama_ok) "true" else "false",
                });
            } else {
                try stdout.print("Initialized codescan: {d} files, {d} symbols indexed", .{ stats.files, stats.symbols });
                if (!ollama_ok) {
                    try stdout.print(" (lexical only)", .{});
                }
                try stdout.print("\n", .{});
            }
```

New code:
```zig
            // Auto-detect embedding server
            var http_client = embedding_http.StdHttpTransport.init(allocator);
            defer http_client.deinit();

            const detected = detectEmbeddingServer(allocator, http_client.transport(), settings.embedding_url, settings.embedding_model);
            var use_embeddings = false;

            if (detected) |d| {
                if (d.model_available) {
                    // Server found with model — write config and proceed with embeddings
                    _ = stderr.print("  Detected {s} on {s} with model '{s}'. Saved to .codescan/config.ini.\n", .{
                        if (d.dialect == .ollama) "Ollama" else "oMLX", d.url, settings.embedding_model,
                    }) catch {};
                    _ = stderr.flush() catch {};
                    use_embeddings = true;
                } else {
                    // Server found but model missing
                    _ = stderr.print("  Found {s} on {s} but model '{s}' not installed.\n" ++
                        "  Run 'ollama pull {s}' then 'codescan index' for semantic search.\n", .{
                        if (d.dialect == .ollama) "Ollama" else "oMLX", d.url, settings.embedding_model, settings.embedding_model,
                    }) catch {};
                    _ = stderr.flush() catch {};
                    _ = stderr.print("  Index in lexical-only mode? [Y/n] ", .{}) catch {};
                    if (!promptYesNo(stderr, true)) {
                        try stdout.print("Aborted. Run 'codescan setup-model' for setup instructions.\n", .{});
                        try stdout.flush();
                        return;
                    }
                }
                // Write detected server config
                writeDetectedConfig(allocator, config_root, d.url, d.dialect) catch |err| {
                    _ = stderr.print("  warning: could not update config: {s}\n", .{@errorName(err)}) catch {};
                    _ = stderr.flush() catch {};
                };
            } else {
                // No server found
                _ = stderr.print("  No embedding server detected.\n" ++
                    "  Index in lexical-only mode? (Semantic search available later via 'codescan setup-model'). [Y/n] ", .{}) catch {};
                if (!promptYesNo(stderr, true)) {
                    try stdout.print("Aborted. Run 'codescan setup-model' for setup instructions.\n", .{});
                    try stdout.flush();
                    return;
                }
            }

            if (!use_embeddings) {
                // Write search_mode=lexical to config
                writeDetectedConfigLexical(allocator, config_root) catch |err| {
                    _ = stderr.print("  warning: could not update config: {s}\n", .{@errorName(err)}) catch {};
                    _ = stderr.flush() catch {};
                };
            }

            var embedder_adapter = embedding.HttpEmbedder{
                .transport = http_client.transport(),
                .base_url = settings.embedding_url,
                .model = settings.embedding_model,
                .dialect = settings.embedding_dialect,
                .auth_header = settings.embedding_auth_header,
            };
            const active_embedder = if (use_embeddings)
                embedder_adapter.embedder()
            else
                embedding.NullEmbedder.embedder();

            const show_progress = shouldShowProgress(std.fs.File.stderr().isTty(), settings.output);

            const stats = try performFullIndex(
                allocator,
                db,
                settings,
                registry,
                active_embedder,
                stderr,
                show_progress,
            );

            // Print summary
            if (settings.output == .json) {
                try stdout.print("{{\"status\":\"ok\",\"files\":{d},\"symbols\":{d},\"semantic\":{s}}}\n", .{
                    stats.files, stats.symbols, if (use_embeddings) "true" else "false",
                });
            } else {
                try stdout.print("Initialized codescan: {d} files, {d} symbols indexed", .{ stats.files, stats.symbols });
                if (!use_embeddings) {
                    try stdout.print(" (lexical only)", .{});
                }
                try stdout.print("\n", .{});
            }
```

- [ ] **Step 2: Add config-writing helper functions**

Add near `detectEmbeddingServer` in `src/main.zig`:

```zig
fn writeDetectedConfig(allocator: std.mem.Allocator, config_root: []const u8, url: []const u8, dialect: embedding_http.ApiDialect) !void {
    const cfg_path = try configPath(allocator, config_root);
    defer allocator.free(cfg_path);
    const content = try std.fs.cwd().readFileAlloc(allocator, cfg_path, 64 * 1024);
    defer allocator.free(content);
    const dialect_str = if (dialect == .ollama) "ollama" else "openai";
    const kvs = [_]config.KV{
        .{ .key = "embedding_url", .value = url },
        .{ .key = "embedding_api", .value = dialect_str },
    };
    const updated = try config.writeConfigValues(allocator, content, &kvs);
    defer allocator.free(updated);
    const file = try std.fs.cwd().createFile(cfg_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(updated);
}

fn writeDetectedConfigLexical(allocator: std.mem.Allocator, config_root: []const u8) !void {
    const cfg_path = try configPath(allocator, config_root);
    defer allocator.free(cfg_path);
    const content = try std.fs.cwd().readFileAlloc(allocator, cfg_path, 64 * 1024);
    defer allocator.free(content);
    const kvs = [_]config.KV{
        .{ .key = "search_mode", .value = "lexical" },
    };
    const updated = try config.writeConfigValues(allocator, content, &kvs);
    defer allocator.free(updated);
    const file = try std.fs.cwd().createFile(cfg_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(updated);
}
```

- [ ] **Step 3: Build and verify compilation**

Run: `cd /Users/pmarreck/Documents-CloudManaged/codescan && nix develop -c zig build 2>&1 | tail -10`
Expected: Clean build.

- [ ] **Step 4: Run tests**

Run: `cd /Users/pmarreck/Documents-CloudManaged/codescan && nix develop -c zig build test-unit 2>&1 | tail -5`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/main.zig
git commit -m "feat: codescan init auto-detects embedding server

Probes Ollama then oMLX on init. If found with model, writes config and
indexes with embeddings. If server found but model missing, or no server
found, prompts user for lexical-only mode. Writes detected settings to
config.ini."
```

---

### Task 7: Update `codescan index` and `codescan update` with --lexical-only and fallback prompt

**Files:**
- Modify: `src/main.zig:318-367` (index command), `src/main.zig:368-460` (update command)

- [ ] **Step 1: Update index command**

Replace lines 318-366 (the `.index` branch):

Old code (lines 326-333):
```zig
            try ensureModelAvailableOrExit(allocator, http_client.transport(), settings.embedding_url, settings.embedding_model, settings.embedding_dialect);
            var embedder_adapter = embedding.HttpEmbedder{
                .transport = http_client.transport(),
                .base_url = settings.embedding_url,
                .model = settings.embedding_model,
                .dialect = settings.embedding_dialect,
                .auth_header = settings.embedding_auth_header,
            };
```

New code:
```zig
            var use_null_embedder = false;
            if (parsed.lexical_only) {
                use_null_embedder = true;
            } else {
                ensureModelAvailableOrPrompt(allocator, http_client.transport(), settings.embedding_url, settings.embedding_model, settings.embedding_dialect, &use_null_embedder) catch {
                    std.process.exit(1);
                };
            }
            var embedder_adapter = embedding.HttpEmbedder{
                .transport = http_client.transport(),
                .base_url = settings.embedding_url,
                .model = settings.embedding_model,
                .dialect = settings.embedding_dialect,
                .auth_header = settings.embedding_auth_header,
            };
            const active_embedder = if (use_null_embedder)
                embedding.NullEmbedder.embedder()
            else
                embedder_adapter.embedder();
```

And update the `indexer.indexAll` call to use `active_embedder` instead of `embedder_adapter.embedder()` (line 343).

- [ ] **Step 2: Add ensureModelAvailableOrPrompt**

Add near `ensureModelAvailableOrExit` in `src/main.zig`:

```zig
/// Like ensureModelAvailableOrExit, but prompts for lexical-only fallback instead of exiting.
/// Sets use_null to true if user opts for lexical-only. Returns error if user declines.
fn ensureModelAvailableOrPrompt(
    allocator: std.mem.Allocator,
    transport: embedding_http.Transport,
    base_url: []const u8,
    model_name: []const u8,
    dialect: embedding_http.ApiDialect,
    use_null: *bool,
) !void {
    if (dialect == .openai) return;
    embedding_http.ensureModelAvailable(allocator, transport, base_url, model_name, dialect) catch |err| switch (err) {
        error.ModelNotFound => {
            var stderr_buf: [4096]u8 = undefined;
            var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
            const stderr = &stderr_writer.interface;
            _ = stderr.print(
                "  Ollama model '{s}' not found.\n" ++
                    "  Index in lexical-only mode? [Y/n] ",
                .{model_name},
            ) catch {};
            if (promptYesNo(stderr, false)) {
                use_null.* = true;
                return;
            }
            _ = stderr.print("Run 'ollama pull {s}' to install, then try again.\n", .{model_name}) catch {};
            _ = stderr.flush() catch {};
            return error.ModelNotFound;
        },
        error.ModelLoading => {
            var stderr_buf: [4096]u8 = undefined;
            var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
            const stderr = &stderr_writer.interface;
            _ = stderr.print(
                "  note: Ollama model '{s}' is loading into memory. This may take a moment...\n",
                .{model_name},
            ) catch {};
            _ = stderr.flush() catch {};
        },
        else => {
            var stderr_buf: [4096]u8 = undefined;
            var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
            const stderr = &stderr_writer.interface;
            _ = stderr.print(
                "  Embedding server unreachable at {s}.\n" ++
                    "  Index in lexical-only mode? [Y/n] ",
                .{base_url},
            ) catch {};
            if (promptYesNo(stderr, false)) {
                use_null.* = true;
                return;
            }
            _ = stderr.print("Start Ollama with: ollama serve\n", .{}) catch {};
            _ = stderr.flush() catch {};
            return err;
        },
    };
}
```

- [ ] **Step 3: Update update command**

Apply the same pattern to the `.update` branch (lines 420-429). Replace the `ensureModelAvailableOrExit` call and embedder creation:

Old code (lines 422-429):
```zig
            try ensureModelAvailableOrExit(allocator, http_client.transport(), settings.embedding_url, settings.embedding_model, settings.embedding_dialect);
            var embedder_adapter = embedding.HttpEmbedder{
                .transport = http_client.transport(),
                .base_url = settings.embedding_url,
                .model = settings.embedding_model,
                .dialect = settings.embedding_dialect,
                .auth_header = settings.embedding_auth_header,
            };
```

New code:
```zig
            var use_null_embedder = false;
            if (parsed.lexical_only) {
                use_null_embedder = true;
            } else {
                ensureModelAvailableOrPrompt(allocator, http_client.transport(), settings.embedding_url, settings.embedding_model, settings.embedding_dialect, &use_null_embedder) catch {
                    std.process.exit(1);
                };
            }
            var embedder_adapter = embedding.HttpEmbedder{
                .transport = http_client.transport(),
                .base_url = settings.embedding_url,
                .model = settings.embedding_model,
                .dialect = settings.embedding_dialect,
                .auth_header = settings.embedding_auth_header,
            };
            const active_embedder = if (use_null_embedder)
                embedding.NullEmbedder.embedder()
            else
                embedder_adapter.embedder();
```

And update `indexer.indexIncremental` call (line 439) to use `active_embedder` instead of `embedder_adapter.embedder()`.

- [ ] **Step 4: Build and verify**

Run: `cd /Users/pmarreck/Documents-CloudManaged/codescan && nix develop -c zig build 2>&1 | tail -10`
Expected: Clean build.

- [ ] **Step 5: Run tests**

Run: `cd /Users/pmarreck/Documents-CloudManaged/codescan && nix develop -c zig build test-unit 2>&1 | tail -5`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/main.zig
git commit -m "feat: index/update commands prompt for lexical-only on server failure

Instead of hard-exiting when embedding server is unreachable, index and
update now prompt 'Index in lexical-only mode? [Y/n]'. The --lexical-only
flag skips the prompt entirely. Non-TTY defaults to exit (explicit flag
required for scripts)."
```

---

### Task 8: Add help text for --lexical-only

**Files:**
- Modify: `src/main.zig` (help topics for index/update commands)

- [ ] **Step 1: Find and update help text**

Search for the index command help topic and add `--lexical-only` to it:

```bash
grep -n "index.*help\|help.*index\|index_help\|\"index\"" src/main.zig | head -20
```

Find the help text string for the `index` command (likely in the help topics section) and add a line:

```
    --lexical-only     Skip embeddings, index for lexical search only
```

Do the same for the `update` command help text.

- [ ] **Step 2: Build and verify**

Run: `cd /Users/pmarreck/Documents-CloudManaged/codescan && nix develop -c zig build 2>&1 | tail -5`
Expected: Clean build.

- [ ] **Step 3: Commit**

```bash
git add src/main.zig
git commit -m "docs: add --lexical-only to index/update help text"
```

---

### Task 9: End-to-end verification

- [ ] **Step 1: Run full test suite**

Run: `cd /Users/pmarreck/Documents-CloudManaged/codescan && nix develop -c zig build test-unit 2>&1 | tail -10`
Expected: All tests pass.

- [ ] **Step 2: Build release binary**

Run: `cd /Users/pmarreck/Documents-CloudManaged/codescan && nix develop -c zig build -Doptimize=ReleaseFast 2>&1 | tail -5`
Expected: Clean build.

- [ ] **Step 3: Test --lexical-only manually**

Run in a temp directory:
```bash
cd "$(mktemp -d)" && mkdir -p test-project && cd test-project
echo 'pub fn hello() void {}' > main.zig
/Users/pmarreck/Documents-CloudManaged/codescan/zig-out/bin/codescan index --lexical-only --root .
/Users/pmarreck/Documents-CloudManaged/codescan/zig-out/bin/codescan search "hello" --root . --mode lexical
```
Expected: Index completes without error, search finds `hello`.

- [ ] **Step 4: Test init with no Ollama (if Ollama is not running)**

```bash
cd "$(mktemp -d)" && mkdir -p test-project && cd test-project
echo 'pub fn hello() void {}' > main.zig
echo "y" | /Users/pmarreck/Documents-CloudManaged/codescan/zig-out/bin/codescan init --root .
```
Expected: Prompts for lexical-only, "y" accepted, indexes successfully.

- [ ] **Step 5: Update PLAN.md**

Mark the auto-detect item as complete and update the bug item. In `PLAN.md`, the relevant pending follow-up in the memory system (`project_auto_detect_embedding_server.md`) should be updated to reflect completion.

- [ ] **Step 6: Final commit**

```bash
git add PLAN.md
git commit -m "docs: mark embedding auto-detect as complete in PLAN.md"
```
