//! Public module surface for the DNS benchmark core and aggregate test root.

pub const posix = @import("posix.zig");
pub const version = @import("version.zig");
pub const types = @import("types.zig");
pub const dns_packet = @import("dns_packet.zig");
pub const default_servers = @import("default_servers.zig");
pub const ranking = @import("ranking.zig");
pub const benchmark_plan = @import("benchmark_plan.zig");
pub const benchmark_record = @import("benchmark_record.zig");
pub const benchmark_validate = @import("benchmark_validate.zig");
pub const benchmark_config = @import("benchmark_config.zig");
pub const net_util = @import("net_util.zig");
pub const udp_queued_runner = @import("udp_queued_runner.zig");

test {
    _ = types;
    _ = dns_packet;
    _ = default_servers;
    _ = ranking;
    _ = benchmark_plan;
    _ = benchmark_record;
    _ = benchmark_validate;
    _ = benchmark_config;
    _ = net_util;
    _ = udp_queued_runner;
}
