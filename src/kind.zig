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
