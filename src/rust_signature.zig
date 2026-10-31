const std = @import("std");
const syntax = @import("signature_syntax.zig").Rust;

pub const Query = struct {
	name: []const u8,
	parameters: ?[]const u8,
	output: []const u8,
	generics: ?[]const u8 = null,
	constraints: ?[]const u8 = null,

	pub fn parse(text: []const u8) ?Query {
		if (syntax.topLevelEnd(text, ':')) |colon| {
			if (colon < text.len and validName(syntax.trim(text[0..colon]))) {
				const types = text[colon + 1 ..];
				const arrow = syntax.topLevelToken(types, "->") orelse return null;
				if (arrow == types.len) return null;
				const output = syntax.trim(types[arrow + 2 ..]);
				if (!syntax.validTypes(output)) return null;
				const parameters = syntax.trim(types[0..arrow]);
				return .{ .name = syntax.trim(text[0..colon]), .parameters = if (parameters.len == 0) null else parameters, .output = output };
			}
		}
		return native(text);
	}

	pub fn matches(self: Query, name: []const u8, signature: []const u8) bool {
		if (!namesEqual(self.name, name)) return false;
		const declaration = native(signature) orelse return false;
		if (!syntax.typesEqual(self.output, declaration.output)) return false;
		if (self.generics) |generics| if (!syntax.typesEqual(generics, declaration.generics orelse return false)) return false;
		if (self.constraints) |constraints| if (!syntax.typesEqual(constraints, declaration.constraints orelse return false)) return false;
		const parameters = self.parameters orelse return true;
		var wanted = syntax.Parameters{ .text = parameters };
		var actual = syntax.Parameters{ .text = declaration.parameters orelse return false };
		while (wanted.next()) |parameter| {
			if (!parameterTypesEqual(parameter, actual.next() orelse return false)) return false;
		}
		return actual.next() == null;
	}
};

fn group(tokens: *syntax.Tokens, closing: u8) ?[]const u8 {
	const start = tokens.offset;
	const end = syntax.topLevelEnd(tokens.text[start..], closing) orelse return null;
	if (start + end == tokens.text.len) return null;
	tokens.offset = start + end + 1;
	return syntax.trim(tokens.text[start .. start + end]);
}

fn native(text: []const u8) ?Query {
	var tokens = syntax.Tokens{ .text = syntax.trim(text) };
	while (tokens.next()) |prefix| {
		if (std.mem.eql(u8, prefix, "fn")) break;
		if (std.mem.eql(u8, prefix, "pub")) {
			const saved = tokens;
			if (std.mem.eql(u8, tokens.next() orelse return null, "(")) {
				_ = group(&tokens, ')') orelse return null;
			} else tokens = saved;
		} else if (std.mem.eql(u8, prefix, "extern")) {
			const saved = tokens;
			if ((tokens.next() orelse return null)[0] != '"') tokens = saved;
		} else if (!std.mem.eql(u8, prefix, "async") and !std.mem.eql(u8, prefix, "unsafe") and !std.mem.eql(u8, prefix, "const")) return null;
	} else return null;
	const name = tokens.next() orelse return null;
	if (!validName(name)) return null;
	var next = tokens.next() orelse return null;
	var generics: ?[]const u8 = null;
	if (std.mem.eql(u8, next, "<")) {
		generics = trimComma(group(&tokens, '>') orelse return null);
		if (generics.?.len == 0) return null;
		next = tokens.next() orelse return null;
	}
	if (!std.mem.eql(u8, next, "(")) return null;
	const parameters = group(&tokens, ')') orelse return null;
	var output: []const u8 = "()";
	var constraints: ?[]const u8 = null;
	if (tokens.next()) |tail| {
		if (std.mem.eql(u8, tail, "->")) {
			const rest = tokens.text[tokens.offset..];
			const end = syntax.topLevelToken(rest, "where") orelse return null;
			output = syntax.trim(rest[0..end]);
			if (end < rest.len) constraints = trimComma(rest[end + "where".len ..]);
		} else if (std.mem.eql(u8, tail, "where")) {
			constraints = trimComma(tokens.text[tokens.offset..]);
		} else return null;
	}
	if (tokens.invalid or !syntax.validTypes(output) or (constraints != null and constraints.?.len == 0)) return null;
	if (constraints) |where| if (syntax.topLevelEnd(where, 0) == null) return null;
	return .{ .name = name, .parameters = if (std.mem.eql(u8, parameters, "...")) null else parameters, .output = output, .generics = generics, .constraints = constraints };
}

fn trimComma(text: []const u8) []const u8 {
	const trimmed = syntax.trim(text);
	return if (std.mem.endsWith(u8, trimmed, ",")) syntax.trim(trimmed[0 .. trimmed.len - 1]) else trimmed;
}

fn validName(name: []const u8) bool {
	var tokens = syntax.Tokens{ .text = name };
	var identifier = true;
	while (tokens.next()) |token| {
		if (identifier) {
			if (!syntax.word(token[0])) return false;
		} else if (!std.mem.eql(u8, token, "::") and !std.mem.eql(u8, token, ".") and !std.mem.eql(u8, token, "/")) return false;
		identifier = !identifier;
	}
	return !identifier and !tokens.invalid;
}

fn nameToken(token: []const u8) []const u8 {
	if (std.mem.eql(u8, token, "::") or std.mem.eql(u8, token, ".")) return "/";
	return if (std.mem.startsWith(u8, token, "r#")) token[2..] else token;
}

fn namesEqual(query: []const u8, name: []const u8) bool {
	const candidate = if (std.mem.indexOfAny(u8, query, "./:") != null) name else
		name[(if (std.mem.lastIndexOfAny(u8, name, "./:")) |i| i + 1 else 0)..];
	var wanted = syntax.Tokens{ .text = query };
	var actual = syntax.Tokens{ .text = candidate };
	while (wanted.next()) |token| {
		if (!std.mem.eql(u8, nameToken(token), nameToken(actual.next() orelse return false))) return false;
	}
	return actual.next() == null;
}

fn receiver(text: []const u8) bool {
	var tokens = syntax.Tokens{ .text = text };
	var token = tokens.next() orelse return false;
	if (std.mem.eql(u8, token, "&")) {
		token = tokens.next() orelse return false;
		if (token[0] == '\'') token = tokens.next() orelse return false;
	}
	if (std.mem.eql(u8, token, "mut")) token = tokens.next() orelse return false;
	return std.mem.eql(u8, token, "self") and tokens.next() == null;
}

fn parameterTokens(text: []const u8) syntax.Tokens {
	var parameter_type = syntax.trim(syntax.parameterType(text));
	// Shared queries group function-type arrows; a trailing comma is a tuple,
	// not transparent type parentheses, and must remain a constraint.
	while (std.mem.startsWith(u8, parameter_type, "(")) {
		const end = syntax.topLevelEnd(parameter_type[1..], ')') orelse break;
		if (end + 2 != parameter_type.len or end == 0) break;
		const inner = parameter_type[1 .. end + 1];
		if ((syntax.topLevelEnd(inner, ',') orelse break) != inner.len) break;
		parameter_type = syntax.trim(inner);
	}
	var tokens = syntax.Tokens{ .text = parameter_type };
	if (receiver(tokens.text)) {
		var probe = tokens;
		if (std.mem.eql(u8, probe.next().?, "mut")) tokens = probe;
	}
	return tokens;
}

fn parameterTypesEqual(a: []const u8, b: []const u8) bool {
	var wanted = parameterTokens(a);
	var actual = parameterTokens(b);
	const wanted_receiver = receiver(wanted.text);
	const actual_receiver = receiver(actual.text);
	while (wanted.next()) |token| {
		const candidate = actual.next() orelse return false;
		const normalized = if (wanted_receiver and std.mem.eql(u8, token, "self")) "Self" else token;
		const actual_normalized = if (actual_receiver and std.mem.eql(u8, candidate, "self")) "Self" else candidate;
		if (!std.mem.eql(u8, normalized, actual_normalized)) return false;
	}
	return actual.next() == null;
}

test "Rust signature queries recognize native shared generic and receiver syntax" {
	const cases = [_]struct { text: []const u8, recognized: bool }{
		.{ .text = "ceil : -> f64", .recognized = true },
		.{ .text = "fn ceil(...) -> f64", .recognized = true },
		.{ .text = "pub(crate) fn ceil(value: f64) -> f64", .recognized = true },
		.{ .text = "fn ceil(&self, value: f64) -> f64", .recognized = true },
		.{ .text = "fn identity<T: Copy>(...) -> T where T: Send", .recognized = true },
		.{ .text = "fn noop()", .recognized = true },
		.{ .text = "Type::ceil : &Self -> f64", .recognized = true },
		.{ .text = "ceil", .recognized = false },
		.{ .text = "fn ceil(...) f64", .recognized = false },
		.{ .text = "ceil : => f64", .recognized = false },
		.{ .text = "fn ceil() ->", .recognized = false },
		.{ .text = "fn identity<T(...) -> T", .recognized = false },
		.{ .text = "find fn ceil() -> f64", .recognized = false },
	};
	for (cases) |case| try std.testing.expectEqual(case.recognized, Query.parse(case.text) != null);
}

test "Rust signature parameter and return constraints classify complete declaration sets" {
	const declarations = [_][]const u8{
		"pub fn ceil(value: f64) -> f64",
		"fn ceil() -> f64",
		"fn ceil(&self, value: f64) -> f64",
		"fn ceil(&mut self, value: f64) -> f64",
		"fn ceil(value: f32) -> f32",
		"fn ceil(value: f64) -> Option<f64>",
	};
	const queries = [_]struct { text: []const u8, expected: [declarations.len]bool }{
		.{ .text = "ceil : -> f64", .expected = .{ true, true, true, true, false, false } },
		.{ .text = "fn ceil(...) -> f64", .expected = .{ true, true, true, true, false, false } },
		.{ .text = "fn ceil(other: f64) -> f64", .expected = .{ true, false, false, false, false, false } },
		.{ .text = "fn ceil() -> f64", .expected = .{ false, true, false, false, false, false } },
		.{ .text = "ceil : &Self, f64 -> f64", .expected = .{ false, false, true, false, false, false } },
		.{ .text = "fn ceil(&mut self, value: f64) -> f64", .expected = .{ false, false, false, true, false, false } },
	};
	for (queries) |query| for (declarations, query.expected) |declaration, expected| {
		try std.testing.expectEqual(expected, Query.parse(query.text).?.matches("ceil", declaration));
	};
	try std.testing.expect(Query.parse("noop : -> ()").?.matches("noop", "fn noop()"));
	try std.testing.expect(Query.parse("exit : -> !").?.matches("exit", "fn exit() -> !"));
	try std.testing.expect(Query.parse("consume : Self -> ()").?.matches("consume", "fn consume(mut self)"));
	try std.testing.expect(Query.parse("accept : (u8) -> ()").?.matches("accept", "fn accept(value: u8)"));
	try std.testing.expect(!Query.parse("accept : u8 -> ()").?.matches("accept", "fn accept(value: (u8,))"));
}

test "Rust signature queries constrain explicit generics and where predicates without unification" {
	const declarations = [_][]const u8{
		"pub fn identity<T: Copy>(value: T) -> T where T: Send",
		"fn identity<T: Clone>(value: T) -> T where T: Send",
		"fn identity<T: Copy>(value: T) -> T where T: Sync",
		"fn identity<U: Copy>(value: U) -> U where U: Send",
	};
	const queries = [_]struct { text: []const u8, expected: [declarations.len]bool }{
		.{ .text = "identity : -> T", .expected = .{ true, true, true, false } },
		.{ .text = "fn identity<T: Copy>(...) -> T", .expected = .{ true, false, true, false } },
		.{ .text = "fn identity(...) -> T where T: Send", .expected = .{ true, true, false, false } },
		.{ .text = "fn identity<T: Copy,>(...) -> T where T: Send,", .expected = .{ true, false, false, false } },
	};
	for (queries) |query| for (declarations, query.expected) |declaration, expected| {
		try std.testing.expectEqual(expected, Query.parse(query.text).?.matches("identity", declaration));
	};
}

test "Rust signature matching preserves lifetimes generic commas paths and nested arrows" {
	const query = Query.parse("decode : &'a [u8], (fn(u8, u8) -> u8) -> Result<Vec<u8>, Error>").?;
	const cases = [_]struct { signature: []const u8, matches: bool }{
		.{ .signature = "fn decode<'a>(bytes: &'a [u8], callback: fn(u8,u8)->u8) -> Result<Vec<u8>, Error>", .matches = true },
		.{ .signature = "fn decode<'a>(bytes: &'a mut [u8], callback: fn(u8,u8)->u8) -> Result<Vec<u8>, Error>", .matches = false },
		.{ .signature = "fn decode<'a>(bytes: &'b [u8], callback: fn(u8,u8)->u8) -> Result<Vec<u8>, Error>", .matches = false },
		.{ .signature = "fn decode<'a>(bytes: &'a [u8], callback: fn(u8)->u8) -> Result<Vec<u8>, Error>", .matches = false },
		.{ .signature = "fn decode<'a>(bytes: &'a [u8], callback: fn(u8,u8)->u8) -> Result<Vec<u16>, Error>", .matches = false },
	};
	for (cases) |case| try std.testing.expectEqual(case.matches, query.matches("decode", case.signature));
	try std.testing.expect(Query.parse("read : &std::path::Path -> ()").?.matches("read", "fn read(path: &std::path::Path)"));
	try std.testing.expect(Query.parse("Type::decode : -> Result<Vec<u8>, Error>").?.matches("Type/decode", cases[0].signature));
	try std.testing.expect(!Query.parse("Type::decode : -> Result<Vec<u8>, Error>").?.matches("Other/decode", cases[0].signature));
	try std.testing.expect(!query.matches("decoder", cases[0].signature));
	try std.testing.expect(Query.parse("r#type : -> ()").?.matches("r#type", "fn r#type()"));
	try std.testing.expect(Query.parse("ceil : -> f64").?.matches("ceil", "fn ceil() -> /* nested /* comment */ type */ f64"));
}

test "Rust signature parsing rejects unbalanced and unbounded source" {
	const cases = [_][]const u8{
		"fn bad<T() -> T", "bad : -> Vec<u8", "fn bad(x: [u8) -> u8",
		"fn bad() -> /* missing", "fn bad() -> &'", "bad : -> " ++ "Vec<" ** 65 ++ "u8" ++ ">" ** 65,
		"fn bad() /* missing", "fn bad() \"missing",
	};
	for (cases) |text| try std.testing.expect(Query.parse(text) == null);
}
