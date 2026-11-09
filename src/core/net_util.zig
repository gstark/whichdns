//! Allocation-free timing, numeric IPv4/IPv6 socket setup, and transport errors.

const std = @import("std");
const dns_packet = @import("dns_packet.zig");
const types = @import("types.zig");
const posix = @import("posix.zig");
const c = posix.c;

pub const SocketError = error{ InvalidArgument, SocketFailure, ConnectionRefused, Timeout, WouldBlock };

/// CLOCK_MONOTONIC is a platform invariant; failure cannot produce a valid sample.
pub fn nowUs() u64 {
    // SAFETY: clock_gettime initializes now on success; failure panics before reads.
    var now: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &now) != 0) @panic("CLOCK_MONOTONIC unavailable");
    return (@as(u64, @intCast(now.sec)) * 1_000_000) + @as(u64, @intCast(@divTrunc(now.nsec, 1000)));
}

pub fn elapsedSince(started_us: u64) u64 {
    return nowUs() -| started_us;
}

/// Complete the remaining sleep after signals interrupt nanosleep.
pub fn sleepUs(microseconds: u64) void {
    var request = std.c.timespec{
        .sec = @intCast(microseconds / 1_000_000),
        .nsec = @intCast((microseconds % 1_000_000) * 1000),
    };
    while (true) {
        // SAFETY: nanosleep initializes remaining on EINTR, the only branch that reads it.
        var remaining: std.c.timespec = undefined;
        switch (posix.errno(std.c.nanosleep(&request, &remaining))) {
            .SUCCESS => return,
            .INTR => request = remaining,
            else => @panic("nanosleep failed for a valid duration"),
        }
    }
}

/// Numeric socket endpoint. Storage is large enough for either IP family.
pub const Address = struct {
    storage: c.struct_sockaddr_storage,
    len: c.socklen_t,
};

/// Parse numeric IPv4 or IPv6 without a DNS lookup. IPv6 scopes may be
/// numeric interface indexes or names understood by if_nametoindex.
pub fn parseAddress(server: types.DnsServer) SocketError!Address {
    if (server.port == 0 or std.mem.indexOfScalar(u8, server.target, 0) != null) return error.InvalidArgument;
    var host: [types.max_server_target + 1]u8 = undefined;
    var target = server.target;
    var scope: u32 = 0;
    if (std.mem.indexOfScalar(u8, target, '%')) |separator| {
        const scope_text = target[separator + 1 ..];
        if (scope_text.len == 0) return error.InvalidArgument;
        scope = std.fmt.parseUnsigned(u32, scope_text, 10) catch blk: {
            const name = std.fmt.bufPrintSentinel(&host, "{s}", .{scope_text}, 0) catch return error.InvalidArgument;
            const index = c.if_nametoindex(name);
            if (index == 0) return error.InvalidArgument;
            break :blk index;
        };
        target = target[0..separator];
    }
    const terminated = std.fmt.bufPrintSentinel(&host, "{s}", .{target}, 0) catch return error.InvalidArgument;
    var address = Address{ .storage = std.mem.zeroes(c.struct_sockaddr_storage), .len = 0 };
    if (std.mem.indexOfScalar(u8, target, ':') != null) {
        const ipv6: *c.struct_sockaddr_in6 = @ptrCast(&address.storage);
        ipv6.sin6_family = c.AF_INET6;
        ipv6.sin6_port = std.mem.nativeToBig(u16, server.port);
        ipv6.sin6_scope_id = scope;
        if (c.inet_pton(c.AF_INET6, terminated, &ipv6.sin6_addr) != 1) return error.InvalidArgument;
        address.len = @sizeOf(c.struct_sockaddr_in6);
    } else {
        if (std.mem.indexOfScalar(u8, server.target, '%') != null) return error.InvalidArgument;
        const ipv4: *c.struct_sockaddr_in = @ptrCast(&address.storage);
        ipv4.sin_family = c.AF_INET;
        ipv4.sin_port = std.mem.nativeToBig(u16, server.port);
        if (c.inet_pton(c.AF_INET, terminated, &ipv4.sin_addr) != 1) return error.InvalidArgument;
        address.len = @sizeOf(c.struct_sockaddr_in);
    }
    return address;
}

pub fn sameEndpoint(a: *const Address, b: *const Address) bool {
    if (a.len != b.len) return false;
    return std.mem.eql(u8, std.mem.asBytes(&a.storage)[0..a.len], std.mem.asBytes(&b.storage)[0..b.len]);
}

/// Connect UDP so the kernel accepts datagrams only from the selected resolver.
pub fn openConnectedSocket(address: *const Address, nonblocking: bool) SocketError!c_int {
    const fd = c.socket(address.storage.ss_family, c.SOCK_DGRAM, c.IPPROTO_UDP);
    if (fd < 0) return error.SocketFailure;
    errdefer _ = c.close(fd);
    if (nonblocking) {
        const flags = c.fcntl(fd, c.F_GETFL);
        if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) < 0) return error.SocketFailure;
    }
    while (true) {
        const rc = c.connect(fd, @ptrCast(&address.storage), address.len);
        switch (posix.errno(rc)) {
            .SUCCESS => return fd,
            .INTR => continue,
            else => |err| return socketError(err),
        }
    }
}

pub fn setSocketTimeout(fd: c_int, timeout_ms: u32) SocketError!void {
    var timeout = c.struct_timeval{
        .tv_sec = @intCast(timeout_ms / 1000),
        .tv_usec = @intCast((timeout_ms % 1000) * 1000),
    };
    for ([_]c_int{ c.SO_RCVTIMEO, c.SO_SNDTIMEO }) |option| {
        if (c.setsockopt(fd, c.SOL_SOCKET, option, &timeout, @sizeOf(c.struct_timeval)) != 0) return error.SocketFailure;
    }
}

pub fn socketError(err: std.c.E) SocketError {
    return switch (err) {
        .AGAIN => error.WouldBlock,
        .TIMEDOUT => error.Timeout,
        .CONNREFUSED => error.ConnectionRefused,
        else => error.SocketFailure,
    };
}

pub fn socketErrorToTransport(err: SocketError) types.TransportResult {
    return switch (err) {
        error.InvalidArgument => .invalid_argument,
        error.Timeout, error.WouldBlock => .timeout,
        error.ConnectionRefused => .connection_refused,
        error.SocketFailure => .socket_failure,
    };
}

pub fn packetBuildErrorToTransport(err: dns_packet.Error) types.TransportResult {
    return switch (err) {
        error.InvalidArgument => .invalid_argument,
        error.BufferTooSmall => .buffer_too_small,
        else => .protocol_failure,
    };
}

pub fn packetParseErrorToTransport(err: dns_packet.Error) types.TransportResult {
    return switch (err) {
        error.BufferTooSmall => .buffer_too_small,
        else => .malformed_response,
    };
}

test "numeric IPv4 resolution rejects hostnames and embedded NUL" {
    const address = try parseAddress(.{ .name = "test", .target = "127.0.0.1", .port = 853 });
    try std.testing.expectEqual(@as(u16, 853), std.mem.bigToNative(u16, @as(*const c.struct_sockaddr_in, @ptrCast(&address.storage)).sin_port));
    try std.testing.expectError(error.InvalidArgument, parseAddress(.{ .name = "test", .target = "localhost" }));
    try std.testing.expectError(error.InvalidArgument, parseAddress(.{ .name = "test", .target = "127.0.0.1\x00bad" }));
}

test "socket timeout setup reports invalid descriptors" {
    try std.testing.expectError(error.SocketFailure, setSocketTimeout(-1, 20));
}

test "numeric IPv6 addresses preserve scope and port" {
    const loopback = try parseAddress(.{ .name = "loopback", .target = "::1", .port = 5353 });
    const ipv6: *const c.struct_sockaddr_in6 = @ptrCast(&loopback.storage);
    try std.testing.expectEqual(@as(u16, 5353), std.mem.bigToNative(u16, ipv6.sin6_port));
    const scoped = try parseAddress(.{ .name = "scoped", .target = "fe80::1%1" });
    try std.testing.expectEqual(@as(u32, 1), @as(*const c.struct_sockaddr_in6, @ptrCast(&scoped.storage)).sin6_scope_id);
}
