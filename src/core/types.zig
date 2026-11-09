//! Value contracts shared by the DNS boundary, benchmark engine, and reports.

const std = @import("std");
const Rcode = @import("dns_packet.zig").Rcode;

pub const max_servers = 512;
pub const max_server_name = 64;
pub const max_server_target = 256;
pub const default_timeout_ms: u32 = 1500;
pub const default_iterations: u32 = 1;
pub const default_retries: u32 = 0;
pub const default_pause_ms: u32 = 400;

pub const QueryKind = enum(u8) {
    cached,
    random_subdomain,
    random_com,

    pub fn label(self: QueryKind) []const u8 {
        return switch (self) {
            .cached => "cached",
            .random_subdomain => "random-subdomain",
            .random_com => "random-com",
        };
    }
};

pub const query_kind_count = std.enums.values(QueryKind).len;

/// Failures without a usable DNS answer. DNS rcodes live in Outcome.dns_error.
pub const TransportResult = enum(u8) {
    invalid_argument,
    buffer_too_small,
    timeout,
    socket_failure,
    connection_refused,
    protocol_failure,
    malformed_response,
    truncated_response,

    pub fn label(self: TransportResult) []const u8 {
        return @tagName(self);
    }
};

/// A classified lookup, never an unrelated tuple of transport status and counts.
pub const Outcome = union(enum) {
    address,
    nodata,
    nxdomain,
    dns_error: Rcode,
    failure: TransportResult,

    pub fn expected(self: Outcome, kind: QueryKind) bool {
        return switch (self) {
            .address => kind != .random_com,
            .nodata, .nxdomain => kind != .cached,
            else => false,
        };
    }
    pub fn retryable(self: Outcome) bool {
        return switch (self) {
            .failure => |failure| switch (failure) {
                .invalid_argument, .buffer_too_small, .connection_refused => false,
                else => true,
            },
            .dns_error => |rcode| rcode == .servfail,
            .nodata => true,
            else => false,
        };
    }
};

pub const ServerStatus = enum(u8) {
    reachable,
    no_answer,
    timeout,
    rejected,
    invalid_reply,
    refused,
    unsupported_protocol,
    redirect_or_intercept,
    incomplete,
    dns_service_available,
    truncated,
    unavailable,
    dropped,

    pub fn label(self: ServerStatus) []const u8 {
        return switch (self) {
            .reachable => "reachable",
            .no_answer => "no answer",
            .timeout => "timeout",
            .rejected => "rejected",
            .invalid_reply => "invalid reply",
            .refused => "refused",
            .unsupported_protocol => "unsupported protocol",
            .redirect_or_intercept => "redirect or intercept",
            .incomplete => "incomplete",
            .dns_service_available => "DNS service available",
            .truncated => "truncated replies",
            .unavailable => "unavailable",
            .dropped => "stopped responding",
        };
    }
};

pub const DnsServer = struct {
    name: []const u8,
    target: []const u8,
    port: u16 = 53,
    system: bool = false,
    custom: bool = false,
    public: bool = false,
};

pub const FailureKind = enum {
    timeout,
    refused,
    malformed,
    truncated,
    socket,
    dns_error,
    no_answer,
    unexpected_answer,
};

/// Only expected lookup outcomes contribute latency. Failure counts are disjoint.
pub const QueryStats = struct {
    attempted: u32 = 0,
    resolved: u32 = 0,
    failures: std.EnumArray(FailureKind, u32) = .initFill(0),
    elapsed_total_us: u64 = 0,
    elapsed_sum_squares_us2: u128 = 0,
    elapsed_min_us: u64 = 0,
    elapsed_max_us: u64 = 0,

    pub fn averageUs(self: QueryStats) u64 {
        return if (self.resolved == 0) 0 else self.elapsed_total_us / self.resolved;
    }
    pub fn failureCount(self: QueryStats, kind: FailureKind) u32 {
        return self.failures.get(kind);
    }
    pub fn add(self: *QueryStats, other: QueryStats) void {
        const other_is_faster = self.resolved == 0 or other.elapsed_min_us < self.elapsed_min_us;
        if (other.resolved > 0 and other_is_faster) self.elapsed_min_us = other.elapsed_min_us;
        self.attempted += other.attempted;
        self.resolved += other.resolved;
        for (&self.failures.values, other.failures.values) |*count, value| count.* += value;
        self.elapsed_total_us += other.elapsed_total_us;
        self.elapsed_sum_squares_us2 += other.elapsed_sum_squares_us2;
        self.elapsed_max_us = @max(self.elapsed_max_us, other.elapsed_max_us);
    }
};

pub const ServerResult = struct {
    server: DnsServer,
    query_stats: std.EnumArray(QueryKind, QueryStats) = .initFill(.{}),
    queries_sent: u32 = 0,
    redirect_outcome: ?Outcome = null,
    validation_attempts: u32 = 0,
    validation_failure: ?Outcome = null,
    intercepted: bool = false,
    /// Set when the resolver timed out on `max_consecutive_timeouts` attempts
    /// in a row; the runner sends it no further benchmark queries.
    dropped: bool = false,
    /// Benchmark tasks finished, including tasks skipped by an early stop.
    benchmark_tasks_done: u32 = 0,

    pub fn totals(self: ServerResult) QueryStats {
        var total = QueryStats{};
        for (self.query_stats.values) |stats| total.add(stats);
        return total;
    }
};

pub const RankedRow = struct {
    server: DnsServer,
    status: ServerStatus,
    rank: u32,
    score: u32,
    success_percent: u32,
    min_us: u64,
    average_us: u64,
    max_us: u64,
    std_dev_us: u64,
    jitter_percent: u32,
    cached_average_us: u64,
    random_subdomain_average_us: u64,
    random_com_average_us: u64,
    attempts: u32 = 0,
    resolved: u32 = 0,
    queries_sent: u32 = 0,
    recommendable: bool = false,
};

test "statistics aggregate without a second mutable set of counters" {
    var total = QueryStats{};
    total.add(.{ .attempted = 2, .resolved = 1, .elapsed_total_us = 12, .elapsed_min_us = 12, .elapsed_max_us = 12 });
    total.add(.{ .attempted = 1, .resolved = 1, .elapsed_total_us = 0, .elapsed_min_us = 0, .elapsed_max_us = 0 });
    try std.testing.expectEqual(3, total.attempted);
    try std.testing.expectEqual(6, total.averageUs());
    try std.testing.expectEqual(0, total.elapsed_min_us);
}
