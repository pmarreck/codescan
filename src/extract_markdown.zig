const std = @import("std");
const model = @import("model.zig");
const util = @import("extract_util.zig");

pub fn extract(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	source: []const u8,
) ![]model.Symbol {
	var lines = try util.splitLines(allocator, source);
	defer lines.deinit(allocator);

	var symbols = @as(std.ArrayListUnmanaged(model.Symbol), .empty);
	errdefer {
		for (symbols.items) |*sym| sym.deinit(allocator);
		symbols.deinit(allocator);
	}

    const frontmatter = parseLeadingFrontmatter(lines.items);
    const content_start = if (frontmatter) |metadata| metadata.end_line_index + 1 else 0;
    if (frontmatter) |metadata| {
        try emitFrontmatter(allocator, file_path, metadata, &symbols);
    }

    var section_start: usize = content_start;
	var section_heading: ?[]const u8 = null;
	var section_lines = @as(std.ArrayListUnmanaged([]const u8), .empty);
	defer section_lines.deinit(allocator);

    for (lines.items[content_start..], content_start..) |line, idx| {
		if (isHeading(line)) {
			if (section_lines.items.len > 0) {
				try emitSection(allocator, file_path, section_heading, section_start, section_lines.items, &symbols);
				section_lines.clearRetainingCapacity();
			}
			section_heading = headingText(line);
			section_start = idx;
		}
		try section_lines.append(allocator, line);
	}

	if (section_lines.items.len > 0) {
		try emitSection(allocator, file_path, section_heading, section_start, section_lines.items, &symbols);
	}

	return symbols.toOwnedSlice(allocator);
}

const Frontmatter = struct {
    end_line_index: usize,
    description: ?[]const u8,
    tags: ?[]const u8,
};

/// Recognizes only a complete leading YAML fence and the two memory-recall
/// fields Codescan weights. Unfinished metadata remains ordinary searchable text.
fn parseLeadingFrontmatter(lines: []const []const u8) ?Frontmatter {
    if (lines.len < 2 or !std.mem.eql(u8, std.mem.trim(u8, lines[0], "\r"), "---")) return null;
    var description: ?[]const u8 = null;
    var tags: ?[]const u8 = null;
    for (lines[1..], 1..) |line, index| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, trimmed, "---")) {
            return .{
                .end_line_index = index,
                .description = description,
                .tags = tags,
            };
        }
        if (frontmatterValue(trimmed, "description")) |value| {
            description = unquoteYamlScalar(value);
        } else if (frontmatterValue(trimmed, "tags")) |value| {
            tags = value;
        }
    }
    return null;
}

fn frontmatterValue(line: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, key) or line.len <= key.len or line[key.len] != ':') return null;
    return std.mem.trim(u8, line[key.len + 1 ..], " \t\r");
}

fn unquoteYamlScalar(value: []const u8) []const u8 {
    if (value.len >= 2 and
        ((value[0] == '"' and value[value.len - 1] == '"') or
            (value[0] == '\'' and value[value.len - 1] == '\'')))
    {
        return value[1 .. value.len - 1];
    }
    return value;
}

fn normalizeFrontmatterTags(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var value = std.mem.trim(u8, raw, " \t\r");
    if (value.len >= 2 and value[0] == '[' and value[value.len - 1] == ']') {
        value = value[1 .. value.len - 1];
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var tags = std.mem.splitScalar(u8, value, ',');
    var wrote_one = false;
    while (tags.next()) |raw_tag| {
        const tag = unquoteYamlScalar(std.mem.trim(u8, raw_tag, " \t\r"));
        if (tag.len == 0) continue;
        if (wrote_one) try out.writer.writeByte(' ');
        try out.writer.writeAll(tag);
        wrote_one = true;
    }
    return out.toOwnedSlice();
}

fn emitFrontmatter(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    metadata: Frontmatter,
    out: *std.ArrayListUnmanaged(model.Symbol),
) !void {
    if (metadata.description == null and metadata.tags == null) return;
    const tags = if (metadata.tags) |raw| try normalizeFrontmatterTags(allocator, raw) else null;
    errdefer if (tags) |value| allocator.free(value);
    const signature_source = metadata.description orelse "frontmatter tags";
    const language = try allocator.dupe(u8, "markdown");
    errdefer allocator.free(language);
    const owned_path = try allocator.dupe(u8, file_path);
    errdefer allocator.free(owned_path);
    const name = try allocator.dupe(u8, std.fs.path.basename(file_path));
    errdefer allocator.free(name);
    const signature = try allocator.dupe(u8, signature_source);
    errdefer allocator.free(signature);
    const symbol_kind = try allocator.dupe(u8, "frontmatter");
    errdefer allocator.free(symbol_kind);
    const symbol = model.Symbol{
        .language = language,
        .file_path = owned_path,
        .name = name,
        .signature = signature,
        .doc_comment = tags,
        .symbol_kind = symbol_kind,
        .start_line = 1,
        .end_line = metadata.end_line_index + 1,
    };
    try out.append(allocator, symbol);
}

fn emitSection(
	allocator: std.mem.Allocator,
	file_path: []const u8,
	heading: ?[]const u8,
	start_idx: usize,
	lines: []const []const u8,
	out: *std.ArrayListUnmanaged(model.Symbol),
) !void {
	const trimmed_len = trimTrailingBlank(lines);
	if (trimmed_len == 0) return;
	const trimmed_lines = lines[0..trimmed_len];

	const name = if (heading) |value|
		try allocator.dupe(u8, std.mem.trim(u8, value, " \t\r"))
	else
		try allocator.dupe(u8, std.fs.path.basename(file_path));

	const full = try util.joinLines(allocator, trimmed_lines);
	const preview = firstNonEmptyContentLine(trimmed_lines) orelse trimmed_lines[0];
	const signature = try allocator.dupe(u8, std.mem.trim(u8, preview, " \t\r"));

	const symbol = model.Symbol{
		.language = try allocator.dupe(u8, "markdown"),
		.file_path = try allocator.dupe(u8, file_path),
		.name = name,
		.signature = signature,
		.doc_comment = full,
		.start_line = start_idx + 1,
		.end_line = start_idx + trimmed_len,
	};

	try out.append(allocator, symbol);
}

fn isHeading(line: []const u8) bool {
	var idx: usize = 0;
	while (idx < line.len and line[idx] == '#') : (idx += 1) {}
	if (idx == 0) return false;
	if (idx >= line.len) return false;
	return line[idx] == ' ' or line[idx] == '\t';
}

fn headingText(line: []const u8) []const u8 {
	var idx: usize = 0;
	while (idx < line.len and line[idx] == '#') : (idx += 1) {}
	if (idx < line.len and (line[idx] == ' ' or line[idx] == '\t')) idx += 1;
	return std.mem.trim(u8, line[idx..], " \t\r");
}

fn firstNonEmptyLine(lines: []const []const u8) ?[]const u8 {
	for (lines) |line| {
		const trimmed = std.mem.trim(u8, line, " \t\r");
		if (trimmed.len > 0) return trimmed;
	}
	return null;
}

fn firstNonEmptyContentLine(lines: []const []const u8) ?[]const u8 {
	if (lines.len == 0) return null;
	var start: usize = 0;
	if (isHeading(lines[0])) start = 1;
	for (lines[start..]) |line| {
		const trimmed = std.mem.trim(u8, line, " \t\r");
		if (trimmed.len > 0) return trimmed;
	}
	return null;
}

fn trimTrailingBlank(lines: []const []const u8) usize {
	var len = lines.len;
	while (len > 0) : (len -= 1) {
		if (!isBlank(lines[len - 1])) break;
	}
	return len;
}

fn isBlank(line: []const u8) bool {
	return std.mem.trim(u8, line, " \t\r").len == 0;
}

test "extract splits markdown by heading" {
	const allocator = std.testing.allocator;
	const source =
		"# Title\n" ++
		"Intro line.\n" ++
		"\n" ++
		"## Sub\n" ++
		"Detail.\n";

	const symbols = try extract(allocator, "README.md", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expectEqual(@as(usize, 2), symbols.len);
	try std.testing.expectEqualStrings("Title", symbols[0].name);
	try std.testing.expectEqualStrings("Intro line.", symbols[0].signature);
	try std.testing.expectEqual(@as(usize, 1), symbols[0].start_line);
	try std.testing.expectEqual(@as(usize, 2), symbols[0].end_line);
	try std.testing.expectEqualStrings("Sub", symbols[1].name);
	try std.testing.expectEqualStrings("Detail.", symbols[1].signature);
	try std.testing.expectEqual(@as(usize, 4), symbols[1].start_line);
	try std.testing.expectEqual(@as(usize, 5), symbols[1].end_line);
}

test "extract uses file basename when no heading" {
	const allocator = std.testing.allocator;
	const source = "plain text\nsecond line\n";

	const symbols = try extract(allocator, "docs/notes.md", source);
	defer {
		for (symbols) |*sym| sym.deinit(allocator);
		allocator.free(symbols);
	}

	try std.testing.expectEqual(@as(usize, 1), symbols.len);
	try std.testing.expectEqualStrings("notes.md", symbols[0].name);
}

test "extract emits leading frontmatter once as structured metadata" {
    const allocator = std.testing.allocator;
    const source =
        "---\n" ++
        "description: \"Git-backed Nix flakes exclude untracked inputs.\"\n" ++
        "datetime: 2026-07-23T14:00:00-04:00\n" ++
        "tags: [nix, flakes, untracked-files]\n" ++
        "---\n" ++
        "# Recovery\n" ++
        "Stage referenced files before building.\n";

    const symbols = try extract(allocator, "MEMORIES/nix.frontmatter.md", source);
    defer {
        for (symbols) |*sym| sym.deinit(allocator);
        allocator.free(symbols);
    }

    try std.testing.expectEqual(@as(usize, 2), symbols.len);
    const metadata_kind = symbols[0].symbol_kind orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("frontmatter", metadata_kind);
    try std.testing.expectEqualStrings("nix.frontmatter.md", symbols[0].name);
    try std.testing.expectEqualStrings(
        "Git-backed Nix flakes exclude untracked inputs.",
        symbols[0].signature,
    );
    try std.testing.expectEqualStrings("nix flakes untracked-files", symbols[0].doc_comment.?);
    try std.testing.expectEqual(@as(usize, 1), symbols[0].start_line);
    try std.testing.expectEqual(@as(usize, 5), symbols[0].end_line);

    try std.testing.expectEqualStrings("Recovery", symbols[1].name);
    try std.testing.expectEqual(@as(usize, 6), symbols[1].start_line);
    try std.testing.expect(std.mem.indexOf(u8, symbols[1].doc_comment.?, "description:") == null);
}

test "extract leaves unterminated frontmatter searchable as ordinary markdown" {
    const allocator = std.testing.allocator;
    const source =
        "---\n" ++
        "description: still being written\n";

    const symbols = try extract(allocator, "draft.frontmatter.md", source);
    defer {
        for (symbols) |*sym| sym.deinit(allocator);
        allocator.free(symbols);
    }

    try std.testing.expectEqual(@as(usize, 1), symbols.len);
    try std.testing.expect(symbols[0].symbol_kind == null);
    try std.testing.expect(std.mem.indexOf(u8, symbols[0].doc_comment.?, "still being written") != null);
}
