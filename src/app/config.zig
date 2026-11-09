//! Persistent custom resolver list. The file holds one numeric endpoint per
//! line; `#` starts a comment. Its path is `$XDG_CONFIG_HOME/whichdns/servers`
//! when XDG_CONFIG_HOME is an absolute path, else `$HOME/.config/whichdns/servers`.

const std = @import("std");
const core = @import("core");
const c = core.posix.c;
const net = core.net_util;
const inventory = @import("resolver_inventory.zig");

pub const file_name = "servers";
pub const max_path = 1024;
pub const max_file = 65536;

pub const PathError = error{ NoHome, NoSpaceLeft };
pub const ReadError = error{ ReadFailed, FileTooLarge, NoSpaceLeft };
pub const WriteError = error{ WriteFailed, NoSpaceLeft };
pub const EditError = error{ InvalidArgument, NoSpaceLeft };

/// Resolves the servers file path from the environment.
pub fn defaultPath(buf: []u8) PathError![]const u8 {
    return path(buf, env("XDG_CONFIG_HOME"), env("HOME"));
}

/// Resolves the servers file path from explicit environment values.
pub fn path(buf: []u8, xdg_config_home: ?[]const u8, home: ?[]const u8) PathError![]const u8 {
    if (xdg_config_home) |dir| if (isAbsolute(dir)) {
        return std.fmt.bufPrint(buf, "{s}/whichdns/" ++ file_name, .{dir}) catch error.NoSpaceLeft;
    };
    const home_dir = home orelse return error.NoHome;
    if (!isAbsolute(home_dir)) return error.NoHome;
    return std.fmt.bufPrint(buf, "{s}/.config/whichdns/" ++ file_name, .{home_dir}) catch error.NoSpaceLeft;
}

fn isAbsolute(dir: []const u8) bool {
    return dir.len != 0 and dir[0] == '/';
}

fn env(name: [*:0]const u8) ?[]const u8 {
    return std.mem.span(std.c.getenv(name) orelse return null);
}

/// Reads the file into `storage`. A missing file reads as empty text.
pub fn read(file_path: []const u8, storage: []u8) ReadError![]const u8 {
    var terminated: [max_path + 1]u8 = undefined;
    const name = std.fmt.bufPrintSentinel(&terminated, "{s}", .{file_path}, 0) catch return error.NoSpaceLeft;
    const stream = c.fopen(name, "r") orelse {
        if (lastErrno() == .NOENT) return "";
        return error.ReadFailed;
    };
    const size = c.fread(storage.ptr, 1, storage.len, stream);
    const read_failed = c.ferror(stream) != 0;
    _ = c.fclose(stream);
    if (read_failed) return error.ReadFailed;
    if (size == storage.len) return error.FileTooLarge;
    return storage[0..size];
}

/// Writes `text` to the file, creating missing parent directories.
pub fn write(file_path: []const u8, text: []const u8) WriteError!void {
    try createParents(file_path);
    var terminated: [max_path + 1]u8 = undefined;
    const name = std.fmt.bufPrintSentinel(&terminated, "{s}", .{file_path}, 0) catch return error.NoSpaceLeft;
    const stream = c.fopen(name, "w") orelse return error.WriteFailed;
    const written = c.fwrite(text.ptr, 1, text.len, stream);
    const closed = c.fclose(stream);
    if (written != text.len or closed != 0) return error.WriteFailed;
}

/// Creates each missing directory above the file with owner-only access.
fn createParents(file_path: []const u8) WriteError!void {
    var terminated: [max_path + 1]u8 = undefined;
    for (file_path, 0..) |byte, i| {
        if (byte != '/' or i == 0) continue;
        const dir = std.fmt.bufPrintSentinel(&terminated, "{s}", .{file_path[0..i]}, 0) catch return error.NoSpaceLeft;
        if (c.mkdir(dir, 0o700) != 0 and lastErrno() != .EXIST) return error.WriteFailed;
    }
}

fn lastErrno() std.c.E {
    return @enumFromInt(std.c._errno().*);
}

/// One endpoint entry with its 1-based line number.
pub const Line = struct { number: usize, text: []const u8 };

/// Iterates endpoint entries, skipping blank lines and comments.
pub const Lines = struct {
    rest: []const u8,
    number: usize = 0,

    pub fn next(self: *Lines) ?Line {
        while (self.rest.len != 0) {
            const raw = nextRaw(&self.rest);
            self.number += 1;
            const text = entryText(raw);
            if (text.len != 0) return .{ .number = self.number, .text = text };
        }
        return null;
    }
};

pub fn lines(text: []const u8) Lines {
    return .{ .rest = text };
}

/// Returns the next line including its newline and advances `rest`.
fn nextRaw(rest: *[]const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, rest.*, '\n');
    const raw = if (end) |e| rest.*[0 .. e + 1] else rest.*;
    rest.* = rest.*[raw.len..];
    return raw;
}

/// The endpoint text of one raw line without comment or surrounding space.
fn entryText(raw: []const u8) []const u8 {
    const uncommented = raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len];
    return std.mem.trim(u8, uncommented, " \t\r\n");
}

/// What an edit did with one requested endpoint.
pub const Change = enum {
    added,
    already_present,
    removed,
    absent,

    pub fn label(self: Change) []const u8 {
        return @tagName(self);
    }
};

/// Appends each endpoint that `text` does not already contain. Comparison is
/// numeric, so `1.1.1.1` matches `1.1.1.1:53`. Returns the new file text.
pub fn addEndpoints(
    text: []const u8,
    endpoints: []const []const u8,
    changes: []Change,
    out: []u8,
) EditError![]const u8 {
    var w = std.Io.Writer.fixed(out);
    w.writeAll(text) catch return error.NoSpaceLeft;
    if (text.len != 0 and text[text.len - 1] != '\n') w.writeByte('\n') catch return error.NoSpaceLeft;
    for (endpoints, changes) |endpoint, *change| {
        const address = try addressOf(endpoint);
        if (contains(w.buffered(), &address)) {
            change.* = .already_present;
        } else {
            w.print("{s}\n", .{endpoint}) catch return error.NoSpaceLeft;
            change.* = .added;
        }
    }
    return w.buffered();
}

/// Drops every entry line that numerically matches one of `endpoints`.
/// Comments, blank lines, and unparsable lines are kept. Returns the new text.
pub fn removeEndpoints(
    text: []const u8,
    endpoints: []const []const u8,
    changes: []Change,
    out: []u8,
) EditError![]const u8 {
    var addresses: [inventory.max_custom_servers]net.Address = undefined;
    if (endpoints.len > addresses.len) return error.InvalidArgument;
    for (endpoints, changes, 0..) |endpoint, *change, i| {
        addresses[i] = try addressOf(endpoint);
        change.* = .absent;
    }
    var w = std.Io.Writer.fixed(out);
    var rest = text;
    while (rest.len != 0) {
        const raw = nextRaw(&rest);
        if (!matchesAny(entryText(raw), addresses[0..endpoints.len], changes)) {
            w.writeAll(raw) catch return error.NoSpaceLeft;
        }
    }
    return w.buffered();
}

fn addressOf(endpoint: []const u8) error{InvalidArgument}!net.Address {
    const server = inventory.parseEndpoint(endpoint) catch return error.InvalidArgument;
    return net.parseAddress(server) catch error.InvalidArgument;
}

/// True when some entry of `text` is numerically `address`.
fn contains(text: []const u8, address: *const net.Address) bool {
    var it = lines(text);
    while (it.next()) |line| {
        const existing = addressOf(line.text) catch continue;
        if (net.sameEndpoint(&existing, address)) return true;
    }
    return false;
}

/// Marks every requested address equal to `entry` as removed.
fn matchesAny(entry: []const u8, addresses: []const net.Address, changes: []Change) bool {
    if (entry.len == 0) return false;
    const address = addressOf(entry) catch return false;
    var matched = false;
    for (addresses, changes) |*requested, *change| {
        if (!net.sameEndpoint(requested, &address)) continue;
        change.* = .removed;
        matched = true;
    }
    return matched;
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "path prefers an absolute XDG_CONFIG_HOME and falls back to HOME" {
    var buf: [max_path]u8 = undefined;
    try expectEqualStrings("/xdg/whichdns/servers", try path(&buf, "/xdg", "/home/me"));
    try expectEqualStrings("/home/me/.config/whichdns/servers", try path(&buf, "relative", "/home/me"));
    try expectEqualStrings("/home/me/.config/whichdns/servers", try path(&buf, "", "/home/me"));
    try expectEqualStrings("/home/me/.config/whichdns/servers", try path(&buf, null, "/home/me"));
    try std.testing.expectError(error.NoHome, path(&buf, null, null));
    try std.testing.expectError(error.NoHome, path(&buf, null, "me"));
    var short: [8]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, path(&short, null, "/home/me"));
}

test "lines skip comments and blanks and number every physical line" {
    var it = lines("# header\n\n1.1.1.1 # primary\r\n  [::1]:5353  \n9.9.9.9");
    const first = it.next().?;
    try expectEqual(3, first.number);
    try expectEqualStrings("1.1.1.1", first.text);
    const second = it.next().?;
    try expectEqual(4, second.number);
    try expectEqualStrings("[::1]:5353", second.text);
    try expectEqualStrings("9.9.9.9", it.next().?.text);
    try expect(it.next() == null);
}

test "add appends missing endpoints once and keeps existing text" {
    var out: [256]u8 = undefined;
    var changes: [3]Change = undefined;
    const text = try addEndpoints("# mine\n1.1.1.1", &.{ "1.1.1.1:53", "8.8.8.8", "8.8.8.8:53" }, &changes, &out);
    try expectEqualStrings("# mine\n1.1.1.1\n8.8.8.8\n", text);
    try expectEqual(Change.already_present, changes[0]);
    try expectEqual(Change.added, changes[1]);
    try expectEqual(Change.already_present, changes[2]);
    try std.testing.expectError(error.InvalidArgument, addEndpoints("", &.{"localhost"}, changes[0..1], &out));
    var tiny: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, addEndpoints("", &.{"1.1.1.1"}, changes[0..1], &tiny));
}

test "remove drops matching entries and reports absent ones" {
    var out: [256]u8 = undefined;
    var changes: [2]Change = undefined;
    const text = try removeEndpoints("# keep\n1.1.1.1\n[::1]:5353 # local\nbogus\n8.8.8.8", &.{ "0:0:0:0:0:0:0:1", "[::1]:5353" }, &changes, &out);
    try expectEqualStrings("# keep\n1.1.1.1\nbogus\n8.8.8.8", text);
    try expectEqual(Change.absent, changes[0]);
    try expectEqual(Change.removed, changes[1]);
}

test "read and write round-trip through a real file and create directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [max_path]u8 = undefined;
    const dir_path = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    var buf: [max_path]u8 = undefined;
    const file_path = try path(&buf, dir_path, null);
    var storage: [max_file]u8 = undefined;
    try expectEqualStrings("", try read(file_path, &storage));
    try write(file_path, "1.1.1.1\n");
    try expectEqualStrings("1.1.1.1\n", try read(file_path, &storage));
    try write(file_path, "");
    try expectEqualStrings("", try read(file_path, &storage));
    try std.testing.expectError(error.ReadFailed, read(dir_path, &storage));
}
