//! Fixed-capacity resolver inventory. Keep Inventory at a stable address while
//! using its server slices, whose strings point into its owned storage.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const types = core.types;
const net = core.net_util;
const c = core.posix.c;

/// Endpoints accepted by one command-line option list.
pub const max_custom_servers = 32;

pub const Format = enum { scutil, resolv_conf };
pub const Source = enum { system, custom, public };

pub const Inventory = struct {
    // SAFETY: add initializes each occupied prefix before advancing count.
    entries: [types.max_servers]types.DnsServer = undefined,
    // SAFETY: add initializes addresses before they participate in deduplication.
    addresses: [types.max_servers]net.Address = undefined,
    // SAFETY: add fills each target before publishing a borrowed slice.
    targets: [types.max_servers][types.max_server_target]u8 = undefined,
    // SAFETY: add fills each name before publishing a borrowed slice.
    names: [types.max_servers][types.max_server_name]u8 = undefined,
    count: usize = 0,

    pub fn servers(self: *const Inventory) []const types.DnsServer {
        return self.entries[0..self.count];
    }

    pub fn parseConfig(self: *Inventory, text: []const u8, format: Format) !void {
        switch (format) {
            .scutil => {
                var blocks = std.mem.splitSequence(u8, text, "resolver #");
                while (blocks.next()) |block| try self.parseScutilBlock(block);
            },
            .resolv_conf => try self.parseResolvConf(text),
        }
    }

    /// Adds the name servers of one `scutil --dns` resolver block with the
    /// block's port and, for link-local IPv6, its interface scope.
    fn parseScutilBlock(self: *Inventory, block: []const u8) !void {
        var port: u16 = 53;
        var scope: u32 = 0;
        var fields = std.mem.splitScalar(u8, block, '\n');
        while (fields.next()) |line| {
            var tokens = std.mem.tokenizeAny(u8, line, " \t\r:");
            const field = tokens.next() orelse continue;
            if (std.mem.eql(u8, field, "port")) {
                port = try parseConfigNumber(u16, tokens.next());
            } else if (std.mem.eql(u8, field, "if_index")) {
                scope = try parseConfigNumber(u32, tokens.next());
            }
        }
        var lines = std.mem.splitScalar(u8, block, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (!std.mem.startsWith(u8, trimmed, "nameserver[")) continue;
            const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return error.InvalidConfiguration;
            var tokens = std.mem.tokenizeAny(u8, trimmed[colon + 1 ..], " \t\r");
            var server = try parseEndpoint(tokens.next() orelse return error.InvalidConfiguration);
            server.port = port;
            var scoped_target: [types.max_server_target]u8 = undefined;
            if (scope != 0 and try isUnscopedLinkLocal(server)) {
                server.target = try std.fmt.bufPrint(&scoped_target, "{s}%{d}", .{ server.target, scope });
            }
            try self.add(server, .system);
        }
    }

    fn parseResolvConf(self: *Inventory, text: []const u8) !void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const uncommented = line[0 .. std.mem.indexOfAny(u8, line, "#;") orelse line.len];
            var tokens = std.mem.tokenizeAny(u8, uncommented, " \t\r");
            if (!std.mem.eql(u8, tokens.next() orelse continue, "nameserver")) continue;
            const endpoint = tokens.next() orelse return error.InvalidConfiguration;
            try self.add(try parseEndpoint(endpoint), .system);
        }
    }

    pub fn addCustom(self: *Inventory, text: []const u8) !void {
        try self.add(try parseEndpoint(text), .custom);
    }

    pub fn addPublic(self: *Inventory) !void {
        for (core.default_servers.list) |server| try self.add(server, .public);
    }

    fn add(self: *Inventory, server: types.DnsServer, source: Source) !void {
        const address = try net.parseAddress(server);
        for (self.addresses[0..self.count], 0..) |*existing, i| {
            if (!net.sameEndpoint(existing, &address)) continue;
            const entry = &self.entries[i];
            switch (source) {
                .system => entry.system = true,
                .custom => entry.custom = true,
                .public => {
                    entry.public = true;
                    entry.name = try store(&self.names[i], server.name);
                },
            }
            return;
        }
        if (self.count == self.entries.len) return error.TooManyServers;
        const i = self.count;
        const name = switch (source) {
            .system => "System DNS",
            .custom => "Custom DNS",
            .public => server.name,
        };
        self.entries[i] = .{
            .target = try store(&self.targets[i], server.target),
            .name = try store(&self.names[i], name),
            .port = server.port,
            .system = source == .system,
            .custom = source == .custom,
            .public = source == .public,
        };
        self.addresses[i] = address;
        self.count += 1;
    }

    /// Use OS resolver configuration, including macOS scoped/VPN resolvers.
    pub fn discoverSystem(self: *Inventory) !void {
        var storage: [65536]u8 = undefined;
        const text = try readSystemConfig(&storage);
        const initial_count = self.count;
        try self.parseConfig(text, if (builtin.os.tag == .macos) .scutil else .resolv_conf);
        if (self.count == initial_count) return error.NoSystemResolvers;
    }
};

/// Reads `scutil --dns` on macOS or /etc/resolv.conf on Linux into `storage`.
fn readSystemConfig(storage: []u8) ![]const u8 {
    const is_macos = builtin.os.tag == .macos;
    if (!is_macos and builtin.os.tag != .linux) return error.UnsupportedSystem;
    const stream = (if (is_macos)
        c.popen("/usr/sbin/scutil --dns 2>/dev/null", "r")
    else
        c.fopen("/etc/resolv.conf", "r")) orelse return error.DiscoveryFailed;
    const size = c.fread(storage.ptr, 1, storage.len, stream);
    const read_failed = c.ferror(stream) != 0;
    const status = if (is_macos) c.pclose(stream) else c.fclose(stream);
    if (read_failed) return error.DiscoveryFailed;
    if (size == storage.len) return error.ConfigurationTooLarge;
    if (status != 0) return error.DiscoveryFailed;
    return storage[0..size];
}

fn parseConfigNumber(comptime T: type, text: ?[]const u8) !T {
    return std.fmt.parseUnsigned(T, text orelse return error.InvalidConfiguration, 10) catch
        return error.InvalidConfiguration;
}

/// True for an IPv6 link-local address (fe80::/10) without a `%scope` suffix.
fn isUnscopedLinkLocal(server: types.DnsServer) !bool {
    if (std.mem.indexOfScalar(u8, server.target, '%') != null) return false;
    const address = try net.parseAddress(server);
    if (address.storage.ss_family != c.AF_INET6) return false;
    const ipv6: *const c.struct_sockaddr_in6 = @ptrCast(&address.storage);
    const bytes = std.mem.asBytes(&ipv6.sin6_addr);
    return bytes[0] == 0xfe and bytes[1] & 0xc0 == 0x80;
}

/// Copies `text` into fixed storage and returns the stored slice.
fn store(storage: []u8, text: []const u8) error{NoSpaceLeft}![]const u8 {
    if (text.len > storage.len) return error.NoSpaceLeft;
    @memcpy(storage[0..text.len], text);
    return storage[0..text.len];
}

/// Targets borrow the input until Inventory.add copies them into owned storage.
pub fn parseEndpoint(text: []const u8) !types.DnsServer {
    var target = text;
    var port: u16 = 53;
    if (std.mem.startsWith(u8, text, "[")) {
        const end = std.mem.indexOfScalar(u8, text, ']') orelse return error.InvalidArgument;
        target = text[1..end];
        if (std.mem.indexOfScalar(u8, target, ':') == null) return error.InvalidArgument;
        if (end + 1 < text.len) {
            if (text[end + 1] != ':') return error.InvalidArgument;
            port = std.fmt.parseUnsigned(u16, text[end + 2 ..], 10) catch return error.InvalidArgument;
        }
    } else if (std.mem.count(u8, text, ":") == 1) {
        const colon = std.mem.indexOfScalar(u8, text, ':').?;
        target = text[0..colon];
        port = std.fmt.parseUnsigned(u16, text[colon + 1 ..], 10) catch return error.InvalidArgument;
    }
    const server = types.DnsServer{ .name = "", .target = target, .port = port };
    _ = try net.parseAddress(server);
    return server;
}

test "scutil finds all resolver blocks and deduplicates IPv6 numerically" {
    var inventory = Inventory{};
    try inventory.parseConfig(
        \\DNS configuration
        \\resolver #1
        \\  nameserver[0] : 127.0.0.1
        \\  nameserver[1] : fd7a:115c:a1e0::53
        \\resolver #2
        \\  nameserver[0] : 192.168.0.1
        \\  nameserver[1] : fd7a:115c:a1e0:0:0:0:0:53
        \\resolver #3
        \\  nameserver[0] : 100.100.100.100
    , .scutil);
    try std.testing.expectEqual(@as(usize, 4), inventory.servers().len);
    for (inventory.servers()) |server| try std.testing.expect(server.system);
}

test "resolv.conf handles comments and retains scoped IPv6" {
    var inventory = Inventory{};
    try inventory.parseConfig("# ignored\nnameserver 1.1.1.1 # primary\nsearch example.org\n nameserver fe80::1%1 ; scoped\nnameserver fe80::1%2\n", .resolv_conf);
    try std.testing.expectEqual(@as(usize, 3), inventory.servers().len);
    try std.testing.expectEqualStrings("fe80::1%1", inventory.servers()[1].target);
    try inventory.addPublic();
    try std.testing.expectEqualStrings("Cloudflare", inventory.servers()[0].name);
    try std.testing.expect(inventory.servers()[0].system and inventory.servers()[0].public);
}

test "custom endpoints merge provenance but keep distinct ports" {
    var inventory = Inventory{};
    try inventory.parseConfig("nameserver 127.0.0.1\n", .resolv_conf);
    try inventory.addCustom("127.0.0.1:53");
    try inventory.addCustom("127.0.0.1:5353");
    try inventory.addCustom("[::1%1]:5353");
    try inventory.addCustom("[0:0:0:0:0:0:0:1%1]:5353");
    try std.testing.expectEqual(@as(usize, 3), inventory.servers().len);
    try std.testing.expect(inventory.servers()[0].system and inventory.servers()[0].custom);
    try std.testing.expectEqual(@as(u16, 5353), inventory.servers()[2].port);
    try std.testing.expectError(error.InvalidArgument, inventory.addCustom("localhost"));
    try std.testing.expectError(error.InvalidArgument, inventory.addCustom("[::1]:0"));
    try std.testing.expectError(error.InvalidArgument, inventory.addCustom("[::1]:65536"));
}

test "scutil supplies interface scopes for link-local resolvers and custom ports" {
    var inventory = Inventory{};
    try inventory.parseConfig("DNS configuration\n\nresolver #1\n  nameserver[0] : fe80::1\n  port : 5353\n  if_index : 1 (lo0)\n\nresolver #2\n  nameserver[0] : fe80::1\n  if_index : 2 (en0)\n", .scutil);
    try std.testing.expectEqual(@as(usize, 2), inventory.servers().len);
    try std.testing.expectEqualStrings("fe80::1%1", inventory.servers()[0].target);
    try std.testing.expectEqual(@as(u16, 5353), inventory.servers()[0].port);
}
