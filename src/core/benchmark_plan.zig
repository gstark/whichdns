//! Deterministic benchmark task counts and DNS hostnames.
//!
//! The production query lifecycle and reporting share these query counts and names.

const std = @import("std");
const dns_packet = @import("dns_packet.zig");
const types = @import("types.zig");

/// Popular domains that every public resolver keeps hot in its cache. Cached
/// samples rotate through them, and random_subdomain samples put a random label under
/// each one to measure random-name lookups. A unique name does not guarantee a cache miss.
pub const default_cached_names = [_][]const u8{
    "google.com",   "youtube.com",       "facebook.com",   "instagram.com", "wikipedia.org",
    "amazon.com",   "microsoft.com",     "linkedin.com",   "yahoo.com",     "whatsapp.com",
    "tiktok.com",   "stackoverflow.com", "bbc.co.uk",      "cnn.com",       "nytimes.com",
    "ebay.com",     "paypal.com",        "spotify.com",    "zoom.us",       "dropbox.com",
    "adobe.com",    "salesforce.com",    "imdb.com",       "pinterest.com", "baidu.com",
    "naver.com",    "qq.com",            "bilibili.com",   "yahoo.co.jp",   "globo.com",
    "walmart.com",  "target.com",        "bestbuy.com",    "booking.com",   "airbnb.com",
    "uber.com",     "mozilla.org",       "duckduckgo.com", "samsung.com",   "apple.com",
    "openai.com",   "amazonaws.com",     "gstatic.com",    "google.co.uk",  "google.de",
    "google.co.jp", "roblox.com",        "x.com",          "reddit.com",    "netflix.com",
};

/// Inputs that define the query matrix for one benchmark run.
pub const Config = struct {
    iterations: u32 = types.default_iterations,
    retries: u32 = types.default_retries,
    qtype: dns_packet.RecordType = .a,
    /// Cached samples cycle through these names. Every cached sample sends an
    /// untimed priming query first, then times a second query for the same
    /// name, so the sample measures a cache hit even after the TTL expired.
    cached_names: []const []const u8 = &default_cached_names,
    samples_per_kind: usize = 50,
    /// Optional zone for every random_subdomain lookup. When empty, random_subdomain samples
    /// use a random label under the cached names instead.
    random_zone: []const u8 = "",
    /// Makes every generated name unique to this benchmark run.
    run_seed: u64 = 0,
};

/// One required positive-resolution probe in the characterization matrix.
pub const ValidationProbe = struct { hostname: []const u8, qtype: dns_packet.RecordType };

/// Fixed, independent positive-resolution checks. They are not timed for
/// ranking; a resolver that cannot answer every one is ineligible.
pub const validation_probes = [_]ValidationProbe{
    .{ .hostname = "google.com", .qtype = .a },
    .{ .hostname = "cloudflare.com", .qtype = .a },
    .{ .hostname = "example.com", .qtype = .a },
    .{ .hostname = "a.gtld-servers.net", .qtype = .a },
    .{ .hostname = "google.com", .qtype = .aaaa },
};

/// One untimed probe sent to every server before its benchmark samples.
pub const CharacterizationProbe = union(enum) {
    /// A nonexistent name that an intercepting resolver answers anyway.
    redirect,
    /// A required positive lookup.
    validation: ValidationProbe,
};

/// Characterization probes per server: one redirect check, then every
/// validation probe. Sessions use this order.
pub const characterization_probes_per_server = 1 + validation_probes.len;

/// Maps a characterization phase index to its probe.
pub fn characterizationProbeAt(phase: usize) CharacterizationProbe {
    if (phase == 0) return .redirect;
    return .{ .validation = validation_probes[phase - 1] };
}

/// Consecutive timed-out benchmark attempts after which a resolver is
/// dropped. It cannot be recommended after one failure, so further samples
/// would only add timeout waits to the run.
pub const max_consecutive_timeouts: u32 = 5;

/// Timed samples per server: every (kind, sample, iteration) combination.
pub fn benchmarkTasksPerServer(config: Config) usize {
    return config.samples_per_kind * types.query_kind_count * config.iterations;
}

/// Total tasks a run completes: the characterization probes plus every timed
/// sample, per server. Runners and progress reporting must agree on this.
pub fn totalTasks(config: Config, servers_len: usize) usize {
    return servers_len * (characterization_probes_per_server + benchmarkTasksPerServer(config));
}

/// DNS queries one server receives when every sample is sent once: each
/// cached sample costs a priming query plus the timed query.
pub fn queriesPerServer(config: Config) usize {
    const priming_queries = config.samples_per_kind * config.iterations;
    return characterization_probes_per_server + benchmarkTasksPerServer(config) + priming_queries;
}

/// Generates the hostname for a timed query into caller-owned storage.
pub fn hostnameFor(
    kind: types.QueryKind,
    config: Config,
    server_index: usize,
    iteration: u32,
    sample_index: usize,
    buffer: []u8,
) ![]const u8 {
    if (sample_index >= config.samples_per_kind or config.cached_names.len == 0) return error.InvalidArgument;
    const cached_name = config.cached_names[sample_index % config.cached_names.len];
    const zone, const salt: u64 = switch (kind) {
        .cached => return copyHostname(cached_name, buffer),
        .random_subdomain => .{ if (config.random_zone.len != 0) config.random_zone else cached_name, 0x9e3779b97f4a7c15 },
        .random_com => .{ "com", 0x6a09e667f3bcc908 },
    };
    return randomLabelHostname(zone, config, server_index, iteration, sample_index, salt, buffer);
}

pub const token_len = 16;
pub const redirect_hostname_len = token_len * 2 + 1;

/// Redirect/interception checks query a nonexistent TLD. The name is derived
/// from the run seed so interceptors cannot special-case a fixed probe name.
pub fn redirectHostnameFor(config: Config, buffer: []u8) ![]const u8 {
    var offset: usize = 0;
    offset = try appendToken(buffer, offset, 0, 0, 0, 0x8f1bbcdc5a5a3f2d ^ config.run_seed);
    offset = try appendByte(buffer, offset, '.');
    offset = try appendToken(buffer, offset, 1, 0, 0, 0x243f6a8885a308d3 ^ config.run_seed);
    return buffer[0..offset];
}

/// Checks whether the packet encoder can represent a hostname.
pub fn isHostnameEncodable(hostname: []const u8) bool {
    if (hostname.len == 0 or hostname.len > dns_packet.max_name_len + 1) return false;
    var packet: [dns_packet.max_udp_packet]u8 = undefined;
    _ = dns_packet.buildQuery(packet[0..], 1, hostname, .a, true) catch return false;
    return true;
}

/// Copies a configured hostname into caller-owned scratch storage.
fn copyHostname(hostname: []const u8, buffer: []u8) ![]const u8 {
    if (hostname.len == 0 or hostname.len > buffer.len) return error.BufferTooSmall;
    @memcpy(buffer[0..hostname.len], hostname);
    return buffer[0..hostname.len];
}

/// Builds a run-specific random label beneath `zone`. Resolvers may synthesize
/// answers from cached DNSSEC proofs or wildcard records.
fn randomLabelHostname(
    zone: []const u8,
    config: Config,
    server_index: usize,
    iteration: u32,
    sample_index: usize,
    salt: u64,
    buffer: []u8,
) ![]const u8 {
    var offset: usize = 0;
    offset = try appendToken(buffer, offset, server_index, iteration, sample_index, salt ^ config.run_seed);
    offset = try appendByte(buffer, offset, '.');
    offset = try append(buffer, offset, zone);
    return buffer[0..offset];
}

/// Appends a byte slice and returns the next free offset.
fn append(buffer: []u8, offset: usize, value: []const u8) !usize {
    if (buffer.len - offset < value.len) return error.BufferTooSmall;
    @memcpy(buffer[offset..][0..value.len], value);
    return offset + value.len;
}

/// Appends one byte and returns the next free offset.
fn appendByte(buffer: []u8, offset: usize, value: u8) !usize {
    if (offset >= buffer.len) return error.BufferTooSmall;
    buffer[offset] = value;
    return offset + 1;
}

/// Encodes a fixed-width, DNS-label-safe base-36 token. Sixteen characters
/// make a collision with a registered name negligible. Two independently
/// mixed halves fill all sixteen, since one 64-bit value only fills thirteen.
fn appendToken(
    buffer: []u8,
    offset: usize,
    server_index: usize,
    iteration: u32,
    sample_index: usize,
    salt: u64,
) !usize {
    const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";
    const half_len = token_len / 2;
    if (buffer.len - offset < token_len) return error.BufferTooSmall;
    const halves = [_]u64{
        mixToken(server_index, iteration, sample_index, salt),
        mixToken(server_index, iteration, sample_index, salt ^ 0x5851f42d4c957f2d),
    };
    for (halves, 0..) |half, h| {
        var remaining = half;
        for (0..half_len) |i| {
            buffer[offset + h * half_len + i] = alphabet[@intCast(remaining % alphabet.len)];
            remaining /= alphabet.len;
        }
    }
    return offset + token_len;
}

/// Mixes sample coordinates and a salt into a well-distributed name token.
fn mixToken(server_index: usize, iteration: u32, sample_index: usize, salt: u64) u64 {
    var x = salt ^ (@as(u64, server_index + 1) *% 0x94d049bb133111eb) ^
        (@as(u64, iteration + 1) *% 0x2545f4914f6cdd1d) ^
        (@as(u64, sample_index + 1) *% 0x369dea0f31a53f85);
    x ^= x >> 30;
    x *%= 0xbf58476d1ce4e5b9;
    x ^= x >> 27;
    x *%= 0x94d049bb133111eb;
    x ^= x >> 31;
    return x;
}

const expect = std.testing.expect;

test "cached names rotate and random_subdomain names sit under the same domain" {
    const config = Config{ .cached_names = &.{ "example.com", "example.net" }, .samples_per_kind = 3 };
    var buffer: [256]u8 = undefined;
    try expect(std.mem.eql(u8, try hostnameFor(.cached, config, 0, 0, 0, buffer[0..]), "example.com"));
    try expect(std.mem.eql(u8, try hostnameFor(.cached, config, 0, 0, 1, buffer[0..]), "example.net"));
    try expect(std.mem.eql(u8, try hostnameFor(.cached, config, 0, 0, 2, buffer[0..]), "example.com"));
    const random_subdomain = try hostnameFor(.random_subdomain, config, 2, 4, 1, buffer[0..]);
    try std.testing.expectEqual(token_len + ".example.net".len, random_subdomain.len);
    try expect(std.mem.eql(u8, random_subdomain[token_len..], ".example.net"));
}

test "a configured zone replaces the cached domain for random_subdomain names" {
    const config = Config{ .cached_names = &.{"example.com"}, .random_zone = "bench.example", .samples_per_kind = 2 };
    var buffer: [256]u8 = undefined;
    const random_subdomain = try hostnameFor(.random_subdomain, config, 0, 0, 1, buffer[0..]);
    try expect(std.mem.eql(u8, random_subdomain[token_len..], ".bench.example"));
}

test "dot-com names are random labels directly under com" {
    var first_buffer: [256]u8 = undefined;
    var second_buffer: [256]u8 = undefined;
    const first = try hostnameFor(.random_com, .{}, 0, 0, 0, first_buffer[0..]);
    const second = try hostnameFor(.random_com, .{}, 0, 1, 0, second_buffer[0..]);
    try std.testing.expectEqual(token_len + ".com".len, first.len);
    try expect(std.mem.eql(u8, first[token_len..], ".com"));
    try expect(!std.mem.eql(u8, first, second));
    var random_subdomain_buffer: [256]u8 = undefined;
    const random_subdomain = try hostnameFor(.random_subdomain, .{}, 0, 0, 0, random_subdomain_buffer[0..]);
    try expect(!std.mem.eql(u8, first[0..token_len], random_subdomain[0..token_len]));
}

test "redirect hostnames differ across run seeds and use two labels" {
    var first_buffer: [redirect_hostname_len]u8 = undefined;
    var second_buffer: [redirect_hostname_len]u8 = undefined;
    const first = try redirectHostnameFor(.{ .run_seed = 1 }, first_buffer[0..]);
    const second = try redirectHostnameFor(.{ .run_seed = 2 }, second_buffer[0..]);
    try std.testing.expectEqual(redirect_hostname_len, first.len);
    try std.testing.expectEqual('.', first[token_len]);
    try expect(!std.mem.eql(u8, first, second));
}

test "generated names rotate with the run seed" {
    var first_buffer: [256]u8 = undefined;
    var second_buffer: [256]u8 = undefined;
    const first = try hostnameFor(.random_subdomain, Config{ .run_seed = 1, .samples_per_kind = 2 }, 0, 0, 0, first_buffer[0..]);
    const second = try hostnameFor(.random_subdomain, Config{ .run_seed = 2, .samples_per_kind = 2 }, 0, 0, 0, second_buffer[0..]);
    try expect(!std.mem.eql(u8, first, second));
}

test "characterization probes are the redirect check then validation" {
    try std.testing.expectEqual(.redirect, characterizationProbeAt(0));
    try expect(std.mem.eql(u8, characterizationProbeAt(1).validation.hostname, "google.com"));
    try expect(std.mem.eql(u8, characterizationProbeAt(characterization_probes_per_server - 1).validation.hostname, "google.com"));
    try std.testing.expectEqual(.aaaa, characterizationProbeAt(characterization_probes_per_server - 1).validation.qtype);
}

test "query counts include one priming query per cached sample" {
    const config = Config{ .samples_per_kind = 2, .iterations = 3 };
    try std.testing.expectEqual(characterization_probes_per_server + 18, totalTasks(config, 1));
    try std.testing.expectEqual(characterization_probes_per_server + 18 + 6, queriesPerServer(config));
}

test "every default cached name is encodable with a random label" {
    var buffer: [256]u8 = undefined;
    for (default_cached_names, 0..) |_, i| {
        const name = try hostnameFor(.random_subdomain, .{}, 0, 0, i, buffer[0..]);
        try expect(isHostnameEncodable(name));
    }
}

test "hostname encodability uses DNS packet builder" {
    try expect(isHostnameEncodable("example.com"));
    try expect(isHostnameEncodable("example.com."));
    try expect(!isHostnameEncodable("example..com"));
}
