# Default Model Change + setup-model Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Change the default embedding model to jina-code-embeddings-1.5b and add a `setup-model` command that prints provider-specific installation instructions.

**Architecture:** Update default values in 4 files, add a `setup_model` variant to the CLI command enum, add a handler in main.zig that prints instructions based on the configured dialect. Update README to document the new default and command.

**Tech Stack:** Zig 0.15

**Spec:** `docs/superpowers/specs/2026-04-08-default-model-and-setup-command-design.md`

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `src/main.zig` | Default values + setup-model handler |
| Modify | `src/mcp.zig` | Default values |
| Modify | `src/cli.zig` | Default values + CommandTag + parsing |
| Modify | `src/config.zig` | Default template comment |
| Modify | `README.md` | Documentation updates |

---

### Task 1: Change default model and dimension

Update the 4 files that hardcode `bge-large` / `1024` as defaults.

**Files:**
- Modify: `src/main.zig:39-40` (Defaults struct)
- Modify: `src/mcp.zig:35,38` (Settings struct defaults)
- Modify: `src/cli.zig:178-179` (Parsed struct defaults)
- Modify: `src/config.zig` (template comment)

- [ ] **Step 1: Update `src/main.zig` Defaults**

Change:
```zig
embedding_model: []const u8 = "bge-large",
embedding_dim: usize = 1024,
```
To:
```zig
embedding_model: []const u8 = "jina-code-embeddings-1.5b",
embedding_dim: usize = 1536,
```

- [ ] **Step 2: Update `src/mcp.zig` Settings defaults**

Change:
```zig
embedding_model: []const u8 = "bge-large",
```
To:
```zig
embedding_model: []const u8 = "jina-code-embeddings-1.5b",
```

And change:
```zig
embedding_dim: usize = 1024,
```
To:
```zig
embedding_dim: usize = 1536,
```

- [ ] **Step 3: Update `src/cli.zig` Parsed defaults**

Change:
```zig
.embedding_model = "bge-large",
```
To:
```zig
.embedding_model = "jina-code-embeddings-1.5b",
```

And change:
```zig
.embedding_dim = 1024,
```
To:
```zig
.embedding_dim = 1536,
```

- [ ] **Step 4: Update `src/config.zig` template comment**

In the `default_template` string, update the embedding model comment to reference the new default. Find `bge-large` in the template and replace with `jina-code-embeddings-1.5b`. Also update the `embedding_dim` comment from `1024` to `1536`.

- [ ] **Step 5: Update test assertions that check old defaults**

Search for tests that assert `bge-large` or `1024` as default values. Key locations:

In `src/cli.zig`, the test `"parse empty args"` (around line 1031) checks:
```zig
try std.testing.expectEqualStrings("http://localhost:11434", parsed.embedding_url);
```
If it also checks `embedding_model` or `embedding_dim`, update those assertions.

In `src/config.zig`, the test `"parseText empty yields defaults"` checks that fields are null (no change needed — config defaults are all null).

In `src/config.zig`, the test `"default_template parses without error"` may reference the old model — update if needed.

In `src/mcp.zig`, multiple test settings blocks hardcode `.embedding_model = "bge-large"`. These are explicit test values (not defaults), so leave them as-is — they test with a specific model, not the default.

- [ ] **Step 6: Run tests**

```bash
nix develop --command zig build test 2>&1 | tail -30
```

Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add src/main.zig src/mcp.zig src/cli.zig src/config.zig
git commit -m "feat: change default embedding model to jina-code-embeddings-1.5b (1536-dim)"
```

---

### Task 2: Add `setup-model` CLI command

Add the command to CLI parsing and implement the handler in main.zig.

**Files:**
- Modify: `src/cli.zig` (CommandTag enum, parse function)
- Modify: `src/main.zig` (handler)

- [ ] **Step 1: Write failing test for CLI parsing**

Add to end of test section in `src/cli.zig`:

```zig
test "parse setup-model command" {
    const args = [_][]const u8{ "codescan", "setup-model" };
    var parsed = try parse(std.testing.allocator, &args);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(CommandTag.setup_model, parsed.command);
}
```

- [ ] **Step 2: Run tests to verify it fails**

```bash
nix develop --command zig build test 2>&1 | tail -30
```

Expected: Compile error — `CommandTag.setup_model` doesn't exist.

- [ ] **Step 3: Add `setup_model` to `CommandTag` enum**

In `src/cli.zig`, add `setup_model` to the `CommandTag` enum (after `status`):

```zig
pub const CommandTag = enum {
    help,
    config,
    init,
    index,
    update,
    search,
    serve,
    symbols,
    replace_symbol,
    insert_after,
    insert_before,
    replace_lines,
    insert_at,
    replace_content,
    create_file,
    read_file,
    destroy_file,
    diff,
    references,
    rename,
    watch,
    mcp_serve,
    clean,
    status,
    setup_model,
};
```

- [ ] **Step 4: Add parsing for `setup-model`**

In the command parsing section of `parse()`, add before the `"clean"` check (around line 390):

```zig
} else if (std.mem.eql(u8, cmd, "setup-model")) {
    parsed.command = .setup_model;
    help_topic_default = "setup-model";
    i += 1;
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
nix develop --command zig build test 2>&1 | tail -30
```

- [ ] **Step 6: Add handler in `main.zig`**

In the main command dispatch switch (find the `.status =>` branch around line 1196), add a new branch before or after it:

```zig
.setup_model => {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    _ = stdout.print(
        \\Recommended model: jina-code-embeddings-1.5b
        \\  1536 dimensions, 32K token context, code-specific training
        \\  License: CC-BY-NC-4.0 (non-commercial)
        \\
        \\
    , .{}) catch {};

    if (settings.embedding_dialect == .openai) {
        _ = stdout.print(
            \\For oMLX Server, download the MLX model from HuggingFace:
            \\
            \\  huggingface-cli download jinaai/jina-code-embeddings-1.5b-mlx
            \\
            \\Then configure your oMLX Server to serve it and set in .codescan/config:
            \\
            \\  embedding_api=openai
            \\  embedding_url=http://localhost:8000
            \\  embedding_model=jinaai/jina-code-embeddings-1.5b-mlx
            \\  embedding_api_key=<your-omlx-key>
            \\
            \\
        , .{}) catch {};
    } else {
        _ = stdout.print(
            \\To install via Ollama, run:
            \\
            \\  ollama pull hf.co/jinaai/jina-code-embeddings-1.5b-GGUF:Q8_0
            \\
            \\
        , .{}) catch {};
    }

    _ = stdout.print(
        \\Then reindex your project:
        \\
        \\  codescan index --force
        \\
        \\Note: If you use a different model, update embedding_model and embedding_dim
        \\in .codescan/config to match. Mismatched dimensions will cause search errors.
        \\
    , .{}) catch {};

    try stdout.flush();
},
```

- [ ] **Step 7: Run tests**

```bash
nix develop --command zig build test 2>&1 | tail -30
```

- [ ] **Step 8: Commit**

```bash
git add src/cli.zig src/main.zig
git commit -m "feat: add setup-model command with provider-specific instructions"
```

---

### Task 3: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update line 9 (feature bullet)**

Change:
```markdown
- Ollama embeddings (default: `bge-large`, override with `OLLAMA_MODEL`)
```
To:
```markdown
- Embedding providers: Ollama and OpenAI-compatible (oMLX, LiteLLM, vLLM) — default model: `jina-code-embeddings-1.5b`
```

- [ ] **Step 2: Update line 68 (integration test comment)**

Change:
```markdown
# requires Ollama running with bge-large pulled (or set OLLAMA_MODEL)
```
To:
```markdown
# requires Ollama running with jina-code-embeddings-1.5b pulled (or set OLLAMA_MODEL)
```

- [ ] **Step 3: Update config example (lines 339-340)**

Change:
```markdown
# Ollama model override (CLI flag or OLLAMA_MODEL env var also supported)
ollama_model=bge-large
```
To:
```markdown
# Embedding model (default: jina-code-embeddings-1.5b)
# Use ollama_model as alias, or OLLAMA_MODEL env var
embedding_model=jina-code-embeddings-1.5b

# For OpenAI-compatible providers (oMLX, LiteLLM, vLLM):
#embedding_api=openai
#embedding_url=http://localhost:8000
#embedding_api_key=<your-key>
```

- [ ] **Step 4: Add `setup-model` to commands table (after line 263)**

Add row:
```markdown
| `setup-model` | Show model installation instructions |
```

- [ ] **Step 5: Add Model Setup section after Config section (after line 345)**

Insert:

```markdown
## Model Setup

codescan defaults to `jina-code-embeddings-1.5b`, a code-specific embedding model with 1536 dimensions and 32K token context. Run `codescan setup-model` for provider-specific installation instructions.

### Quick start (Ollama)

```bash
ollama pull hf.co/jinaai/jina-code-embeddings-1.5b-GGUF:Q8_0
codescan index --force
```

### OpenAI-compatible providers (oMLX, LiteLLM, vLLM)

Set `embedding_api=openai` in `.codescan/config` along with `embedding_url` and `embedding_api_key`. See `codescan setup-model` for details.
```

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "docs: update README for new default model and setup-model command"
```

---

### Task 4: Final verification

- [ ] **Step 1: Run full test suite**

```bash
nix develop --command zig build test 2>&1 | tail -30
```

- [ ] **Step 2: Build release binary**

```bash
nix build 2>&1
```

- [ ] **Step 3: Smoke test setup-model**

```bash
./result/bin/codescan setup-model 2>&1
```

Verify it prints the Ollama instructions (since default dialect is ollama).
