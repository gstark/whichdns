//! Preflight validation for benchmark plans, resolver metadata, and capacity.

const std = @import("std");
const benchmark_plan = @import("benchmark_plan.zig");
const types = @import("types.zig");

/// Errors reported when a benchmark cannot be run safely.
pub const Error = error{
    InvalidArgument,
    BufferTooSmall,
};

/// Validates bounds and proves every generated hostname is DNS-encodable.
pub fn check(config: benchmark_plan.Config, servers: []const types.DnsServer, result_capacity: usize) Error!void {
    if (servers.len > result_capacity or servers.len > types.max_servers) return error.BufferTooSmall;
    if (servers.len == 0) return;
    const qtype_supported = config.qtype == .a or config.qtype == .aaaa;
    if (config.iterations == 0 or config.retries == std.math.maxInt(u32) or !qtype_supported) return error.InvalidArgument;
    if (config.samples_per_kind == 0 or config.cached_names.len == 0) return error.InvalidArgument;
    checkCounts(config, servers.len) catch return error.InvalidArgument;

    for (servers) |dns_server| {
        if (dns_server.name.len == 0 or dns_server.name.len >= types.max_server_name) return error.InvalidArgument;
        if (dns_server.target.len == 0 or dns_server.target.len >= types.max_server_target) {
            return error.InvalidArgument;
        }
    }

    checkHostnames(config, servers.len) catch return error.InvalidArgument;
}

/// Proves that attempt, wire query, and task counts fit their counters.
fn checkCounts(config: benchmark_plan.Config, server_count: usize) error{Overflow}!void {
    const max_u32 = std.math.maxInt(u32);
    const characterization = benchmark_plan.characterization_probes_per_server;
    const samples = try std.math.mul(u64, config.iterations, config.samples_per_kind);
    const attempts_per_kind = try std.math.mul(u64, samples, @as(u64, config.retries) + 1);
    if (attempts_per_kind > max_u32) return error.Overflow;
    // Cached attempts can each send a priming query, and characterization
    // probes can each be retried once.
    const max_wire_queries = attempts_per_kind * (types.query_kind_count + 1) + characterization * 2;
    if (max_wire_queries > max_u32) return error.Overflow;
    const timed_tasks = try std.math.mul(usize, @intCast(samples), types.query_kind_count);
    const tasks_per_server = try std.math.add(usize, timed_tasks, characterization);
    _ = try std.math.mul(usize, tasks_per_server, server_count);
}

/// Proves that every configured and generated hostname is DNS-encodable.
fn checkHostnames(config: benchmark_plan.Config, server_count: usize) !void {
    for (config.cached_names) |name| {
        if (!benchmark_plan.isHostnameEncodable(name)) return error.InvalidArgument;
    }

    // Every zone that can carry a random label must still fit the wire limit.
    var buffer: [256]u8 = undefined;
    const last_server = server_count - 1;
    const last_iteration = config.iterations - 1;
    const zones = @min(config.cached_names.len, config.samples_per_kind);
    for (0..zones) |sample_index| {
        const name = try benchmark_plan.hostnameFor(.random_subdomain, config, last_server, last_iteration, sample_index, &buffer);
        if (!benchmark_plan.isHostnameEncodable(name)) return error.InvalidArgument;
    }
    const random_com = try benchmark_plan.hostnameFor(.random_com, config, 0, 0, 0, &buffer);
    if (!benchmark_plan.isHostnameEncodable(random_com)) return error.InvalidArgument;
}

/// Creates the valid resolver fixture used by preflight tests.
fn fixtureServer() types.DnsServer {
    return types.DnsServer{
        .name = "cloudflare",
        .target = "1.1.1.1",
    };
}

test "validate accepts normal config and server" {
    const servers = [_]types.DnsServer{fixtureServer()};
    try check(.{}, servers[0..], servers.len);
}

test "validate accepts empty server list" {
    const servers = [_]types.DnsServer{};
    try check(.{}, servers[0..], 0);
}

test "validate rejects small result capacity" {
    const servers = [_]types.DnsServer{ fixtureServer(), fixtureServer() };
    const result = check(.{}, servers[0..], 1);
    try std.testing.expectError(Error.BufferTooSmall, result);
}

test "validate rejects bad iterations and qtype" {
    const servers = [_]types.DnsServer{fixtureServer()};
    try std.testing.expectError(Error.InvalidArgument, check(.{ .iterations = 0 }, servers[0..], servers.len));
    try std.testing.expectError(Error.InvalidArgument, check(.{ .qtype = .opt }, servers[0..], servers.len));
    try std.testing.expectError(Error.InvalidArgument, check(.{ .cached_names = &.{} }, servers[0..], servers.len));
}

test "validate rejects unencodable hostnames" {
    const servers = [_]types.DnsServer{fixtureServer()};
    try std.testing.expectError(Error.InvalidArgument, check(.{ .cached_names = &.{"example..com"} }, servers[0..], servers.len));
    try std.testing.expectError(Error.InvalidArgument, check(.{ .random_zone = "bench..example" }, servers[0..], servers.len));
    const too_long_zone = "a" ** 63 ++ "." ++ "a" ** 63 ++ "." ++ "a" ** 63 ++ "." ++ "a" ** 50;
    try std.testing.expectError(Error.InvalidArgument, check(.{ .random_zone = too_long_zone }, servers[0..], servers.len));
}

test "validate rejects too-long server metadata" {
    const too_long_name = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const servers = [_]types.DnsServer{.{
        .name = too_long_name,
        .target = "1.1.1.1",
    }};
    try std.testing.expectError(Error.InvalidArgument, check(.{}, servers[0..], servers.len));
}

test "validation rejects overflowing sample counts" {
    const servers = [_]types.DnsServer{fixtureServer()};
    try std.testing.expectError(error.InvalidArgument, check(.{
        .iterations = 2,
        .samples_per_kind = std.math.maxInt(usize),
    }, &servers, servers.len));
}

test "validation includes primes and characterization in the wire counter bound" {
    const servers = [_]types.DnsServer{fixtureServer()};
    try std.testing.expectError(error.InvalidArgument, check(.{ .samples_per_kind = 1_073_741_824 }, &servers, 1));
}
