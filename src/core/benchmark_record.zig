//! Records semantic lookup outcomes, with category statistics as the source of truth.

const std = @import("std");
const types = @import("types.zig");
const plan = @import("benchmark_plan.zig");

pub fn passedCharacterization(result: *const types.ServerResult) bool {
    const redirect = result.redirect_outcome orelse return false;
    return !result.intercepted and (redirect == .nxdomain or redirect == .nodata) and
        result.validation_attempts == plan.validation_probes.len and result.validation_failure == null;
}

pub fn recordRedirectCheck(result: *types.ServerResult, outcome: types.Outcome) void {
    result.redirect_outcome = outcome;
    if (outcome == .address) result.intercepted = true;
}

pub fn recordValidationCheck(result: *types.ServerResult, outcome: types.Outcome) void {
    result.validation_attempts += 1;
    if (outcome != .address and result.validation_failure == null) result.validation_failure = outcome;
}

pub fn recordAttempt(result: *types.ServerResult, kind: types.QueryKind, outcome: types.Outcome, elapsed_us: u64) void {
    const stats = result.query_stats.getPtr(kind);
    stats.attempted += 1;
    if (kind == .random_com and outcome == .address) result.intercepted = true;
    if (!outcome.expected(kind)) {
        stats.failures.getPtr(failureKind(outcome)).* += 1;
        return;
    }
    if (stats.resolved == 0 or elapsed_us < stats.elapsed_min_us) stats.elapsed_min_us = elapsed_us;
    stats.resolved += 1;
    stats.elapsed_total_us += elapsed_us;
    stats.elapsed_sum_squares_us2 += @as(u128, elapsed_us) * elapsed_us;
    stats.elapsed_max_us = @max(stats.elapsed_max_us, elapsed_us);
}

fn failureKind(outcome: types.Outcome) types.FailureKind {
    return switch (outcome) {
        .address => .unexpected_answer,
        .nodata, .nxdomain => .no_answer,
        .dns_error => .dns_error,
        .failure => |failure| switch (failure) {
            .timeout => .timeout,
            .connection_refused => .refused,
            .malformed_response, .protocol_failure => .malformed,
            .truncated_response => .truncated,
            else => .socket,
        },
    };
}

test "SERVFAIL and missing cached answers do not contribute latency" {
    var result = types.ServerResult{ .server = .{ .name = "test", .target = "127.0.0.1" } };
    recordAttempt(&result, .cached, .address, 100_000);
    recordAttempt(&result, .cached, .{ .dns_error = .servfail }, 1000);
    recordAttempt(&result, .cached, .nodata, 1000);
    const stats = result.totals();
    try std.testing.expectEqual(3, stats.attempted);
    try std.testing.expectEqual(1, stats.resolved);
    try std.testing.expectEqual(100_000, stats.averageUs());
}

test "characterization requires actual negative and positive probes" {
    var result = types.ServerResult{ .server = .{ .name = "test", .target = "127.0.0.1" } };
    try std.testing.expect(!passedCharacterization(&result));
    recordRedirectCheck(&result, .{ .failure = .timeout });
    for (plan.validation_probes) |_| recordValidationCheck(&result, .address);
    try std.testing.expect(!passedCharacterization(&result));
    recordRedirectCheck(&result, .nxdomain);
    try std.testing.expect(passedCharacterization(&result));
    recordAttempt(&result, .random_com, .address, 10);
    try std.testing.expect(!passedCharacterization(&result));
}
