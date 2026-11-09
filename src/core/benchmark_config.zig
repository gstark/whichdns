//! Runtime controls shared by the queued engine and its observers.

const types = @import("types.zig");
const benchmark_plan = @import("benchmark_plan.zig");

pub const Progress = struct {
    context: *anyopaque,
    callback: *const fn (*anyopaque, usize) void,
};

pub const RunConfig = struct {
    plan: benchmark_plan.Config = .{},
    timeout_ms: u32 = types.default_timeout_ms,
    pause_ms: u32 = types.default_pause_ms,
    progress: ?Progress = null,

    pub fn timeoutUs(self: RunConfig) u64 {
        return @as(u64, self.timeout_ms) * 1000;
    }

    pub fn pauseUs(self: RunConfig) u64 {
        return @as(u64, self.pause_ms) * 1000;
    }
};
