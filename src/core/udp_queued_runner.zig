//! Bounded UDP event loop. Each resolver owns one socket and at most one query.
//! Receiving completes pure session transitions; only dispatch performs sends.

const std = @import("std");
const types = @import("types.zig");
const plan = @import("benchmark_plan.zig");
const record = @import("benchmark_record.zig");
const benchmark_config = @import("benchmark_config.zig");
const validate = @import("benchmark_validate.zig");
const dns = @import("dns_packet.zig");
const net = @import("net_util.zig");
const session = @import("query_session.zig");
const posix = @import("posix.zig");
const c = posix.c;

const RunConfig = benchmark_config.RunConfig;

pub const max_queue_depth: usize = 224;

const Resolver = struct {
    fd: c_int = -1,
    address: ?net.Address = null,
    query: session.Session = .{},
    transaction_id: u16 = 0,
    // SAFETY: prepare fills hostname before setting hostname_len.
    hostname: [dns.max_presentation_name_len]u8 = undefined,
    hostname_len: usize = 0,
    qtype: dns.RecordType = .a,

    fn close(self: *Resolver) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
    }

    fn reopen(self: *Resolver) void {
        self.close();
        if (self.address) |*address| self.fd = net.openConnectedSocket(address, true) catch return;
    }

    /// The hostname of the current query, set by `prepare`.
    fn queryName(self: *const Resolver) []const u8 {
        return self.hostname[0..self.hostname_len];
    }

    fn prepare(self: *Resolver, config: RunConfig, server_index: usize) !void {
        self.qtype = config.plan.qtype;
        const name = switch (self.query.stage) {
            .characterization => |index| switch (plan.characterizationProbeAt(index)) {
                .redirect => try plan.redirectHostnameFor(config.plan, &self.hostname),
                .validation => |probe| blk: {
                    self.qtype = probe.qtype;
                    @memcpy(self.hostname[0..probe.hostname.len], probe.hostname);
                    break :blk self.hostname[0..probe.hostname.len];
                },
            },
            .benchmark => |index| blk: {
                const sample = session.sampleAt(index, config.plan);
                const kind = sample.kind;
                break :blk try plan.hostnameFor(
                    kind,
                    config.plan,
                    server_index,
                    sample.iteration,
                    sample.index,
                    &self.hostname,
                );
            },
            .done => unreachable,
        };
        self.hostname_len = name.len;
    }

    /// Completes the query with a socket error and replaces the socket.
    fn failSocket(
        self: *Resolver,
        config: RunConfig,
        result: *types.ServerResult,
        err: std.c.E,
        elapsed_us: u64,
    ) usize {
        const failure = net.socketErrorToTransport(net.socketError(err));
        const completed = self.query.complete(config, result, .{ .failure = failure }, elapsed_us);
        self.reopen();
        return completed;
    }

    fn send(self: *Resolver, config: RunConfig, result: *types.ServerResult, index: usize) usize {
        const started_us = net.nowUs();
        self.query.state = .{ .waiting = .{ .started_us = started_us } };
        if (self.query.stage == .benchmark) {
            const sample = session.sampleAt(self.query.stage.benchmark, config.plan);
            if (self.query.priming or sample.kind != .cached) self.query.next_sample_us = started_us + config.pauseUs();
        }
        self.prepare(config, index) catch {
            return self.query.complete(config, result, .{ .failure = .invalid_argument }, 0);
        };
        self.transaction_id = if (self.transaction_id == std.math.maxInt(u16)) 1 else self.transaction_id + 1;
        var packet: [dns.max_udp_packet]u8 = undefined;
        const len = dns.buildQuery(&packet, self.transaction_id, self.queryName(), self.qtype, true) catch |err| {
            return self.query.complete(config, result, .{ .failure = net.packetBuildErrorToTransport(err) }, 0);
        };
        while (true) {
            const sent = c.send(self.fd, &packet, len, 0);
            switch (posix.errno(sent)) {
                .SUCCESS => {
                    if (sent != len) return self.query.complete(config, result, .{ .failure = .socket_failure }, 0);
                    result.queries_sent += 1;
                    return 0;
                },
                .INTR => {
                    if (net.elapsedSince(started_us) < config.timeoutUs()) continue;
                    return self.query.complete(config, result, .{ .failure = .timeout }, 0);
                },
                else => |err| return self.failSocket(config, result, err, 0),
            }
        }
    }

    fn receive(self: *Resolver, config: RunConfig, result: *types.ServerResult) usize {
        const started_us = self.query.state.waiting.started_us;
        // Bound ignored datagrams so unsolicited traffic cannot starve deadlines.
        for (0..64) |_| {
            var packet: [dns.max_udp_packet]u8 = undefined;
            const received = c.recv(self.fd, &packet, packet.len, 0);
            const elapsed_us = net.nowUs() -| started_us;
            switch (posix.errno(received)) {
                .SUCCESS => {},
                .AGAIN => return 0,
                .INTR => continue,
                else => |err| return self.failSocket(config, result, err, elapsed_us),
            }
            if (elapsed_us >= config.timeoutUs()) {
                return self.query.complete(config, result, .{ .failure = .timeout }, elapsed_us);
            }
            const len: usize = @intCast(received);
            if (len < 2 or std.mem.readInt(u16, packet[0..2], .big) != self.transaction_id) continue;
            const response = dns.parseResponse(
                packet[0..len],
                self.transaction_id,
                self.queryName(),
                self.qtype,
            ) catch |err| {
                const failure = net.packetParseErrorToTransport(err);
                return self.query.complete(config, result, .{ .failure = failure }, elapsed_us);
            };
            const outcome: types.Outcome = dns.classify(response, self.queryName(), self.qtype) catch
                .{ .failure = .malformed_response };
            return self.query.complete(config, result, outcome, elapsed_us);
        }
        return 0;
    }
};

/// The resolvers of one run and the round-robin dispatch position. Each step
/// returns the number of logical tasks it completed.
const Loop = struct {
    config: RunConfig,
    resolvers: []Resolver,
    results: []types.ServerResult,
    queue_depth: usize,
    cursor: usize = 0,

    fn inFlight(self: *const Loop) usize {
        var count: usize = 0;
        for (self.resolvers) |resolver| {
            if (resolver.query.state == .waiting) count += 1;
        }
        return count;
    }

    /// Starts the timed phase for every resolver from one shared epoch.
    fn beginBenchmark(self: *Loop) usize {
        const epoch_us = net.nowUs();
        const count = self.resolvers.len;
        var completed: usize = 0;
        for (self.resolvers, self.results, 0..) |*resolver, *result, index| {
            completed += resolver.query.beginBenchmark(self.config, result, epoch_us, index, count);
        }
        return completed;
    }

    /// Sends for ready resolvers, round robin from the cursor, until the queue is full.
    fn dispatch(self: *Loop) usize {
        var completed: usize = 0;
        var in_flight = self.inFlight();
        const start_cursor = self.cursor;
        for (0..self.resolvers.len) |offset| {
            if (in_flight == self.queue_depth) break;
            const index = (start_cursor + offset) % self.resolvers.len;
            const resolver = &self.resolvers[index];
            if (resolver.query.state != .ready or resolver.query.ready_at_us > net.nowUs()) continue;
            completed += resolver.send(self.config, &self.results[index], index);
            if (resolver.query.state == .waiting) in_flight += 1;
            self.cursor = (index + 1) % self.resolvers.len;
        }
        return completed;
    }

    /// Waits for a reply or the next deadline, then receives. With nothing in
    /// flight it sleeps instead, when `idle_sleep` allows it. Returns null when
    /// a signal interrupts the wait.
    fn wait(self: *Loop, idle_sleep: bool) error{PollFailed}!?usize {
        var polls: [types.max_servers]c.struct_pollfd = undefined;
        var indexes: [types.max_servers]usize = undefined;
        var count: usize = 0;
        const now_us = net.nowUs();
        const queue_open = self.inFlight() < self.queue_depth;
        var wait_us: u64 = 50_000;
        for (self.resolvers, 0..) |resolver, index| {
            switch (resolver.query.state) {
                .waiting => |waiting| {
                    wait_us = @min(wait_us, (waiting.started_us + self.config.timeoutUs()) -| now_us);
                    polls[count] = .{ .fd = resolver.fd, .events = c.POLLIN, .revents = 0 };
                    indexes[count] = index;
                    count += 1;
                },
                .ready => if (queue_open) {
                    wait_us = @min(wait_us, resolver.query.ready_at_us -| now_us);
                },
                .done => {},
            }
        }
        if (count == 0) {
            if (wait_us > 0 and idle_sleep) net.sleepUs(wait_us);
            return 0;
        }
        switch (posix.errno(c.poll(&polls, @intCast(count), @intCast((wait_us + 999) / 1000)))) {
            .SUCCESS => {},
            .INTR => return null,
            else => return error.PollFailed,
        }
        // No sends occur during this receive pass, including after priming.
        var completed: usize = 0;
        const readable = c.POLLIN | c.POLLERR | c.POLLHUP | c.POLLNVAL;
        for (polls[0..count], indexes[0..count]) |pfd, index| {
            if ((pfd.revents & readable) == 0) continue;
            completed += self.resolvers[index].receive(self.config, &self.results[index]);
        }
        return completed;
    }

    /// Times out every query whose deadline has passed.
    fn expire(self: *Loop) usize {
        const now_us = net.nowUs();
        var completed: usize = 0;
        for (self.resolvers, self.results) |*resolver, *result| {
            if (resolver.query.state != .waiting) continue;
            const elapsed_us = now_us -| resolver.query.state.waiting.started_us;
            if (elapsed_us < self.config.timeoutUs()) continue;
            completed += resolver.query.complete(self.config, result, .{ .failure = .timeout }, elapsed_us);
        }
        return completed;
    }
};

pub fn run(
    config: RunConfig,
    servers: []const types.DnsServer,
    results: []types.ServerResult,
    queue_depth: usize,
) ![]types.ServerResult {
    try validate.check(config.plan, servers, results.len);
    if (config.timeout_ms == 0 or queue_depth == 0 or queue_depth > max_queue_depth) return error.InvalidArgument;
    if (servers.len == 0) return results[0..0];
    var resolvers: [types.max_servers]Resolver = undefined;
    for (servers, 0..) |server, index| {
        results[index] = .{ .server = server };
        resolvers[index] = .{ .address = net.parseAddress(server) catch null };
        resolvers[index].reopen();
    }
    const active = resolvers[0..servers.len];
    defer for (active) |*resolver| resolver.close();

    var loop: Loop = .{
        .config = config,
        .resolvers = active,
        .results = results[0..servers.len],
        .queue_depth = queue_depth,
    };
    const total = plan.totalTasks(config.plan, servers.len);
    const characterization_total = plan.characterization_probes_per_server * servers.len;
    var completed: usize = 0;
    var reported: usize = 0;
    var benchmarking = false;
    while (completed < total) {
        if (!benchmarking and completed == characterization_total) {
            benchmarking = true;
            completed += loop.beginBenchmark();
        }
        completed += loop.dispatch();
        if (completed >= total) break;
        // At the phase boundary, skip the idle sleep so benchmarking starts at once.
        completed += try loop.wait(completed != characterization_total) orelse continue;
        completed += loop.expire();
        // Observers throttle their own output; heartbeats keep timers and resize
        // handling responsive even while every request is still pending.
        if (config.progress) |progress| progress.callback(progress.context, completed);
        reported = completed;
    }
    if (reported != completed) {
        if (config.progress) |progress| progress.callback(progress.context, completed);
    }
    return loop.results;
}

const support = @import("udp_test_support.zig");
const ranking = @import("ranking.zig");

test "queued runner records expected answers, actual sends and positive timings" {
    const socket = try support.openLoopbackSocket(20);
    defer _ = c.close(socket.fd);
    var responder = support.Responder{ .fd = socket.fd };
    const thread = try std.Thread.spawn(.{}, support.Responder.run, .{&responder});
    defer thread.join();
    defer @atomicStore(bool, &responder.done, true, .seq_cst);
    const servers = [_]types.DnsServer{.{ .name = "loop", .target = "127.0.0.1", .port = socket.port }};
    var results: [1]types.ServerResult = undefined;
    const config = benchmark_config.RunConfig{ .timeout_ms = 500, .pause_ms = 0, .plan = .{ .samples_per_kind = 300 } };
    const ran = try run(config, &servers, &results, max_queue_depth);
    try std.testing.expect(record.passedCharacterization(&ran[0]));
    try std.testing.expectEqual(900, ran[0].totals().resolved);
    try std.testing.expectEqual(plan.queriesPerServer(config.plan), ran[0].queries_sent);
    try std.testing.expect(!responder.port_changed);
    for (ran[0].query_stats.values) |stats| {
        try std.testing.expect(stats.elapsed_min_us > 0);
        try std.testing.expect(stats.elapsed_max_us < 50_000);
    }
}

test "failed characterization skips all timed queries without pacing" {
    const socket = try support.openLoopbackSocket(20);
    defer _ = c.close(socket.fd);
    var responder = support.Responder{ .fd = socket.fd, .mode = .intercept, .honest_replies = 0 };
    const thread = try std.Thread.spawn(.{}, support.Responder.run, .{&responder});
    defer thread.join();
    defer @atomicStore(bool, &responder.done, true, .seq_cst);
    const servers = [_]types.DnsServer{.{ .name = "intercept", .target = "127.0.0.1", .port = socket.port }};
    var results: [1]types.ServerResult = undefined;
    const started = net.nowUs();
    _ = try run(.{}, &servers, &results, 8);
    try std.testing.expect(net.elapsedSince(started) < 500_000);
    try std.testing.expectEqual(0, results[0].totals().attempted);
    try std.testing.expectEqual(6, results[0].queries_sent);
    try std.testing.expectEqual(.redirect_or_intercept, ranking.characterizeServer(results[0]));
}

test "timeouts retry with exact attempt and wire counts until the resolver is dropped" {
    const socket = try support.openLoopbackSocket(20);
    defer _ = c.close(socket.fd);
    var responder = support.Responder{ .fd = socket.fd, .mode = .silent, .honest_replies = 6 };
    const thread = try std.Thread.spawn(.{}, support.Responder.run, .{&responder});
    defer thread.join();
    defer @atomicStore(bool, &responder.done, true, .seq_cst);
    const servers = [_]types.DnsServer{.{ .name = "silent", .target = "127.0.0.1", .port = socket.port }};
    var results: [1]types.ServerResult = undefined;
    _ = try run(.{ .timeout_ms = 10, .pause_ms = 0, .plan = .{ .samples_per_kind = 1, .retries = 1 } }, &servers, &results, 8);
    // Six validation probes, then five timed-out attempts: two samples with one
    // retry each, and a third sample whose first timeout drops the resolver.
    try std.testing.expectEqual(plan.max_consecutive_timeouts, results[0].totals().attempted);
    try std.testing.expectEqual(plan.max_consecutive_timeouts, results[0].totals().failureCount(.timeout));
    try std.testing.expectEqual(11, results[0].queries_sent);
    try std.testing.expect(results[0].dropped);
    try std.testing.expectEqual(.dropped, ranking.characterizeServer(results[0]));
}

test "closed socket follow-up send cannot re-enter completion" {
    const socket = try support.openLoopbackSocket(20);
    defer _ = c.close(socket.fd);
    const address = try net.parseAddress(.{ .name = "test", .target = "127.0.0.1", .port = socket.port });
    var resolver = Resolver{ .address = address, .query = .{ .stage = .{ .benchmark = 0 } } };
    defer resolver.close();
    var result = types.ServerResult{ .server = .{ .name = "test", .target = "127.0.0.1" } };
    const completed = resolver.send(.{ .plan = .{ .samples_per_kind = 1 } }, &result, 0);
    try std.testing.expectEqual(1, completed);
    try std.testing.expectEqual(1, result.totals().attempted);
    try std.testing.expectEqual(0, result.queries_sent);
    try std.testing.expect(resolver.query.state == .ready);
}

test "responses from another port cannot satisfy a request" {
    const socket = try support.openLoopbackSocket(20);
    defer _ = c.close(socket.fd);
    const wrong = try support.openLoopbackSocket(20);
    defer _ = c.close(wrong.fd);
    var responder = support.Responder{ .fd = socket.fd, .mode = .wrong_port, .reply_fd = wrong.fd, .honest_replies = 6 };
    const thread = try std.Thread.spawn(.{}, support.Responder.run, .{&responder});
    defer thread.join();
    defer @atomicStore(bool, &responder.done, true, .seq_cst);
    const servers = [_]types.DnsServer{.{ .name = "wrong", .target = "127.0.0.1", .port = socket.port }};
    var results: [1]types.ServerResult = undefined;
    _ = try run(.{ .timeout_ms = 10, .pause_ms = 0, .plan = .{ .samples_per_kind = 1 } }, &servers, &results, 8);
    try std.testing.expectEqual(3, results[0].totals().failureCount(.timeout));
}

test "a response read after the deadline is a timeout" {
    const socket = try support.openLoopbackSocket(20);
    defer _ = c.close(socket.fd);
    var responder = support.Responder{ .fd = socket.fd };
    const thread = try std.Thread.spawn(.{}, support.Responder.run, .{&responder});
    defer thread.join();
    defer @atomicStore(bool, &responder.done, true, .seq_cst);
    var resolver = Resolver{ .address = try net.parseAddress(.{ .name = "late", .target = "127.0.0.1", .port = socket.port }) };
    resolver.reopen();
    defer resolver.close();
    var result = types.ServerResult{ .server = .{ .name = "late", .target = "127.0.0.1" } };
    const config = benchmark_config.RunConfig{ .timeout_ms = 1 };
    _ = resolver.send(config, &result, 0);
    net.sleepUs(5000);
    _ = resolver.receive(config, &result);
    try std.testing.expectEqual(.timeout, result.redirect_outcome.?.failure);
}

test "one paced server does not block another ready resolver" {
    const socket = try support.openLoopbackSocket(20);
    defer _ = c.close(socket.fd);
    var responder = support.Responder{ .fd = socket.fd };
    const thread = try std.Thread.spawn(.{}, support.Responder.run, .{&responder});
    defer thread.join();
    defer @atomicStore(bool, &responder.done, true, .seq_cst);
    var servers: [20]types.DnsServer = undefined;
    for (&servers) |*server| server.* = .{ .name = "local", .target = "127.0.0.1", .port = socket.port };
    var results: [20]types.ServerResult = undefined;
    const started_us = net.nowUs();
    _ = try run(.{ .timeout_ms = 500, .pause_ms = 40, .plan = .{ .samples_per_kind = 1 } }, &servers, &results, max_queue_depth);
    // One 40ms staggering window and two paced intervals, plus generous scheduling margin.
    try std.testing.expect(net.elapsedSince(started_us) < 350_000);
    for (results) |result| try std.testing.expectEqual(3, result.totals().resolved);
}

test "progress observers receive heartbeats while a query is pending" {
    const Observer = struct {
        pending_calls: usize = 0,
        fn update(context: *anyopaque, done: usize) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (done == 0) self.pending_calls += 1;
        }
    };
    const socket = try support.openLoopbackSocket(20);
    defer _ = c.close(socket.fd);
    const servers = [_]types.DnsServer{.{ .name = "silent", .target = "127.0.0.1", .port = socket.port }};
    var results: [1]types.ServerResult = undefined;
    var observer = Observer{};
    _ = try run(.{ .timeout_ms = 150, .pause_ms = 0, .plan = .{ .samples_per_kind = 1 }, .progress = .{ .context = &observer, .callback = Observer.update } }, &servers, &results, 1);
    try std.testing.expect(observer.pending_calls >= 2);
}
