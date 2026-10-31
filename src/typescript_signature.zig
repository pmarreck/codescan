const std = @import("std");
const syntax = @import("signature_syntax.zig").TypeScript;

pub const Query = struct {
	name: []const u8,
	parameters: ?[]const u8,
	output: []const u8,
	generics: ?[]const u8 = null,
	shared: bool = false,

	pub fn parse(text: []const u8) ?Query {
		if (syntax.topLevelEnd(text, ':')) |colon| {
			if (colon < text.len and validName(syntax.trim(text[0..colon]))) {
				const types = text[colon + 1 ..];
				const arrow = syntax.topLevelToken(types, "->") orelse return null;
				if (arrow == types.len) return null;
				const output = syntax.trim(types[arrow + 2 ..]);
				if (!syntax.validTypes(output)) return null;
				const parameters = syntax.trim(types[0..arrow]);
				return .{ .name = syntax.trim(text[0..colon]), .parameters = if (parameters.len == 0) null else parameters, .output = output, .shared = true };
			}
		}
		return native(text);
	}

	pub fn matches(self: Query, name: []const u8, signature: []const u8) bool {
		if (!syntax.namesEqual(self.name, name)) return false;
		const declaration = native(signature) orelse return false;
		if (!syntax.typesEqual(self.output, declaration.output)) return false;
		if (self.generics) |generics| if (!syntax.typesEqual(generics, declaration.generics orelse return false)) return false;
		var wanted = syntax.Parameters{ .text = self.parameters orelse return true };
		var actual = syntax.Parameters{ .text = declaration.parameters orelse return false };
		while (wanted.next()) |text| {
			const candidate = parameter(actual.next() orelse return false) orelse return false;
			if (self.shared) {
				if (!syntax.typesEqual(text, candidate.type)) return false;
			} else {
				const constraint = parameter(text) orelse return false;
				if (constraint.optional != candidate.optional or constraint.rest != candidate.rest or
					!syntax.typesEqual(constraint.type, candidate.type)) return false;
			}
		}
		return actual.next() == null;
	}
};

fn validName(text: []const u8) bool {
	var tokens = syntax.Tokens{ .text = text };
	var identifier = true;
	while (tokens.next()) |token| {
		if (identifier) {
			if (!syntax.word(token[0])) return false;
		} else if (!std.mem.eql(u8, token, ".") and !std.mem.eql(u8, token, "/")) return false;
		identifier = !identifier;
	}
	return !identifier and !tokens.invalid;
}

fn group(tokens: *syntax.Tokens, closing: u8) ?[]const u8 {
	const start = tokens.offset;
	const end = syntax.topLevelEnd(tokens.text[start..], closing) orelse return null;
	if (start + end == tokens.text.len) return null;
	tokens.offset = start + end + 1;
	return syntax.trim(tokens.text[start .. start + end]);
}

fn native(text: []const u8) ?Query {
	var tokens = syntax.Tokens{ .text = syntax.trim(text) };
	var name = tokens.next() orelse return null;
	while (true) {
		if (std.mem.eql(u8, name, "function")) {
			name = tokens.next() orelse return null;
			if (std.mem.eql(u8, name, "*")) name = tokens.next() orelse return null;
			break;
		}
		var modifier = false;
		for ([_][]const u8{ "export", "default", "declare", "async", "public", "private", "protected", "static", "abstract", "override", "readonly", "get", "set" }) |keyword| {
			if (std.mem.eql(u8, name, keyword)) modifier = true;
		}
		if (!modifier) break;
		var lookahead = tokens;
		const next = lookahead.next() orelse return null;
		if (std.mem.eql(u8, next, "(") or std.mem.eql(u8, next, "<")) break;
		name = tokens.next() orelse return null;
	}
	if (!validName(name)) return null;
	var next = tokens.next() orelse return null;
	var generics: ?[]const u8 = null;
	if (std.mem.eql(u8, next, "<")) {
		generics = group(&tokens, '>') orelse return null;
		if (generics.?.len == 0) return null;
		next = tokens.next() orelse return null;
	}
	if (!std.mem.eql(u8, next, "(")) return null;
	const parameters = group(&tokens, ')') orelse return null;
	if (!std.mem.eql(u8, tokens.next() orelse return null, ":")) return null;
	var output = syntax.trim(tokens.text[tokens.offset..]);
	if (std.mem.endsWith(u8, output, ";")) output = syntax.trim(output[0 .. output.len - 1]);
	if (!syntax.validTypes(output)) return null;
	return .{ .name = name, .parameters = if (std.mem.eql(u8, parameters, "...")) null else parameters, .output = output, .generics = generics };
}

const Parameter = struct { type: []const u8, optional: bool, rest: bool };

fn parameter(text: []const u8) ?Parameter {
	const colon = syntax.topLevelEnd(text, ':') orelse return null;
	if (colon == text.len) return null; // No implicit/inferred `any` constraint.
	const prefix = syntax.trim(text[0..colon]);
	const tail = text[colon + 1 ..];
	const assignment = syntax.topLevelEnd(tail, '=') orelse return null;
	const annotation = syntax.trim(tail[0..assignment]);
	if (!syntax.validTypes(annotation)) return null;
	return .{
		.type = annotation,
		.optional = (syntax.topLevelEnd(prefix, '?') orelse return null) != prefix.len or assignment < tail.len,
		.rest = std.mem.startsWith(u8, prefix, "..."),
	};
}

test "TypeScript signature queries classify native methods shared forms and generic bounds" {
	const cases = [_]struct { text: []const u8, recognized: bool }{
		.{ .text = "ceil : -> number", .recognized = true },
		.{ .text = "function ceil(...): number", .recognized = true },
		.{ .text = "ceil(value: number): number", .recognized = true },
		.{ .text = "public static ceil(): number", .recognized = true },
		.{ .text = "function identity<T extends object>(...): T", .recognized = true },
		.{ .text = "ceil", .recognized = false },
		.{ .text = "function ceil(value)", .recognized = false },
		.{ .text = "function ceil():", .recognized = false },
		.{ .text = "fn ceil(...) -> number", .recognized = false },
		.{ .text = "find function ceil(): number", .recognized = false },
		.{ .text = "ceil : => number", .recognized = false },
	};
	for (cases) |case| try std.testing.expectEqual(case.recognized, Query.parse(case.text) != null);
}

test "TypeScript signature constraints classify parameter shape and exact return types over sets" {
	const declarations = [_][]const u8{
		"export function ceil(value: number): number",
		"public ceil(value: number): number",
		"function ceil(): number",
		"function ceil(value?: number): number",
		"function ceil(value: number = 1): number",
		"function ceil(value: number): string",
		"function ceil(value) { return value; }",
	};
	const queries = [_]struct { text: []const u8, expected: [declarations.len]bool }{
		.{ .text = "ceil : -> number", .expected = .{ true, true, true, true, true, false, false } },
		.{ .text = "function ceil(...): number", .expected = .{ true, true, true, true, true, false, false } },
		.{ .text = "ceil : number -> number", .expected = .{ true, true, false, true, true, false, false } },
		.{ .text = "ceil(renamed: number): number", .expected = .{ true, true, false, false, false, false, false } },
		.{ .text = "function ceil(): number", .expected = .{ false, false, true, false, false, false, false } },
		.{ .text = "ceil(value?: number): number", .expected = .{ false, false, false, true, true, false, false } },
	};
	for (queries) |query| for (declarations, query.expected) |declaration, expected| {
		try std.testing.expectEqual(expected, Query.parse(query.text).?.matches("ceil", declaration));
	};
	try std.testing.expect(!Query.parse("ceil : -> number").?.matches("ceiling", declarations[0]));
	try std.testing.expect(Query.parse("ceil(...values: number[]): number").?.matches("ceil", "ceil(...renamed: number[]): number"));
	try std.testing.expect(!Query.parse("ceil(values: number[]): number").?.matches("ceil", "ceil(...values: number[]): number"));
}

test "TypeScript signature matching preserves nested type arrows generics and literal tokens" {
	const callback = Query.parse("decode : (value: number) => string -> Map<string, Array<number>>").?;
	try std.testing.expect(callback.matches("decode", "function decode(callback: (value: number) => string): Map<string, Array<number>>"));
	try std.testing.expect(!callback.matches("decode", "function decode(callback: (value: number) => number): Map<string, Array<number>>"));
	try std.testing.expect(!callback.matches("decode", "function decode(callback: (value: number) => string): Map<string, Array<string>>"));
	const generic = Query.parse("function identity<T extends object>(...): T").?;
	try std.testing.expect(generic.matches("identity", "function identity<T extends object>(value: T): T"));
	try std.testing.expect(!generic.matches("identity", "function identity<T extends string>(value: T): T"));
	try std.testing.expect(!generic.matches("identity", "function identity<U extends object>(value: U): U"));
	try std.testing.expect(Query.parse("$answer : -> 'yes'").?.matches("$answer", "function $answer(): 'yes'"));
	try std.testing.expect(!Query.parse("$answer : -> 'yes'").?.matches("$answer", "function $answer(): 'no'"));
	try std.testing.expect(Query.parse("format : -> `item-${number}`").?.matches("format", "function format(): `item-${number}`"));
	try std.testing.expect(Query.parse("Codec.decode : -> string").?.matches("Codec/decode", "decode(value: number): string"));
	try std.testing.expect(!Query.parse("Codec.decode : -> string").?.matches("Other/decode", "decode(value: number): string"));
}

test "TypeScript signature parsing remains bounded and does not infer missing annotations" {
	const cases = [_][]const u8{
		"function bad(value: [): number", "function bad()", "function bad(): /* missing",
		"function bad(): 'missing", "bad : -> " ++ "Array<" ** 65 ++ "number" ++ ">" ** 65,
	};
	for (cases) |text| try std.testing.expect(Query.parse(text) == null);
	try std.testing.expect(Query.parse("bad : -> number").?.matches("bad", "function bad(flag: boolean = 1 < 2): number"));
	const comparison_defaults = Query.parse("choose : boolean -> number").?;
	const defaults = [_]struct { signature: []const u8, matches: bool }{
		.{ .signature = "function choose(flag: boolean = 1 < 2): number", .matches = true },
		.{ .signature = "function choose(flag: boolean = 2 > 1): number", .matches = true },
		.{ .signature = "function choose(flag: boolean = true): number", .matches = true },
		.{ .signature = "function choose(flag: string = '<'): number", .matches = false },
		.{ .signature = "function choose(flag: boolean = 1 < 2, label: string = ''): number", .matches = false },
	};
	for (defaults) |case| try std.testing.expectEqual(case.matches, comparison_defaults.matches("choose", case.signature));
	const two_inputs = Query.parse("choose : boolean, string -> number").?;
	try std.testing.expect(two_inputs.matches("choose", defaults[4].signature));
	try std.testing.expect(!two_inputs.matches("choose", "function choose(flag: boolean = 1 < 2, count: number = 0): number"));
}
