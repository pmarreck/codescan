const std = @import("std");

/// An empty parameter list in a query leaves the inputs unspecified. Return
/// types and effect arrows still match exactly; this does not infer Roc types.
pub const Query = struct {
	name: []const u8,
	parameters: []const u8,
	arrow: []const u8,
	output: []const u8,

	pub fn parse(text: []const u8) ?Query {
		const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
		const name = trim(text[0..colon]);
		if (name.len == 0) return null;
		var segment_start = true;
		for (name) |ch| {
			if (ch == '.' or ch == '/') {
				if (segment_start) return null;
				segment_start = true;
			} else {
				if (!word(ch)) return null;
				segment_start = false;
			}
		}
		if (segment_start) return null;
		const types = text[colon + 1 ..];
		var depth: usize = 0;
		var comment = false;
		for (types, 0..) |ch, i| {
			if (comment) {
				if (ch == '\n') comment = false;
				continue;
			}
			if (ch == '#') {
				comment = true;
				continue;
			}
			if (ch == '(' or ch == '[' or ch == '{') depth += 1;
			if (ch == ')' or ch == ']' or ch == '}') {
				if (depth == 0) return null;
				depth -= 1;
			}
			if (depth == 0 and (ch == '-' or ch == '=') and i + 1 < types.len and types[i + 1] == '>') {
				const output = trim(types[i + 2 ..]);
				if (output.len == 0) return null;
				return .{ .name = name, .parameters = trim(types[0..i]), .arrow = types[i .. i + 2], .output = output };
			}
		}
		return null;
	}

	pub fn matches(self: Query, name: []const u8, signature: []const u8) bool {
		const qualified = std.mem.indexOfAny(u8, self.name, "./") != null;
		const candidate = if (qualified) name else name[(if (std.mem.lastIndexOfAny(u8, name, "./")) |i| i + 1 else 0)..];
		if (self.name.len != candidate.len) return false;
		for (self.name, candidate) |a, b| {
			if ((if (a == '.') '/' else a) != (if (b == '.') '/' else b)) return false;
		}
		const declaration = parse(signature) orelse return false;
		return std.mem.eql(u8, self.arrow, declaration.arrow) and
			(self.parameters.len == 0 or typesEqual(self.parameters, declaration.parameters)) and
			typesEqual(self.output, declaration.output);
	}
};

fn trim(text: []const u8) []const u8 {
	return std.mem.trim(u8, text, " \t\r\n");
}

fn word(ch: u8) bool {
	return std.ascii.isAlphanumeric(ch) or ch == '_' or ch >= 128;
}

fn token(text: []const u8, offset: *usize) ?[]const u8 {
	while (offset.* < text.len) {
		if (std.ascii.isWhitespace(text[offset.*])) {
			offset.* += 1;
		} else if (text[offset.*] == '#') {
			while (offset.* < text.len and text[offset.*] != '\n') offset.* += 1;
		} else break;
	}
	if (offset.* == text.len) return null;
	const start = offset.*;
	offset.* += 1;
	if (word(text[start])) {
		while (offset.* < text.len and word(text[offset.*])) offset.* += 1;
	}
	return text[start..offset.*];
}

fn typesEqual(a: []const u8, b: []const u8) bool {
	var ai: usize = 0;
	var bi: usize = 0;
	while (token(a, &ai)) |at| {
		const bt = token(b, &bi) orelse return false;
		if (!std.mem.eql(u8, at, bt)) return false;
	}
	return token(b, &bi) == null;
}

test "Roc query recognition classifies signatures and ordinary searches" {
	const cases = [_]struct { text: []const u8, recognized: bool }{
		.{ .text = "ceil : -> Dec", .recognized = true },
		.{ .text = " Dec.ceil : Dec -> Dec ", .recognized = true },
		.{ .text = "ceil : (Dec -> Str), Dec => Dec", .recognized = true },
		.{ .text = "ceil", .recognized = false },
		.{ .text = "find ceil : -> Dec", .recognized = false },
		.{ .text = "ceil : Dec", .recognized = false },
		.{ .text = "ceil : ->", .recognized = false },
		.{ .text = ": -> Dec", .recognized = false },
		.{ .text = "Dec..ceil : -> Dec", .recognized = false },
		.{ .text = "ceil : (Dec -> Dec", .recognized = false },
	};
	for (cases) |case| try std.testing.expectEqual(case.recognized, Query.parse(case.text) != null);
}

test "Roc signature matching preserves type token and effect boundaries" {
	const query = Query.parse("ceil : List ( Dec ) => List Dec").?;
	try std.testing.expect(query.matches("Dec/ceil", "ceil : List(Dec) => List\tDec"));
	try std.testing.expect(!query.matches("ceil", "ceil : List(Dec) => ListDec"));
	try std.testing.expect(!query.matches("ceil", "ceil : List(Dec) -> List Dec"));
	try std.testing.expect(!query.matches("ceil", "ceil : Dec => List Dec"));
}

test "Roc signature matching ignores annotation comments" {
	const query = Query.parse("ceil : -> Dec").?;
	try std.testing.expect(query.matches("ceil", "ceil : # (a misleading -> Str)\n\tDec -> Dec # round up"));
}
