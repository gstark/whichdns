//! Live progress view drawn in place while the benchmark runs on a TTY.

const std = @import("std");
const core = @import("core");
const net_util = core.net_util;
const ranking = core.ranking;
const types = core.types;
const format = @import("format.zig");
const term = @import("term.zig");

pub const top_count: usize = 10;
const redraw_interval_us: u64 = 100_000;
const bar_width: usize = 30;
const label_width: usize = 22;
const name_width: usize = 21;
const avg_width: usize = 7;
const success_width: usize = 8;
/// Below this width the resolver name column is dropped so the address fits.
const name_min_width: usize = 60;

/// Position within the current phase, derived from the runner's overall
/// completed task count. Validation tasks run before benchmark tasks.
pub const Phase = struct {
    validating: bool,
    done: usize,
    total: usize,

    pub fn at(done: usize, validation_total: usize, total: usize) Phase {
        const validating = done < validation_total;
        const phase_total = if (validating) validation_total else total -| validation_total;
        const phase_done = if (validating) done else done -| validation_total;
        return .{ .validating = validating, .done = @min(phase_done, phase_total), .total = phase_total };
    }
};

/// Draws in place on the normal screen: each frame moves the cursor back to
/// the first dashboard line and redraws, so the terminal scrollback keeps
/// only the final output.
pub const Dashboard = struct {
    w: *std.Io.Writer,
    total: usize,
    validation_total: usize,
    results: []const types.ServerResult,
    started_us: u64,
    phase_started_us: u64,
    in_validation: bool = true,
    drawn: bool = false,
    /// Lines written by the last frame; the next frame moves up this many.
    lines: usize = 0,
    last_draw_us: u64 = 0,
    unicode: bool,
    address_width: usize,
    render: term.RenderStyle,
    completed: usize = 0,
    output_error: ?std.Io.Writer.Error = null,

    pub fn init(
        w: *std.Io.Writer,
        total: usize,
        validation_total: usize,
        results: []const types.ServerResult,
        render: term.RenderStyle,
    ) Dashboard {
        const now = net_util.nowUs();
        var address_width: usize = "Address".len;
        var buf: [types.max_server_target + 16]u8 = undefined;
        for (results) |result| address_width = @max(address_width, format.endpoint(&buf, result.server).len);
        return .{
            .w = w,
            .total = total,
            .validation_total = validation_total,
            .results = results,
            .started_us = now,
            .phase_started_us = now,
            .unicode = term.utf8Locale(),
            .address_width = address_width,
            .render = render,
        };
    }

    /// Progress callback for the benchmark runner. Redraws at most every 100 ms.
    pub fn progress(context: *anyopaque, done: usize) void {
        const self: *Dashboard = @ptrCast(@alignCast(context));
        self.completed = done;
        if (self.output_error != null) return;
        const now = net_util.nowUs();
        if (self.last_draw_us != 0 and now -| self.last_draw_us < redraw_interval_us) return;
        self.last_draw_us = now;
        self.draw(done, now) catch |err| {
            self.output_error = err;
        };
    }

    /// Erases the dashboard and restores the cursor before the final report,
    /// which repeats the full ranking.
    pub fn finish(self: *Dashboard) std.Io.Writer.Error!void {
        const erased = self.erase();
        const restore = term.endDashboard(self.w);
        if (self.output_error) |err| return err;
        try erased;
        try restore;
    }

    fn draw(self: *Dashboard, done: usize, now_us: u64) std.Io.Writer.Error!void {
        try term.beginDashboard(self.w);
        self.drawn = true;
        const phase = Phase.at(done, self.validation_total, self.total);
        if (self.in_validation and !phase.validating) {
            self.in_validation = false;
            self.phase_started_us = now_us;
        }
        try self.moveToTop();
        // Re-query dimensions so a resize changes the next frame's layout.
        self.lines = try self.writeFrame(self.w, term.dimensions(), done, now_us);
        try self.w.flush();
    }

    fn erase(self: *Dashboard) std.Io.Writer.Error!void {
        if (!self.drawn) return;
        try self.moveToTop();
        self.lines = 0;
        try self.w.flush();
    }

    /// Returns to the first dashboard line and clears everything below it.
    fn moveToTop(self: *const Dashboard) std.Io.Writer.Error!void {
        if (self.lines != 0) try self.w.print("\x1b[{d}A", .{self.lines});
        try self.w.writeAll("\r\x1b[J");
    }

    /// Writes one frame and returns its line count. Lines stop one column
    /// short of the edge to prevent autowrap, and the frame stays at least one
    /// row shorter than the terminal so moving up never passes the top.
    pub fn writeFrame(
        self: *const Dashboard,
        w: *std.Io.Writer,
        size: term.Dimensions,
        done: usize,
        now_us: u64,
    ) std.Io.Writer.Error!usize {
        const width = @min(size.columns -| 1, 512);
        if (width == 0 or size.rows < 2) return 0;
        const phase = Phase.at(done, self.validation_total, self.total);
        try self.writeProgressLine(w, width, phase, now_us);
        if (size.rows < 4) return 1;
        const wide = width >= name_min_width;
        try self.writeHeaderLine(w, width, wide);
        var rows: [types.max_servers]types.RankedRow = undefined;
        const top = liveTop(self.results, &rows);
        const count = @min(top_count, size.rows - 3);
        var rank: [20]u8 = undefined;
        for (0..count) |i| {
            var line = self.lineWriter(w, width);
            try line.padded(format.unsigned(&rank, i + 1), 4, .right);
            try line.spaces(2);
            if (i < top.len) {
                try self.writeRow(&line, top[i], wide);
            } else {
                try line.style(.dim);
                try line.cells(if (self.unicode) "·" else ".", 1);
            }
            try line.end();
        }
        return 2 + count;
    }

    fn writeProgressLine(
        self: *const Dashboard,
        w: *std.Io.Writer,
        width: usize,
        phase: Phase,
        now_us: u64,
    ) std.Io.Writer.Error!void {
        // Holds two maximum usize values and a separator.
        var buf: [48]u8 = undefined;
        var line = self.lineWriter(w, width);
        try line.style(.bold);
        try line.padded(if (phase.validating) "Validating resolvers" else "Benchmarking", label_width, .left);
        try line.style(.reset);
        const filled = if (phase.total == 0) bar_width else (phase.done * bar_width) / phase.total;
        try line.style(.cyan);
        try line.cells(if (self.unicode) "█" else "#", filled);
        try line.style(.dim);
        try line.cells(if (self.unicode) "░" else "-", bar_width - filled);
        try line.style(.reset);
        try line.spaces(2);
        const percent = if (phase.total == 0) 100 else (phase.done * 100) / phase.total;
        try line.padded(format.percent(&buf, percent), 4, .right);
        try line.spaces(2);
        try line.text(format.print(&buf, "{d}/{d}", .{ phase.done, phase.total }));
        try line.spaces(3);
        try line.text(format.clock(&buf, (now_us -| self.started_us) / 1_000_000));
        try line.text(" elapsed");
        if (phaseEtaUs(phase, now_us -| self.phase_started_us, self.results)) |eta| {
            try line.text(", ~");
            try line.text(format.clock(&buf, eta / 1_000_000));
            try line.text(" left");
        }
        try line.end();
    }

    fn writeHeaderLine(self: *const Dashboard, w: *std.Io.Writer, width: usize, wide: bool) std.Io.Writer.Error!void {
        var line = self.lineWriter(w, width);
        try line.style(.dim);
        try line.padded("#", 4, .right);
        try line.spaces(2);
        if (wide) {
            try line.padded("Resolver", name_width, .left);
            try line.spaces(2);
        }
        try line.padded("Address", self.address_width, .left);
        try line.spaces(2);
        try line.padded("Avg ms", avg_width, .right);
        try line.padded("Success", success_width, .right);
        try line.end();
    }

    fn writeRow(self: *const Dashboard, line: *Line, row: types.RankedRow, wide: bool) std.Io.Writer.Error!void {
        var buf: [types.max_server_name + types.max_server_target + 16]u8 = undefined;
        if (wide) {
            try line.padded(format.resolverName(&buf, row.server), name_width, .left);
            try line.spaces(2);
        }
        try line.padded(format.endpoint(&buf, row.server), self.address_width, .left);
        try line.spaces(2);
        try line.padded(format.ms(&buf, row.average_us), avg_width, .right);
        try line.padded(format.percent(&buf, row.success_percent), success_width, .right);
    }

    fn lineWriter(self: *const Dashboard, w: *std.Io.Writer, width: usize) Line {
        return .{ .w = w, .render = self.render, .left = width };
    }
};

/// One output line clipped to the terminal width. Dynamic text is
/// ASCII-sanitized so bytes equal display columns and names cannot inject
/// terminal control sequences.
const Line = struct {
    w: *std.Io.Writer,
    render: term.RenderStyle,
    left: usize,

    fn text(self: *Line, s: []const u8) std.Io.Writer.Error!void {
        const shown = @min(s.len, self.left);
        for (s[0..shown]) |byte| try self.w.writeByte(if (byte >= 32 and byte <= 126) byte else '?');
        self.left -= shown;
    }

    fn padded(self: *Line, s: []const u8, width: usize, alignment: format.Alignment) std.Io.Writer.Error!void {
        const shown = @min(s.len, width);
        if (alignment == .right) try self.spaces(width - shown);
        try self.text(s[0..shown]);
        if (alignment == .left) try self.spaces(width - shown);
    }

    fn spaces(self: *Line, count: usize) std.Io.Writer.Error!void {
        const shown = @min(count, self.left);
        try self.w.splatByteAll(' ', shown);
        self.left -= shown;
    }

    /// Writes `count` copies of a glyph that occupies one column.
    fn cells(self: *Line, glyph: []const u8, count: usize) std.Io.Writer.Error!void {
        const shown = @min(count, self.left);
        for (0..shown) |_| try self.w.writeAll(glyph);
        self.left -= shown;
    }

    fn style(self: *Line, s: term.Style) std.Io.Writer.Error!void {
        try self.render.style(self.w, s);
    }

    fn end(self: *Line) std.Io.Writer.Error!void {
        try self.render.style(self.w, .reset);
        try self.w.writeByte('\n');
    }
};

/// Estimates the remaining time for a phase in microseconds. Null before
/// 5 percent is done and once the phase is complete.
pub fn etaUs(phase_elapsed_us: u64, done: usize, total: usize) ?u64 {
    if (total == 0 or done == 0 or done >= total) return null;
    if (done * 100 < total * 5) return null;
    const remaining: u64 = @intCast(total - done);
    return phase_elapsed_us * remaining / @as(u64, @intCast(done));
}

/// Estimates the remaining time for a phase. Benchmark samples are paced per
/// resolver, so a slow resolver can need far longer than the overall rate
/// suggests. The estimate is the larger of the overall estimate and the
/// slowest unfinished resolver's own estimate.
pub fn phaseEtaUs(phase: Phase, phase_elapsed_us: u64, results: []const types.ServerResult) ?u64 {
    const overall = etaUs(phase_elapsed_us, phase.done, phase.total) orelse return null;
    if (phase.validating or results.len == 0) return overall;
    const per_server = phase.total / results.len;
    var slowest: u64 = 0;
    for (results) |result| {
        const done = result.benchmark_tasks_done;
        if (done == 0 or done >= per_server) continue;
        slowest = @max(slowest, phase_elapsed_us * (per_server - done) / done);
    }
    return @max(overall, slowest);
}

/// Ranks the partial results into `rows` and returns at most `top_count`
/// leaders. Resolvers without a successful sample yet are left out.
pub fn liveTop(results: []const types.ServerResult, rows: *[types.max_servers]types.RankedRow) []const types.RankedRow {
    const ranked = ranking.rank(results, rows[0..]) catch return &.{};
    var shown: usize = 0;
    for (ranked) |row| {
        if (shown == top_count) break;
        if (row.resolved == 0) continue;
        rows[shown] = row;
        shown += 1;
    }
    return ranked[0..shown];
}

const expect = std.testing.expect;

test "eta waits for five percent then scales elapsed time" {
    try expect(etaUs(1_000_000, 4, 100) == null);
    try expect(etaUs(1_000_000, 0, 100) == null);
    try expect(etaUs(1_000_000, 5, 0) == null);
    try expect(etaUs(1_000_000, 100, 100) == null);
    try std.testing.expectEqual(10_000_000, etaUs(10_000_000, 50, 100).?);
    try std.testing.expectEqual(10_000_000, etaUs(30_000_000, 75, 100).?);
}

test "benchmark eta follows the slowest unfinished resolver" {
    var results = [_]types.ServerResult{
        .{ .server = .{ .name = "fast", .target = "127.0.0.1" }, .benchmark_tasks_done = 100 },
        .{ .server = .{ .name = "slow", .target = "127.0.0.2" }, .benchmark_tasks_done = 25 },
    };
    const phase = Phase{ .validating = false, .done = 125, .total = 200 };
    // Overall: 10 s for 125 of 200 tasks gives 6 s. The slow resolver needs 30 s.
    try std.testing.expectEqual(30_000_000, phaseEtaUs(phase, 10_000_000, &results).?);
    results[1].benchmark_tasks_done = 100;
    try expect(phaseEtaUs(.{ .validating = false, .done = 200, .total = 200 }, 10_000_000, &results) == null);
    try expect(phaseEtaUs(.{ .validating = true, .done = 50, .total = 100 }, 10_000_000, &results).? == 10_000_000);
}

test "throttled progress retains the latest completed count" {
    var unused: std.Io.Writer = .failing;
    var live = Dashboard.init(&unused, 100, 7, &.{}, .{});
    // A future timestamp deterministically keeps the saturating elapsed time at zero.
    live.last_draw_us = std.math.maxInt(u64);
    Dashboard.progress(&live, 100);
    try std.testing.expectEqual(@as(usize, 100), live.completed);
    try std.testing.expect(!live.drawn);
}

test "finish returns a write failure captured by the progress callback" {
    var failing: std.Io.Writer = .failing;
    var live = Dashboard.init(&failing, 100, 7, &.{}, .{});
    Dashboard.progress(&live, 1);
    try std.testing.expectEqual(error.WriteFailed, live.output_error.?);
    try std.testing.expectError(error.WriteFailed, live.finish());
    var restore_storage: [64]u8 = undefined;
    var restore = std.Io.Writer.fixed(&restore_storage);
    try term.endDashboard(&restore);
}

test "redraws move up over the previous frame and finish erases it" {
    var storage: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&storage);
    var live = Dashboard.init(&w, 100, 7, &.{}, .{});
    live.unicode = false;
    try live.draw(1, live.started_us);
    const lines = live.lines;
    try expect(lines > 0);
    try expect(std.mem.indexOf(u8, w.buffered(), "A\r") == null);
    try live.draw(2, live.started_us);
    var expected: [16]u8 = undefined;
    const move = try std.fmt.bufPrint(&expected, "\x1b[{d}A\r\x1b[J", .{lines});
    try std.testing.expectEqual(1, std.mem.count(u8, w.buffered(), move));
    try live.finish();
    try std.testing.expectEqual(2, std.mem.count(u8, w.buffered(), move));
    try expect(std.mem.indexOf(u8, w.buffered(), "\x1b[?1049") == null);
}

test "frames fit eighty column and narrow terminals before and after resize" {
    var result = types.ServerResult{ .server = .{ .name = "System\x1b[31m", .target = "2001:db8:1234:5678:abcd:efab:1234:5678", .port = 5353, .system = true } };
    for (&result.query_stats.values) |*stats| stats.* = .{ .attempted = 1, .resolved = 1, .elapsed_total_us = 1000 };
    var unused: std.Io.Writer = .failing;
    var live = Dashboard.init(&unused, 10000, 1000, &.{result}, .{});
    live.unicode = false;
    for ([_]term.Dimensions{ .{ .columns = 80, .rows = 24 }, .{ .columns = 40, .rows = 10 }, .{ .columns = 12, .rows = 3 }, .{ .columns = 1, .rows = 1 } }) |size| {
        var storage: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&storage);
        const written = try live.writeFrame(&w, size, 999, live.started_us + 10_000_000);
        try expect(std.mem.indexOfScalar(u8, w.buffered(), 27) == null);
        try std.testing.expectEqual(written, std.mem.count(u8, w.buffered(), "\n"));
        var lines = std.mem.splitScalar(u8, w.buffered(), '\n');
        var count: usize = 0;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try expect(line.len < size.columns);
            count += 1;
        }
        try expect(count < size.rows);
    }
}

test "live rows label system DNS and keep custom ports at every width" {
    var result = types.ServerResult{ .server = .{ .name = "Local", .target = "127.0.0.1", .port = 5353, .system = true } };
    for (&result.query_stats.values) |*stats| stats.* = .{ .attempted = 1, .resolved = 1, .elapsed_total_us = 1000 };
    var unused: std.Io.Writer = .failing;
    var live = Dashboard.init(&unused, 10, 1, &.{result}, .{});
    live.unicode = false;
    var storage: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&storage);
    _ = try live.writeFrame(&w, .{ .columns = 80, .rows = 24 }, 5, live.started_us);
    try expect(std.mem.indexOf(u8, w.buffered(), "   1  [system] Local         127.0.0.1:5353") != null);
    w = std.Io.Writer.fixed(&storage);
    _ = try live.writeFrame(&w, .{ .columns = 40, .rows = 10 }, 5, live.started_us);
    try expect(std.mem.indexOf(u8, w.buffered(), "   1  127.0.0.1:5353") != null);
}

test "live leaders include successful samples rounded to zero microseconds" {
    var result = types.ServerResult{ .server = .{ .name = "Local", .target = "127.0.0.1" } };
    for (&result.query_stats.values) |*stats| stats.* = .{ .attempted = 1, .resolved = 1 };
    var rows: [types.max_servers]types.RankedRow = undefined;
    try std.testing.expectEqual(@as(usize, 1), liveTop(&.{result}, &rows).len);
}
