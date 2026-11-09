//! Terminal plumbing: buffered stdout and stderr, color detection, ANSI
//! styles, cursor visibility, and cleanup on Ctrl-C.
//!
//! Write failures propagate to the application exit status.

const std = @import("std");

const c = @import("core").posix.c;

var stdout_buffer: [8192]u8 = undefined;
pub var stdout = std.Io.Writer{
    .vtable = &.{ .drain = stdoutDrain },
    .buffer = &stdout_buffer,
};

var stderr_buffer: [1024]u8 = undefined;
pub var stderr = std.Io.Writer{
    .vtable = &.{ .drain = stderrDrain },
    .buffer = &stderr_buffer,
};

fn stdoutDrain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    return drainTo(1, w, data, splat);
}

fn stderrDrain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    return drainTo(2, w, data, splat);
}

/// Writes buffered and vectored data to `fd` with `write(2)`.
fn drainTo(fd: c_int, w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    if (w.buffered().len != 0) return w.consume(try writeFd(fd, w.buffered()));
    if (data.len == 0) return 0;
    for (data[0 .. data.len - 1]) |bytes| {
        if (bytes.len != 0) return try writeFd(fd, bytes);
    }
    const pattern = data[data.len - 1];
    if (splat != 0 and pattern.len != 0) return try writeFd(fd, pattern);
    return 0;
}

/// Makes one successful write, retrying only interrupted system calls.
fn writeFd(fd: c_int, bytes: []const u8) std.Io.Writer.Error!usize {
    while (true) {
        const written = c.write(fd, bytes.ptr, bytes.len);
        if (written > 0) return @intCast(written);
        if (std.c.errno(written) == .INTR) continue;
        return error.WriteFailed;
    }
}

pub fn flushAll() std.Io.Writer.Error!void {
    // Attempt both streams even when one fails.
    const stdout_result = stdout.flush();
    const stderr_result = stderr.flush();
    try stdout_result;
    try stderr_result;
}

// ---------------------------------------------------------------------------
// Styles

pub const Style = enum {
    reset,
    bold,
    dim,
    green,
    yellow,
    cyan,

    pub fn code(self: Style) []const u8 {
        return switch (self) {
            .reset => "\x1b[0m",
            .bold => "\x1b[1m",
            .dim => "\x1b[2m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .cyan => "\x1b[36m",
        };
    }
};

/// Rendering choices belong to each report or dashboard, not global state.
pub const RenderStyle = struct {
    color: bool = false,

    pub fn style(self: RenderStyle, w: *std.Io.Writer, s: Style) std.Io.Writer.Error!void {
        if (self.color) try w.writeAll(s.code());
    }

    pub fn styled(self: RenderStyle, w: *std.Io.Writer, s: Style, text: []const u8) std.Io.Writer.Error!void {
        try self.style(w, s);
        try w.writeAll(text);
        try self.style(w, .reset);
    }
};

/// Cursor addressing needs both a terminal and a usable TERM setting.
pub fn isInteractive() bool {
    return c.isatty(1) == 1 and supportsDashboard(getenv("TERM"));
}

fn supportsDashboard(value: ?[]const u8) bool {
    const terminal = value orelse return false;
    return terminal.len != 0 and !std.mem.eql(u8, terminal, "dumb");
}

pub const Dimensions = struct { columns: usize = 80, rows: usize = 24 };
pub fn dimensions() Dimensions {
    var size: c.struct_winsize = std.mem.zeroes(c.struct_winsize);
    if (c.ioctl(1, c.TIOCGWINSZ, &size) != 0) return .{};
    return .{
        .columns = if (size.ws_col == 0) 80 else size.ws_col,
        .rows = if (size.ws_row == 0) 24 else size.ws_row,
    };
}

/// Decides whether to emit color: a TTY, no `--no-color`, `NO_COLOR` unset,
/// and `TERM` not `dumb`.
pub fn detectColor(no_color_flag: bool) bool {
    if (no_color_flag) return false;
    if (!isInteractive()) return false;
    if (getenv("NO_COLOR")) |value| {
        if (value.len != 0) return false;
    }
    if (getenv("TERM")) |term| {
        if (std.mem.eql(u8, term, "dumb")) return false;
    }
    return true;
}

/// True when the active locale names a UTF-8 character set.
pub fn utf8Locale() bool {
    const names = [_][*:0]const u8{ "LC_ALL", "LC_CTYPE", "LANG" };
    for (names) |name| {
        const value = getenv(name) orelse continue;
        if (value.len == 0) continue;
        return localeIsUtf8(value);
    }
    return false;
}

fn localeIsUtf8(value: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(value, "utf-8") != null or
        std.ascii.indexOfIgnoreCase(value, "utf8") != null;
}

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const raw = c.getenv(name) orelse return null;
    return std.mem.span(raw);
}

// ---------------------------------------------------------------------------
// Cursor and interrupt handling

const cursor_hide = "\x1b[?25l";
const cursor_show = "\x1b[?25h";
var dashboard_active = false;

pub fn beginDashboard(w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (dashboard_active) return;
    dashboard_active = true;
    try w.writeAll(cursor_hide);
    try w.flush();
}

pub fn endDashboard(w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (!dashboard_active) return;
    try w.writeAll(cursor_show ++ "\x1b[0m");
    try w.flush();
    dashboard_active = false;
}

/// Restores the cursor and colors if the user interrupts a live dashboard.
/// The last frame stays on screen, and the shell prompt starts below it.
pub fn installInterruptRestore() void {
    _ = c.signal(c.SIGINT, onInterrupt);
    _ = c.signal(c.SIGTERM, onInterrupt);
}

fn onInterrupt(signal: c_int) callconv(.c) void {
    const restore = cursor_show ++ "\x1b[0m\n";
    if (dashboard_active) _ = c.write(1, restore, restore.len);
    c._exit(128 + signal);
}

const expect = std.testing.expect;

test "locale detection accepts common UTF-8 spellings" {
    try expect(localeIsUtf8("en_US.UTF-8"));
    try expect(localeIsUtf8("C.utf8"));
    try expect(!localeIsUtf8("C"));
    try expect(!localeIsUtf8("POSIX"));
}

test "styles are silent when color is off" {
    var storage: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(storage[0..]);
    try (RenderStyle{}).styled(&w, .bold, "x");
    try std.testing.expectEqualStrings("x", w.buffered());
}

test "drain reports a bad descriptor without consuming buffered bytes" {
    var storage: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&storage);
    try w.writeAll("pending");
    try std.testing.expectError(error.WriteFailed, drainTo(-1, &w, &.{}, 0));
    try std.testing.expectEqualStrings("pending", w.buffered());
}

test "styles are independent for interleaved renders" {
    var storage: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&storage);
    const colored = RenderStyle{ .color = true };
    const plain = RenderStyle{};
    try colored.styled(&w, .bold, "a");
    try plain.styled(&w, .bold, "b");
    try colored.styled(&w, .green, "c");
    try std.testing.expectEqualStrings("\x1b[1ma\x1b[0mb\x1b[32mc\x1b[0m", w.buffered());
}

test "partial drain consumes exactly the bytes written" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(0, c.pipe(&fds));
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    try std.testing.expectEqual(0, c.fcntl(fds[1], c.F_SETFL, @as(c_int, c.O_NONBLOCK)));

    var storage: [1024 * 1024]u8 = @splat('x');
    var w = std.Io.Writer.fixed(&storage);
    w.end = storage.len;
    try std.testing.expectEqual(@as(usize, 0), try drainTo(fds[1], &w, &.{}, 0));
    const transferred = storage.len - w.end;
    try expect(transferred > 0 and transferred < storage.len);
    var received: [1024 * 1024]u8 = undefined;
    const count = c.read(fds[0], &received, received.len);
    try std.testing.expectEqual(transferred, @as(usize, @intCast(count)));
    try std.testing.expectEqualSlices(u8, storage[0..transferred], received[0..transferred]);
}

test "dumb empty and absent TERM disable cursor addressing" {
    try expect(!supportsDashboard(null));
    try expect(!supportsDashboard(""));
    try expect(!supportsDashboard("dumb"));
    try expect(supportsDashboard("xterm-256color"));
}

test "dashboard lifecycle restores the cursor once" {
    const saved_active = dashboard_active;
    defer dashboard_active = saved_active;
    dashboard_active = false;
    var storage: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&storage);
    try beginDashboard(&w);
    try beginDashboard(&w);
    try endDashboard(&w);
    try endDashboard(&w);
    try std.testing.expectEqualStrings(cursor_hide ++ cursor_show ++ "\x1b[0m", w.buffered());
    try expect(!dashboard_active);
}
