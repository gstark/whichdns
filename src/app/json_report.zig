//! Machine-readable output for `--json`: JSON Lines on stdout. Each line is
//! one event object with a `type` field. A benchmark run writes `start`,
//! `progress` events, one `result` per shown resolver, then `summary`. Any
//! failure writes an `error` event as the last line.

const std = @import("std");
const core = @import("core");
const net_util = core.net_util;
const types = core.types;
const version = core.version;
const cli = @import("cli.zig");
const config = @import("config.zig");
const dashboard = @import("dashboard.zig");

const Stringify = std.json.Stringify;
const Error = std.Io.Writer.Error;

/// Failure category reported in the `kind` field of an `error` event.
pub const ErrorKind = enum { usage, benchmark, ranking, config };

const PhaseName = enum { validating, benchmarking };

/// Minimum time between progress events within one phase.
const progress_interval_us: u64 = 1_000_000;

/// Writes `{"type":"version","version":...}`.
pub fn writeVersion(w: *std.Io.Writer) Error!void {
    var s = try beginEvent(w, "version");
    try field(&s, "version", version.string);
    try endEvent(&s);
}

/// Writes one `server` event per built-in resolver.
pub fn writeServerList(w: *std.Io.Writer, servers: []const types.DnsServer) Error!void {
    for (servers) |server| {
        var s = try beginEvent(w, "server");
        try field(&s, "name", server.name);
        try field(&s, "address", server.target);
        try field(&s, "port", server.port);
        try sources(&s, server);
        try endEvent(&s);
    }
}

/// Writes an `error` event. `code` is the internal error name, null for usage errors.
pub fn writeError(w: *std.Io.Writer, kind: ErrorKind, message: []const u8, code: ?anyerror) Error!void {
    var s = try beginEvent(w, "error");
    try field(&s, "kind", kind);
    try field(&s, "message", message);
    try field(&s, "code", if (code) |err| @errorName(err) else null);
    try endEvent(&s);
}

pub fn writeWarning(w: *std.Io.Writer, message: []const u8) Error!void {
    var s = try beginEvent(w, "warning");
    try field(&s, "message", message);
    try endEvent(&s);
}

/// Writes a `config` event for one endpoint of --add-server or --remove-server.
pub fn writeConfigChange(w: *std.Io.Writer, path: []const u8, server: types.DnsServer, change: config.Change) Error!void {
    var s = try beginEvent(w, "config");
    try field(&s, "path", path);
    try field(&s, "address", server.target);
    try field(&s, "port", server.port);
    try field(&s, "change", change);
    try endEvent(&s);
}

fn sources(s: *Stringify, server: types.DnsServer) Error!void {
    try s.objectField("sources");
    try s.beginObject();
    try field(s, "system", server.system);
    try field(s, "custom", server.custom);
    try field(s, "public", server.public);
    try s.endObject();
}

/// Writes the `start` event: the version, settings, and resolver count.
pub fn writeStart(w: *std.Io.Writer, options: cli.Options, resolver_count: usize) Error!void {
    var s = try beginEvent(w, "start");
    try field(&s, "version", version.string);
    try s.objectField("config");
    try s.beginObject();
    try field(&s, "iterations", options.iterations);
    try field(&s, "timeout_ms", options.timeout_ms);
    try field(&s, "retries", options.retries);
    try field(&s, "pause_ms", options.pause_ms);
    try field(&s, "queue_depth", options.queue_depth);
    try field(&s, "random_zone", if (options.hasRandomZone()) options.random_zone else null);
    try field(&s, "top", if (options.top == 0) null else options.top);
    try s.endObject();
    try field(&s, "resolver_count", resolver_count);
    try endEvent(&s);
}

/// Writes one `result` event per shown row, then the `summary` event.
pub fn writeResults(
    w: *std.Io.Writer,
    ranked: []const types.RankedRow,
    shown: usize,
    elapsed_ms: u64,
) Error!void {
    for (ranked[0..shown]) |row| {
        var s = try beginEvent(w, "result");
        try field(&s, "rank", row.rank);
        try field(&s, "name", row.server.name);
        try field(&s, "address", row.server.target);
        try field(&s, "port", row.server.port);
        try sources(&s, row.server);
        try field(&s, "attempts", row.attempts);
        try field(&s, "resolved", row.resolved);
        try field(&s, "queries_sent", row.queries_sent);
        try field(&s, "recommendable", row.recommendable);
        try field(&s, "status", row.status);
        try field(&s, "score", row.score);
        try field(&s, "success_percent", row.success_percent);
        try field(&s, "avg_us", row.average_us);
        try field(&s, "min_us", row.min_us);
        try field(&s, "max_us", row.max_us);
        try field(&s, "std_dev_us", row.std_dev_us);
        try field(&s, "jitter_percent", row.jitter_percent);
        try field(&s, "cached_avg_us", row.cached_average_us);
        try field(&s, "random_com_avg_us", row.random_com_average_us);
        try field(&s, "random_subdomain_avg_us", row.random_subdomain_average_us);
        try endEvent(&s);
    }

    const summary = core.ranking.Summary.from(ranked);
    var s = try beginEvent(w, "summary");
    try field(&s, "elapsed_ms", elapsed_ms);
    try field(&s, "resolver_count", summary.resolver_count);
    try field(&s, "reachable_count", summary.reachable_count);
    try field(&s, "reliable_count", summary.reliable_count);
    try field(&s, "system_count", summary.system_count);
    try field(&s, "queries_sent", summary.queries_sent);
    try field(&s, "attempts", summary.attempts);
    try field(&s, "resolved", summary.resolved);
    try field(&s, "shown_count", shown);
    try s.objectField("fastest");
    if (summary.fastest) |best| {
        try s.beginObject();
        try field(&s, "name", best.server.name);
        try field(&s, "address", best.server.target);
        try field(&s, "port", best.server.port);
        try sources(&s, best.server);
        try field(&s, "avg_us", best.average_us);
        try s.endObject();
    } else {
        try s.write(null);
    }
    try endEvent(&s);
}

/// Runner progress observer that writes `progress` events: the phase,
/// counts, timing, and the live top ten, like the terminal dashboard.
/// Writes at most one event per second, plus the first and last event of
/// each phase.
pub const Progress = struct {
    w: *std.Io.Writer,
    total: usize,
    validation_total: usize,
    results: []const types.ServerResult,
    started_us: u64,
    phase_started_us: u64,
    phase: PhaseName = .validating,
    last_event_us: u64 = 0,
    last_event_done: ?usize = null,
    completed: usize = 0,
    output_error: ?Error = null,

    pub fn init(
        w: *std.Io.Writer,
        total: usize,
        validation_total: usize,
        results: []const types.ServerResult,
    ) Progress {
        const now = net_util.nowUs();
        return .{
            .w = w,
            .total = total,
            .validation_total = validation_total,
            .results = results,
            .started_us = now,
            .phase_started_us = now,
        };
    }

    /// Writes the opening event at zero completed tasks.
    pub fn begin(self: *Progress) Error!void {
        try self.emitAt(0, net_util.nowUs());
    }

    /// Progress callback for the benchmark runner.
    pub fn progress(context: *anyopaque, done: usize) void {
        const self: *Progress = @ptrCast(@alignCast(context));
        self.completed = done;
        if (self.output_error != null) return;
        self.update(done, net_util.nowUs()) catch |err| {
            self.output_error = err;
        };
    }

    /// Writes the final event if the last one was throttled away.
    pub fn finish(self: *Progress) Error!void {
        if (self.output_error) |err| return err;
        if (self.last_event_done != self.completed) try self.emitAt(self.completed, net_util.nowUs());
    }

    fn update(self: *Progress, done: usize, now_us: u64) Error!void {
        if (self.phase == .validating and done >= self.validation_total) {
            // Close the validation phase at 100 percent before benchmarking starts.
            if (self.last_event_done != self.validation_total) {
                const closing: dashboard.Phase = .{
                    .validating = true,
                    .done = self.validation_total,
                    .total = self.validation_total,
                };
                try self.emit(self.validation_total, closing, now_us);
            }
            self.phase = .benchmarking;
            self.phase_started_us = now_us;
            return self.emitAt(done, now_us);
        }
        if (now_us -| self.last_event_us < progress_interval_us) return;
        try self.emitAt(done, now_us);
    }

    fn emitAt(self: *Progress, done: usize, now_us: u64) Error!void {
        try self.emit(done, dashboard.Phase.at(done, self.validation_total, self.total), now_us);
    }

    fn emit(self: *Progress, done: usize, phase: dashboard.Phase, now_us: u64) Error!void {
        self.last_event_us = now_us;
        self.last_event_done = done;

        var s = try beginEvent(self.w, "progress");
        try field(&s, "phase", if (phase.validating) PhaseName.validating else PhaseName.benchmarking);
        try field(&s, "done", phase.done);
        try field(&s, "total", phase.total);
        try field(&s, "percent", if (phase.total == 0) 100 else phase.done * 100 / phase.total);
        try field(&s, "elapsed_ms", (now_us -| self.started_us) / 1000);
        const eta = dashboard.phaseEtaUs(phase, now_us -| self.phase_started_us, self.results);
        try field(&s, "eta_ms", if (eta) |us| us / 1000 else null);

        var rows: [types.max_servers]types.RankedRow = undefined;
        try s.objectField("top");
        try s.beginArray();
        for (dashboard.liveTop(self.results, &rows)) |row| {
            try s.beginObject();
            try field(&s, "rank", row.rank);
            try field(&s, "name", row.server.name);
            try field(&s, "address", row.server.target);
            try field(&s, "port", row.server.port);
            try sources(&s, row.server);
            try field(&s, "avg_us", row.average_us);
            try field(&s, "success_percent", row.success_percent);
            try s.endObject();
        }
        try s.endArray();
        try endEvent(&s);
    }
};

/// Opens one event line with its `type` field.
fn beginEvent(w: *std.Io.Writer, event_type: []const u8) Error!Stringify {
    var s = Stringify{ .writer = w };
    try s.beginObject();
    try field(&s, "type", event_type);
    return s;
}

/// Closes the event line and flushes it so readers see it immediately.
fn endEvent(s: *Stringify) Error!void {
    try s.endObject();
    try s.writer.writeAll("\n");
    try s.writer.flush();
}

fn field(s: *Stringify, name: []const u8, value: anytype) Error!void {
    try s.objectField(name);
    try s.write(value);
}

// ---------------------------------------------------------------------------
// Tests

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

const sampleRow = @import("test_fixtures.zig").sampleRow;

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "start event carries version and config" {
    var storage: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(storage[0..]);
    try writeStart(&w, .{ .top = 1 }, 125);
    try expectEqualStrings(
        "{\"type\":\"start\",\"version\":\"" ++ version.string ++ "\"," ++
            "\"config\":{\"iterations\":3,\"timeout_ms\":1500,\"retries\":0,\"pause_ms\":400,\"queue_depth\":224,\"random_zone\":null,\"top\":1}," ++
            "\"resolver_count\":125}\n",
        w.buffered(),
    );
}

test "results write one line per shown row then the summary" {
    const rows = [_]types.RankedRow{ sampleRow(1, .reachable), sampleRow(2, .timeout) };
    var storage: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(storage[0..]);
    try writeResults(&w, &rows, 1, 4_200);
    const output = w.buffered();
    try expect(contains(output, "\"type\":\"result\""));
    try expect(contains(output, "\"random_subdomain_avg_us\":41300"));
    try expect(contains(output, "\"random_com_avg_us\":13800"));
    try expect(contains(output, "\"reliable_count\":1"));
    try expect(contains(output, "\"fastest\":{\"name\":\"Quad9\""));
}

test "fastest is null when nothing was reachable" {
    const rows = [_]types.RankedRow{sampleRow(1, .redirect_or_intercept)};
    var storage: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(storage[0..]);
    try writeResults(&w, &rows, 1, 10);
    const text = w.buffered();
    try expect(contains(text, "\"fastest\":null"));
    try expect(contains(text, "\"status\":\"redirect_or_intercept\""));
}

test "usage error escapes the message and has a null code" {
    var storage: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(storage[0..]);
    try writeError(&w, .usage, "unknown option '\"x'", null);
    try expectEqualStrings(
        "{\"type\":\"error\",\"kind\":\"usage\",\"message\":\"unknown option '\\\"x'\",\"code\":null}\n",
        w.buffered(),
    );
}

test "runtime error names the internal error" {
    var storage: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(storage[0..]);
    try writeError(&w, .benchmark, "benchmark failed", error.SocketFailure);
    try expect(contains(w.buffered(), "\"kind\":\"benchmark\",\"message\":\"benchmark failed\",\"code\":\"SocketFailure\""));
}

test "server list and version events" {
    var storage: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(storage[0..]);
    try writeServerList(&w, &.{ .{ .name = "Quad9", .target = "9.9.9.9" }, .{ .name = "Other", .target = "192.0.2.1" } });
    try expectEqualStrings(
        "{\"type\":\"server\",\"name\":\"Quad9\",\"address\":\"9.9.9.9\",\"port\":53,\"sources\":{\"system\":false,\"custom\":false,\"public\":false}}\n" ++
            "{\"type\":\"server\",\"name\":\"Other\",\"address\":\"192.0.2.1\",\"port\":53,\"sources\":{\"system\":false,\"custom\":false,\"public\":false}}\n",
        w.buffered(),
    );
    w = std.Io.Writer.fixed(storage[0..]);
    try writeVersion(&w);
    try expectEqualStrings("{\"type\":\"version\",\"version\":\"" ++ version.string ++ "\"}\n", w.buffered());
}

test "config change event names the file, endpoint, and change" {
    var storage: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(storage[0..]);
    try writeConfigChange(&w, "/home/me/.config/whichdns/servers", .{ .name = "", .target = "::1", .port = 5353 }, .added);
    try expectEqualStrings(
        "{\"type\":\"config\",\"path\":\"/home/me/.config/whichdns/servers\",\"address\":\"::1\",\"port\":5353,\"change\":\"added\"}\n",
        w.buffered(),
    );
}

test "progress closes validation at 100 percent and throttles within a phase" {
    var storage: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(storage[0..]);
    var live = Progress.init(&w, 10, 4, &.{});
    live.started_us = 0;
    live.phase_started_us = 0;
    try live.emitAt(0, 0);
    try live.update(1, 10); // throttled
    try live.update(6, 20); // crosses into benchmarking
    try live.update(7, 30); // throttled
    live.completed = 10;
    try live.finish();

    var lines = std.mem.splitScalar(u8, w.buffered(), '\n');
    try expect(contains(lines.next().?, "\"phase\":\"validating\",\"done\":0,\"total\":4,\"percent\":0"));
    try expect(contains(lines.next().?, "\"phase\":\"validating\",\"done\":4,\"total\":4,\"percent\":100"));
    try expect(contains(lines.next().?, "\"phase\":\"benchmarking\",\"done\":2,\"total\":6,\"percent\":33"));
    try expect(contains(lines.next().?, "\"phase\":\"benchmarking\",\"done\":6,\"total\":6,\"percent\":100,\"elapsed_ms\":"));
    try expectEqualStrings("", lines.next().?);
    try expect(lines.next() == null);
}

test "json output propagates writer failure" {
    var w = std.Io.Writer.fixed(&.{});
    try std.testing.expectError(error.WriteFailed, writeVersion(&w));
}

test "partially successful resolver is never recommended and actual sends are reported" {
    var row = sampleRow(1, .reachable);
    row.attempts = 10;
    row.resolved = 1;
    row.recommendable = false;
    row.queries_sent = 19;
    row.server.system = true;
    var storage: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&storage);
    try writeResults(&w, &.{row}, 1, 100);
    try expect(contains(w.buffered(), "\"fastest\":null"));
    try expect(contains(w.buffered(), "\"queries_sent\":19"));
    try expect(contains(w.buffered(), "\"system\":true"));
    try expect(contains(w.buffered(), "\"reliable_count\":0"));
}

test "warning is a JSON event and propagates output failure" {
    var storage: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&storage);
    try writeWarning(&w, "discovery failed");
    try expectEqualStrings("{\"type\":\"warning\",\"message\":\"discovery failed\"}\n", w.buffered());
    w = std.Io.Writer.fixed(&.{});
    try std.testing.expectError(error.WriteFailed, writeWarning(&w, "failed"));
}

test "live JSON preserves endpoint source and zero-latency success" {
    var result = types.ServerResult{ .server = .{ .name = "Local", .target = "127.0.0.1", .port = 5353, .system = true, .custom = true } };
    for (&result.query_stats.values) |*stats| stats.* = .{ .attempted = 1, .resolved = 1 };
    var storage: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&storage);
    var progress = Progress.init(&w, 10, 1, &.{result});
    try progress.emitAt(5, progress.started_us);
    try expect(contains(w.buffered(), "\"address\":\"127.0.0.1\",\"port\":5353"));
    try expect(contains(w.buffered(), "\"sources\":{\"system\":true,\"custom\":true,\"public\":false}"));
    try expect(contains(w.buffered(), "\"avg_us\":0"));
}
