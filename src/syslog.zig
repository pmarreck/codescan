const std = @import("std");

pub const LOG_PID: c_int = 0x01;
pub const LOG_NDELAY: c_int = 0x08;

// facility
pub const LOG_DAEMON: c_int = 3 << 3;

// priorities
pub const LOG_ERR: c_int = 3;
pub const LOG_WARNING: c_int = 4;
pub const LOG_NOTICE: c_int = 5;

extern "c" fn openlog(ident: [*:0]const u8, option: c_int, facility: c_int) void;
extern "c" fn syslog(priority: c_int, format: [*:0]const u8, ...) void;
extern "c" fn closelog() void;

var initialized: bool = false;

pub fn init(ident: [*:0]const u8) void {
    openlog(ident, LOG_PID | LOG_NDELAY, LOG_DAEMON);
    initialized = true;
}

pub fn deinit() void {
    if (!initialized) return;
    closelog();
    initialized = false;
}

pub fn log(priority: c_int, message: []const u8) void {
    if (!initialized) return;
    var buf: [1024]u8 = undefined;
    const copy_len = @min(message.len, buf.len - 1);
    @memcpy(buf[0..copy_len], message[0..copy_len]);
    buf[copy_len] = 0;
    syslog(priority, "%s", @as([*:0]const u8, @ptrCast(&buf)));
}

pub fn logWithRoot(priority: c_int, root: []const u8, message: []const u8) void {
    if (!initialized) return;
    var buf: [1024]u8 = undefined;
    // Format: "<root>: <message>" truncated with "..." if overflow.
    const suffix = "...";
    var written: usize = 0;

    const root_copy = @min(root.len, buf.len - 1);
    @memcpy(buf[0..root_copy], root[0..root_copy]);
    written = root_copy;

    if (written + 2 <= buf.len - 1) {
        buf[written] = ':';
        buf[written + 1] = ' ';
        written += 2;
    }

    const remaining = buf.len - 1 - written;
    if (message.len <= remaining) {
        @memcpy(buf[written .. written + message.len], message);
        written += message.len;
    } else {
        const msg_room = if (remaining >= suffix.len) remaining - suffix.len else 0;
        @memcpy(buf[written .. written + msg_room], message[0..msg_room]);
        written += msg_room;
        const ellipsis_room = @min(suffix.len, buf.len - 1 - written);
        @memcpy(buf[written .. written + ellipsis_room], suffix[0..ellipsis_room]);
        written += ellipsis_room;
    }

    buf[written] = 0;
    syslog(priority, "%s", @as([*:0]const u8, @ptrCast(&buf)));
}

test "log before init is a no-op and does not crash" {
    // Do NOT call init(). Any of these must return without panicking.
    log(LOG_NOTICE, "should be dropped");
    logWithRoot(LOG_ERR, "/tmp/fake-root", "should also be dropped");
}

test "logWithRoot truncates messages longer than 1024 bytes with ellipsis" {
    // Init briefly so the formatting path runs (syslog call is made but
    // we don't assert on delivery — only that no crash occurs).
    init("codescan-test-truncate");
    defer deinit();

    var buf: [2048]u8 = undefined;
    for (&buf) |*b| b.* = 'x';
    logWithRoot(LOG_NOTICE, "/tmp/fake-root", &buf);
    // Implicit assertion: did not panic/segfault on >1024-byte input.
}
