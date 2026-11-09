//! Allocation-free number formatting shared by the dashboard and report.
//!
//! Every function panics if `buf` cannot hold its result. Callers size their
//! buffers for the largest value, so a short buffer is a bug, not a
//! condition to render as an empty cell.

const std = @import("std");
const DnsServer = @import("core").types.DnsServer;

/// Formats into `buf`. Panics when `buf` is too small for the result.
pub fn print(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch @panic("format buffer too small");
}

/// Formats an unsigned integer in base 10.
pub fn unsigned(buf: []u8, value: u64) []const u8 {
    return print(buf, "{d}", .{value});
}

/// Formats microseconds as milliseconds with one fractional digit.
pub fn ms(buf: []u8, us: u64) []const u8 {
    return print(buf, "{d}.{d}", .{ us / 1000, (us % 1000) / 100 });
}

/// Formats milliseconds as seconds with one fractional digit.
pub fn seconds(buf: []u8, ms_value: u64) []const u8 {
    return print(buf, "{d}.{d}", .{ ms_value / 1000, (ms_value % 1000) / 100 });
}

/// Formats a duration in seconds as `m:ss`.
pub fn clock(buf: []u8, total_seconds: u64) []const u8 {
    return print(buf, "{d}:{d:0>2}", .{ total_seconds / 60, total_seconds % 60 });
}

/// Formats a whole-number percentage with its sign.
pub fn percent(buf: []u8, value: u64) []const u8 {
    return print(buf, "{d}%", .{value});
}

/// Labels the current DNS source wherever a resolver name is displayed.
pub fn resolverName(buf: []u8, server: DnsServer) []const u8 {
    if (!server.system) return server.name;
    return print(buf, "[system] {s}", .{server.name});
}

/// Keeps distinct nonstandard ports visible, including IPv6 endpoints.
pub fn endpoint(buf: []u8, server: DnsServer) []const u8 {
    if (server.port == 53) return server.target;
    return if (std.mem.indexOfScalar(u8, server.target, ':') != null)
        print(buf, "[{s}]:{d}", .{ server.target, server.port })
    else
        print(buf, "{s}:{d}", .{ server.target, server.port });
}

pub const Alignment = enum { left, right };

/// Writes text truncated or padded to `width` columns.
pub fn writePadded(w: *std.Io.Writer, text: []const u8, width: usize, alignment: Alignment) std.Io.Writer.Error!void {
    const shown = @min(text.len, width);
    if (alignment == .right) try w.splatByteAll(' ', width - shown);
    try w.writeAll(text[0..shown]);
    if (alignment == .left) try w.splatByteAll(' ', width - shown);
}

/// Writes an unsigned integer right-aligned in `width` columns.
pub fn writeUnsignedPadded(w: *std.Io.Writer, value: u64, width: usize) std.Io.Writer.Error!void {
    var buf: [20]u8 = undefined;
    try writePadded(w, unsigned(buf[0..], value), width, .right);
}

/// Writes an unsigned integer with no padding.
pub fn writeUnsigned(w: *std.Io.Writer, value: u64) std.Io.Writer.Error!void {
    var buf: [20]u8 = undefined;
    try w.writeAll(unsigned(buf[0..], value));
}

const expectEqualStrings = std.testing.expectEqualStrings;

test "milliseconds keep one decimal" {
    var buf: [32]u8 = undefined;
    try expectEqualStrings("14.2", ms(buf[0..], 14_250));
    try expectEqualStrings("0.0", ms(buf[0..], 0));
}

test "seconds keep one decimal" {
    var buf: [32]u8 = undefined;
    try expectEqualStrings("14.5", seconds(buf[0..], 14_506));
}

test "clock pads seconds" {
    var buf: [32]u8 = undefined;
    try expectEqualStrings("1:04", clock(buf[0..], 64));
    try expectEqualStrings("0:00", clock(buf[0..], 0));
}

test "padded text truncates and aligns" {
    var storage: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(storage[0..]);
    try writePadded(&w, "abcdef", 4, .left);
    try writePadded(&w, "ab", 4, .right);
    try expectEqualStrings("abcd  ab", w.buffered());
}

test "padding propagates writer failure" {
    var w = std.Io.Writer.fixed(&.{});
    const result: std.Io.Writer.Error!void = writePadded(&w, "x", 4, .right);
    try std.testing.expectError(error.WriteFailed, result);
}
