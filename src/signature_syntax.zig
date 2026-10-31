const std = @import("std");

pub const Dialect = enum { zig, rust };
pub const Zig = Syntax(.zig);
pub const Rust = Syntax(.rust);

fn Syntax(comptime dialect: Dialect) type {
	return struct {
		pub fn trim(text: []const u8) []const u8 {
			return std.mem.trim(u8, text, " \t\r\n");
		}

		pub fn word(ch: u8) bool {
			return std.ascii.isAlphanumeric(ch) or ch == '_' or ch >= 128;
		}

		pub const Tokens = struct {
			text: []const u8,
			offset: usize = 0,
			invalid: bool = false,

			pub fn next(self: *Tokens) ?[]const u8 {
				while (self.offset < self.text.len) {
					if (std.ascii.isWhitespace(self.text[self.offset])) {
						self.offset += 1;
					} else if (std.mem.startsWith(u8, self.text[self.offset..], "//")) {
						while (self.offset < self.text.len and self.text[self.offset] != '\n') self.offset += 1;
					} else if (dialect == .rust and std.mem.startsWith(u8, self.text[self.offset..], "/*")) {
						self.offset += 2;
						var depth: usize = 1;
						while (self.offset + 1 < self.text.len and depth > 0) {
							if (std.mem.startsWith(u8, self.text[self.offset..], "/*")) {
								depth += 1;
								self.offset += 2;
							} else if (std.mem.startsWith(u8, self.text[self.offset..], "*/")) {
								depth -= 1;
								self.offset += 2;
							} else self.offset += 1;
						}
						if (depth != 0) {
							self.invalid = true;
							return null;
						}
					} else break;
				}
				if (self.offset == self.text.len) return null;
				const start = self.offset;
				self.offset += 1;
				if (dialect == .rust) {
					for ([_][]const u8{ "->", "::" }) |operator| {
						if (std.mem.startsWith(u8, self.text[start..], operator)) {
							self.offset = start + operator.len;
							return self.text[start..self.offset];
						}
					}
					if (self.text[start] == '\'') {
						var end = self.offset;
						while (end < self.text.len and word(self.text[end])) end += 1;
						if (end > self.offset and (end == self.text.len or self.text[end] != '\'')) {
							self.offset = end;
							return self.text[start..end];
						}
					}
					if (std.mem.startsWith(u8, self.text[start..], "r#") and start + 2 < self.text.len and word(self.text[start + 2])) {
						self.offset = start + 2;
						while (self.offset < self.text.len and word(self.text[self.offset])) self.offset += 1;
						return self.text[start..self.offset];
					}
				}
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
		pub fn topLevelEnd(text: []const u8, stop: u8) ?usize {
			return topLevelToken(text, &.{stop});
		}

		pub fn topLevelToken(text: []const u8, stop: []const u8) ?usize {
			var tokens = Tokens{ .text = text };
			var stack: [64]u8 = undefined;
			var depth: usize = 0;
			var braces: usize = 0;
			while (tokens.next()) |token| {
				if (depth == 0 and std.mem.eql(u8, token, stop)) return tokens.offset - token.len;
				if (token.len != 1) continue;
				const ch = token[0];
				const angle = dialect == .rust and braces == 0;
				if (ch == '(' or ch == '[' or ch == '{' or (angle and ch == '<')) {
					if (depth == stack.len) return null;
					stack[depth] = ch;
					depth += 1;
					if (ch == '{') braces += 1;
				} else if (ch == ')' or ch == ']' or ch == '}' or (angle and ch == '>')) {
					if (depth == 0) return null;
					const opening: u8 = switch (ch) { ')' => '(', ']' => '[', '>' => '<', else => '{' };
					depth -= 1;
					if (stack[depth] != opening) return null;
					if (ch == '}') braces -= 1;
				}
			}
			return if (depth == 0 and !tokens.invalid) text.len else null;
		}

		pub fn validTypes(text: []const u8) bool {
			if (topLevelEnd(text, 0) == null) return false;
			if (dialect == .rust and (typesEqual(text, "()") or typesEqual(text, "!"))) return true;
			var tokens = Tokens{ .text = text };
			while (tokens.next()) |token| if (word(token[0]) or token[0] == '@') return true;
			return false;
		}

		pub fn typesEqual(a: []const u8, b: []const u8) bool {
			var at = Tokens{ .text = a };
			var bt = Tokens{ .text = b };
			while (at.next()) |token| {
				if (!std.mem.eql(u8, token, bt.next() orelse return false)) return false;
			}
			return bt.next() == null and !at.invalid and !bt.invalid;
		}

		pub fn namesEqual(query: []const u8, name: []const u8) bool {
			const candidate = if (std.mem.indexOfAny(u8, query, "./") != null) name else
				name[(if (std.mem.lastIndexOfAny(u8, name, "./")) |i| i + 1 else 0)..];
			if (query.len != candidate.len) return false;
			for (query, candidate) |a, b| if ((if (a == '.') '/' else a) != (if (b == '.') '/' else b)) return false;
			return true;
		}

		pub const Parameters = struct {
			text: []const u8,
			pub fn next(self: *Parameters) ?[]const u8 {
				var tokens = Tokens{ .text = self.text };
				if (tokens.next() == null) return null;
				const end = topLevelEnd(self.text, ',') orelse return null;
				const parameter = self.text[0..end];
				self.text = if (end == self.text.len) "" else self.text[end + 1 ..];
				return parameter;
			}
		};

		pub fn parameterType(text: []const u8) []const u8 {
			const colon = topLevelEnd(text, ':') orelse return text;
			return if (colon == text.len) text else text[colon + 1 ..];
		}
	};
}
