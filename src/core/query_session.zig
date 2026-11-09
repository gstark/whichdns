//! Pure per-resolver query lifecycle. No sockets, clocks, rendering, or recursion.

const std = @import("std");
const types = @import("types.zig");
const plan = @import("benchmark_plan.zig");
const record = @import("benchmark_record.zig");
const RunConfig = @import("benchmark_config.zig").RunConfig;

pub const Sample = struct {
    kind: types.QueryKind,
    iteration: u32,
    index: usize,
};

/// Maps a benchmark task index to its sample. Kinds interleave on every sample,
/// so a resolver never sees a long run of uncached (mostly NXDOMAIN) queries.
pub fn sampleAt(index: usize, config: plan.Config) Sample {
    const per_kind = config.samples_per_kind;
    return .{
        .index = (index / types.query_kind_count) % per_kind,
        .kind = std.enums.values(types.QueryKind)[index % types.query_kind_count],
        .iteration = @intCast(index / (per_kind * types.query_kind_count)),
    };
}

pub const Stage = union(enum) {
    characterization: usize,
    benchmark: usize,
    done,
};

pub const State = union(enum) {
    ready,
    waiting: struct { started_us: u64 },
    done,
};

pub const Session = struct {
    stage: Stage = .{ .characterization = 0 },
    state: State = .ready,
    attempt: u32 = 0,
    priming: bool = false,
    ready_at_us: u64 = 0,
    next_sample_us: u64 = 0,
    consecutive_timeouts: u32 = 0,

    pub fn beginBenchmark(
        self: *Session,
        config: RunConfig,
        result: *types.ServerResult,
        epoch_us: u64,
        index: usize,
        count: usize,
    ) usize {
        if (!record.passedCharacterization(result)) {
            self.stage = .done;
            self.state = .done;
            return finishTasks(result, plan.benchmarkTasksPerServer(config.plan));
        }
        self.stage = .{ .benchmark = 0 };
        self.state = .ready;
        self.priming = true;
        self.ready_at_us = epoch_us + config.pauseUs() * index / count;
        return 0;
    }

    /// Consume a completed attempt exactly once, returning completed logical tasks.
    /// The caller dispatches any resulting ready state on a subsequent event-loop turn.
    pub fn complete(
        self: *Session,
        config: RunConfig,
        result: *types.ServerResult,
        outcome: types.Outcome,
        elapsed_us: u64,
    ) usize {
        std.debug.assert(self.state == .waiting);
        self.state = .ready;
        switch (self.stage) {
            .characterization => |index| {
                const probe = plan.characterizationProbeAt(index);
                if (probe == .validation and outcome != .address and outcome.retryable() and self.attempt < 1) {
                    self.attempt += 1;
                    return 0;
                }
                switch (probe) {
                    .redirect => record.recordRedirectCheck(result, outcome),
                    .validation => record.recordValidationCheck(result, outcome),
                }
                self.attempt = 0;
                if (index + 1 == plan.characterization_probes_per_server) {
                    self.state = .done;
                } else self.stage = .{ .characterization = index + 1 };
                return 1;
            },
            .benchmark => |index| {
                const sample = sampleAt(index, config.plan);
                if (self.priming and outcome == .address) {
                    self.priming = false;
                    self.ready_at_us = 0;
                    return 0;
                }
                record.recordAttempt(result, sample.kind, outcome, elapsed_us);
                self.ready_at_us = self.next_sample_us;
                const timed_out = outcome == .failure and outcome.failure == .timeout;
                self.consecutive_timeouts = if (timed_out) self.consecutive_timeouts + 1 else 0;
                if (self.consecutive_timeouts >= plan.max_consecutive_timeouts) result.dropped = true;
                const can_retry = !result.dropped and outcome.retryable() and self.attempt < config.plan.retries;
                if (can_retry and !outcome.expected(sample.kind)) {
                    self.attempt += 1;
                    self.priming = sample.kind == .cached;
                    return 0;
                }
                self.attempt = 0;
                if (result.intercepted or result.dropped or index + 1 == plan.benchmarkTasksPerServer(config.plan)) {
                    self.stage = .done;
                    self.state = .done;
                    return finishTasks(result, plan.benchmarkTasksPerServer(config.plan) - index);
                }
                self.stage = .{ .benchmark = index + 1 };
                self.priming = sampleAt(index + 1, config.plan).kind == .cached;
                return finishTasks(result, 1);
            },
            .done => unreachable,
        }
    }
};

fn finishTasks(result: *types.ServerResult, count: usize) usize {
    result.benchmark_tasks_done += @intCast(count);
    return count;
}

test "a failed follow-up send completes once after the prime leaves waiting state" {
    var session = Session{ .stage = .{ .benchmark = 0 }, .state = .{ .waiting = .{ .started_us = 10 } }, .priming = true };
    var result = types.ServerResult{ .server = .{ .name = "test", .target = "127.0.0.1" } };
    const config = RunConfig{ .plan = .{ .samples_per_kind = 1 } };
    try std.testing.expectEqual(0, session.complete(config, &result, .address, 10));
    try std.testing.expect(session.state == .ready);
    try std.testing.expect(!session.priming);
    // Dispatch failure is a new completion, never a nested completion of the prime.
    session.state = .{ .waiting = .{ .started_us = 30 } };
    try std.testing.expectEqual(1, session.complete(config, &result, .{ .failure = .socket_failure }, 0));
    try std.testing.expectEqual(1, result.totals().attempted);
}

test "all first-send offsets share one epoch" {
    const config = RunConfig{ .pause_ms = 400 };
    for (0..125) |index| {
        var session = Session{};
        var result = types.ServerResult{ .server = .{ .name = "test", .target = "127.0.0.1" }, .redirect_outcome = .nxdomain, .validation_attempts = plan.validation_probes.len };
        _ = session.beginBenchmark(config, &result, 1_000_000, index, 125);
        try std.testing.expect(session.ready_at_us >= 1_000_000 and session.ready_at_us < 1_400_000);
    }
}

test "retry pacing and accounting are independent of transport" {
    var session = Session{ .stage = .{ .benchmark = 0 }, .state = .{ .waiting = .{ .started_us = 10 } }, .priming = true, .next_sample_us = 400_010 };
    var result = types.ServerResult{ .server = .{ .name = "test", .target = "127.0.0.1" } };
    const config = RunConfig{ .plan = .{ .samples_per_kind = 1, .retries = 1 } };
    try std.testing.expectEqual(0, session.complete(config, &result, .{ .failure = .timeout }, 100));
    try std.testing.expectEqual(400_010, session.ready_at_us);
    try std.testing.expectEqual(1, session.attempt);
    try std.testing.expectEqual(1, result.totals().failureCount(.timeout));
}

test "consecutive timeouts drop a resolver and finish its remaining tasks" {
    const config = RunConfig{ .plan = .{ .samples_per_kind = 10 } };
    const total = plan.benchmarkTasksPerServer(config.plan);
    var session = Session{ .stage = .{ .benchmark = 1 } };
    var result = types.ServerResult{ .server = .{ .name = "test", .target = "127.0.0.1" } };
    var completed: usize = 0;
    for (0..plan.max_consecutive_timeouts) |_| {
        session.state = .{ .waiting = .{ .started_us = 0 } };
        completed += session.complete(config, &result, .{ .failure = .timeout }, 0);
    }
    try std.testing.expect(result.dropped);
    try std.testing.expect(session.state == .done);
    try std.testing.expectEqual(total - 1, completed);
    try std.testing.expectEqual(@as(u32, @intCast(total - 1)), result.benchmark_tasks_done);
    try std.testing.expectEqual(plan.max_consecutive_timeouts, result.totals().attempted);
}

test "a successful sample resets the consecutive timeout count" {
    const config = RunConfig{ .plan = .{ .samples_per_kind = 10 } };
    var session = Session{ .stage = .{ .benchmark = 10 } };
    var result = types.ServerResult{ .server = .{ .name = "test", .target = "127.0.0.1" } };
    for (0..2 * plan.max_consecutive_timeouts) |i| {
        session.state = .{ .waiting = .{ .started_us = 0 } };
        const outcome: types.Outcome = if (i % plan.max_consecutive_timeouts == 0) .nxdomain else .{ .failure = .timeout };
        _ = session.complete(config, &result, outcome, 0);
    }
    try std.testing.expect(!result.dropped);
    try std.testing.expect(session.state == .ready);
}

test "the next sample after a timeout is not delayed by the pause" {
    const config = RunConfig{ .pause_ms = 400, .timeout_ms = 1500, .plan = .{ .samples_per_kind = 10 } };
    var session = Session{ .stage = .{ .benchmark = 10 }, .state = .{ .waiting = .{ .started_us = 0 } }, .next_sample_us = 400_000 };
    var result = types.ServerResult{ .server = .{ .name = "test", .target = "127.0.0.1" } };
    _ = session.complete(config, &result, .{ .failure = .timeout }, 1_500_000);
    // The pause runs from the send, so it has already elapsed when the deadline passes.
    try std.testing.expect(session.ready_at_us <= 1_500_000);
}
