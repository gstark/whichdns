//! Final output: the ranked table, the resolver list, and the verdict lines.

const std = @import("std");
const core = @import("core");
const types = core.types;
const format = @import("format.zig");
const term = @import("term.zig");

/// One column of the ranked table.
pub const Column = enum {
    rank,
    resolver,
    address,
    status,
    avg,
    min,
    max,
    cached,
    random_subdomain,
    random_com,
    std_dev,
    jitter,
    success,
    score,

    pub fn header(self: Column) []const u8 {
        return switch (self) {
            .rank => "#",
            .resolver => "Resolver",
            .address => "Address",
            .status => "Status",
            .avg => "Avg ms",
            .min => "Min ms",
            .max => "Max ms",
            .cached => "Cached ms",
            .random_subdomain => "Random subdomain ms",
            .random_com => "Random .com ms",
            .std_dev => "Std dev ms",
            .jitter => "Jitter",
            .success => "Success",
            .score => "Score",
        };
    }

    pub fn isNumeric(self: Column) bool {
        return switch (self) {
            .resolver, .address, .status => false,
            else => true,
        };
    }

    /// Formats this column's cell for `row` into `buf`.
    pub fn cell(self: Column, row: types.RankedRow, buf: []u8) []const u8 {
        return switch (self) {
            .rank => format.unsigned(buf, row.rank),
            .resolver => format.resolverName(buf, row.server),
            .address => format.endpoint(buf, row.server),
            .status => row.status.label(),
            .avg => format.ms(buf, row.average_us),
            .min => format.ms(buf, row.min_us),
            .max => format.ms(buf, row.max_us),
            .cached => format.ms(buf, row.cached_average_us),
            .random_subdomain => format.ms(buf, row.random_subdomain_average_us),
            .random_com => format.ms(buf, row.random_com_average_us),
            .std_dev => format.ms(buf, row.std_dev_us),
            .jitter => format.percent(buf, row.jitter_percent),
            .success => format.percent(buf, row.success_percent),
            .score => format.unsigned(buf, row.score),
        };
    }
};

/// The printed columns. Iteration follows the declaration order of `Column`.
pub const Columns = std.EnumSet(Column);

/// Chooses the columns to print. Compact by default: the overall average and
/// the three per-kind averages. `wide` adds minimum, maximum, and standard
/// deviation. Status appears when any printed row is not reachable.
pub fn selectColumns(rows: []const types.RankedRow, wide: bool) Columns {
    return .init(.{
        .rank = true,
        .resolver = true,
        .address = true,
        .status = wide or anyNotReachable(rows),
        .avg = true,
        .min = wide,
        .max = wide,
        .cached = true,
        .random_subdomain = true,
        .random_com = true,
        .std_dev = wide,
        .jitter = true,
        .success = true,
        .score = true,
    });
}

fn anyNotReachable(rows: []const types.RankedRow) bool {
    for (rows) |row| if (row.status != .reachable) return true;
    return false;
}

const cell_capacity = types.max_server_target + 16;

/// Writes the ranked table with measured column widths.
pub fn writeRankedTable(
    w: *std.Io.Writer,
    render: term.RenderStyle,
    rows: []const types.RankedRow,
    columns: Columns,
) std.Io.Writer.Error!void {
    const first = firstColumn(columns);
    var widths: std.EnumArray(Column, usize) = .initFill(0);
    var measure = columns.iterator();
    while (measure.next()) |column| {
        var width = column.header().len;
        var buf: [cell_capacity]u8 = undefined;
        for (rows) |row| width = @max(width, column.cell(row, &buf).len);
        widths.set(column, width);
    }

    try render.style(w, .bold);
    var headers = columns.iterator();
    while (headers.next()) |column| {
        if (column != first) try w.writeAll("  ");
        try format.writePadded(w, column.header(), widths.get(column), alignment(column));
    }
    try render.style(w, .reset);
    try w.writeAll("\n");

    var rules = columns.iterator();
    while (rules.next()) |column| {
        if (column != first) try w.writeAll("  ");
        try w.splatByteAll('-', widths.get(column));
    }
    try w.writeAll("\n");

    for (rows) |row| {
        var cells = columns.iterator();
        while (cells.next()) |column| {
            if (column != first) try w.writeAll("  ");
            var buf: [cell_capacity]u8 = undefined;
            const text = column.cell(row, &buf);
            if (column == .status) {
                try render.style(w, if (row.status == .reachable) .green else .yellow);
            }
            try format.writePadded(w, text, widths.get(column), alignment(column));
            if (column == .status) try render.style(w, .reset);
        }
        try w.writeAll("\n");
    }
}

fn firstColumn(columns: Columns) ?Column {
    var it = columns.iterator();
    return it.next();
}

fn alignment(column: Column) format.Alignment {
    return if (column.isNumeric()) .right else .left;
}

/// Writes the built-in resolver inventory.
pub fn writeServerList(
    w: *std.Io.Writer,
    render: term.RenderStyle,
    servers: []const types.DnsServer,
) std.Io.Writer.Error!void {
    const headers = [_][]const u8{ "Resolver", "Address", "Port" };
    var widths = [_]usize{ headers[0].len, headers[1].len, headers[2].len };
    var buf: [cell_capacity]u8 = undefined;
    for (servers) |server| {
        widths[0] = @max(widths[0], format.resolverName(&buf, server).len);
        widths[1] = @max(widths[1], server.target.len);
        widths[2] = @max(widths[2], format.unsigned(buf[0..], server.port).len);
    }

    try render.style(w, .bold);
    try format.writePadded(w, headers[0], widths[0], .left);
    try w.writeAll("  ");
    try format.writePadded(w, headers[1], widths[1], .left);
    try w.writeAll("  ");
    try format.writePadded(w, headers[2], widths[2], .right);
    try render.style(w, .reset);
    try w.writeAll("\n");
    for (widths, 0..) |width, i| {
        if (i > 0) try w.writeAll("  ");
        try w.splatByteAll('-', width);
    }
    try w.writeAll("\n");

    for (servers) |server| {
        try format.writePadded(w, format.resolverName(&buf, server), widths[0], .left);
        try w.writeAll("  ");
        try format.writePadded(w, server.target, widths[1], .left);
        try w.writeAll("  ");
        try format.writePadded(w, format.unsigned(buf[0..], server.port), widths[2], .right);
        try w.writeAll("\n");
    }
    try w.print("\n{d} resolvers\n", .{servers.len});
}

/// Writes the closing summary: how many rows were shown, the recommended
/// resolver, how many resolvers answered every lookup, and a reminder that
/// one burst of queries is a snapshot.
pub fn writeVerdict(
    w: *std.Io.Writer,
    render: term.RenderStyle,
    ranked: []const types.RankedRow,
    shown: usize,
    elapsed_ms: u64,
) std.Io.Writer.Error!void {
    const summary = core.ranking.Summary.from(ranked);
    if (shown < ranked.len) {
        try render.style(w, .dim);
        try w.print("Showing {d} of {d} resolvers.\n", .{ shown, ranked.len });
        try render.style(w, .reset);
    }
    var buf: [cell_capacity]u8 = undefined;
    if (summary.fastest) |best| {
        try w.writeAll("Fastest reliable resolver: ");
        try render.style(w, .bold);
        try w.writeAll(format.resolverName(&buf, best.server));
        try w.print(" ({s})", .{format.endpoint(&buf, best.server)});
        try render.style(w, .reset);
        try w.print(", {s} ms average.\n", .{format.ms(&buf, best.average_us)});
    } else {
        try w.writeAll("No resolver passed characterization and succeeded on every measured lookup.\n");
    }
    try w.print("{d} of {d} resolvers passed characterization and succeeded on every measured lookup in {s} s.\n", .{
        summary.reliable_count,
        summary.resolver_count,
        format.seconds(&buf, elapsed_ms),
    });
    try w.print("{d} reachable; {d} from system DNS; {d}/{d} measured lookups succeeded; {d} queries sent.\n", .{
        summary.reachable_count,
        summary.system_count,
        summary.resolved,
        summary.attempts,
        summary.queries_sent,
    });
    try render.styled(w, .dim, "This ranking is a snapshot. " ++
        "Run again at another time of day before you change settings.\n");
}

// ---------------------------------------------------------------------------
// Tests

const expect = std.testing.expect;

const sampleRow = @import("test_fixtures.zig").sampleRow;

test "compact columns hide status, min, max, and std dev" {
    const rows = [_]types.RankedRow{sampleRow(1, .reachable)};
    const columns = selectColumns(&rows, false);
    try std.testing.expectEqual(10, columns.count());
    try expect(!columns.contains(.status));
    try expect(!columns.contains(.min));
    try expect(!columns.contains(.std_dev));
    try expect(columns.contains(.cached));
    try expect(columns.contains(.random_subdomain));
    try expect(columns.contains(.random_com));
}

test "wide shows every column" {
    const rows = [_]types.RankedRow{sampleRow(1, .reachable)};
    try std.testing.expectEqual(Columns.len, selectColumns(&rows, true).count());
}

test "non-reachable rows add the status column" {
    const rows = [_]types.RankedRow{ sampleRow(1, .reachable), sampleRow(2, .timeout) };
    const columns = selectColumns(&rows, false);
    try expect(columns.contains(.status));
    try std.testing.expectEqual(11, columns.count());
}

test "verdict reports canonical counts and fastest reliable resolver" {
    const rows = [_]types.RankedRow{ sampleRow(1, .reachable), sampleRow(2, .timeout) };
    var storage: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&storage);
    try writeVerdict(&w, .{}, &rows, 1, 14_506);
    try expect(std.mem.indexOf(u8, w.buffered(), "Fastest reliable resolver: Quad9 (9.9.9.9)") != null);
    try expect(std.mem.indexOf(u8, w.buffered(), "1 of 2 resolvers passed characterization") != null);
    try expect(std.mem.indexOf(u8, w.buffered(), "10/20 measured lookups succeeded; 34 queries sent") != null);
}

test "table and list identify system source and nonstandard ports" {
    var row = sampleRow(1, .reachable);
    row.server.system = true;
    row.server.port = 5353;
    var storage: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&storage);
    try writeRankedTable(&w, .{}, &.{row}, selectColumns(&.{row}, false));
    try expect(std.mem.indexOf(u8, w.buffered(), "[system] Quad9") != null);
    try expect(std.mem.indexOf(u8, w.buffered(), "9.9.9.9:5353") != null);
    try expect(std.mem.indexOf(u8, w.buffered(), "Random subdomain ms") != null);
    try expect(std.mem.indexOf(u8, w.buffered(), "Random .com ms") != null);
    w = std.Io.Writer.fixed(&storage);
    try writeServerList(&w, .{}, &.{row.server});
    try expect(std.mem.indexOf(u8, w.buffered(), "[system] Quad9") != null);
    try expect(std.mem.indexOf(u8, w.buffered(), "5353") != null);
}

test "report propagates writer failure" {
    var w = std.Io.Writer.fixed(&.{});
    const result: std.Io.Writer.Error!void = writeServerList(&w, .{}, &.{});
    try std.testing.expectError(error.WriteFailed, result);
}

test "partial success cannot produce a reliable verdict" {
    var row = sampleRow(1, .reachable);
    row.attempts = 10;
    row.resolved = 1;
    row.recommendable = false;
    row.queries_sent = 19;
    var storage: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&storage);
    try writeVerdict(&w, .{}, &.{row}, 1, 100);
    try expect(std.mem.indexOf(u8, w.buffered(), "Fastest reliable resolver") == null);
    try expect(std.mem.indexOf(u8, w.buffered(), "19 queries sent") != null);
}
