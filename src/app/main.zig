//! Command-line entry point: parse options, run the UDP benchmark, report.

const std = @import("std");
pub const panic = std.debug.FullPanic(panicToStderr);
fn panicToStderr(msg: []const u8, _: ?usize) noreturn {
    _ = c.write(2, msg.ptr, msg.len);
    _ = c.write(2, "\n", 1);
    @trap();
}
pub const std_options: std.Options = .{ .log_level = .info, .logFn = logToStderr };
fn logToStderr(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    term.stderr.print(level.asText() ++ "(" ++ @tagName(scope) ++ "): " ++ format ++ "\n", args) catch {};
}

const core = @import("core");
const c = core.posix.c;
const benchmark_plan = core.benchmark_plan;
const benchmark_config = core.benchmark_config;
const net_util = core.net_util;
const ranking = core.ranking;
const types = core.types;
const udp_queued_runner = core.udp_queued_runner;
const version = core.version;

const cli = @import("cli.zig");
const config = @import("config.zig");
const dashboard = @import("dashboard.zig");
const text_format = @import("format.zig");
const json_report = @import("json_report.zig");
const report = @import("report.zig");
const resolver_inventory = @import("resolver_inventory.zig");
const term = @import("term.zig");

const max_servers = types.max_servers;
const max_args: usize = 128;

/// Runs the application and returns the process exit code.
///
/// A C-style entry point is used because it receives argv without an allocator
/// in this libc-linked build.
pub export fn main(argc: c_int, argv: [*][*:0]u8) c_int {
    // Report broken output pipes through Writer.Error and exit status 1.
    std.posix.sigaction(.PIPE, &.{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);
    const status = run(argc, argv) catch 1;
    term.flushAll() catch return 1;
    return status;
}

fn run(argc: c_int, argv: [*][*:0]u8) std.Io.Writer.Error!c_int {
    var arg_storage: [max_args][]const u8 = undefined;
    const arg_count: usize = @intCast(argc);
    if (arg_count - 1 > max_args) {
        var json = false;
        for (1..arg_count) |i| json = json or std.mem.eql(u8, std.mem.span(argv[i]), "--json");
        var diag = cli.Diagnostic{};
        diag.set("too many arguments", .{});
        return usageError(json, &diag);
    }
    for (1..arg_count) |i| arg_storage[i - 1] = std.mem.span(argv[i]);
    const args = arg_storage[0 .. arg_count - 1];

    var options = cli.Options{};
    var diag = cli.Diagnostic{};
    switch (cli.parse(args, &options, &diag)) {
        .show_help => {
            try cli.writeHelp(&term.stdout);
            return 0;
        },
        .show_version => {
            if (cli.jsonRequested(args)) {
                try json_report.writeVersion(&term.stdout);
            } else {
                try term.stdout.print("{s}\n", .{version.string});
            }
            return 0;
        },
        .fail => return usageError(cli.jsonRequested(args), &diag),
        .proceed => {},
    }
    if (options.config_action) |action| return editConfig(options, action);

    const render = term.RenderStyle{ .color = !options.json and term.detectColor(options.no_color) };
    var inventory = resolver_inventory.Inventory{};
    if (!options.public_only) {
        inventory.discoverSystem() catch |err| {
            if (options.system_only) return runtimeError(options.json, .benchmark, "system DNS discovery failed", err);
            // Discard partial discovery after an invalid or truncated configuration.
            inventory.count = 0;
            var warning_storage: [256]u8 = undefined;
            const warning = std.fmt.bufPrint(
                &warning_storage,
                "system DNS discovery failed ({s}); using public catalog and custom servers",
                .{@errorName(err)},
            ) catch @panic("discovery warning exceeds fixed storage");
            if (options.json) {
                try json_report.writeWarning(&term.stdout, warning);
            } else {
                try term.stderr.print("whichdns: warning: {s}\n", .{warning});
            }
        };
    }
    if (!options.system_only) inventory.addPublic() catch |err| {
        return runtimeError(options.json, .benchmark, "resolver inventory failed", err);
    };
    if (!options.no_config) {
        if (try addConfigServers(options.json, &inventory)) |status| return status;
    }
    for (options.custom_servers.slice()) |endpoint| {
        inventory.addCustom(endpoint) catch |err| {
            return runtimeError(options.json, .benchmark, "custom DNS server failed", err);
        };
    }
    const servers = inventory.servers();

    if (options.list_only) {
        if (options.json) {
            try json_report.writeServerList(&term.stdout, servers);
        } else {
            try report.writeServerList(&term.stdout, render, servers);
        }
        return 0;
    }

    return runBenchmark(options, render, servers);
}

/// Adds the saved custom servers. Returns an exit status when the file
/// cannot be used, and null after success or when there is no file.
fn addConfigServers(json: bool, inventory: *resolver_inventory.Inventory) std.Io.Writer.Error!?c_int {
    var path_buf: [config.max_path]u8 = undefined;
    const path = config.defaultPath(&path_buf) catch |err| switch (err) {
        error.NoHome => return null,
        error.NoSpaceLeft => return try runtimeError(json, .config, "configuration path too long", err),
    };
    var storage: [config.max_file]u8 = undefined;
    const text = config.read(path, &storage) catch |err| return try configError(json, path, "cannot read", err);
    var lines = config.lines(text);
    while (lines.next()) |line| {
        inventory.addCustom(line.text) catch |err| {
            var what: [config.max_path + 128]u8 = undefined;
            const shown = line.text[0..@min(line.text.len, 64)];
            const message = std.fmt.bufPrint(&what, "{s} line {d}: invalid endpoint '{s}'", .{ path, line.number, shown }) catch
                @panic("config diagnostic exceeds fixed storage");
            return try runtimeError(json, .config, message, err);
        };
    }
    return null;
}

/// Applies --add-server or --remove-server to the configuration file, reports
/// each endpoint, and exits. A removal of an endpoint that is not saved fails.
fn editConfig(options: cli.Options, action: cli.ConfigAction) std.Io.Writer.Error!c_int {
    const json = options.json;
    var path_buf: [config.max_path]u8 = undefined;
    const path = config.defaultPath(&path_buf) catch |err| {
        return runtimeError(json, .config, "cannot locate the configuration directory; set HOME or XDG_CONFIG_HOME", err);
    };
    var storage: [config.max_file]u8 = undefined;
    const text = config.read(path, &storage) catch |err| return configError(json, path, "cannot read", err);
    const endpoints = options.config_servers.slice();
    var changes: [resolver_inventory.max_custom_servers]config.Change = undefined;
    var out: [config.max_file]u8 = undefined;
    const edited = switch (action) {
        .add => config.addEndpoints(text, endpoints, changes[0..endpoints.len], &out),
        .remove => config.removeEndpoints(text, endpoints, changes[0..endpoints.len], &out),
    } catch |err| return configError(json, path, "cannot update", err);
    if (!std.mem.eql(u8, edited, text)) {
        config.write(path, edited) catch |err| return configError(json, path, "cannot write", err);
    }
    var status: c_int = 0;
    for (endpoints, changes[0..endpoints.len]) |endpoint, change| {
        if (change == .absent) status = 1;
        // Parsing succeeded during option validation.
        const server = resolver_inventory.parseEndpoint(endpoint) catch @panic("validated endpoint failed to parse");
        if (json) {
            try json_report.writeConfigChange(&term.stdout, path, server, change);
            continue;
        }
        var buf: [types.max_server_target + 8]u8 = undefined;
        const shown = text_format.endpoint(&buf, server);
        switch (change) {
            .added => try term.stdout.print("{s}: added {s} to {s}\n", .{ cli.program_name, shown, path }),
            .already_present => try term.stdout.print("{s}: {s} is already in {s}\n", .{ cli.program_name, shown, path }),
            .removed => try term.stdout.print("{s}: removed {s} from {s}\n", .{ cli.program_name, shown, path }),
            .absent => try term.stdout.print("{s}: {s} is not in {s}\n", .{ cli.program_name, shown, path }),
        }
    }
    return status;
}

/// Reports a configuration file failure with its path.
fn configError(json: bool, path: []const u8, what: []const u8, err: anyerror) std.Io.Writer.Error!c_int {
    var buf: [config.max_path + 64]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, "{s} {s}", .{ what, path }) catch @panic("config diagnostic exceeds fixed storage");
    return runtimeError(json, .config, message, err);
}

fn usageError(json: bool, diag: *const cli.Diagnostic) std.Io.Writer.Error!c_int {
    if (json) {
        try json_report.writeError(&term.stdout, .usage, diag.text(), null);
    } else {
        try cli.writeUsageError(&term.stderr, diag);
    }
    return 2;
}

fn runtimeError(json: bool, kind: json_report.ErrorKind, what: []const u8, err: anyerror) std.Io.Writer.Error!c_int {
    if (json) {
        try json_report.writeError(&term.stdout, kind, what, err);
    } else {
        try cli.writeFailure(&term.stderr, what, err);
    }
    return 1;
}

fn runBenchmark(
    options: cli.Options,
    render: term.RenderStyle,
    servers: []const types.DnsServer,
) std.Io.Writer.Error!c_int {
    const out = &term.stdout;
    const server_count = servers.len;
    if (options.json) {
        try json_report.writeStart(out, options, server_count);
    } else {
        try writeBanner(out, render, options, server_count);
    }

    var results: [max_servers]types.ServerResult = undefined;
    for (servers, 0..) |server, i| results[i] = .{ .server = server };

    const plan = benchmark_plan.Config{
        .iterations = options.iterations,
        .retries = options.retries,
        .run_seed = runSeed(),
        .random_zone = options.random_zone,
    };
    const total = benchmark_plan.totalTasks(plan, server_count);
    const validation_total = benchmark_plan.characterization_probes_per_server * server_count;

    const interactive = !options.json and term.isInteractive();
    var live = dashboard.Dashboard.init(out, total, validation_total, results[0..server_count], render);
    var events = json_report.Progress.init(out, total, validation_total, results[0..server_count]);
    if (interactive) term.installInterruptRestore();
    if (options.json) try events.begin();

    errdefer if (interactive) {
        term.endDashboard(out) catch |err| std.log.warn("could not restore terminal cursor: {t}", .{err});
    };
    const run_config = benchmark_config.RunConfig{
        .plan = plan,
        .timeout_ms = options.timeout_ms,
        .pause_ms = options.pause_ms,
        .progress = if (options.json)
            .{ .context = &events, .callback = json_report.Progress.progress }
        else if (interactive)
            .{ .context = &live, .callback = dashboard.Dashboard.progress }
        else
            null,
    };

    const started_us = net_util.nowUs();
    const ran = udp_queued_runner.run(run_config, servers, results[0..], options.queue_depth) catch |err| {
        if (interactive) try term.endDashboard(out);
        return runtimeError(options.json, .benchmark, "benchmark failed", err);
    };
    const elapsed_ms = net_util.elapsedSince(started_us) / 1000;
    if (interactive) try live.finish();
    if (options.json) try events.finish();

    var rows: [max_servers]types.RankedRow = undefined;
    const ranked = ranking.rank(ran, rows[0..]) catch |err| {
        return runtimeError(options.json, .ranking, "ranking failed", err);
    };

    const shown = if (options.top == 0 or options.top > ranked.len) ranked.len else options.top;
    if (options.json) {
        try json_report.writeResults(out, ranked, shown, elapsed_ms);
        return 0;
    }
    const columns = report.selectColumns(ranked[0..shown], options.wide);
    try report.writeRankedTable(out, render, ranked[0..shown], columns);
    try out.writeAll("\n");
    try report.writeVerdict(out, render, ranked, shown, elapsed_ms);
    return 0;
}

/// Prints the two-line header that opens every benchmark run.
fn writeBanner(
    w: *std.Io.Writer,
    render: term.RenderStyle,
    options: cli.Options,
    server_count: usize,
) std.Io.Writer.Error!void {
    try render.style(w, .bold);
    try w.print("{s} {s}", .{ cli.program_name, version.string });
    try render.style(w, .reset);
    const pass_word: []const u8 = if (options.iterations == 1) "pass" else "passes";
    try w.print("\nTesting {d} resolvers over UDP: {d} {s}, {d} ms timeout, ", .{
        server_count,
        options.iterations,
        pass_word,
        options.timeout_ms,
    });
    if (options.hasRandomZone()) {
        try w.print("random-label queries under {s}\n\n", .{options.random_zone});
    } else {
        try w.print("random-label queries under {d} popular domains\n\n", .{benchmark_plan.default_cached_names.len});
    }
    try w.flush();
}

/// Produces a wall-clock seed used only to vary generated query names.
fn runSeed() u64 {
    // SAFETY: clock_gettime initializes both fields; failure returns before either is read.
    var now: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &now) != 0) return 0;
    return (@as(u64, @intCast(now.sec)) *% 1_000_000_000) +% @as(u64, @intCast(now.nsec));
}
