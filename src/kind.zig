const std = @import("std");

pub const Kind = enum {
	code,
	doc,
	text,
	log,
};

pub fn parse(value: []const u8) ?Kind {
	if (std.mem.eql(u8, value, "code")) return .code;
	if (std.mem.eql(u8, value, "doc")) return .doc;
	if (std.mem.eql(u8, value, "text")) return .text;
	if (std.mem.eql(u8, value, "log")) return .log;
	return null;
}

pub fn name(kind: Kind) []const u8 {
	return switch (kind) {
		.code => "code",
		.doc => "doc",
		.text => "text",
		.log => "log",
	};
}


// ============================================================================
// Tests
// ============================================================================

test "name() returns stable user-facing strings (persistence contract)" {
	// LOCKED: these strings are persisted to .codescan/config and accepted by
	// CLI flags (`--type code/doc/text/log`). Changing any of them is a
	// breaking change for users with saved configs and shell aliases.
	try std.testing.expectEqualStrings("code", name(.code));
	try std.testing.expectEqualStrings("doc", name(.doc));
	try std.testing.expectEqualStrings("text", name(.text));
	try std.testing.expectEqualStrings("log", name(.log));
}

test "parse() roundtrips for every enum variant" {
	inline for (@typeInfo(Kind).@"enum".fields) |field| {
		const variant: Kind = @field(Kind, field.name);
		const parsed = parse(name(variant)) orelse {
			std.debug.print("parse({s}) returned null\n", .{field.name});
			return error.TestFailed;
		};
		try std.testing.expectEqual(variant, parsed);
	}
}

test "parse() returns null for unknown values" {
	try std.testing.expect(parse("") == null);
	try std.testing.expect(parse("CODE") == null); // case-sensitive
	try std.testing.expect(parse("script") == null);
	try std.testing.expect(parse("logfile") == null);
}

test "every Kind variant is exhaustively covered by name()" {
	// If a future variant is added without updating `name()`'s switch, the
	// compiler errors out on the switch expression itself. This test exists
	// to flag the situation at the test level so it shows up in CI summary
	// as a clear miss rather than a compile-only error.
	inline for (@typeInfo(Kind).@"enum".fields) |field| {
		const variant: Kind = @field(Kind, field.name);
		const label = name(variant);
		try std.testing.expect(label.len > 0);
	}
}

test "@intFromEnum values are stable (locked for any wire/binary use)" {
	// LOCKED for forward-compatibility of any future serialization that
	// uses the integer value. Adding a NEW variant is fine (append at end);
	// reordering or removing existing variants breaks the contract.
	try std.testing.expectEqual(@as(u2, 0), @intFromEnum(Kind.code));
	try std.testing.expectEqual(@as(u2, 1), @intFromEnum(Kind.doc));
	try std.testing.expectEqual(@as(u2, 2), @intFromEnum(Kind.text));
	try std.testing.expectEqual(@as(u2, 3), @intFromEnum(Kind.log));
}
