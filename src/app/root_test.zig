//! Aggregate test root for the command-line application modules.

test {
    _ = @import("cli.zig");
    _ = @import("config.zig");
    _ = @import("resolver_inventory.zig");
    _ = @import("dashboard.zig");
    _ = @import("format.zig");
    _ = @import("json_report.zig");
    _ = @import("report.zig");
    _ = @import("term.zig");
    _ = @import("test_fixtures.zig");
}
