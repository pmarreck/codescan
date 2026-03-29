# Kind Filter & Search Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix broken `--kind` filter, add const/var split, browse mode, path filtering, diagnostic counts, and MCP parity.

**Architecture:** All changes flow through three layers: (1) `inferKindFromSignature` in indexer.zig writes short canonical forms to DB, (2) `normalizeSymbolKind` in filters.zig maps user aliases to those same short forms, (3) search.zig/main.zig/mcp.zig wire filters and present results. Each task is self-contained and testable independently.

**Tech Stack:** Zig 0.15, SQLite (via C FFI), PCRE2 (via filter.zig), tree-sitter

**Build/test command:** `nix develop -c zig build test --summary all`

**Build binary:** `nix develop -c zig build install` (produces `./zig-out/bin/codescan`)

**Spec:** `docs/superpowers/specs/2026-03-29-kind-filter-improvements-design.md`

---

## File Map

| File | Responsibility | Tasks |
|---|---|---|
| `src/indexer.zig` | `inferKindFromSignature` — returns short canonical kind strings, language-aware const/var | 1, 2 |
| `src/filters.zig` | `normalizeSymbolKind` — maps user aliases to DB canonical forms; `parseSymbolKindList` — expands meta-kinds | 1, 2, 3 |
| `src/search.zig` | `tokenToKind` — NLP query extraction; `matchesFilters` — kind matching with `"*"` sentinel; `browse` — empty-query SQL path; `diagnosticCounts` — per-filter counts | 1, 4, 6 |
| `src/cli.zig` | Parse `--path` and `--file` flags | 5 |
| `src/main.zig` | Wire new filters through to search, diagnostic output | 5, 6 |
| `src/mcp.zig` | Add kind/path/file/lang/top parameters to search tool, diagnostic response | 7 |
| `src/model.zig` | No changes |  |
| `src/storage.zig` | Test fixtures only | 1 |
| `src/filter.zig` | Already has PCRE2 glob support, no changes needed | |

---

### Task 1: Short canonical forms + const/var split in indexer

This task changes `inferKindFromSignature` to return short forms (`"fn"`, `"const"`, `"var"`, `"mod"`) and split const/var by mutability. It also updates `normalizeSymbolKind` to map aliases to these short forms, and fixes all downstream string comparisons.

**Files:**
- Modify: `src/indexer.zig:497-541` (inferKindFromSignature, containsTypeAssignment, enrichSymbolMetadata)
- Modify: `src/indexer.zig:556-568` (inferScope — "function" → "fn" comparison)
- Modify: `src/indexer.zig:1139-1180` (existing tests)
- Modify: `src/filters.zig:265-294` (normalizeSymbolKind)
- Modify: `src/filters.zig:296-312` (normalizeSymbolKind test)
- Modify: `src/search.zig:1041-1064` (tokenToKind)
- Modify: `src/search.zig:2654-2735` (test fixtures)
- Modify: `src/storage.zig:1098,1120` (test fixtures)

- [ ] **Step 1: Write failing test for inferKindFromSignature short forms + const/var split**

In `src/indexer.zig`, replace the existing test `"inferKindFromSignature handles Zig pub const struct/enum/union patterns"` with this updated version that expects short forms and the const/var split. Add the `language` parameter.

```zig
test "inferKindFromSignature returns short canonical forms with const/var split" {
	// Functions → "fn"
	try std.testing.expectEqualStrings("fn", inferKindFromSignature("pub fn add(a: i32) i32", "zig").?);
	try std.testing.expectEqualStrings("fn", inferKindFromSignature("fn sub(a: i32) i32", "zig").?);
	try std.testing.expectEqualStrings("fn", inferKindFromSignature("def foo(x):", "python").?);
	try std.testing.expectEqualStrings("fn", inferKindFromSignature("inline fn vecToLower(v: Vec) Vec", "zig").?);
	try std.testing.expectEqualStrings("fn", inferKindFromSignature("pub inline fn foo() void", "zig").?);
	try std.testing.expectEqualStrings("fn", inferKindFromSignature("extern fn write() void", "zig").?);
	// Structs/enums/unions from Zig patterns
	try std.testing.expectEqualStrings("struct", inferKindFromSignature("pub const FsWatch = struct", "zig").?);
	try std.testing.expectEqualStrings("struct", inferKindFromSignature("const Config = struct", "zig").?);
	try std.testing.expectEqualStrings("enum", inferKindFromSignature("pub const Color = enum", "zig").?);
	try std.testing.expectEqualStrings("union", inferKindFromSignature("pub const Value = union", "zig").?);
	// Immutable → "const"
	try std.testing.expectEqualStrings("const", inferKindFromSignature("pub const MAX_SIZE = 100", "zig").?);
	try std.testing.expectEqualStrings("const", inferKindFromSignature("const name = \"hello\"", "zig").?);
	try std.testing.expectEqualStrings("const", inferKindFromSignature("val x = 1", "kotlin").?);
	// let in Rust/Swift → "const" (immutable)
	try std.testing.expectEqualStrings("const", inferKindFromSignature("let x = 1", "rust").?);
	try std.testing.expectEqualStrings("const", inferKindFromSignature("let x = 1", "swift").?);
	// let in JS/TS → "var" (mutable)
	try std.testing.expectEqualStrings("var", inferKindFromSignature("let x = 1", "typescript").?);
	try std.testing.expectEqualStrings("var", inferKindFromSignature("let x = 1", "javascript").?);
	// Mutable → "var"
	try std.testing.expectEqualStrings("var", inferKindFromSignature("pub var count = 0", "zig").?);
	try std.testing.expectEqualStrings("var", inferKindFromSignature("comptime var i: usize = 0", "zig").?);
	try std.testing.expectEqualStrings("var", inferKindFromSignature("mut x = 1", "rust").?);
	// Module → "mod"
	try std.testing.expectEqualStrings("mod", inferKindFromSignature("module Foo", "elixir").?);
	// Test
	try std.testing.expectEqualStrings("test", inferKindFromSignature("test \"basic addition\"", "zig").?);
	// Other kinds unchanged
	try std.testing.expectEqualStrings("struct", inferKindFromSignature("struct Foo", "c").?);
	try std.testing.expectEqualStrings("class", inferKindFromSignature("class Foo", "typescript").?);
	try std.testing.expectEqualStrings("enum", inferKindFromSignature("enum Color", "rust").?);
	try std.testing.expectEqualStrings("macro", inferKindFromSignature("macro foo", "elixir").?);
	try std.testing.expectEqualStrings("type", inferKindFromSignature("type Foo = int", "go").?);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nix develop -c zig build test --summary all 2>&1 | grep -A5 "FAIL\|error.*test\|panic"`

Expected: Compilation error — `inferKindFromSignature` doesn't accept a `language` parameter yet.

- [ ] **Step 3: Update `inferKindFromSignature` to accept language and return short forms**

In `src/indexer.zig`, replace `inferKindFromSignature`:

```zig
fn inferKindFromSignature(signature: []const u8, language: []const u8) ?[]const u8 {
	var trimmed = std.mem.trimLeft(u8, signature, " \t");
	// Strip visibility and qualifier prefixes so "pub inline fn" / "pub const X = struct" work
	inline for ([_][]const u8{ "pub ", "export ", "inline ", "comptime ", "extern " }) |prefix| {
		if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{prefix})) {
			trimmed = std.mem.trimLeft(u8, trimmed[prefix.len..], " \t");
		}
	}
	if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{
		"fn ",
		"def ",
		"defp ",
		"func ",
		"function ",
		"proc ",
	})) return "fn";
	if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{ "class ", "class\t" })) return "class";
	if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{ "struct ", "record " })) return "struct";
	if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{ "enum " })) return "enum";
	if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{ "interface " })) return "interface";
	if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{ "trait " })) return "trait";
	if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{ "module ", "mod ", "namespace " })) return "mod";
	if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{ "macro " })) return "macro";
	if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{ "test ", "test\t", "test\"" })) return "test";
	// const/val → always immutable
	if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{ "const ", "val " })) {
		if (containsTypeAssignment(signature)) |type_kind| return type_kind;
		return "const";
	}
	// let → language-dependent mutability
	if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{ "let " })) {
		if (containsTypeAssignment(signature)) |type_kind| return type_kind;
		// let is immutable in Rust and Swift
		if (std.ascii.eqlIgnoreCase(language, "rust") or std.ascii.eqlIgnoreCase(language, "swift")) {
			return "const";
		}
		return "var";
	}
	// var/mut → always mutable
	if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{ "var ", "mut " })) {
		if (containsTypeAssignment(signature)) |type_kind| return type_kind;
		return "var";
	}
	if (hasAnyPrefixIgnoreCase(trimmed, &[_][]const u8{ "type ", "typedef " })) return "type";
	return null;
}
```

- [ ] **Step 4: Update `enrichSymbolMetadata` to pass language**

In `src/indexer.zig`, change `enrichSymbolMetadata`:

```zig
fn enrichSymbolMetadata(allocator: std.mem.Allocator, symbol: *model.Symbol) !void {
	if (symbol.symbol_kind == null) {
		if (inferKindFromSignature(symbol.signature, symbol.language)) |value| {
			symbol.symbol_kind = try allocator.dupe(u8, value);
		}
	}
	// ... rest unchanged
```

- [ ] **Step 5: Update `inferScope` to compare against `"fn"` instead of `"function"`**

In `src/indexer.zig:563`, change:

```zig
// Old:
if (std.ascii.eqlIgnoreCase(kind_value, "function")) return "method";
// New:
if (std.ascii.eqlIgnoreCase(kind_value, "fn")) return "method";
```

- [ ] **Step 6: Update `tokenToKind` in search.zig to return short forms**

In `src/search.zig`, replace `tokenToKind`:

```zig
fn tokenToKind(token: []const u8) ?[]const u8 {
	if (std.ascii.eqlIgnoreCase(token, "function") or
		std.ascii.eqlIgnoreCase(token, "fn") or
		std.ascii.eqlIgnoreCase(token, "def") or
		std.ascii.eqlIgnoreCase(token, "method"))
		return "fn";
	if (std.ascii.eqlIgnoreCase(token, "class")) return "class";
	if (std.ascii.eqlIgnoreCase(token, "struct")) return "struct";
	if (std.ascii.eqlIgnoreCase(token, "enum")) return "enum";
	if (std.ascii.eqlIgnoreCase(token, "interface")) return "interface";
	if (std.ascii.eqlIgnoreCase(token, "trait")) return "trait";
	if (std.ascii.eqlIgnoreCase(token, "module") or
		std.ascii.eqlIgnoreCase(token, "namespace") or
		std.ascii.eqlIgnoreCase(token, "ns"))
		return "mod";
	if (std.ascii.eqlIgnoreCase(token, "variable") or
		std.ascii.eqlIgnoreCase(token, "var") or
		std.ascii.eqlIgnoreCase(token, "const") or
		std.ascii.eqlIgnoreCase(token, "let") or
		std.ascii.eqlIgnoreCase(token, "field"))
		return "var";
	if (std.ascii.eqlIgnoreCase(token, "type")) return "type";
	if (std.ascii.eqlIgnoreCase(token, "macro")) return "macro";
	return null;
}
```

Note: `tokenToKind` is for NLP query parsing ("find public function"), not the `--kind` filter. It returns `"var"` for all variable-like tokens because the NLP intent is broad — the user saying "find variable foo" wants both const and var. This is separate from the `--kind` filter which allows precise filtering.

- [ ] **Step 7: Update `normalizeSymbolKind` in filters.zig to use short forms**

Replace `normalizeSymbolKind` and its test:

```zig
/// Normalizes user-facing symbol kind aliases to the short canonical form stored in the DB.
/// Returns null for unknown kinds. For multi-value aliases (let, declaration, definition),
/// see parseSymbolKindList which handles expansion.
fn normalizeSymbolKind(value: []const u8) ?[]const u8 {
	const map = .{
		.{ "fn", "fn" },
		.{ "func", "fn" },
		.{ "function", "fn" },
		.{ "struct", "struct" },
		.{ "enum", "enum" },
		.{ "union", "union" },
		.{ "class", "class" },
		.{ "interface", "interface" },
		.{ "trait", "trait" },
		.{ "impl", "impl" },
		.{ "const", "const" },
		.{ "constant", "const" },
		.{ "val", "const" },
		.{ "var", "var" },
		.{ "variable", "var" },
		.{ "mut", "var" },
		.{ "field", "field" },
		.{ "test", "test" },
		.{ "mod", "mod" },
		.{ "module", "mod" },
		.{ "type", "type" },
		.{ "macro", "macro" },
	};
	inline for (map) |entry| {
		if (std.mem.eql(u8, value, entry[0])) return entry[1];
	}
	return null;
}

test "normalizeSymbolKind maps aliases to short DB canonical forms" {
	try std.testing.expectEqualStrings("fn", normalizeSymbolKind("fn").?);
	try std.testing.expectEqualStrings("fn", normalizeSymbolKind("func").?);
	try std.testing.expectEqualStrings("fn", normalizeSymbolKind("function").?);
	try std.testing.expectEqualStrings("const", normalizeSymbolKind("const").?);
	try std.testing.expectEqualStrings("const", normalizeSymbolKind("constant").?);
	try std.testing.expectEqualStrings("const", normalizeSymbolKind("val").?);
	try std.testing.expectEqualStrings("var", normalizeSymbolKind("var").?);
	try std.testing.expectEqualStrings("var", normalizeSymbolKind("variable").?);
	try std.testing.expectEqualStrings("var", normalizeSymbolKind("mut").?);
	try std.testing.expectEqualStrings("mod", normalizeSymbolKind("mod").?);
	try std.testing.expectEqualStrings("mod", normalizeSymbolKind("module").?);
	try std.testing.expectEqualStrings("macro", normalizeSymbolKind("macro").?);
	try std.testing.expectEqualStrings("struct", normalizeSymbolKind("struct").?);
	try std.testing.expectEqualStrings("test", normalizeSymbolKind("test").?);
	try std.testing.expect(normalizeSymbolKind("bogus") == null);
}
```

- [ ] **Step 8: Update existing test for `enrichSymbolMetadata`**

In `src/indexer.zig`, in `test "enrichSymbolMetadata infers kind visibility scope and arity"`, change:

```zig
// Old:
try std.testing.expectEqualStrings("function", symbol.symbol_kind.?);
// New:
try std.testing.expectEqualStrings("fn", symbol.symbol_kind.?);
```

- [ ] **Step 9: Update test fixtures in search.zig and storage.zig**

In `src/search.zig`, find all test fixtures that create symbols with `.symbol_kind = try allocator.dupe(u8, "function")` and change to `"fn"`. Same for `"variable"` → `"var"`.

In `src/search.zig:2654` (tokenToKind test), change expected `"function"` to `"fn"`:
```zig
// Old:
try std.testing.expectEqualStrings("function", meta.kind.?);
// New:
try std.testing.expectEqualStrings("fn", meta.kind.?);
```

In `src/search.zig:2679,2722` change `"function"` to `"fn"` and `src/search.zig:2735` change `"variable"` to `"var"`.

In `src/storage.zig:1098`:
```zig
// Old:
.symbol_kind = try allocator.dupe(u8, "function"),
// New:
.symbol_kind = try allocator.dupe(u8, "fn"),
```

In `src/storage.zig:1120`:
```zig
// Old:
try std.testing.expectEqualStrings("function", std.mem.span(kind_ptr));
// New:
try std.testing.expectEqualStrings("fn", std.mem.span(kind_ptr));
```

Also check `src/extract_haskell.zig:68` which compares against `"function"`:
```zig
// Old:
return std.mem.eql(u8, ty, "function");
// New:
return std.mem.eql(u8, ty, "fn");
```

- [ ] **Step 10: Run all tests**

Run: `nix develop -c zig build test --summary all`

Expected: All tests pass (2780+ tests, 0 failures).

- [ ] **Step 11: End-to-end CLI verification**

```bash
nix develop -c zig build install
./zig-out/bin/codescan index  # full reindex to get new short forms
sqlite3 .codescan/index.sqlite3 "SELECT DISTINCT symbol_kind, count(*) FROM symbols WHERE symbol_kind IS NOT NULL GROUP BY symbol_kind ORDER BY count(*) DESC;"
# Expected: fn|642+, var|N, const|N, struct|80+, enum|16+, test|N, mod|0, union|1
./zig-out/bin/codescan search "init" --kind fn --top 3
# Expected: results showing functions
./zig-out/bin/codescan search "init" --kind function --top 3
# Expected: same results (alias works)
./zig-out/bin/codescan search "config" --kind struct --top 3
# Expected: results showing structs
```

- [ ] **Step 12: Commit**

```bash
git add src/indexer.zig src/filters.zig src/search.zig src/storage.zig src/extract_haskell.zig
git commit -m "feat: short canonical symbol kinds with const/var split

- inferKindFromSignature returns short forms (fn, const, var, mod, etc.)
- Language-aware const/var: let→const in Rust/Swift, let→var in JS/TS
- normalizeSymbolKind maps all aliases to DB canonical forms
- tokenToKind (NLP query parsing) updated to short forms
- Requires full reindex to pick up new kind values"
```

---

### Task 2: Meta-kinds (definition, declaration, let)

Add `definition`, `declaration`, and `let` as meta-kinds that expand to multiple DB values.

**Files:**
- Modify: `src/filters.zig:247-263` (parseSymbolKindList)
- Modify: `src/search.zig:449-458` (matchesFilters — handle `"*"` sentinel)

- [ ] **Step 1: Write failing test for meta-kind expansion**

Add to end of `src/filters.zig`:

```zig
test "parseSymbolKindList expands meta-kinds" {
	const allocator = std.testing.allocator;
	var list: std.ArrayListUnmanaged([]const u8) = .{};
	defer {
		for (list.items) |item| allocator.free(item);
		list.deinit(allocator);
	}

	// "declaration" expands to const + var
	try parseSymbolKindList(allocator, &list, "declaration");
	try std.testing.expectEqual(@as(usize, 2), list.items.len);
	try std.testing.expectEqualStrings("const", list.items[0]);
	try std.testing.expectEqualStrings("var", list.items[1]);

	// Reset
	for (list.items) |item| allocator.free(item);
	list.clearRetainingCapacity();

	// "let" expands to const + var
	try parseSymbolKindList(allocator, &list, "let");
	try std.testing.expectEqual(@as(usize, 2), list.items.len);
	try std.testing.expectEqualStrings("const", list.items[0]);
	try std.testing.expectEqualStrings("var", list.items[1]);

	// Reset
	for (list.items) |item| allocator.free(item);
	list.clearRetainingCapacity();

	// "definition" expands to sentinel "*"
	try parseSymbolKindList(allocator, &list, "definition");
	try std.testing.expectEqual(@as(usize, 1), list.items.len);
	try std.testing.expectEqualStrings("*", list.items[0]);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nix develop -c zig build test --summary all 2>&1 | grep -A5 "FAIL\|error.*test\|panic"`

Expected: FAIL — `parseSymbolKindList` returns `error.InvalidSymbolKind` for "declaration", "let", "definition".

- [ ] **Step 3: Update `parseSymbolKindList` to handle meta-kinds**

In `src/filters.zig`, replace `parseSymbolKindList`:

```zig
pub fn parseSymbolKindList(
	allocator: std.mem.Allocator,
	list: *std.ArrayListUnmanaged([]const u8),
	value: []const u8,
) !void {
	var it = std.mem.splitScalar(u8, value, ',');
	while (it.next()) |part| {
		const trimmed = std.mem.trim(u8, part, " \t\r");
		if (trimmed.len == 0) continue;
		const lower = try normalizeLower(allocator, trimmed);
		defer allocator.free(lower);
		// Check for meta-kinds that expand to multiple values
		if (expandMetaKind(lower)) |expansions| {
			for (expansions) |canonical| {
				if (!containsString(list.items, canonical)) {
					try list.append(allocator, try allocator.dupe(u8, canonical));
				}
			}
			continue;
		}
		const canonical = normalizeSymbolKind(lower) orelse return error.InvalidSymbolKind;
		if (!containsString(list.items, canonical)) {
			try list.append(allocator, try allocator.dupe(u8, canonical));
		}
	}
}

/// Meta-kinds that expand to multiple canonical values.
fn expandMetaKind(value: []const u8) ?[]const []const u8 {
	const decl = [_][]const u8{ "const", "var" };
	const defn = [_][]const u8{"*"};
	if (std.mem.eql(u8, value, "declaration")) return &decl;
	if (std.mem.eql(u8, value, "let")) return &decl;
	if (std.mem.eql(u8, value, "definition")) return &defn;
	return null;
}
```

- [ ] **Step 4: Update `matchesFilters` in search.zig to handle `"*"` sentinel**

In `src/search.zig`, in the `allowed_symbol_kinds` check block (around line 449):

```zig
if (options.allowed_symbol_kinds.len > 0) {
	const sk = symbol.symbol_kind orelse return false;
	var ok = false;
	for (options.allowed_symbol_kinds) |k| {
		if (std.mem.eql(u8, k, "*")) {
			// "*" sentinel means "any non-null symbol_kind" — already passed the null check above
			ok = true;
			break;
		}
		if (std.mem.eql(u8, sk, k)) {
			ok = true;
			break;
		}
	}
	if (!ok) return false;
}
```

- [ ] **Step 5: Run all tests**

Run: `nix develop -c zig build test --summary all`

Expected: All tests pass.

- [ ] **Step 6: End-to-end CLI verification**

```bash
nix develop -c zig build install
./zig-out/bin/codescan search "config" --kind declaration --top 3
# Expected: results with kind=const or kind=var
./zig-out/bin/codescan search "config" --kind definition --top 5
# Expected: results of any non-null kind (fn, struct, const, var, enum, etc.)
```

- [ ] **Step 7: Commit**

```bash
git add src/filters.zig src/search.zig
git commit -m "feat: add definition, declaration, and let meta-kinds

- --kind declaration expands to const + var
- --kind let expands to const + var (language-aware at index time)
- --kind definition matches any symbol with a non-null kind (sentinel '*')"
```

---

### Task 3: Empty query browse mode

Allow `codescan search --kind fn` with no query text to browse all symbols of that kind.

**Files:**
- Modify: `src/search.zig:93-101` (search function — empty query handling)
- Add browse SQL path in `src/search.zig`

- [ ] **Step 1: Write failing test for browse mode**

Add test in `src/search.zig` near the existing search tests:

```zig
test "search with empty query and kind filter returns browse results" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);
	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 4, .embedding_model = "test" });

	// Insert test symbols
	var sym1 = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/a.zig"),
		.name = try allocator.dupe(u8, "foo"),
		.signature = try allocator.dupe(u8, "pub fn foo() void"),
		.doc_comment = null,
		.symbol_kind = try allocator.dupe(u8, "fn"),
		.start_line = 1,
		.end_line = 3,
	};
	defer sym1.deinit(allocator);
	_ = try storage.insertSymbol(db, sym1);

	var sym2 = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/b.zig"),
		.name = try allocator.dupe(u8, "Config"),
		.signature = try allocator.dupe(u8, "pub const Config = struct"),
		.doc_comment = null,
		.symbol_kind = try allocator.dupe(u8, "struct"),
		.start_line = 1,
		.end_line = 10,
	};
	defer sym2.deinit(allocator);
	_ = try storage.insertSymbol(db, sym2);

	const null_embedder = embedding.nullEmbedder();
	// Empty query with kind filter should return browse results
	const sr = try search(allocator, db, null_embedder, "", .{
		.top_n = 10,
		.mode = .hybrid,
		.allowed_symbol_kinds = &[_][]const u8{"fn"},
	});
	defer freeResults(allocator, sr.results);

	try std.testing.expectEqual(@as(usize, 1), sr.results.len);
	try std.testing.expectEqualStrings("foo", sr.results[0].symbol.name);

	// Empty query with no filters should still error
	const err_result = search(allocator, db, null_embedder, "", .{ .top_n = 10, .mode = .hybrid });
	try std.testing.expectError(error.EmptyQuery, err_result);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nix develop -c zig build test --summary all 2>&1 | grep -A5 "FAIL\|error.*test\|panic"`

Expected: FAIL — `search` returns `error.EmptyQuery` for empty string regardless of filters.

- [ ] **Step 3: Implement browse mode in `search.zig`**

In `src/search.zig`, replace the `EmptyQuery` check at line 100 with:

```zig
if (query.len == 0) {
	// Browse mode: empty query with filters returns SQL-only results
	if (options.allowed_symbol_kinds.len == 0 and
		options.allowed_langs.len == 0 and
		options.allowed_exts.len == 0)
	{
		return error.EmptyQuery;
	}
	return browseSymbols(allocator, db, options);
}
```

Then add the `browseSymbols` function:

```zig
/// SQL-only browse mode: returns symbols matching filters, ordered by file_path and start_line.
/// Used when query is empty but filters are present.
fn browseSymbols(allocator: std.mem.Allocator, db: storage.Db, options: Options) !SearchResult {
	// Build WHERE clause from filters
	var where_parts = std.ArrayListUnmanaged([]const u8){};
	defer where_parts.deinit(allocator);
	var owned_parts = std.ArrayListUnmanaged([]const u8){};
	defer {
		for (owned_parts.items) |p| allocator.free(p);
		owned_parts.deinit(allocator);
	}

	if (options.allowed_symbol_kinds.len > 0) {
		var has_wildcard = false;
		for (options.allowed_symbol_kinds) |k| {
			if (std.mem.eql(u8, k, "*")) { has_wildcard = true; break; }
		}
		if (has_wildcard) {
			try where_parts.append(allocator, "symbol_kind IS NOT NULL");
		} else {
			// Build IN clause
			var in_buf = std.ArrayListUnmanaged(u8){};
			defer in_buf.deinit(allocator);
			try in_buf.appendSlice(allocator, "symbol_kind IN (");
			for (options.allowed_symbol_kinds, 0..) |k, i| {
				if (i > 0) try in_buf.appendSlice(allocator, ", ");
				try in_buf.append(allocator, '\'');
				try in_buf.appendSlice(allocator, k);
				try in_buf.append(allocator, '\'');
			}
			try in_buf.appendSlice(allocator, ")");
			const owned = try allocator.dupe(u8, in_buf.items);
			try owned_parts.append(allocator, owned);
			try where_parts.append(allocator, owned);
		}
	}

	if (options.allowed_langs.len > 0) {
		var in_buf = std.ArrayListUnmanaged(u8){};
		defer in_buf.deinit(allocator);
		try in_buf.appendSlice(allocator, "lang IN (");
		for (options.allowed_langs, 0..) |l, i| {
			if (i > 0) try in_buf.appendSlice(allocator, ", ");
			try in_buf.append(allocator, '\'');
			try in_buf.appendSlice(allocator, l);
			try in_buf.append(allocator, '\'');
		}
		try in_buf.appendSlice(allocator, ")");
		const owned = try allocator.dupe(u8, in_buf.items);
		try owned_parts.append(allocator, owned);
		try where_parts.append(allocator, owned);
	}

	// Build full SQL
	var sql_buf = std.ArrayListUnmanaged(u8){};
	defer sql_buf.deinit(allocator);
	try sql_buf.appendSlice(allocator,
		"SELECT id, lang, file_path, start_line, start_hash, end_line, end_hash, " ++
		"symbol_name, signature, doc_comment, " ++
		"symbol_kind, symbol_visibility, symbol_scope, symbol_arity " ++
		"FROM symbols");

	if (where_parts.items.len > 0) {
		try sql_buf.appendSlice(allocator, " WHERE ");
		for (where_parts.items, 0..) |part, i| {
			if (i > 0) try sql_buf.appendSlice(allocator, " AND ");
			try sql_buf.appendSlice(allocator, part);
		}
	}
	try sql_buf.appendSlice(allocator, " ORDER BY file_path, start_line");

	const limit_str = try std.fmt.allocPrintZ(allocator, " LIMIT {d}", .{options.top_n});
	defer allocator.free(limit_str);
	try sql_buf.appendSlice(allocator, limit_str);
	try sql_buf.append(allocator, 0); // null terminate

	const sql: [:0]const u8 = sql_buf.items[0 .. sql_buf.items.len - 1 :0];

	var stmt: ?*storage.sqlite.sqlite3_stmt = null;
	if (storage.sqlite.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != storage.sqlite.SQLITE_OK) {
		return error.SqlPrepareFailed;
	}
	defer _ = storage.sqlite.sqlite3_finalize(stmt.?);

	var results = std.ArrayListUnmanaged(Result){};
	errdefer {
		for (results.items) |*res| res.deinit(allocator);
		results.deinit(allocator);
	}

	// Count total matching rows
	var total: usize = 0;

	while (true) {
		const rc = storage.sqlite.sqlite3_step(stmt.?);
		if (rc == storage.sqlite.SQLITE_DONE) break;
		if (rc != storage.sqlite.SQLITE_ROW) return error.SqlStepFailed;

		total += 1;

		const symbol = try readSymbolFromRow(allocator, stmt.?);

		try results.append(allocator, .{
			.id = storage.sqlite.sqlite3_column_int64(stmt.?, 0),
			.symbol = symbol,
			.score = 1.0,
			.distance = 0.0,
			.lexical = 0.0,
			.bm25 = 0.0,
		});
	}

	return .{
		.results = try results.toOwnedSlice(allocator),
		.total_relevant = total,
	};
}
```

Note: `readSymbolFromRow` is an existing helper — check if it exists. If not, extract the row-reading logic from the existing `runFtsSearch`/`runVectorSearch` functions into a shared helper. The column order must match the SELECT.

- [ ] **Step 4: Run all tests**

Run: `nix develop -c zig build test --summary all`

Expected: All tests pass.

- [ ] **Step 5: Also update CLI to allow empty query when kind filter is present**

In `src/main.zig`, find where `MissingQuery` is checked for the search command and allow it through when `--kind` is set. In `src/cli.zig`, the search command requires a query — update it to make query optional when other flags are present. In `src/main.zig`, pass an empty string to search when query is null and kind filter is set.

Look for the section around line 490-510 where the search command extracts `query`:

```zig
// Old pattern:
const query = parsed.query orelse return error.MissingQuery;
// New pattern:
const query = parsed.query orelse "";
// (The search function itself validates empty query + no filters → EmptyQuery)
```

- [ ] **Step 6: End-to-end CLI verification**

```bash
nix develop -c zig build install
./zig-out/bin/codescan search --kind fn --top 5
# Expected: lists 5 functions sorted by file_path
./zig-out/bin/codescan search --kind struct --top 3
# Expected: lists 3 structs
./zig-out/bin/codescan search --kind definition --top 10
# Expected: lists 10 symbols of any defined kind
./zig-out/bin/codescan search 2>&1
# Expected: error (no query AND no filters)
```

- [ ] **Step 7: Commit**

```bash
git add src/search.zig src/main.zig src/cli.zig
git commit -m "feat: browse mode for empty query with kind filter

codescan search --kind fn now lists all functions without requiring
a text query. Returns SQL-only results sorted by file_path, start_line."
```

---

### Task 4: --path (glob) and --file (exact) filters for search

**Files:**
- Modify: `src/cli.zig` (parse --path and --file flags)
- Modify: `src/search.zig:55-72` (Options — add path filter)
- Modify: `src/search.zig:430-461` (matchesFilters — add path check)
- Modify: `src/main.zig` (wire path filter)
- Modify: `src/filters.zig` (add path_patterns to FilterLists)

- [ ] **Step 1: Write failing test for path filtering**

Add test in `src/search.zig`:

```zig
test "search filters results by file path pattern" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);
	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 4, .embedding_model = "test" });

	// Insert symbols in different paths
	var sym1 = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/storage.zig"),
		.name = try allocator.dupe(u8, "initDb"),
		.signature = try allocator.dupe(u8, "pub fn initDb() void"),
		.doc_comment = null,
		.symbol_kind = try allocator.dupe(u8, "fn"),
		.start_line = 1,
		.end_line = 3,
	};
	defer sym1.deinit(allocator);
	_ = try storage.insertSymbol(db, sym1);

	var sym2 = model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/search.zig"),
		.name = try allocator.dupe(u8, "initSearch"),
		.signature = try allocator.dupe(u8, "pub fn initSearch() void"),
		.doc_comment = null,
		.symbol_kind = try allocator.dupe(u8, "fn"),
		.start_line = 1,
		.end_line = 3,
	};
	defer sym2.deinit(allocator);
	_ = try storage.insertSymbol(db, sym2);

	try storage.insertFts(db, sym1.name, "fn initDb", 1);
	try storage.insertFts(db, sym2.name, "fn initSearch", 2);

	const null_embedder = embedding.nullEmbedder();
	// Search with path filter
	const sr = try search(allocator, db, null_embedder, "init", .{
		.top_n = 10,
		.mode = .lexical,
		.allowed_paths = &[_][]const u8{"src/storage*"},
	});
	defer freeResults(allocator, sr.results);

	try std.testing.expectEqual(@as(usize, 1), sr.results.len);
	try std.testing.expectEqualStrings("initDb", sr.results[0].symbol.name);
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: Compilation error — `allowed_paths` field doesn't exist on `Options`.

- [ ] **Step 3: Add `allowed_paths` to search Options and implement path filtering**

In `src/search.zig`, add to `Options`:

```zig
allowed_paths: []const []const u8 = &[_][]const u8{},
```

In `matchesFilters`, add path check after the existing ext/kind checks:

```zig
if (options.allowed_paths.len > 0) {
	var ok = false;
	for (options.allowed_paths) |pattern| {
		if (pathMatchesGlob(symbol.file_path, pattern)) {
			ok = true;
			break;
		}
	}
	if (!ok) return false;
}
```

Add the `pathMatchesGlob` helper (simple glob without PCRE2 — `*` matches any sequence, `?` matches one char):

```zig
/// Simple glob match for path filtering. Supports * and ? wildcards.
fn pathMatchesGlob(path: []const u8, pattern: []const u8) bool {
	var pi: usize = 0;
	var gi: usize = 0;
	var star_pi: ?usize = null;
	var star_gi: ?usize = null;

	while (pi < path.len) {
		if (gi < pattern.len and (pattern[gi] == '?' or pattern[gi] == path[pi])) {
			pi += 1;
			gi += 1;
		} else if (gi < pattern.len and pattern[gi] == '*') {
			star_pi = pi;
			star_gi = gi;
			gi += 1;
		} else if (star_gi) |sg| {
			gi = sg + 1;
			star_pi = star_pi.? + 1;
			pi = star_pi.?;
		} else {
			return false;
		}
	}
	while (gi < pattern.len and pattern[gi] == '*') gi += 1;
	return gi == pattern.len;
}
```

Also add path filtering to `browseSymbols` — add a `WHERE file_path GLOB ?` clause or post-filter. Post-filtering is simpler:

In `browseSymbols`, after reading each row, before appending to results, check:
```zig
// After: const symbol = try readSymbolFromRow(allocator, stmt.?);
if (options.allowed_paths.len > 0) {
	var path_ok = false;
	for (options.allowed_paths) |pattern| {
		if (pathMatchesGlob(symbol.file_path, pattern)) {
			path_ok = true;
			break;
		}
	}
	if (!path_ok) {
		var s = symbol;
		s.deinit(allocator);
		continue;
	}
}
```

- [ ] **Step 4: Add --path and --file to CLI parser**

In `src/cli.zig`, add fields to `Parsed`:

```zig
path_filters: std.ArrayListUnmanaged([]const u8),
file_filter: ?[]const u8,
```

Initialize in `parse()`:
```zig
.path_filters = .{},
.file_filter = null,
```

Add to `deinit`:
```zig
self.path_filters.deinit(allocator);
```

Add parsing in the flag loop:
```zig
if (std.mem.eql(u8, arg, "--path")) {
	i += 1;
	if (i >= args.len) return error.MissingValue;
	try parsed.path_filters.append(allocator, args[i]);
	i += 1;
	continue;
}
if (std.mem.eql(u8, arg, "--file")) {
	i += 1;
	if (i >= args.len) return error.MissingValue;
	// Reject glob characters in --file
	const val = args[i];
	if (std.mem.indexOfAny(u8, val, "*?[{") != null) return error.InvalidFileFilter;
	parsed.file_filter = val;
	i += 1;
	continue;
}
```

- [ ] **Step 5: Wire path filters through main.zig**

In `src/main.zig`, where search options are built, add:

```zig
// Build path filter list combining --path and --file
var path_filters = std.ArrayListUnmanaged([]const u8){};
defer path_filters.deinit(allocator);
for (parsed.path_filters.items) |p| {
	try path_filters.append(allocator, p);
}
if (parsed.file_filter) |f| {
	try path_filters.append(allocator, f);
}

// Then in the search options:
.allowed_paths = path_filters.items,
```

- [ ] **Step 6: Run all tests**

Run: `nix develop -c zig build test --summary all`

Expected: All tests pass.

- [ ] **Step 7: End-to-end CLI verification**

```bash
nix develop -c zig build install
./zig-out/bin/codescan search "init" --path "src/storage*" --top 3
# Expected: only results from src/storage.zig
./zig-out/bin/codescan search "init" --file src/storage.zig --top 3
# Expected: only results from src/storage.zig
./zig-out/bin/codescan search "init" --file "src/*.zig" 2>&1
# Expected: error (glob character in --file)
./zig-out/bin/codescan search --kind fn --path "src/search*" --top 5
# Expected: functions from src/search.zig only (browse + path filter)
```

- [ ] **Step 8: Commit**

```bash
git add src/search.zig src/cli.zig src/main.zig
git commit -m "feat: add --path (glob) and --file (exact) filters for search

--path supports wildcards (*, ?) for file path filtering, repeatable.
--file accepts a single exact file path (rejects glob characters).
Works with both text search and browse mode."
```

---

### Task 5: Informative "no results" diagnostics

**Files:**
- Add: `src/diagnostics.zig` (new file — diagnostic count queries)
- Modify: `src/main.zig:572-586` (zero-result output)

- [ ] **Step 1: Write failing test for diagnostic counts**

Create `src/diagnostics.zig`:

```zig
const std = @import("std");
const storage = @import("storage.zig");
const search = @import("search.zig");
const embedding = @import("embedding.zig");

pub const DiagnosticCounts = struct {
	query_only: ?usize = null,
	kind_only: ?usize = null,
	lang_only: ?usize = null,
	path_only: ?usize = null,
};

pub fn countDiagnostics(
	allocator: std.mem.Allocator,
	db: storage.Db,
	embedder: embedding.Embedder,
	query: []const u8,
	options: search.Options,
) !DiagnosticCounts {
	_ = allocator;
	_ = db;
	_ = embedder;
	_ = query;
	_ = options;
	return .{};
}

test "diagnosticCounts returns per-filter counts when search yields zero results" {
	const allocator = std.testing.allocator;
	const db = try storage.openMemoryWithVec(allocator);
	defer storage.close(db);
	_ = try storage.initSchema(allocator, db, .{ .embedding_dim = 4, .embedding_model = "test" });

	// Insert a function symbol
	var sym = storage.model.Symbol{
		.language = try allocator.dupe(u8, "zig"),
		.file_path = try allocator.dupe(u8, "src/a.zig"),
		.name = try allocator.dupe(u8, "foo"),
		.signature = try allocator.dupe(u8, "pub fn foo() void"),
		.doc_comment = null,
		.symbol_kind = try allocator.dupe(u8, "fn"),
		.start_line = 1,
		.end_line = 3,
	};
	defer sym.deinit(allocator);
	_ = try storage.insertSymbol(db, sym);
	try storage.insertFts(db, sym.name, "fn foo", 1);

	const null_embedder = embedding.nullEmbedder();

	// Search for "foo" with kind=struct → 0 results
	// But "foo" alone would match, and kind=struct alone would not
	const diag = try countDiagnostics(allocator, db, null_embedder, "foo", .{
		.top_n = 10,
		.mode = .lexical,
		.allowed_symbol_kinds = &[_][]const u8{"struct"},
	});

	// query alone should find results
	try std.testing.expect(diag.query_only != null);
	try std.testing.expect(diag.query_only.? > 0);
	// kind alone should find 0 (no structs)
	try std.testing.expect(diag.kind_only != null);
	try std.testing.expectEqual(@as(usize, 0), diag.kind_only.?);
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — `countDiagnostics` returns empty struct, assertions fail.

- [ ] **Step 3: Implement `countDiagnostics`**

```zig
pub fn countDiagnostics(
	allocator: std.mem.Allocator,
	db: storage.Db,
	embedder: embedding.Embedder,
	query: []const u8,
	options: search.Options,
) !DiagnosticCounts {
	var counts = DiagnosticCounts{};
	const has_query = query.len > 0;
	const has_kind = options.allowed_symbol_kinds.len > 0;
	const has_lang = options.allowed_langs.len > 0;
	const has_path = options.allowed_paths.len > 0;

	const active_dims = @as(usize, @intFromBool(has_query)) +
		@as(usize, @intFromBool(has_kind)) +
		@as(usize, @intFromBool(has_lang)) +
		@as(usize, @intFromBool(has_path));

	if (active_dims < 2) return counts; // Need 2+ dimensions for useful diagnostics

	// Query alone (no kind/lang/path filter)
	if (has_query) {
		const sr = try search.search(allocator, db, embedder, query, .{
			.top_n = options.top_n,
			.mode = options.mode,
			.weight_vector = options.weight_vector,
			.weight_lexical = options.weight_lexical,
			.fts_mode = options.fts_mode,
		});
		defer search.freeResults(allocator, sr.results);
		counts.query_only = sr.total_relevant;
	}

	// Kind alone (no query)
	if (has_kind) {
		counts.kind_only = try countSymbolsByKind(db, options.allowed_symbol_kinds);
	}

	// Lang alone
	if (has_lang) {
		counts.lang_only = try countSymbolsByLang(db, options.allowed_langs);
	}

	return counts;
}

fn countSymbolsByKind(db: storage.Db, kinds: []const []const u8) !usize {
	var has_wildcard = false;
	for (kinds) |k| {
		if (std.mem.eql(u8, k, "*")) { has_wildcard = true; break; }
	}
	if (has_wildcard) {
		return countSql(db, "SELECT COUNT(*) FROM symbols WHERE symbol_kind IS NOT NULL");
	}
	// For simplicity, count each kind and sum
	var total: usize = 0;
	for (kinds) |k| {
		const sql = "SELECT COUNT(*) FROM symbols WHERE symbol_kind = ?1;\x00";
		var stmt: ?*storage.sqlite.sqlite3_stmt = null;
		if (storage.sqlite.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != storage.sqlite.SQLITE_OK) {
			return error.SqlPrepareFailed;
		}
		defer _ = storage.sqlite.sqlite3_finalize(stmt.?);
		try storage.bindText(stmt.?, 1, k);
		if (storage.sqlite.sqlite3_step(stmt.?) == storage.sqlite.SQLITE_ROW) {
			total += @intCast(storage.sqlite.sqlite3_column_int64(stmt.?, 0));
		}
	}
	return total;
}

fn countSymbolsByLang(db: storage.Db, langs: []const []const u8) !usize {
	var total: usize = 0;
	for (langs) |l| {
		const sql = "SELECT COUNT(*) FROM symbols WHERE lang = ?1;\x00";
		var stmt: ?*storage.sqlite.sqlite3_stmt = null;
		if (storage.sqlite.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != storage.sqlite.SQLITE_OK) {
			return error.SqlPrepareFailed;
		}
		defer _ = storage.sqlite.sqlite3_finalize(stmt.?);
		try storage.bindText(stmt.?, 1, l);
		if (storage.sqlite.sqlite3_step(stmt.?) == storage.sqlite.SQLITE_ROW) {
			total += @intCast(storage.sqlite.sqlite3_column_int64(stmt.?, 0));
		}
	}
	return total;
}

fn countSql(db: storage.Db, sql: [:0]const u8) !usize {
	var stmt: ?*storage.sqlite.sqlite3_stmt = null;
	if (storage.sqlite.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != storage.sqlite.SQLITE_OK) {
		return error.SqlPrepareFailed;
	}
	defer _ = storage.sqlite.sqlite3_finalize(stmt.?);
	if (storage.sqlite.sqlite3_step(stmt.?) == storage.sqlite.SQLITE_ROW) {
		return @intCast(storage.sqlite.sqlite3_column_int64(stmt.?, 0));
	}
	return 0;
}
```

Note: `storage.bindText` may not be public. If not, either make it public or duplicate the bind logic. Check `src/storage.zig` for visibility.

- [ ] **Step 4: Add diagnostics.zig to build.zig**

Check `build.zig` to see how source files are registered. If the project uses `@import` chains (no explicit file list), then adding an `@import("diagnostics.zig")` in the file that uses it is sufficient.

- [ ] **Step 5: Wire diagnostics into main.zig zero-result output**

In `src/main.zig`, around line 572 where zero results are handled:

```zig
if (sr.results.len == 0) {
	const diagnostics = @import("diagnostics.zig");
	const diag = diagnostics.countDiagnostics(allocator, db, embedder_adapter.embedder(), query, .{
		.top_n = settings.top_n,
		.mode = effective_search_mode,
		.weight_vector = effective_weights.weight_vector,
		.weight_lexical = effective_weights.weight_lexical,
		.fts_mode = settings.fts_mode,
		.allowed_symbol_kinds = search_filters.symbol_kinds.items,
		.allowed_langs = search_filters.langs.items,
		.allowed_paths = path_filters.items,
	}) catch DiagnosticCounts{};

	// Print diagnostic breakdown
	if (diag.query_only != null or diag.kind_only != null or diag.lang_only != null) {
		_ = stderr.print("note: no results for query \"{s}\"", .{query}) catch {};
		if (settings.search_symbol_kind) |k| {
			_ = stderr.print(" with kind={s}", .{k}) catch {};
		}
		_ = stderr.print("\n", .{}) catch {};
		if (diag.query_only) |c| {
			_ = stderr.print("  -> query alone: {d} results\n", .{c}) catch {};
		}
		if (diag.kind_only) |c| {
			_ = stderr.print("  -> kind filter alone: {d} results\n", .{c}) catch {};
		}
		if (diag.lang_only) |c| {
			_ = stderr.print("  -> lang filter alone: {d} results\n", .{c}) catch {};
		}
		_ = stderr.flush() catch {};
	} else {
		// Original message (no diagnostics available)
		const codescan_dir = std.fs.path.dirname(settings.db_path) orelse ".codescan";
		if (pidfile.isWatcherRunning(allocator, codescan_dir)) {
			_ = stderr.print("note: no results found (watcher is running and index is up to date).\n", .{}) catch {};
		} else {
			_ = stderr.print("note: no results found; consider re-indexing with `codescan update` or starting the watcher with `codescan watch start`.\n", .{}) catch {};
		}
		_ = stderr.flush() catch {};
	}
}
```

- [ ] **Step 6: Run all tests**

Run: `nix develop -c zig build test --summary all`

Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add src/diagnostics.zig src/main.zig
git commit -m "feat: informative diagnostics when search returns no results

When 2+ filter dimensions are active and results are empty, shows
per-filter counts to help identify which filter narrowed to nothing."
```

---

### Task 6: MCP parity

Add kind, path, file, lang, and top parameters to the MCP search tool, and include diagnostics in the response.

**Files:**
- Modify: `src/mcp.zig:299-427` (search handler)
- Modify: `src/mcp.zig:584-601` (tools_list_json)
- Modify: `src/mcp.zig:30-59` (Settings)

- [ ] **Step 1: Write failing test for MCP search with kind parameter**

Add test in `src/mcp.zig`:

```zig
test "MCP search accepts kind parameter" {
	const allocator = std.testing.allocator;
	// Parse a search request with kind parameter
	const msg =
		\\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search","arguments":{"query":"init","kind":"fn"}}}
	;
	var parsed_msg = try std.json.parseFromSlice(std.json.Value, allocator, msg, .{});
	defer parsed_msg.deinit();
	const obj = parsed_msg.value.object;
	const params = obj.get("params").?.object;
	const args_val = params.get("arguments").?.object;
	const kind_val = getArg(args_val, "kind");
	try std.testing.expect(kind_val != null);
	try std.testing.expectEqualStrings("fn", kind_val.?);
}
```

- [ ] **Step 2: Run test to verify it passes** (this is a parse test, should pass already)

- [ ] **Step 3: Update `tools_list_json` with new search parameters**

In `src/mcp.zig`, replace the search tool entry in `tools_list_json`:

```zig
\\{"name":"search","description":"Semantic code search across indexed repository","inputSchema":{"type":"object","properties":{"query":{"type":"string","description":"Search query (optional if kind is provided)"},"kind":{"type":"string","description":"Symbol kind filter: fn, struct, enum, union, class, const, var, declaration, definition, test, type, macro, mod"},"path":{"type":"string","description":"Glob pattern for file path filtering (e.g. src/*.zig)"},"file":{"type":"string","description":"Exact file path filter"},"lang":{"type":"string","description":"Language filter (e.g. zig, typescript, rust)"},"top":{"type":"integer","description":"Max results (default 20)"}}}},
```

Also update the query alias:
```zig
\\{"name":"query","description":"Alias for search. Semantic code search.","inputSchema":{"type":"object","properties":{"query":{"type":"string","description":"Search query (optional if kind is provided)"},"kind":{"type":"string","description":"Symbol kind filter"},"path":{"type":"string","description":"Glob pattern for file path filtering"},"file":{"type":"string","description":"Exact file path filter"},"lang":{"type":"string","description":"Language filter"},"top":{"type":"integer","description":"Max results (default 20)"}}}},
```

- [ ] **Step 4: Wire new parameters in the MCP search handler**

In `src/mcp.zig`, in the search handler (around line 299), after extracting `query`:

```zig
} else if (std.mem.eql(u8, name, "search") or std.mem.eql(u8, name, "query")) {
	const query = getArg(args, "query") orelse "";
	const kind_arg = getArg(args, "kind");
	const path_arg = getArg(args, "path");
	const file_arg = getArg(args, "file");
	const lang_arg = getArg(args, "lang");
	const top_arg = getArgInt(args, "top");

	// Override settings with MCP args
	if (kind_arg) |k| settings.search_symbol_kind = k;
	if (lang_arg) |l| settings.search_lang = l;
	if (top_arg) |t| settings.search_top_n = t;
```

Add `getArgInt` helper:

```zig
fn getArgInt(args: ?std.json.ObjectMap, key: []const u8) ?usize {
	const a = args orelse return null;
	const val = a.get(key) orelse return null;
	if (val != .integer) return null;
	if (val.integer < 0) return null;
	return @intCast(val.integer);
}
```

Build path filters:
```zig
	var path_filters = std.ArrayListUnmanaged([]const u8){};
	defer path_filters.deinit(allocator);
	if (path_arg) |p| try path_filters.append(allocator, p);
	if (file_arg) |f| try path_filters.append(allocator, f);
```

Then in the search options, add:
```zig
	.allowed_paths = path_filters.items,
```

And handle empty query validation:
```zig
	if (query.len == 0 and kind_arg == null and lang_arg == null and path_arg == null and file_arg == null) {
		return toolError("MCP search: query is required when no filters are provided\n", .{});
	}
```

- [ ] **Step 5: Add diagnostics to MCP JSON response**

In the MCP search handler, after the `output.writeResults` call, when results are empty and diagnostics are available, append them to the output. This requires modifying the output format. The simplest approach: when `sr.results.len == 0`, compute diagnostics and include them in the JSON response.

Check how `output.writeResults` formats JSON. If it writes a complete JSON object, we need to intercept. Alternatively, add a `diagnostics` field to the output struct.

For now, the simplest approach is to include diagnostics as a note in the response text (MCP tool responses are text). After `writeResults`:

```zig
	if (sr.results.len == 0) {
		const diagnostics_mod = @import("diagnostics.zig");
		const diag = diagnostics_mod.countDiagnostics(allocator, db, embedder_adapter.embedder(), query, /* options */) catch diagnostics_mod.DiagnosticCounts{};
		if (diag.query_only != null or diag.kind_only != null) {
			try out.writer.print("\n// Diagnostics: ", .{});
			if (diag.query_only) |c| try out.writer.print("query_only={d} ", .{c});
			if (diag.kind_only) |c| try out.writer.print("kind_only={d} ", .{c});
			if (diag.lang_only) |c| try out.writer.print("lang_only={d} ", .{c});
		}
	}
```

- [ ] **Step 6: Update existing MCP test for tools list**

In `test "handleToolsList returns all tools"`, the assertion may check tool count or specific tool names. Update as needed to account for new parameters.

- [ ] **Step 7: Run all tests**

Run: `nix develop -c zig build test --summary all`

Expected: All tests pass.

- [ ] **Step 8: End-to-end MCP verification**

Test via the running MCP server (if the watcher started it) or manually:

```bash
nix develop -c zig build install
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search","arguments":{"query":"init","kind":"fn","top":3}}}' | ./zig-out/bin/codescan mcp-serve
# Expected: JSON response with function results only
echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search","arguments":{"kind":"struct","top":5}}}' | ./zig-out/bin/codescan mcp-serve
# Expected: JSON response listing structs (browse mode)
```

- [ ] **Step 9: Commit**

```bash
git add src/mcp.zig
git commit -m "feat: MCP search supports kind, path, file, lang, top parameters

All CLI filter capabilities now available via MCP tool calls.
Includes diagnostic counts in response when search yields no results."
```

---

### Task 7: Final integration test + reindex

Verify everything works end-to-end after a full reindex.

- [ ] **Step 1: Full reindex**

```bash
nix develop -c zig build install
./zig-out/bin/codescan index
```

- [ ] **Step 2: Verify DB contents**

```bash
sqlite3 .codescan/index.sqlite3 "SELECT DISTINCT symbol_kind, count(*) FROM symbols WHERE symbol_kind IS NOT NULL GROUP BY symbol_kind ORDER BY count(*) DESC;"
# Expected: fn, var, const, struct, enum, test, union, mod, type (short forms)
```

- [ ] **Step 3: Run full test suite**

```bash
nix develop -c zig build test --summary all
# Expected: All tests pass
```

- [ ] **Step 4: CLI integration tests**

```bash
# Kind filters
./zig-out/bin/codescan search "init" --kind fn --top 3
./zig-out/bin/codescan search "init" --kind function --top 3  # alias
./zig-out/bin/codescan search "Config" --kind struct
./zig-out/bin/codescan search "MAX" --kind const --top 3
./zig-out/bin/codescan search "count" --kind var --top 3

# Meta-kinds
./zig-out/bin/codescan search "config" --kind declaration --top 5
./zig-out/bin/codescan search "config" --kind definition --top 5

# Browse mode
./zig-out/bin/codescan search --kind fn --top 5
./zig-out/bin/codescan search --kind struct --top 5
./zig-out/bin/codescan search --kind test --top 5

# Path filtering
./zig-out/bin/codescan search "init" --path "src/storage*" --top 3
./zig-out/bin/codescan search "init" --file src/storage.zig --top 3

# Diagnostics
./zig-out/bin/codescan search "nonexistent_xyz" --kind struct
# Expected: diagnostic breakdown showing query alone vs kind alone counts

# Combined
./zig-out/bin/codescan search --kind fn --path "src/search*" --top 3
```

- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "chore: full reindex with short canonical symbol kinds"
```
