//! Reliability-first ranking and one factual summary shared by all reports.

const std = @import("std");
const types = @import("types.zig");
const record = @import("benchmark_record.zig");
const benchmark_plan = @import("benchmark_plan.zig");

pub fn serverAverageUs(result: types.ServerResult) u64 {
    var sum: u64 = 0;
    var count: u64 = 0;
    for (result.query_stats.values) |stats| {
        if (stats.resolved == 0) continue;
        sum += stats.averageUs();
        count += 1;
    }
    return if (count == 0) 0 else sum / count;
}

pub fn serverStdDevUs(result: types.ServerResult) u64 {
    const stats = result.query_stats.get(.cached);
    if (stats.resolved < 2) return 0;
    const count: u256 = stats.resolved;
    const sum: u256 = stats.elapsed_total_us;
    const numerator = @as(u256, stats.elapsed_sum_squares_us2) * count - sum * sum;
    return @intCast(integerSqrt(@intCast(numerator / (count * count))));
}

fn integerSqrt(value: u128) u128 {
    if (value < 2) return value;
    var low: u128 = 1;
    var high: u128 = value / 2 + 1;
    while (low + 1 < high) {
        const middle = low + (high - low) / 2;
        if (middle <= value / middle) {
            low = middle;
        } else {
            high = middle;
        }
    }
    return low;
}

pub fn characterizeServer(result: types.ServerResult) types.ServerStatus {
    if (result.intercepted) return .redirect_or_intercept;
    if (result.validation_failure) |failure| return failureStatus(failure);
    if (result.redirect_outcome) |outcome| {
        if (outcome != .nxdomain and outcome != .nodata) return failureStatus(outcome);
    }
    if (!record.passedCharacterization(&result)) return .unavailable;
    const total = result.totals();
    if (total.attempted == 0) return .unavailable;
    if (result.dropped) return .dropped;
    if (total.failureCount(.timeout) == total.attempted) return .timeout;
    for (result.query_stats.values) |stats| if (stats.resolved == 0) return .incomplete;
    return .reachable;
}

fn failureStatus(outcome: types.Outcome) types.ServerStatus {
    return switch (outcome) {
        .address => .redirect_or_intercept,
        .nodata, .nxdomain => .no_answer,
        .dns_error => |rcode| if (rcode == .refused) .rejected else .dns_service_available,
        .failure => |failure| switch (failure) {
            .timeout => .timeout,
            .connection_refused => .refused,
            .malformed_response => .invalid_reply,
            .truncated_response => .truncated,
            .protocol_failure => .unsupported_protocol,
            else => .rejected,
        },
    };
}

pub fn rank(results: []const types.ServerResult, rows: []types.RankedRow) ![]types.RankedRow {
    if (results.len > rows.len) return error.BufferTooSmall;
    for (results, 0..) |result, i| {
        const total = result.totals();
        const status = characterizeServer(result);
        const cached = result.query_stats.get(.cached).averageUs();
        const deviation = serverStdDevUs(result);
        rows[i] = .{
            .server = result.server,
            .status = status,
            .rank = 0,
            .score = if (status == .reachable) ratio(total.resolved, total.attempted, 1000) else 0,
            .success_percent = ratio(total.resolved, total.attempted, 100),
            .min_us = total.elapsed_min_us,
            .average_us = serverAverageUs(result),
            .max_us = total.elapsed_max_us,
            .std_dev_us = deviation,
            .jitter_percent = if (cached == 0) 0 else @intCast(deviation * 100 / cached),
            .cached_average_us = cached,
            .random_subdomain_average_us = result.query_stats.get(.random_subdomain).averageUs(),
            .random_com_average_us = result.query_stats.get(.random_com).averageUs(),
            .attempts = total.attempted,
            .resolved = total.resolved,
            .queries_sent = result.queries_sent,
            .recommendable = status == .reachable and total.attempted > 0 and total.resolved == total.attempted,
        };
    }
    const ranked = rows[0..results.len];
    // Insertion sort is fast enough for max_servers rows. std.mem.sort adds
    // about 7 KB of block-sort code to the release binary.
    std.sort.insertion(types.RankedRow, ranked, {}, rowLessThan);
    for (ranked, 0..) |*row, i| row.rank = @intCast(i + 1);
    return ranked;
}

fn ratio(numerator: u32, denominator: u32, scale: u32) u32 {
    return if (denominator == 0) 0 else @intCast(@as(u64, numerator) * scale / denominator);
}

fn rowLessThan(_: void, left: types.RankedRow, right: types.RankedRow) bool {
    const left_eligible = left.status == .reachable;
    const right_eligible = right.status == .reachable;
    if (left_eligible != right_eligible) return left_eligible;
    const left_ratio = @as(u64, left.resolved) * @max(right.attempts, 1);
    const right_ratio = @as(u64, right.resolved) * @max(left.attempts, 1);
    if (left_ratio != right_ratio) return left_ratio > right_ratio;
    if (left.resolved != 0 and right.resolved == 0) return true;
    if (left.resolved == 0 and right.resolved != 0) return false;
    if (left.average_us != right.average_us) return left.average_us < right.average_us;
    const names = std.mem.order(u8, left.server.name, right.server.name);
    if (names != .eq) return names == .lt;
    const addresses = std.mem.order(u8, left.server.target, right.server.target);
    if (addresses != .eq) return addresses == .lt;
    return left.server.port < right.server.port;
}

pub const Summary = struct {
    resolver_count: usize = 0,
    reachable_count: usize = 0,
    reliable_count: usize = 0,
    system_count: usize = 0,
    queries_sent: u64 = 0,
    attempts: u64 = 0,
    resolved: u64 = 0,
    fastest: ?types.RankedRow = null,

    pub fn from(ranked: []const types.RankedRow) Summary {
        var summary = Summary{ .resolver_count = ranked.len };
        for (ranked) |row| {
            summary.queries_sent += row.queries_sent;
            summary.attempts += row.attempts;
            summary.resolved += row.resolved;
            if (row.server.system) summary.system_count += 1;
            if (row.status == .reachable) summary.reachable_count += 1;
            if (row.recommendable) {
                summary.reliable_count += 1;
                if (summary.fastest == null) summary.fastest = row;
            }
        }
        return summary;
    }
};

fn fixture(name: []const u8) types.ServerResult {
    var result = types.ServerResult{
        .server = .{ .name = name, .target = "127.0.0.1" },
        .redirect_outcome = .nxdomain,
    };
    for (benchmark_plan.validation_probes) |_| record.recordValidationCheck(&result, .address);
    return result;
}

test "SERVFAIL responses never make a resolver outrank a fully successful peer" {
    var bad = fixture("bad");
    var good = fixture("good");
    for (std.enums.values(types.QueryKind)) |kind| {
        const answer: types.Outcome = if (kind == .cached) .address else .nxdomain;
        record.recordAttempt(&bad, kind, answer, 100_000);
        for (0..9) |_| record.recordAttempt(&bad, kind, .{ .dns_error = .servfail }, 1000);
        for (0..10) |_| record.recordAttempt(&good, kind, answer, 100_000);
    }
    var rows: [2]types.RankedRow = undefined;
    const ranked = try rank(&.{ bad, good }, &rows);
    try std.testing.expectEqualStrings("good", ranked[0].server.name);
    try std.testing.expectEqual(100_000, ranked[1].average_us);
    try std.testing.expect(!ranked[1].recommendable);
    const summary = Summary.from(ranked);
    try std.testing.expectEqual(1, summary.reliable_count);
    try std.testing.expectEqualStrings("good", summary.fastest.?.server.name);
}

test "rank exact success ratios before latency and before rounded percentages" {
    var a = fixture("99.9 percent");
    var b = fixture("99.8 percent");
    for (std.enums.values(types.QueryKind)) |kind| {
        for (0..999) |_| record.recordAttempt(&a, kind, if (kind == .cached) .address else .nxdomain, 100_000);
        for (0..998) |_| record.recordAttempt(&b, kind, if (kind == .cached) .address else .nxdomain, 100);
        record.recordAttempt(&a, kind, .{ .failure = .timeout }, 0);
        for (0..2) |_| record.recordAttempt(&b, kind, .{ .failure = .timeout }, 0);
    }
    var rows: [2]types.RankedRow = undefined;
    const ranked = try rank(&.{ b, a }, &rows);
    try std.testing.expectEqualStrings(a.server.name, ranked[0].server.name);
    try std.testing.expect(Summary.from(ranked).fastest == null);
}

test "cached deviation preserves fractional means and known variance" {
    var result = fixture("test");
    record.recordAttempt(&result, .cached, .address, 1_000_000);
    record.recordAttempt(&result, .cached, .address, 1_000_001);
    try std.testing.expectEqual(0, serverStdDevUs(result));
    result = fixture("test");
    for ([_]u64{ 2, 4, 4, 4, 5, 5, 7, 9 }) |elapsed| record.recordAttempt(&result, .cached, .address, elapsed);
    try std.testing.expectEqual(2, serverStdDevUs(result));
}
