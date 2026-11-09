//! Loopback DNS fixtures shared by production-runner integration tests.

const std = @import("std");
const c = @import("posix.zig").c;
const dns_packet = @import("dns_packet.zig");
const benchmark_plan = @import("benchmark_plan.zig");
const net_util = @import("net_util.zig");

/// Opens an ephemeral IPv4 UDP loopback socket for integration tests.
pub fn openLoopbackSocket(receive_timeout_ms: u32) !struct { fd: c_int, port: u16 } {
    const fd = c.socket(c.AF_INET, c.SOCK_DGRAM, c.IPPROTO_UDP);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);

    var address: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
    address.sin_family = c.AF_INET;
    address.sin_port = 0;
    address.sin_addr.s_addr = std.mem.nativeToBig(u32, c.INADDR_LOOPBACK);
    if (c.bind(fd, @ptrCast(&address), @sizeOf(c.struct_sockaddr_in)) != 0) return error.BindFailed;

    var bound: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
    var bound_len: c.socklen_t = @sizeOf(c.struct_sockaddr_in);
    if (c.getsockname(fd, @ptrCast(&bound), &bound_len) != 0) return error.GetSockNameFailed;

    try net_util.setSocketTimeout(fd, receive_timeout_ms);
    return .{ .fd = fd, .port = std.mem.bigToNative(u16, bound.sin_port) };
}

/// Rewrites a received query in place into a response and returns its length.
/// Random-label names get NXDOMAIN and every other name gets one address
/// record, like a real resolver. `intercept` answers random labels too, like
/// an NXDOMAIN redirection page. The query's OPT record is dropped.
pub fn answerQuery(buffer: []u8, query_len: usize, intercept: bool) ?usize {
    if (query_len < dns_packet.header_len + 5) return null;
    const first_label_len: usize = buffer[dns_packet.header_len];
    var offset: usize = dns_packet.header_len;
    while (true) {
        if (offset >= query_len) return null;
        const label_len: usize = buffer[offset];
        offset += 1 + label_len;
        if (label_len == 0) break;
    }
    if (query_len - offset < 4) return null;
    const qtype = std.mem.readInt(u16, buffer[offset..][0..2], .big);
    offset += 4;
    const nonexistent = first_label_len == benchmark_plan.token_len and !intercept;
    buffer[2] = 0x81;
    buffer[3] = if (nonexistent) 0x83 else 0x80;
    @memset(buffer[6..12], 0);
    if (nonexistent) return offset;
    buffer[7] = 1;
    const rdata_len: usize = if (qtype == @intFromEnum(dns_packet.RecordType.aaaa)) 16 else 4;
    if (buffer.len - offset < 12 + rdata_len) return null;
    buffer[offset] = 0xC0;
    buffer[offset + 1] = 0x0C;
    std.mem.writeInt(u16, buffer[offset + 2 ..][0..2], qtype, .big);
    std.mem.writeInt(u16, buffer[offset + 4 ..][0..2], dns_packet.class_in, .big);
    std.mem.writeInt(u32, buffer[offset + 6 ..][0..4], 300, .big);
    std.mem.writeInt(u16, buffer[offset + 10 ..][0..2], @intCast(rdata_len), .big);
    @memset(buffer[offset + 12 ..][0..rdata_len], 0x7f);
    return offset + 12 + rdata_len;
}

/// How a test responder misbehaves once its honest replies run out.
pub const ResponderMode = enum {
    /// Keep answering honestly.
    honest,
    /// Answer every name, including random labels.
    intercept,
    /// Drop every query.
    silent,
    /// Reply with the reserved Z flag bit set, which the parser rejects.
    corrupt,
    /// Reply from an unrelated socket.
    wrong_port,
    /// Close the listening socket so later sends are refused.
    close,
};

/// Loopback DNS server for integration tests. It answers `honest_replies`
/// queries like a real resolver, which lets a server pass characterization,
/// then switches to `mode`.
pub const Responder = struct {
    fd: c_int,
    mode: ResponderMode = .honest,
    honest_replies: usize = std.math.maxInt(usize),
    reply_fd: c_int = -1,
    done: bool = false,
    first_port: u16 = 0,
    port_changed: bool = false,

    pub fn run(self: *Responder) void {
        while (!@atomicLoad(bool, &self.done, .seq_cst)) {
            var buffer: [dns_packet.max_udp_packet]u8 = undefined;
            // SAFETY: a successful recvfrom initializes the address before sendto uses it.
            var from: c.struct_sockaddr_storage = undefined;
            var from_len: c.socklen_t = @sizeOf(c.struct_sockaddr_storage);
            const received = c.recvfrom(self.fd, &buffer, buffer.len, 0, @ptrCast(&from), &from_len);
            if (received < dns_packet.header_len) continue;
            const from_port = @as(*const c.struct_sockaddr_in, @ptrCast(@alignCast(&from))).sin_port;
            if (self.first_port == 0) self.first_port = from_port;
            if (from_port != self.first_port) self.port_changed = true;
            const query_len: usize = @intCast(received);
            const mode: ResponderMode = if (self.honest_replies > 0) .honest else self.mode;
            if (self.honest_replies > 0) self.honest_replies -= 1;
            switch (mode) {
                .honest, .intercept => {
                    const len = answerQuery(buffer[0..], query_len, mode == .intercept) orelse continue;
                    _ = c.sendto(self.fd, &buffer, len, 0, @ptrCast(&from), from_len);
                },
                .silent => {},
                .corrupt => {
                    const len = answerQuery(buffer[0..], query_len, false) orelse continue;
                    buffer[3] |= 0x40;
                    _ = c.sendto(self.fd, &buffer, len, 0, @ptrCast(&from), from_len);
                },
                .wrong_port => {
                    const len = answerQuery(buffer[0..], query_len, false) orelse continue;
                    _ = c.sendto(self.reply_fd, &buffer, len, 0, @ptrCast(&from), from_len);
                },
                .close => {},
            }
            // Close right after the last honest reply, before the next query
            // arrives, so every later send is refused instead of timing out.
            if (self.mode == .close and self.honest_replies == 0) {
                _ = c.close(self.fd);
                return;
            }
        }
    }
};
