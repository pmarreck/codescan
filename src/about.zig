const std = @import("std");

pub const Platform = struct {
	pf: []const u8,
	variant: ?[]const u8,
};

pub fn forTarget(os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch, abi: std.Target.Abi) ?Platform {
	const pf: []const u8 = switch (os) {
		.linux => switch (arch) {
			.x86_64 => "linux-amd64",
			.aarch64 => "linux-arm64",
			else => return null,
		},
		.windows => switch (arch) {
			.x86_64 => "mswin-amd64",
			.aarch64 => "mswin-arm64",
			else => return null,
		},
		.macos => if (arch == .aarch64) "macos-arm64" else return null,
		else => return null,
	};
	const variant: ?[]const u8 = switch (os) {
		.linux => switch (abi) {
			.gnu => "gnu",
			.musl => "musl",
			else => return null,
		},
		.windows => if (abi == .gnu) "gnu" else return null,
		.macos => if (abi == .none) null else return null,
		else => unreachable,
	};
	return .{ .pf = pf, .variant = variant };
}

pub fn format(allocator: std.mem.Allocator, version: []const u8, platform: Platform) ![]u8 {
	if (platform.variant) |variant| {
		return std.fmt.allocPrint(allocator, "codescan {s} - Semantic code search and targeted edits; PF={s} VARIANT={s}\n", .{ version, platform.pf, variant });
	}
	return std.fmt.allocPrint(allocator, "codescan {s} - Semantic code search and targeted edits; PF={s}\n", .{ version, platform.pf });
}

test "compilation platform classifier covers exactly the declared target variants" {
	const Case = struct { os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch, abi: std.Target.Abi, pf: []const u8, variant: ?[]const u8 };
	const allowed = [_]Case{
		.{ .os = .linux, .arch = .x86_64, .abi = .gnu, .pf = "linux-amd64", .variant = "gnu" },
		.{ .os = .linux, .arch = .x86_64, .abi = .musl, .pf = "linux-amd64", .variant = "musl" },
		.{ .os = .linux, .arch = .aarch64, .abi = .gnu, .pf = "linux-arm64", .variant = "gnu" },
		.{ .os = .linux, .arch = .aarch64, .abi = .musl, .pf = "linux-arm64", .variant = "musl" },
		.{ .os = .windows, .arch = .x86_64, .abi = .gnu, .pf = "mswin-amd64", .variant = "gnu" },
		.{ .os = .windows, .arch = .aarch64, .abi = .gnu, .pf = "mswin-arm64", .variant = "gnu" },
		.{ .os = .macos, .arch = .aarch64, .abi = .none, .pf = "macos-arm64", .variant = null },
	};
	var accepted: usize = 0;
	for ([_]std.Target.Os.Tag{ .linux, .macos, .windows, .freebsd }) |os| {
		for ([_]std.Target.Cpu.Arch{ .x86_64, .aarch64, .arm }) |arch| {
			for ([_]std.Target.Abi{ .gnu, .musl, .none, .msvc }) |abi| {
				var expected: ?Case = null;
				for (allowed) |case| {
					if (case.os == os and case.arch == arch and case.abi == abi) expected = case;
				}
				const actual = forTarget(os, arch, abi);
				if (expected) |case| {
					try std.testing.expect(actual != null);
					try std.testing.expectEqualStrings(case.pf, actual.?.pf);
					if (case.variant) |variant| {
						try std.testing.expectEqualStrings(variant, actual.?.variant.?);
					} else try std.testing.expect(actual.?.variant == null);
					accepted += 1;
				} else try std.testing.expect(actual == null);
			}
		}
	}
	try std.testing.expectEqual(allowed.len, accepted);
}

test "about rendering is one line with an optional separate ABI variant" {
	const cases = [_]struct { platform: Platform, expected: []const u8 }{
		.{ .platform = .{ .pf = "linux-amd64", .variant = "musl" }, .expected = "codescan 1.2.3 - Semantic code search and targeted edits; PF=linux-amd64 VARIANT=musl\n" },
		.{ .platform = .{ .pf = "macos-arm64", .variant = null }, .expected = "codescan 1.2.3 - Semantic code search and targeted edits; PF=macos-arm64\n" },
		.{ .platform = .{ .pf = "mswin-arm64", .variant = "gnu" }, .expected = "codescan 1.2.3 - Semantic code search and targeted edits; PF=mswin-arm64 VARIANT=gnu\n" },
	};
	for (cases) |case| {
		const text = try format(std.testing.allocator, "1.2.3", case.platform);
		defer std.testing.allocator.free(text);
		try std.testing.expectEqualStrings(case.expected, text);
	}
}
