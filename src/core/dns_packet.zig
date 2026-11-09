//! Allocation-free DNS query encoding and strict response parsing.
//!
//! The parser validates transaction and question identity, safely follows
//! backward compression pointers, and rejects trailing or malformed records.

const std = @import("std");
const Outcome = @import("types.zig").Outcome;

/// Every query advertises this EDNS0 UDP payload size, so a response never
/// exceeds it and the receive buffer matches it. 1232 bytes avoids IP
/// fragmentation on common paths.
pub const edns_udp_payload_size: u16 = 1232;
pub const max_udp_packet = edns_udp_payload_size;
pub const header_len = 12;
pub const class_in: u16 = 1;
pub const max_name_len = 253;
pub const max_presentation_name_len = 256;

/// Resource record types that the client sends or validates.
pub const RecordType = enum(u16) {
    a = 1,
    cname = 5,
    soa = 6,
    aaaa = 28,
    opt = 41,
    _,
};

/// Response codes, including the EDNS0 extended range.
pub const Rcode = enum(u16) {
    no_error = 0,
    servfail = 2,
    nxdomain = 3,
    refused = 5,
    _,
};

/// Header flags. Packed struct fields start at the least significant bit.
pub const Flags = packed struct(u16) {
    rcode: u4 = 0,
    checking_disabled: bool = false,
    authentic_data: bool = false,
    /// Reserved; must be zero.
    z: bool = false,
    recursion_available: bool = false,
    recursion_desired: bool = false,
    truncated: bool = false,
    authoritative: bool = false,
    opcode: u4 = 0,
    response: bool = false,
};

/// Failures produced while encoding or validating a DNS packet.
pub const Error = error{
    InvalidArgument,
    BufferTooSmall,
    Malformed,
    UnexpectedTransactionId,
    UnexpectedQuestion,
};

/// Parsed DNS response header plus offsets into the original packet.
pub const Response = struct {
    packet: []const u8,
    answer_offset: usize,
    id: u16,
    flags: Flags,
    question_count: u16,
    answer_count: u16,
    authority_count: u16,
    additional_count: u16,
    /// The header rcode combined with the OPT extended rcode bits.
    rcode: Rcode,
};

/// Parsed resource record whose slices borrow packet or caller storage.
pub const Answer = struct {
    name: []const u8,
    record_type: RecordType,
    class_code: u16,
    ttl: u32,
    rdata: []const u8,
    rdata_offset: usize,
};

/// Stateful iterator over the answer section of a validated response.
pub const AnswerIterator = struct {
    packet: []const u8,
    next_offset: usize,
    remaining: u16,

    /// Parses and returns the next answer, or `null` when exhausted.
    pub fn next(self: *AnswerIterator, name_buffer: []u8) Error!?Answer {
        if (self.remaining == 0) return null;
        const name_result = try readName(self.packet, self.next_offset, name_buffer);
        var offset = name_result.next_offset;
        if (self.packet.len - offset < 10) return error.Malformed;
        const record_type = readType(self.packet[offset..]);
        const class_code = readU16(self.packet[offset + 2 ..]);
        const ttl = readU32(self.packet[offset + 4 ..]);
        const rdata_length: usize = readU16(self.packet[offset + 8 ..]);
        offset += 10;
        if (self.packet.len - offset < rdata_length) return error.Malformed;
        const rdata = self.packet[offset .. offset + rdata_length];
        self.next_offset = offset + rdata_length;
        self.remaining -= 1;
        return .{
            .name = name_buffer[0..name_result.name_len],
            .record_type = record_type,
            .class_code = class_code,
            .ttl = ttl,
            .rdata = rdata,
            .rdata_offset = offset,
        };
    }
};

/// Encodes one recursive IN-class DNS question with an EDNS0 OPT record and
/// returns its packet length.
pub fn buildQuery(
    buffer: []u8,
    transaction_id: u16,
    hostname: []const u8,
    qtype: RecordType,
    recursion_desired: bool,
) Error!usize {
    if (hostname.len == 0) return error.InvalidArgument;
    if (buffer.len < header_len) return error.BufferTooSmall;

    writeU16(buffer[0..], transaction_id);
    writeU16(buffer[2..], @bitCast(Flags{ .recursion_desired = recursion_desired }));
    writeU16(buffer[4..], 1); // Questions.
    writeU16(buffer[6..], 0); // Answers.
    writeU16(buffer[8..], 0); // Authority records.
    writeU16(buffer[10..], 1); // Additional records: the OPT record.

    var offset = try encodeName(buffer, header_len, hostname);
    if (buffer.len - offset < 4 + opt_record_len) return error.BufferTooSmall;
    writeU16(buffer[offset..], @intFromEnum(qtype));
    writeU16(buffer[offset + 2 ..], class_in);
    offset += 4;
    // OPT pseudo-record: root name, type OPT, payload size as class, zeroed
    // extended rcode, version, and flags, then no rdata.
    buffer[offset] = 0;
    writeU16(buffer[offset + 1 ..], @intFromEnum(RecordType.opt));
    writeU16(buffer[offset + 3 ..], edns_udp_payload_size);
    @memset(buffer[offset + 5 ..][0..6], 0);
    return offset + opt_record_len;
}

const opt_record_len = 11;

/// Strictly validates a response against the exact request question.
pub fn parseResponse(
    packet: []const u8,
    expected_transaction_id: u16,
    expected_hostname: []const u8,
    expected_qtype: RecordType,
) Error!Response {
    if (expected_hostname.len == 0) return error.InvalidArgument;
    if (packet.len < header_len) return error.Malformed;

    const transaction_id = readU16(packet[0..]);
    if (transaction_id != expected_transaction_id) return error.UnexpectedTransactionId;

    // Only the Z bit is reserved. AD and CD are legitimate.
    const flags: Flags = @bitCast(readU16(packet[2..]));
    if (!flags.response or flags.opcode != 0 or flags.z) return error.Malformed;
    var rcode: u16 = flags.rcode;

    const question_count = readU16(packet[4..]);
    if (question_count != 1) return error.UnexpectedQuestion;
    const answer_count = readU16(packet[6..]);
    const authority_count = readU16(packet[8..]);
    const additional_count = readU16(packet[10..]);

    var question_name_buffer: [max_presentation_name_len]u8 = undefined;
    const question_name = try readName(packet, header_len, question_name_buffer[0..]);
    const question = question_name_buffer[0..question_name.name_len];
    if (!nameEquals(question, expected_hostname)) return error.UnexpectedQuestion;
    var offset = question_name.next_offset;
    if (packet.len - offset < 4) return error.Malformed;
    const qtype = readType(packet[offset..]);
    const qclass = readU16(packet[offset + 2 ..]);
    if (qtype != expected_qtype or qclass != class_in) return error.UnexpectedQuestion;
    offset += 4;
    const answer_offset = offset;

    const record_count = @as(u32, answer_count) + authority_count + additional_count;
    var opt_seen = false;
    for (0..record_count) |index| {
        const end = try skipRecord(packet, offset);
        var owner: [max_presentation_name_len]u8 = undefined;
        const name = try readName(packet, offset, &owner);
        const header = name.next_offset;
        if (readType(packet[header..]) == .opt) {
            const in_additional = index >= @as(u32, answer_count) + authority_count;
            if (opt_seen or name.name_len != 0 or !in_additional) return error.Malformed;
            opt_seen = true;
            rcode |= @as(u16, packet[header + 4]) << 4;
        }
        offset = end;
    }
    if (offset != packet.len) return error.Malformed;

    return .{
        .packet = packet,
        .answer_offset = answer_offset,
        .id = transaction_id,
        .flags = flags,
        .question_count = question_count,
        .answer_count = answer_count,
        .authority_count = authority_count,
        .additional_count = additional_count,
        .rcode = @enumFromInt(rcode),
    };
}

/// Interprets a validated packet once, before validation or statistics consume it.
/// A count of records is never evidence that an address lookup succeeded.
pub fn classify(response: Response, hostname: []const u8, qtype: RecordType) Error!Outcome {
    if (response.flags.truncated) return .{ .failure = .truncated_response };
    switch (response.rcode) {
        .no_error, .nxdomain => {},
        else => |rcode| return .{ .dns_error = rcode },
    }
    var current_buffer: [max_presentation_name_len]u8 = undefined;
    if (hostname.len > current_buffer.len) return error.InvalidArgument;
    @memcpy(current_buffer[0..hostname.len], hostname);
    var current: []const u8 = current_buffer[0..hostname.len];
    // Bounded traversal also rejects alias cycles, without allocations.
    for (0..32) |aliases| {
        var iterator = answerIterator(response);
        var name_buffer: [max_presentation_name_len]u8 = undefined;
        var target_buffer: [max_presentation_name_len]u8 = undefined;
        var target_len: ?usize = null;
        var found_address = false;
        while (try iterator.next(&name_buffer)) |answer| {
            if (answer.class_code != class_in or !nameEquals(answer.name, current)) continue;
            if (answer.record_type == qtype) found_address = true;
            if (answer.record_type == .cname) {
                if (target_len != null) return error.Malformed;
                const target = try readName(response.packet, answer.rdata_offset, &target_buffer);
                target_len = target.name_len;
            }
        }
        if (found_address) {
            if (target_len != null or response.rcode == .nxdomain) return error.Malformed;
            return .address;
        }
        const len = target_len orelse {
            if (response.answer_count != aliases) return .{ .failure = .protocol_failure };
            if (response.rcode == .nxdomain) return .nxdomain;
            if (try hasNegativeAuthority(response, current)) return .nodata;
            return .{ .failure = .protocol_failure };
        };
        @memcpy(current_buffer[0..len], target_buffer[0..len]);
        current = current_buffer[0..len];
    }
    return error.Malformed;
}

/// NODATA needs a negative authority record, not merely an absent address.
fn hasNegativeAuthority(response: Response, hostname: []const u8) Error!bool {
    var iterator = answerIterator(response);
    var name_buffer: [max_presentation_name_len]u8 = undefined;
    while (try iterator.next(&name_buffer)) |_| {}
    iterator.remaining = response.authority_count;
    while (try iterator.next(&name_buffer)) |answer| {
        if (answer.record_type != .soa or answer.class_code != class_in) continue;
        const name = std.mem.trimEnd(u8, hostname, ".");
        if (answer.name.len == 0 or nameEquals(name, answer.name)) return true;
        if (name.len > answer.name.len and name[name.len - answer.name.len - 1] == '.' and
            std.ascii.eqlIgnoreCase(name[name.len - answer.name.len ..], answer.name)) return true;
    }
    return false;
}

/// Encodes a presentation-format hostname as DNS wire labels.
fn encodeName(buffer: []u8, start_offset: usize, hostname: []const u8) Error!usize {
    const name = if (std.mem.endsWith(u8, hostname, ".")) hostname[0 .. hostname.len - 1] else hostname;
    if (name.len == 0 or name.len > max_name_len) return error.InvalidArgument;

    var offset = start_offset;
    var labels = std.mem.splitScalar(u8, name, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63) return error.InvalidArgument;
        if (buffer.len - offset < label.len + 1) return error.BufferTooSmall;
        buffer[offset] = @intCast(label.len);
        offset += 1;
        @memcpy(buffer[offset..][0..label.len], label);
        offset += label.len;
    }
    if (offset == buffer.len) return error.BufferTooSmall;
    buffer[offset] = 0;
    return offset + 1;
}

/// Creates an iterator positioned at the validated answer section.
pub fn answerIterator(response: Response) AnswerIterator {
    return .{
        .packet = response.packet,
        .next_offset = response.answer_offset,
        .remaining = response.answer_count,
    };
}

/// Name decoder output: wire continuation offset and presentation length.
const NameReadResult = struct {
    next_offset: usize,
    name_len: usize,
};

/// Decodes a possibly compressed DNS name with loop and bounds protection.
/// Null output validates wire structure only, including binary mailbox labels.
fn readName(packet: []const u8, start_offset: usize, out_name: ?[]u8) Error!NameReadResult {
    var offset = start_offset;
    var next_offset: usize = start_offset;
    var jumped = false;
    var name_len: usize = 0;
    var jumps: usize = 0;

    while (true) {
        if (offset >= packet.len) return error.Malformed;
        const length_or_pointer: usize = packet[offset];
        if ((length_or_pointer & 0xc0) == 0xc0) {
            if (packet.len - offset < 2) return error.Malformed;
            const pointer = ((length_or_pointer & 0x3f) << 8) | @as(usize, packet[offset + 1]);
            if (pointer >= offset) return error.Malformed;
            if (!jumped) next_offset = offset + 2;
            offset = pointer;
            jumped = true;
            jumps += 1;
            if (jumps > 16) return error.Malformed;
            continue;
        }
        if ((length_or_pointer & 0xc0) != 0) return error.Malformed;
        offset += 1;
        if (length_or_pointer == 0) {
            if (!jumped) next_offset = offset;
            // An empty name is the root, as in the OPT record of an EDNS response.
            return .{ .next_offset = next_offset, .name_len = name_len };
        }
        if (length_or_pointer > 63) return error.Malformed;
        if (packet.len - offset < length_or_pointer) return error.Malformed;
        if (name_len != 0) {
            if (out_name) |out| {
                if (name_len >= out.len) return error.Malformed;
                out[name_len] = '.';
            }
            name_len += 1;
        }
        if (out_name) |out| {
            if (out.len - name_len < length_or_pointer) return error.Malformed;
            for (packet[offset .. offset + length_or_pointer], 0..) |ch, index| {
                // Do not flatten a literal dot into a separator when comparing names.
                if (ch == '.') return error.Malformed;
                out[name_len + index] = ch;
            }
        }
        name_len += length_or_pointer;
        if (name_len > max_name_len) return error.Malformed;
        offset += length_or_pointer;
        if (!jumped) next_offset = offset;
    }
}

/// Validates and skips one complete DNS resource record.
fn skipRecord(packet: []const u8, start_offset: usize) Error!usize {
    var name_buffer: [max_presentation_name_len]u8 = undefined;
    const name = try readName(packet, start_offset, name_buffer[0..]);
    var offset = name.next_offset;
    if (packet.len - offset < 10) return error.Malformed;
    const record_type = readType(packet[offset..]);
    const class_code = readU16(packet[offset + 2 ..]);
    const rdata_length: usize = readU16(packet[offset + 8 ..]);
    offset += 10;
    if (packet.len - offset < rdata_length) return error.Malformed;
    const rdata_end = offset + rdata_length;
    if (class_code == class_in) switch (record_type) {
        .a => if (rdata_length != 4) return error.Malformed,
        .aaaa => if (rdata_length != 16) return error.Malformed,
        .soa => {
            // Two names, then serial, refresh, retry, expire, and minimum.
            const primary = try readName(packet, offset, null);
            const mailbox = try readName(packet, primary.next_offset, null);
            if (mailbox.next_offset + 20 != rdata_end) return error.Malformed;
        },
        .cname => {
            const target = try readName(packet, offset, &name_buffer);
            if (target.name_len == 0 or target.next_offset != rdata_end) return error.Malformed;
        },
        else => {},
    };
    return rdata_end;
}

/// Compares decoded and expected names while accepting an absolute trailing dot.
fn nameEquals(parsed: []const u8, expected: []const u8) bool {
    const absolute = std.mem.endsWith(u8, expected, ".");
    const relative = if (absolute) expected[0 .. expected.len - 1] else expected;
    return std.ascii.eqlIgnoreCase(parsed, relative);
}

/// Reads a big-endian record type from a validated slice.
fn readType(bytes: []const u8) RecordType {
    return @enumFromInt(readU16(bytes));
}

/// Reads a big-endian 16-bit integer from a validated slice.
fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .big);
}

/// Reads a big-endian 32-bit integer from a validated slice.
fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .big);
}

/// Writes a 16-bit integer in DNS network byte order.
fn writeU16(bytes: []u8, value: u16) void {
    std.mem.writeInt(u16, bytes[0..2], value, .big);
}

const expect = std.testing.expect;

test "build A query for example.com with an EDNS0 OPT record" {
    const expected = [_]u8{
        0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        0x07, 'e',  'x',  'a',  'm',  'p',  'l',  'e',  0x03, 'c',  'o',  'm',
        0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x29, 0x04, 0xD0, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    var packet: [max_udp_packet]u8 = undefined;
    const len = try buildQuery(packet[0..], 0x1234, "example.com", .a, true);
    try std.testing.expectEqual(expected.len, len);
    try std.testing.expectEqualSlices(u8, expected[0..], packet[0..len]);
}

test "build query accepts absolute hostname" {
    var packet: [max_udp_packet]u8 = undefined;
    const len = try buildQuery(packet[0..], 0x1234, "example.com.", .a, true);
    try std.testing.expectEqual(40, len);
}

test "build query rejects empty label" {
    var packet: [max_udp_packet]u8 = undefined;
    const result = buildQuery(packet[0..], 0x1234, "example..com", .a, true);
    try std.testing.expectError(Error.InvalidArgument, result);
}

test "parse valid response and answer count" {
    const response_packet = [_]u8{
        0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
        0x07, 'e',  'x',  'a',  'm',  'p',  'l',  'e',  0x03, 'c',  'o',  'm',
        0x00, 0x00, 0x01, 0x00, 0x01, 0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00,
        0x00, 0x01, 0x2C, 0x00, 0x04, 0x5D, 0xB8, 0xD8, 0x22,
    };
    const parsed = try parseResponse(response_packet[0..], 0x1234, "example.com", .a);
    try std.testing.expectEqual(.no_error, parsed.rcode);
    try std.testing.expectEqual(1, parsed.answer_count);
    try expect(parsed.flags.recursion_available);

    var iterator = answerIterator(parsed);
    var name_buffer: [max_presentation_name_len]u8 = undefined;
    const answer = (try iterator.next(name_buffer[0..])).?;
    try expect(std.mem.eql(u8, answer.name, "example.com"));
    try std.testing.expectEqual(.a, answer.record_type);
    try std.testing.expectEqual(class_in, answer.class_code);
    try std.testing.expectEqual(300, answer.ttl);
    try std.testing.expectEqual(4, answer.rdata.len);
    try expect(answer.rdata[0] == 93 and answer.rdata[1] == 184 and answer.rdata[2] == 216 and answer.rdata[3] == 34);
    try expect((try iterator.next(name_buffer[0..])) == null);
}

test "parse keeps rcode for error responses" {
    const response_packet = [_]u8{ 0x12, 0x34, 0x81, 0x83, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 0x03, 'c', 'o', 'm', 0x00, 0x00, 0x01, 0x00, 0x01 };
    const parsed = try parseResponse(response_packet[0..], 0x1234, "example.com", .a);
    try std.testing.expectEqual(.nxdomain, parsed.rcode);
    try std.testing.expectEqual(0, parsed.answer_count);
}

test "parse accepts AD and CD flag bits" {
    const response_packet = [_]u8{ 0x12, 0x34, 0x81, 0xb0, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 0x03, 'c', 'o', 'm', 0x00, 0x00, 0x01, 0x00, 0x01 };
    const parsed = try parseResponse(response_packet[0..], 0x1234, "example.com", .a);
    try std.testing.expectEqual(.no_error, parsed.rcode);
}

test "parse rejects reserved Z bit" {
    const response_packet = [_]u8{ 0x12, 0x34, 0x81, 0xc0, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 0x03, 'c', 'o', 'm', 0x00, 0x00, 0x01, 0x00, 0x01 };
    const result = parseResponse(response_packet[0..], 0x1234, "example.com", .a);
    try std.testing.expectError(Error.Malformed, result);
}

test "parse rejects trailing garbage" {
    const response_packet = [_]u8{ 0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 0x03, 'c', 'o', 'm', 0x00, 0x00, 0x01, 0x00, 0x01, 0xff };
    const result = parseResponse(response_packet[0..], 0x1234, "example.com", .a);
    try std.testing.expectError(Error.Malformed, result);
}

test "parse rejects forward compressed answer pointer" {
    const response_packet = [_]u8{
        0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
        0x07, 'e',  'x',  'a',  'm',  'p',  'l',  'e',  0x03, 'c',  'o',  'm',
        0x00, 0x00, 0x01, 0x00, 0x01, 0xC0, 0x28, 0x00, 0x01, 0x00, 0x01, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00,
    };
    const result = parseResponse(response_packet[0..], 0x1234, "example.com", .a);
    try std.testing.expectError(Error.Malformed, result);
}

test "parse rejects wrong transaction id" {
    const response_packet = [_]u8{ 0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 0x03, 'c', 'o', 'm', 0x00, 0x00, 0x01, 0x00, 0x01 };
    const result = parseResponse(response_packet[0..], 0x9999, "example.com", .a);
    try std.testing.expectError(Error.UnexpectedTransactionId, result);
}

test "response question comparison ignores ASCII case" {
    var packet: [max_udp_packet]u8 = undefined;
    const len = try buildQuery(&packet, 42, "EXAMPLE.COM", .a, true);
    packet[2] |= 0x80;
    _ = try parseResponse(packet[0..len], 42, "example.com.", .a);
}

test "query rejects a name exceeding the DNS wire limit" {
    var packet: [max_udp_packet]u8 = undefined;
    const label = "a" ** 63;
    const name = label ++ "." ++ label ++ "." ++ label ++ "." ++ label;
    try std.testing.expectError(error.InvalidArgument, buildQuery(&packet, 42, name, .a, true));
}

test "query rejects a second trailing dot" {
    var packet: [max_udp_packet]u8 = undefined;
    try std.testing.expectError(error.InvalidArgument, buildQuery(&packet, 42, "example.com..", .a, true));
}

test "query accepts the longest absolute DNS name" {
    var packet: [max_udp_packet]u8 = undefined;
    const label = "a" ** 63;
    const name = label ++ "." ++ label ++ "." ++ label ++ "." ++ "a" ** 61 ++ ".";
    const len = try buildQuery(&packet, 42, name, .a, true);
    try std.testing.expectEqual(header_len + 255 + 4 + opt_record_len, len);
}

test "parse accepts a response that echoes the OPT record" {
    const response_packet = [_]u8{
        0x12, 0x34, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x07, 'e',  'x',  'a',  'm',  'p',  'l',  'e',  0x03, 'c',  'o',  'm',
        0x00, 0x00, 0x01, 0x00, 0x01, 0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00,
        0x00, 0x01, 0x2C, 0x00, 0x04, 0x5D, 0xB8, 0xD8, 0x22, 0x00, 0x00, 0x29,
        0x04, 0xD0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    const parsed = try parseResponse(response_packet[0..], 0x1234, "example.com", .a);
    try std.testing.expectEqual(1, parsed.answer_count);
    try std.testing.expectEqual(1, parsed.additional_count);
}

test "query buffer holds the advertised payload size" {
    try std.testing.expectEqual(1232, max_udp_packet);
    try std.testing.expectEqual(1232, edns_udp_payload_size);
}

test "reject an IN A answer without four address bytes" {
    var packet: [max_udp_packet]u8 = undefined;
    const len = try buildQuery(&packet, 42, "example.com", .a, true);
    const offset = len - 11;
    packet[2] = 0x81;
    packet[3] = 0x80;
    packet[7] = 1;
    packet[11] = 0;
    @memcpy(packet[offset..][0..12], &[_]u8{ 0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 0 });
    try std.testing.expectError(error.Malformed, parseResponse(packet[0 .. offset + 12], 42, "example.com", .a));
}

test "classification requires an address for the actual question and treats TC as failure" {
    var packet: [max_udp_packet]u8 = undefined;
    const len = try buildQuery(&packet, 42, "example.com", .a, true);
    const offset = len - 11;
    packet[2] = 0x81;
    packet[3] = 0x80;
    packet[7] = 1;
    packet[11] = 0;
    @memcpy(packet[offset..][0..16], &[_]u8{ 0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 127, 0, 0, 1 });
    var response = try parseResponse(packet[0 .. offset + 16], 42, "example.com", .a);
    try std.testing.expectEqual(.address, try classify(response, "example.com", .a));
    try std.testing.expectEqual(.protocol_failure, (try classify(response, "other.com", .a)).failure);
    try std.testing.expectEqual(.protocol_failure, (try classify(response, "example.com", .aaaa)).failure);
    response.flags.truncated = true;
    try std.testing.expectEqual(.truncated_response, (try classify(response, "example.com", .a)).failure);
}

test "classification follows a CNAME to an address and rejects an alias cycle" {
    var packet: [max_udp_packet]u8 = undefined;
    const len = try buildQuery(&packet, 42, "example.com", .a, true);
    const offset = len - 11;
    packet[2] = 0x81;
    packet[3] = 0x80;
    packet[7] = 2;
    packet[11] = 0;
    // example.com -> www.example.com, then its A record.
    const records = [_]u8{ 0xc0, 0x0c, 0, 5, 0, 1, 0, 0, 0, 60, 0, 6, 3, 'w', 'w', 'w', 0xc0, 0x0c, 3, 'w', 'w', 'w', 0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 127, 0, 0, 1 };
    @memcpy(packet[offset..][0..records.len], &records);
    const response = try parseResponse(packet[0 .. offset + records.len], 42, "example.com", .a);
    try std.testing.expectEqual(.address, try classify(response, "example.com", .a));
    packet[7] = 1;
    packet[offset + 11] = 2;
    packet[offset + 12] = 0xc0;
    packet[offset + 13] = 0x0c;
    const cycle = try parseResponse(packet[0 .. offset + 14], 42, "example.com", .a);
    try std.testing.expectError(error.Malformed, classify(cycle, "example.com", .a));
}

test "EDNS extended errors are not negative answers" {
    var packet: [max_udp_packet]u8 = undefined;
    const len = try buildQuery(&packet, 42, "example.com", .a, true);
    packet[2] = 0x81;
    packet[3] = 0x80;
    packet[len - 6] = 1; // OPT extended RCODE: BADVERS = 16.
    const response = try parseResponse(packet[0..len], 42, "example.com", .a);
    try std.testing.expectEqual(@as(u16, 16), @intFromEnum(response.rcode));
}

test "NODATA requires a well formed SOA for the terminal name zone" {
    var packet: [max_udp_packet]u8 = undefined;
    const len = try buildQuery(&packet, 42, "example.com", .a, true);
    const offset = len - 11;
    packet[2] = 0x81;
    packet[3] = 0x80;
    packet[9] = 1;
    packet[11] = 0;
    // SOA owner example.com; two compressed names and five 32-bit fields.
    @memcpy(packet[offset..][0..16], &[_]u8{ 0xc0, 0x0c, 0, 6, 0, 1, 0, 0, 0, 60, 0, 24, 0xc0, 0x0c, 0xc0, 0x0c });
    @memset(packet[offset + 16 ..][0..20], 0);
    const response = try parseResponse(packet[0 .. offset + 36], 42, "example.com", .a);
    try std.testing.expectEqual(.nodata, try classify(response, "example.com", .a));
    try std.testing.expectEqual(.protocol_failure, (try classify(response, "unrelated.net", .a)).failure);
    packet[9] = 0;
    const empty = try parseResponse(packet[0..offset], 42, "example.com", .a);
    try std.testing.expectEqual(.protocol_failure, (try classify(empty, "example.com", .a)).failure);
}

test "NXDOMAIN rejects contradictory answers and cycles but permits negative aliases" {
    var packet: [max_udp_packet]u8 = undefined;
    const len = try buildQuery(&packet, 42, "example.com", .a, true);
    const offset = len - 11;
    packet[2] = 0x81;
    packet[3] = 0x83;
    packet[7] = 1;
    packet[11] = 0;
    @memcpy(packet[offset..][0..16], &[_]u8{ 0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 127, 0, 0, 1 });
    const positive = try parseResponse(packet[0 .. offset + 16], 42, "example.com", .a);
    try std.testing.expectError(error.Malformed, classify(positive, "example.com", .a));
    try std.testing.expectEqual(.protocol_failure, (try classify(positive, "unrelated.net", .a)).failure);
    const alias = [_]u8{ 0xc0, 0x0c, 0, 5, 0, 1, 0, 0, 0, 60, 0, 6, 3, 'w', 'w', 'w', 0xc0, 0x0c };
    @memcpy(packet[offset..][0..alias.len], &alias);
    const negative = try parseResponse(packet[0 .. offset + alias.len], 42, "example.com", .a);
    try std.testing.expectEqual(.nxdomain, try classify(negative, "example.com", .a));
    packet[offset + 11] = 2;
    packet[offset + 12] = 0xc0;
    packet[offset + 13] = 0x0c;
    const cycle = try parseResponse(packet[0 .. offset + 14], 42, "example.com", .a);
    try std.testing.expectError(error.Malformed, classify(cycle, "example.com", .a));
}

test "SOA mailbox labels can contain literal dots" {
    var packet: [max_udp_packet]u8 = undefined;
    const len = try buildQuery(&packet, 42, "example.com", .a, true);
    const offset = len - 11;
    packet[2] = 0x81;
    packet[3] = 0x83;
    packet[9] = 1;
    packet[11] = 0;
    // The mailbox local part a.b is one wire label, not two domain labels.
    @memcpy(packet[offset..][0..20], &[_]u8{ 0xc0, 0x0c, 0, 6, 0, 1, 0, 0, 0, 60, 0, 28, 0xc0, 0x0c, 3, 'a', '.', 'b', 0xc0, 0x0c });
    @memset(packet[offset + 20 ..][0..20], 0);
    const response = try parseResponse(packet[0 .. offset + 40], 42, "example.com", .a);
    try std.testing.expectEqual(.nxdomain, try classify(response, "example.com", .a));
}
