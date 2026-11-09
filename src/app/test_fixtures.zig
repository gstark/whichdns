//! Ranked-row fixtures shared by the report and JSON output tests.

const types = @import("core").types;

/// A Quad9 row with typical timings. Only reachable rows resolve lookups.
pub fn sampleRow(rank: u32, status: types.ServerStatus) types.RankedRow {
    return .{
        .server = .{ .name = "Quad9", .target = "9.9.9.9", .port = 53 },
        .status = status,
        .rank = rank,
        .score = if (status == .reachable) 986 else 0,
        .success_percent = 100,
        .recommendable = status == .reachable,
        .attempts = 10,
        .resolved = if (status == .reachable) 10 else 0,
        .queries_sent = 17,
        .min_us = 10_800,
        .average_us = 14_200,
        .max_us = 28_200,
        .std_dev_us = 2_800,
        .jitter_percent = 19,
        .cached_average_us = 14_600,
        .random_subdomain_average_us = 41_300,
        .random_com_average_us = 13_800,
    };
}
