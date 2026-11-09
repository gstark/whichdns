//! Command-line options, parsing, help text, and usage errors.

const std = @import("std");
const core = @import("core");
const types = core.types;
const version = core.version;
const max_queue_depth = core.udp_queued_runner.max_queue_depth;
const inventory = @import("resolver_inventory.zig");

pub const program_name = "whichdns";

/// Parsed command-line settings for one invocation.
pub const Options = struct {
    timeout_ms: u32 = types.default_timeout_ms,
    // Three complete passes make the result less sensitive to a one-off
    // network spike.
    iterations: u32 = 3,
    retries: u32 = 0,
    pause_ms: u32 = types.default_pause_ms,
    queue_depth: usize = max_queue_depth,
    random_zone: []const u8 = "",
    top: usize = 0,
    wide: bool = false,
    no_color: bool = false,
    list_only: bool = false,
    json: bool = false,
    system_only: bool = false,
    public_only: bool = false,
    no_config: bool = false,
    custom_servers: EndpointList = .{},
    /// Set by --add-server or --remove-server; the run edits the file and exits.
    config_action: ?ConfigAction = null,
    config_servers: EndpointList = .{},

    pub fn hasRandomZone(self: Options) bool {
        return self.random_zone.len != 0;
    }
};

pub const ConfigAction = enum { add, remove };

/// Validated endpoints collected from one repeatable, comma-separated option.
pub const EndpointList = struct {
    // SAFETY: append initializes entries before advancing count.
    items: [inventory.max_custom_servers][]const u8 = undefined,
    count: usize = 0,

    pub fn slice(self: *const EndpointList) []const []const u8 {
        return self.items[0..self.count];
    }

    /// Splits `value` on commas and appends each numeric endpoint.
    fn append(self: *EndpointList, value: []const u8, diag: *Diagnostic) bool {
        var parts = std.mem.splitScalar(u8, value, ',');
        while (parts.next()) |part| {
            _ = inventory.parseEndpoint(part) catch {
                diag.set("invalid numeric DNS endpoint '{s}'", .{part});
                return false;
            };
            if (self.count == self.items.len) {
                diag.set("at most {d} custom servers are supported", .{self.items.len});
                return false;
            }
            self.items[self.count] = part;
            self.count += 1;
        }
        return true;
    }
};

/// A 16-character random label, a dot, and the zone must fit a DNS name.
const max_random_zone_len = 253 - 17;

pub const Action = enum { proceed, show_help, show_version, fail };

/// Holds the usage error message for a failed parse.
pub const Diagnostic = struct {
    // SAFETY: set fills the message before setting len; text reads only that prefix.
    buf: [160]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const Diagnostic) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn set(self: *Diagnostic, comptime fmt: []const u8, args: anytype) void {
        // A usage diagnostic may be truncated to its fixed storage capacity.
        const written = std.fmt.bufPrint(self.buf[0..], fmt, args) catch self.buf[0..];
        self.len = written.len;
    }
};

/// Parses `args` (argv without the program name) into `options`.
pub fn parse(args: []const []const u8, options: *Options, diag: *Diagnostic) Action {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eql(arg, "--help") or eql(arg, "-h")) return .show_help;
        if (eql(arg, "--version")) return .show_version;
        if (eql(arg, "--list")) {
            options.list_only = true;
        } else if (eql(arg, "--wide")) {
            options.wide = true;
        } else if (eql(arg, "--no-color")) {
            options.no_color = true;
        } else if (eql(arg, "--json")) {
            options.json = true;
        } else if (eql(arg, "--system-only")) {
            options.system_only = true;
        } else if (eql(arg, "--public-only")) {
            options.public_only = true;
        } else if (eql(arg, "--no-config")) {
            options.no_config = true;
        } else if (eql(arg, "--server")) {
            const value = valueArg(args, &i, diag) orelse return .fail;
            if (!options.custom_servers.append(value, diag)) return .fail;
        } else if (eql(arg, "--add-server") or eql(arg, "--remove-server")) {
            const action: ConfigAction = if (eql(arg, "--add-server")) .add else .remove;
            if ((options.config_action orelse action) != action) {
                diag.set("--add-server and --remove-server are mutually exclusive", .{});
                return .fail;
            }
            options.config_action = action;
            const value = valueArg(args, &i, diag) orelse return .fail;
            if (!options.config_servers.append(value, diag)) return .fail;
        } else if (eql(arg, "--timeout-ms")) {
            options.timeout_ms = ranged(u32, args, &i, 1, 60000, diag) orelse return .fail;
        } else if (eql(arg, "--iterations")) {
            options.iterations = ranged(u32, args, &i, 1, 100, diag) orelse return .fail;
        } else if (eql(arg, "--retries")) {
            options.retries = ranged(u32, args, &i, 0, 10, diag) orelse return .fail;
        } else if (eql(arg, "--pause-ms")) {
            options.pause_ms = ranged(u32, args, &i, 0, 5000, diag) orelse return .fail;
        } else if (eql(arg, "--queue-depth")) {
            options.queue_depth = ranged(usize, args, &i, 1, max_queue_depth, diag) orelse return .fail;
        } else if (eql(arg, "--top")) {
            options.top = ranged(usize, args, &i, 1, types.max_servers, diag) orelse return .fail;
        } else if (eql(arg, "--random-zone")) {
            const value = valueArg(args, &i, diag) orelse return .fail;
            if (value.len == 0 or value.len > max_random_zone_len) {
                diag.set("--random-zone must be 1-{d} characters", .{max_random_zone_len});
                return .fail;
            }
            var hostname: [253]u8 = undefined;
            @memcpy(hostname[0..17], "0123456789abcdef.");
            @memcpy(hostname[17..][0..value.len], value);
            const generated = hostname[0 .. 17 + value.len];
            if (!core.benchmark_plan.isHostnameEncodable(generated)) {
                diag.set("--random-zone must be a valid DNS name with labels of at most 63 characters", .{});
                return .fail;
            }
            options.random_zone = value;
        } else {
            diag.set("unknown option '{s}'", .{arg});
            return .fail;
        }
    }
    if (options.system_only and options.public_only) {
        diag.set("--system-only and --public-only are mutually exclusive", .{});
        return .fail;
    }
    return .proceed;
}

/// True when `--json` appears anywhere in `args`. Checked before parsing so
/// that usage errors are also reported as JSON.
pub fn jsonRequested(args: []const []const u8) bool {
    for (args) |arg| if (eql(arg, "--json")) return true;
    return false;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Consumes the value following the option at `i.*`.
fn valueArg(args: []const []const u8, i: *usize, diag: *Diagnostic) ?[]const u8 {
    const name = args[i.*];
    i.* += 1;
    if (i.* >= args.len) {
        diag.set("{s} needs a value", .{name});
        return null;
    }
    return args[i.*];
}

/// Consumes and range-checks an unsigned value for the option at `i.*`.
fn ranged(comptime T: type, args: []const []const u8, i: *usize, min: T, max: T, diag: *Diagnostic) ?T {
    const name = args[i.*];
    const raw = valueArg(args, i, diag) orelse return null;
    const value = std.fmt.parseUnsigned(T, raw, 10) catch {
        diag.set("{s} must be between {d} and {d}, got {s}", .{ name, min, max, raw });
        return null;
    };
    if (value < min or value > max) {
        diag.set("{s} must be between {d} and {d}, got {d}", .{ name, min, max, value });
        return null;
    }
    return value;
}

pub const flags = [_][]const u8{
    "--top",        "--iterations",  "--retries",     "--pause-ms", "--queue-depth", "--random-zone",
    "--timeout-ms", "--wide",        "--no-color",    "--list",     "--version",     "--help",
    "--json",       "--system-only", "--public-only", "--server",   "--add-server",  "--remove-server",
    "--no-config",
};

const help_body =
    \\Benchmark system and public DNS resolvers from this machine and rank them by reliability, then latency.
    \\
    \\Usage: whichdns [options]
    \\
    \\Options:
    \\  --system-only         Use configured system resolvers, plus custom servers
    \\  --public-only         Use the built-in catalog, plus custom servers
    \\  --server LIST         Add IP, IPv4:port, or [IPv6%scope]:port endpoints, comma-separated (repeatable)
    \\  --add-server LIST     Save endpoints to the configuration file and exit
    \\  --remove-server LIST  Delete endpoints from the configuration file and exit
    \\  --no-config           Ignore the saved custom servers for this run
    \\  --top N               Show only the N best resolvers (default: all)
    \\  --iterations N        Full passes per resolver, 1-100 (default: 3)
    \\  --timeout-ms N        Per-query timeout in ms, 1-60000 (default: 1500)
    \\  --retries N           Retries per failed query, 0-10 (default: 0)
    \\  --pause-ms N          Pause between timed samples to one resolver in ms, 0-5000 (default: 400)
    \\  --queue-depth N       Maximum in-flight UDP queries, 1-224 (default: 224)
    \\  --random-zone ZONE    Query random labels beneath ZONE instead of built-in domains
    \\  --wide                Show every measurement column
    \\  --no-color            Disable colored output (NO_COLOR is also honored)
    \\  --json                Write progress, results, and errors as JSON Lines on stdout only
    \\  --list                Print the selected resolver inventory and exit
    \\  --version             Print the version and exit
    \\  -h, --help            Show this help and exit
    \\
;

/// Writes the full help text.
pub fn writeHelp(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("{s} {s}\n", .{ program_name, version.string });
    try w.writeAll(help_body);
}

/// Writes a usage error and the pointer to `--help`.
pub fn writeUsageError(w: *std.Io.Writer, diag: *const Diagnostic) std.Io.Writer.Error!void {
    try w.print("{s}: {s}\nTry '{s} --help' for more information.\n", .{ program_name, diag.text(), program_name });
}

/// Writes a runtime failure line.
pub fn writeFailure(w: *std.Io.Writer, what: []const u8, err: anyerror) std.Io.Writer.Error!void {
    try w.print("{s}: {s}: {s}\n", .{ program_name, what, @errorName(err) });
}

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

test "empty arguments keep defaults" {
    var options = Options{};
    var diag = Diagnostic{};
    try std.testing.expectEqual(.proceed, parse(&.{}, &options, &diag));
    try std.testing.expectEqual(1500, options.timeout_ms);
    try std.testing.expectEqual(3, options.iterations);
    try std.testing.expectEqual(0, options.top);
    try std.testing.expectEqual(224, options.queue_depth);
    try expect(!options.wide);
}

test "every option sets its field" {
    var options = Options{};
    var diag = Diagnostic{};
    const args = [_][]const u8{
        "--top",         "8",                 "--iterations", "2",          "--timeout-ms",  "900",
        "--retries",     "1",                 "--pause-ms",   "5",          "--queue-depth", "4",
        "--random-zone", "bench.example.net", "--wide",       "--no-color", "--list",        "--json",
    };
    try std.testing.expectEqual(.proceed, parse(&args, &options, &diag));
    try std.testing.expectEqual(8, options.top);
    try std.testing.expectEqual(2, options.iterations);
    try std.testing.expectEqual(900, options.timeout_ms);
    try std.testing.expectEqual(1, options.retries);
    try std.testing.expectEqual(5, options.pause_ms);
    try std.testing.expectEqual(4, options.queue_depth);
    try expectEqualStrings("bench.example.net", options.random_zone);
    try expect(options.wide);
    try expect(options.no_color);
    try expect(options.list_only);
    try expect(options.json);
    try expect(options.hasRandomZone());
}

test "out of range values name the option and value" {
    var options = Options{};
    var diag = Diagnostic{};
    try std.testing.expectEqual(.fail, parse(&.{ "--timeout-ms", "0" }, &options, &diag));
    try expectEqualStrings("--timeout-ms must be between 1 and 60000, got 0", diag.text());
    try std.testing.expectEqual(.fail, parse(&.{ "--top", "abc" }, &options, &diag));
    var expected: [64]u8 = undefined;
    const expected_text = try std.fmt.bufPrint(expected[0..], "--top must be between 1 and {d}, got abc", .{types.max_servers});
    try expectEqualStrings(expected_text, diag.text());
}

test "missing value and unknown option messages" {
    var options = Options{};
    var diag = Diagnostic{};
    try std.testing.expectEqual(.fail, parse(&.{"--top"}, &options, &diag));
    try expectEqualStrings("--top needs a value", diag.text());
    try std.testing.expectEqual(.fail, parse(&.{"--bogus"}, &options, &diag));
    try expectEqualStrings("unknown option '--bogus'", diag.text());
}

test "json is detected even after an invalid option" {
    try expect(jsonRequested(&.{ "--bogus", "--json" }));
    try expect(!jsonRequested(&.{ "--top", "3" }));
}

test "help and version exit early" {
    var options = Options{};
    var diag = Diagnostic{};
    try std.testing.expectEqual(.show_help, parse(&.{ "--top", "3", "--help" }, &options, &diag));
    try std.testing.expectEqual(.show_help, parse(&.{"-h"}, &options, &diag));
    try std.testing.expectEqual(.show_version, parse(&.{"--version"}, &options, &diag));
}

test "help text mentions every flag" {
    var storage: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(storage[0..]);
    try writeHelp(&w);
    const text = w.buffered();
    for (flags) |flag| {
        try expect(std.mem.indexOf(u8, text, flag) != null);
    }
    try expect(std.mem.startsWith(u8, text, program_name ++ " " ++ version.string ++ "\n"));
    const queue_depth = std.fmt.comptimePrint("1-{d} (default: {d})", .{ max_queue_depth, max_queue_depth });
    const timeout = std.fmt.comptimePrint("(default: {d})", .{types.default_timeout_ms});
    try expect(std.mem.indexOf(u8, text, queue_depth) != null);
    try expect(std.mem.indexOf(u8, text, timeout) != null);
}

test "usage error points at help" {
    var storage: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(storage[0..]);
    var diag = Diagnostic{};
    diag.set("unknown option '--x'", .{});
    try writeUsageError(&w, &diag);
    try expectEqualStrings("whichdns: unknown option '--x'\nTry 'whichdns --help' for more information.\n", w.buffered());
}

test "help propagates writer failure" {
    var w = std.Io.Writer.fixed(&.{});
    const result: std.Io.Writer.Error!void = writeHelp(&w);
    try std.testing.expectError(error.WriteFailed, result);
}

test "queue depth accepts its limits and rejects legacy threads" {
    var options = Options{};
    var diag = Diagnostic{};
    try std.testing.expectEqual(.proceed, parse(&.{ "--queue-depth", "1" }, &options, &diag));
    try std.testing.expectEqual(.proceed, parse(&.{ "--queue-depth", "224" }, &options, &diag));
    try std.testing.expectEqual(.fail, parse(&.{ "--queue-depth", "0" }, &options, &diag));
    try std.testing.expectEqual(.fail, parse(&.{ "--queue-depth", "225" }, &options, &diag));
    try std.testing.expectEqual(.fail, parse(&.{ "--threads", "4" }, &options, &diag));
}

test "random_subdomain zone length leaves room for the random label" {
    var options = Options{};
    var diag = Diagnostic{};
    const longest = "a" ** 63 ++ "." ++ "b" ** 63 ++ "." ++ "c" ** 63 ++ "." ++ "d" ** 44;
    try std.testing.expectEqual(.proceed, parse(&.{ "--random-zone", longest }, &options, &diag));
    try std.testing.expectEqual(.fail, parse(&.{ "--random-zone", longest ++ "a" }, &options, &diag));
    try expectEqualStrings("--random-zone must be 1-236 characters", diag.text());
}

test "resolver selection flags accept explicit selection and reject conflicts" {
    var options = Options{};
    var diag = Diagnostic{};
    try std.testing.expectEqual(.proceed, parse(&.{"--system-only"}, &options, &diag));
    options = .{};
    try std.testing.expectEqual(.proceed, parse(&.{"--public-only"}, &options, &diag));
    options = .{};
    try std.testing.expectEqual(.fail, parse(&.{ "--system-only", "--public-only" }, &options, &diag));
    options = .{};
    try std.testing.expectEqual(.proceed, parse(&.{ "--server", "127.0.0.1:5353", "--server", "[::1%1]:53", "--random-zone", "example.com" }, &options, &diag));
    try std.testing.expectEqual(2, options.custom_servers.count);
}

test "server lists split on commas and validate every entry" {
    var options = Options{};
    var diag = Diagnostic{};
    try std.testing.expectEqual(.proceed, parse(&.{ "--server", "1.1.1.1,[::1]:5353", "--server", "9.9.9.9", "--no-config" }, &options, &diag));
    const servers = options.custom_servers.slice();
    try std.testing.expectEqual(3, servers.len);
    try expectEqualStrings("[::1]:5353", servers[1]);
    try expectEqualStrings("9.9.9.9", servers[2]);
    try expect(options.no_config);
    try std.testing.expectEqual(.fail, parse(&.{ "--server", "1.1.1.1,,8.8.8.8" }, &options, &diag));
    try expectEqualStrings("invalid numeric DNS endpoint ''", diag.text());
    try std.testing.expectEqual(.fail, parse(&.{ "--server", "1.1.1.1,dns.example" }, &options, &diag));
    try expectEqualStrings("invalid numeric DNS endpoint 'dns.example'", diag.text());
}

test "server lists stop at the custom server limit" {
    var options = Options{};
    var diag = Diagnostic{};
    const limit = inventory.max_custom_servers;
    var list: [limit * 12]u8 = undefined;
    var w = std.Io.Writer.fixed(&list);
    for (0..limit + 1) |i| try w.print("{s}10.0.0.{d}", .{ if (i == 0) "" else ",", i });
    try std.testing.expectEqual(.fail, parse(&.{ "--server", w.buffered() }, &options, &diag));
    try expectEqualStrings("at most 32 custom servers are supported", diag.text());
}

test "config edits collect endpoints and reject mixed actions" {
    var options = Options{};
    var diag = Diagnostic{};
    try std.testing.expectEqual(.proceed, parse(&.{ "--add-server", "1.1.1.1,8.8.8.8", "--add-server", "9.9.9.9" }, &options, &diag));
    try std.testing.expectEqual(ConfigAction.add, options.config_action.?);
    try std.testing.expectEqual(3, options.config_servers.count);
    try std.testing.expectEqual(0, options.custom_servers.count);
    options = .{};
    try std.testing.expectEqual(.proceed, parse(&.{ "--remove-server", "[::1]:5353" }, &options, &diag));
    try std.testing.expectEqual(ConfigAction.remove, options.config_action.?);
    try expectEqualStrings("[::1]:5353", options.config_servers.slice()[0]);
    options = .{};
    try std.testing.expectEqual(.fail, parse(&.{ "--add-server", "1.1.1.1", "--remove-server", "8.8.8.8" }, &options, &diag));
    try expectEqualStrings("--add-server and --remove-server are mutually exclusive", diag.text());
    try std.testing.expectEqual(.fail, parse(&.{"--add-server"}, &options, &diag));
    try expectEqualStrings("--add-server needs a value", diag.text());
}

test "random zone rejects names whose generated query cannot be encoded" {
    for ([_][]const u8{ "bad..name", "a" ** 64 ++ ".com", ".example.com", "example.com.." }) |zone| {
        var options = Options{};
        var diag = Diagnostic{};
        try std.testing.expectEqual(.fail, parse(&.{ "--random-zone", zone }, &options, &diag));
        try expect(std.mem.startsWith(u8, diag.text(), "--random-zone"));
    }
}
