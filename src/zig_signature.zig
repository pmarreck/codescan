const std = @import("std");
const roc = @import("roc_signature.zig");

/// Borrowed declared types, not inferred types or alias resolution. Native `()`
/// means zero inputs; native `(...)` and an empty shared input leave them open.
pub const Query = struct {
	name: []const u8,
	parameters: ?[]const u8,
	output: []const u8,

	pub fn parse(text: []const u8) ?Query {
		if (roc.Query.parse(text)) |shared| {
			if (!std.mem.eql(u8, shared.arrow, "->") or !validTypes(shared.output)) return null;
			if (topLevelEnd(shared.parameters, 0) == null) return null;
			return .{ .name = shared.name, .parameters = if (shared.parameters.len == 0) null else shared.parameters, .output = shared.output };
		}
		return native(text);
	}

	pub fn matches(self: Query, name: []const u8, signature: []const u8) bool {
		if (!namesEqual(self.name, name)) return false;
		const declaration = native(signature) orelse return false;
		if (!typesEqual(self.output, declaration.output)) return false;
		const parameters = self.parameters orelse return true;
		var wanted = Parameters{ .text = parameters };
		var actual = Parameters{ .text = declaration.parameters orelse return false };
		while (wanted.next()) |parameter| {
			const candidate = actual.next() orelse return false;
			if (!typesEqual(parameterType(parameter), parameterType(candidate))) return false;
		}
		return actual.next() == null;
	}
};

fn native(text: []const u8) ?Query {
	var tokens = Tokens{ .text = text };
	var external = false;
	while (tokens.next()) |prefix| {
		if (std.mem.eql(u8, prefix, "fn")) break;
		if (std.mem.eql(u8, prefix, "extern")) {
			external = true;
		} else if (!std.mem.eql(u8, prefix, "pub") and !std.mem.eql(u8, prefix, "export") and
			!std.mem.eql(u8, prefix, "inline") and !std.mem.eql(u8, prefix, "noinline") and
			!(external and prefix[0] == '"')) return null;
	} else return null;
	const name = tokens.next() orelse return null;
	if (!word(name[0]) and !std.mem.startsWith(u8, name, "@\"")) return null;
	if (!std.mem.eql(u8, tokens.next() orelse return null, "(")) return null;
	const start = tokens.offset;
	const end = topLevelEnd(text[start..], ')') orelse return null;
	if (start + end == text.len) return null;
	const parameters = trim(text[start .. start + end]);
	var output = trim(text[start + end + 1 ..]);
	// ABI/alignment attributes are not part of the requested type relation.
	while (true) {
		var attributes = Tokens{ .text = output };
		const attribute = attributes.next() orelse return null;
		if (!std.mem.eql(u8, attribute, "callconv") and !std.mem.eql(u8, attribute, "align") and
			!std.mem.eql(u8, attribute, "linksection") and !std.mem.eql(u8, attribute, "addrspace")) break;
		if (!std.mem.eql(u8, attributes.next() orelse return null, "(")) return null;
		const attribute_end = topLevelEnd(output[attributes.offset..], ')') orelse return null;
		if (attributes.offset + attribute_end == output.len) return null;
		output = trim(output[attributes.offset + attribute_end + 1 ..]);
	}
	if (!validTypes(output)) return null;
	return .{ .name = name, .parameters = if (std.mem.eql(u8, parameters, "...")) null else parameters, .output = output };
}

fn trim(text: []const u8) []const u8 {
	return std.mem.trim(u8, text, " \t\r\n");
}

fn word(ch: u8) bool {
	return std.ascii.isAlphanumeric(ch) or ch == '_' or ch >= 128;
}

const Tokens = struct {
	text: []const u8,
	offset: usize = 0,
	invalid: bool = false,

	fn next(self: *Tokens) ?[]const u8 {
		while (self.offset < self.text.len) {
			if (std.ascii.isWhitespace(self.text[self.offset])) {
				self.offset += 1;
			} else if (std.mem.startsWith(u8, self.text[self.offset..], "//")) {
				while (self.offset < self.text.len and self.text[self.offset] != '\n') self.offset += 1;
			} else break;
		}
		if (self.offset == self.text.len) return null;
		const start = self.offset;
		self.offset += 1;
		if (self.text[start] == '@' and self.offset < self.text.len and self.text[self.offset] == '"') self.offset += 1;
		const quote = self.text[self.offset - 1];
		if (quote == '"' or quote == '\'') {
			while (self.offset < self.text.len) {
				const ch = self.text[self.offset];
				self.offset += 1;
				if (ch == quote) return self.text[start..self.offset];
				if (ch == '\\' and self.offset < self.text.len) self.offset += 1;
			}
			self.invalid = true;
			return null;
		}
		if (word(self.text[start])) {
			while (self.offset < self.text.len and word(self.text[self.offset])) self.offset += 1;
		}
		return self.text[start..self.offset];
	}
};

/// A fixed bound rejects pathological nesting without recursion or allocation.
fn topLevelEnd(text: []const u8, stop: u8) ?usize {
	var tokens = Tokens{ .text = text };
	var stack: [64]u8 = undefined;
	var depth: usize = 0;
	while (tokens.next()) |token| {
		if (token.len != 1) continue;
		const ch = token[0];
		if (depth == 0 and ch == stop) return tokens.offset - 1;
		if (ch == '(' or ch == '[' or ch == '{') {
			if (depth == stack.len) return null;
			stack[depth] = ch;
			depth += 1;
		} else if (ch == ')' or ch == ']' or ch == '}') {
			if (depth == 0) return null;
			const opening: u8 = switch (ch) { ')' => '(', ']' => '[', else => '{' };
			depth -= 1;
			if (stack[depth] != opening) return null;
		}
	}
	return if (depth == 0 and !tokens.invalid) text.len else null;
}

fn validTypes(text: []const u8) bool {
	if (topLevelEnd(text, 0) == null) return false;
	var tokens = Tokens{ .text = text };
	while (tokens.next()) |token| if (word(token[0]) or token[0] == '@') return true;
	return false;
}

fn typesEqual(a: []const u8, b: []const u8) bool {
	var at = Tokens{ .text = a };
	var bt = Tokens{ .text = b };
	while (at.next()) |token| {
		if (!std.mem.eql(u8, token, bt.next() orelse return false)) return false;
	}
	return bt.next() == null and !at.invalid and !bt.invalid;
}

fn namesEqual(query: []const u8, name: []const u8) bool {
	const candidate = if (std.mem.indexOfAny(u8, query, "./") != null) name else
		name[(if (std.mem.lastIndexOfAny(u8, name, "./")) |i| i + 1 else 0)..];
	if (query.len != candidate.len) return false;
	for (query, candidate) |a, b| if ((if (a == '.') '/' else a) != (if (b == '.') '/' else b)) return false;
	return true;
}

const Parameters = struct {
	text: []const u8,
	fn next(self: *Parameters) ?[]const u8 {
		var tokens = Tokens{ .text = self.text };
		if (tokens.next() == null) return null;
		const end = topLevelEnd(self.text, ',') orelse return null;
		const parameter = self.text[0..end];
		self.text = if (end == self.text.len) "" else self.text[end + 1 ..];
		return parameter;
	}
};

fn parameterType(text: []const u8) []const u8 {
	const colon = topLevelEnd(text, ':') orelse return text;
	return if (colon == text.len) text else text[colon + 1 ..];
}

test "Zig signature query recognition classifies native and shared syntax" {
	const cases = [_]struct { text: []const u8, recognized: bool }{
		.{ .text = "ceil : -> f64", .recognized = true },
		.{ .text = "Math.ceil : f64 -> f64", .recognized = true },
		.{ .text = "fn ceil(...) f64", .recognized = true },
		.{ .text = "pub fn ceil(value: f64) f64", .recognized = true },
		.{ .text = "fn ceil() f64", .recognized = true },
		.{ .text = "ceil", .recognized = false },
		.{ .text = "find fn ceil(...) f64", .recognized = false },
		.{ .text = "ceil : => f64", .recognized = false },
		.{ .text = "fn ceil(", .recognized = false },
		.{ .text = "fn ceil()", .recognized = false },
		.{ .text = "ceil : ->", .recognized = false },
		.{ .text = "ceil : -> []", .recognized = false },
		.{ .text = "fn ceil(value: [) f64", .recognized = false },
	};
	for (cases) |case| try std.testing.expectEqual(case.recognized, Query.parse(case.text) != null);
}

test "Zig signature queries classify parameter and return constraints over sets" {
	const declarations = [_]struct { name: []const u8 = "ceil", signature: []const u8 }{
		.{ .signature = "pub fn ceil(value: f64) f64" },
		.{ .signature = "fn ceil() f64" },
		.{ .signature = "fn ceil(value: f32) f64" },
		.{ .signature = "fn ceil(left: f64, right: f64) f64" },
		.{ .name = "ceiling", .signature = "fn ceiling(value: f64) f64" },
		.{ .signature = "fn ceil(value: f64) f32" },
		.{ .signature = "fn ceil(renamed: f64,) f64 // rounds up" },
	};
	const queries = [_]struct { text: []const u8, expected: [declarations.len]bool }{
		.{ .text = "ceil : -> f64", .expected = .{ true, true, true, true, false, false, true } },
		.{ .text = "fn ceil(...) f64", .expected = .{ true, true, true, true, false, false, true } },
		.{ .text = "ceil : f64 -> f64", .expected = .{ true, false, false, false, false, false, true } },
		.{ .text = "fn ceil(other: f64) f64", .expected = .{ true, false, false, false, false, false, true } },
		.{ .text = "fn ceil() f64", .expected = .{ false, true, false, false, false, false, false } },
		.{ .text = "ceil : f32 -> f64", .expected = .{ false, false, true, false, false, false, false } },
		.{ .text = "ceil : f64, f64 -> f64", .expected = .{ false, false, false, true, false, false, false } },
	};
	for (queries) |query| {
		const parsed = Query.parse(query.text).?;
		for (declarations, query.expected) |declaration, expected| {
			try std.testing.expectEqual(expected, parsed.matches(declaration.name, declaration.signature));
		}
	}
}

test "Zig signature matching preserves nested types qualifiers and name boundaries" {
	const query = Query.parse("apply : []const u8, fn(u8, u8) u8 -> ![]const u8").?;
	const cases = [_]struct { name: []const u8 = "apply", signature: []const u8, matches: bool }{
		.{ .signature = "pub fn apply(noalias bytes: []const u8, callback: fn(u8,u8)u8) ![]const u8", .matches = true },
		.{ .name = "Codec/apply", .signature = "fn apply(bytes: []const u8, callback: fn(u8, u8) u8,) ![]const u8", .matches = true },
		.{ .signature = "fn apply(bytes: []u8, callback: fn(u8,u8)u8) ![]const u8", .matches = false },
		.{ .signature = "fn apply(bytes: []constu8, callback: fn(u8,u8)u8) ![]const u8", .matches = false },
		.{ .signature = "fn apply(bytes: []const u8, callback: fn(u8)u8) ![]const u8", .matches = false },
		.{ .signature = "fn apply(bytes: []const u8, callback: fn(u8,u8)u8) []const u8", .matches = false },
		.{ .name = "applyMore", .signature = "fn applyMore(bytes: []const u8, callback: fn(u8,u8)u8) ![]const u8", .matches = false },
	};
	for (cases) |case| try std.testing.expectEqual(case.matches, query.matches(case.name, case.signature));
	const qualified = Query.parse("Codec.apply : -> ![]const u8").?;
	try std.testing.expect(qualified.matches("Codec/apply", cases[1].signature));
	try std.testing.expect(!qualified.matches("Other/apply", cases[1].signature));
	try std.testing.expect(!qualified.matches("apply", cases[1].signature));
	const attribute = Query.parse("extern \"c\" fn apply(...) callconv(.c) ![]const u8").?;
	try std.testing.expect(attribute.matches("apply", cases[0].signature));
	try std.testing.expect(typesEqual("@TypeOf(\"(,)\")", "@TypeOf ( \"(,)\" )"));
	try std.testing.expect(!typesEqual("@TypeOf(\"a b\")", "@TypeOf(\"ab\")"));
}

test "Zig signature nesting and unterminated strings are bounded" {
	const too_deep = "fn ceil(x: " ++ "[" ** 65 ++ "u8" ++ "]" ** 65 ++ ") f64";
	try std.testing.expect(Query.parse(too_deep) == null);
	try std.testing.expect(Query.parse("fn ceil(x: @TypeOf(\"missing)) f64") == null);
	try std.testing.expect(Query.parse("ceil : -> @TypeOf(\"missing)") == null);
}
