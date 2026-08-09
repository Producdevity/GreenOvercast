const std = @import("std");
const rtp = @import("packet.zig");

const access_unit_capacity = 512 * 1024;
const parameter_set_capacity = 2048;
const start_code = [_]u8{ 0, 0, 0, 1 };

pub const AccessUnitInfo = extern struct {
    timestamp: u32,
    has_idr: u32,
    has_sps: u32,
    has_pps: u32,
};

pub const FeedResult = extern struct {
    accepted: u32 = 0,
    timestamp: u32 = 0,
    missing_packets: u32 = 0,
    late_packets: u32 = 0,
    discontinuities: u32 = 0,
    access_units: u32 = 0,
    frame_nals: u32 = 0,
    idr_nals: u32 = 0,
    parameter_nals: u32 = 0,
    auxiliary_nals: u32 = 0,
    requires_keyframe: u32 = 0,
};

pub const AccessUnitCallback = *const fn (
    context: ?*anyopaque,
    data: [*]const u8,
    length: usize,
    info: *const AccessUnitInfo,
) callconv(.c) void;

const FragmentState = enum {
    idle,
    writing,
    dropping,
};

pub const Depacketizer = struct {
    expected_payload_type: u7,
    access_unit: [access_unit_capacity]u8 = undefined,
    access_unit_length: usize = 0,
    access_unit_timestamp: ?u32 = null,
    access_unit_has_idr: bool = false,
    access_unit_has_sps: bool = false,
    access_unit_has_pps: bool = false,
    last_sequence: ?u16 = null,
    fragment_state: FragmentState = .idle,
    fragment_type: u5 = 0,
    fragment_nal_offset: usize = 0,
    have_sps: bool = false,
    have_pps: bool = false,
    decode_epoch_ready: bool = false,
    bootstrap_pending: bool = false,
    fresh_parameter_epoch: bool = false,
    fresh_sps: bool = false,
    fresh_pps: bool = false,
    parameter_sets_dirty: bool = false,
    sps: [parameter_set_capacity]u8 = undefined,
    sps_length: usize = 0,
    pps: [parameter_set_capacity]u8 = undefined,
    pps_length: usize = 0,

    pub fn init(expected_payload_type: u7) Depacketizer {
        return .{ .expected_payload_type = expected_payload_type };
    }

    pub fn setBootstrap(self: *Depacketizer, data: []const u8) bool {
        var next_sps: [parameter_set_capacity]u8 = undefined;
        var next_pps: [parameter_set_capacity]u8 = undefined;
        var next_sps_length: usize = 0;
        var next_pps_length: usize = 0;
        var offset: usize = 0;

        while (findStartCode(data, offset)) |start| {
            const nal_start = start.offset + start.length;
            const next = findStartCode(data, nal_start);
            const nal_end = if (next) |value| value.offset else data.len;
            if (nal_start < nal_end) {
                const nal = data[nal_start..nal_end];
                switch (nal[0] & 0x1f) {
                    7 => {
                        if (nal.len > next_sps.len) return false;
                        @memcpy(next_sps[0..nal.len], nal);
                        next_sps_length = nal.len;
                    },
                    8 => {
                        if (nal.len > next_pps.len) return false;
                        @memcpy(next_pps[0..nal.len], nal);
                        next_pps_length = nal.len;
                    },
                    else => {},
                }
            }
            offset = if (next) |value| value.offset else break;
        }

        if (next_sps_length == 0 or next_pps_length == 0) return false;
        @memcpy(self.sps[0..next_sps_length], next_sps[0..next_sps_length]);
        @memcpy(self.pps[0..next_pps_length], next_pps[0..next_pps_length]);
        self.sps_length = next_sps_length;
        self.pps_length = next_pps_length;
        self.have_sps = true;
        self.have_pps = true;
        self.decode_epoch_ready = true;
        self.bootstrap_pending = true;
        self.fresh_parameter_epoch = false;
        self.fresh_sps = false;
        self.fresh_pps = false;
        self.parameter_sets_dirty = false;
        return true;
    }

    pub fn takeBootstrap(self: *Depacketizer, output: []u8) ?usize {
        if (!self.parameter_sets_dirty) return 0;
        const required = start_code.len * 2 + self.sps_length + self.pps_length;
        if (self.sps_length == 0 or self.pps_length == 0 or output.len < required) return null;

        var offset: usize = 0;
        @memcpy(output[offset .. offset + start_code.len], &start_code);
        offset += start_code.len;
        @memcpy(output[offset .. offset + self.sps_length], self.sps[0..self.sps_length]);
        offset += self.sps_length;
        @memcpy(output[offset .. offset + start_code.len], &start_code);
        offset += start_code.len;
        @memcpy(output[offset .. offset + self.pps_length], self.pps[0..self.pps_length]);
        offset += self.pps_length;
        self.parameter_sets_dirty = false;
        return offset;
    }

    pub fn feed(
        self: *Depacketizer,
        packet: []const u8,
        callback: ?AccessUnitCallback,
        context: ?*anyopaque,
    ) FeedResult {
        var result = FeedResult{};
        const parsed = rtp.parse(packet) catch return result;
        if (parsed.header.payload_type != self.expected_payload_type or parsed.payload.len == 0)
            return result;

        result.accepted = 1;
        result.timestamp = parsed.header.timestamp;

        if (self.last_sequence) |last| {
            const expected = last +% 1;
            const distance = parsed.header.sequence -% expected;
            if (distance >= 0x8000) {
                result.late_packets = 1;
                return result;
            }
            if (distance > 0) {
                result.missing_packets = distance;
                self.discardAccessUnit(&result);
            }
        }
        self.last_sequence = parsed.header.sequence;

        if (self.access_unit_timestamp) |timestamp| {
            if (timestamp != parsed.header.timestamp) {
                if (self.fragment_state != .idle)
                    self.discardAccessUnit(&result)
                else
                    self.emitAccessUnit(timestamp, callback, context, &result);
            }
        }
        self.access_unit_timestamp = parsed.header.timestamp;

        self.processPayload(parsed.payload, &result);

        if (parsed.header.marker) {
            if (self.fragment_state != .idle)
                self.discardAccessUnit(&result)
            else
                self.emitAccessUnit(parsed.header.timestamp, callback, context, &result);
        }
        return result;
    }

    fn processPayload(self: *Depacketizer, payload: []const u8, result: *FeedResult) void {
        const nal_type: u5 = @intCast(payload[0] & 0x1f);
        switch (nal_type) {
            1...23 => self.processCompleteNal(payload, result),
            24 => self.processStapA(payload, result),
            28 => self.processFuA(payload, result),
            else => self.discardAccessUnit(result),
        }
    }

    fn processCompleteNal(self: *Depacketizer, nal: []const u8, result: *FeedResult) void {
        const nal_type: u5 = @intCast(nal[0] & 0x1f);
        self.countNal(nal_type, result);
        if ((nal_type == 7 or nal_type == 8) and
            !self.observeParameterSet(nal_type, nal, result)) return;
        if ((nal_type == 1 or nal_type == 5) and !self.prependBootstrap(result)) return;
        if (!self.shouldAppend(nal_type, result)) return;
        if (!self.appendNal(nal)) self.discardAccessUnit(result);
    }

    fn processStapA(self: *Depacketizer, payload: []const u8, result: *FeedResult) void {
        var offset: usize = 1;
        while (offset < payload.len) {
            if (payload.len - offset < 2) {
                self.discardAccessUnit(result);
                return;
            }
            const nal_length = std.mem.readInt(u16, payload[offset..][0..2], .big);
            offset += 2;
            if (nal_length == 0 or nal_length > payload.len - offset) {
                self.discardAccessUnit(result);
                return;
            }
            offset += nal_length;
        }

        offset = 1;
        while (offset < payload.len) {
            const nal_length = std.mem.readInt(u16, payload[offset..][0..2], .big);
            offset += 2;
            self.processCompleteNal(payload[offset .. offset + nal_length], result);
            offset += nal_length;
        }
    }

    fn processFuA(self: *Depacketizer, payload: []const u8, result: *FeedResult) void {
        if (payload.len < 2) {
            self.discardAccessUnit(result);
            return;
        }

        const fu_header = payload[1];
        const is_start = fu_header & 0x80 != 0;
        const is_end = fu_header & 0x40 != 0;
        const nal_type: u5 = @intCast(fu_header & 0x1f);

        if (nal_type == 0 or nal_type > 23) {
            self.discardAccessUnit(result);
            return;
        }

        if (is_start) {
            if (self.fragment_state != .idle) self.discardAccessUnit(result);
            self.countNal(nal_type, result);
            if ((nal_type == 1 or nal_type == 5) and !self.prependBootstrap(result)) {
                self.fragment_state = .dropping;
            } else if (!self.shouldAppend(nal_type, result)) {
                self.fragment_state = .dropping;
            } else {
                const nal_header = (payload[0] & 0x60) | @as(u8, nal_type);
                if (!self.appendStartCodeAndHeader(nal_header)) {
                    self.discardAccessUnit(result);
                    self.fragment_state = .dropping;
                } else {
                    self.fragment_state = .writing;
                    self.fragment_type = nal_type;
                    self.fragment_nal_offset = self.access_unit_length - 1;
                }
            }
        } else if (self.fragment_state == .idle) {
            self.discardAccessUnit(result);
            return;
        }

        if (self.fragment_state == .writing and payload.len > 2) {
            if (!self.appendBytes(payload[2..])) {
                self.discardAccessUnit(result);
                self.fragment_state = .dropping;
            }
        }

        if (is_end) {
            if (self.fragment_state == .writing and
                (self.fragment_type == 7 or self.fragment_type == 8))
            {
                const nal = self.access_unit[self.fragment_nal_offset..self.access_unit_length];
                _ = self.observeParameterSet(self.fragment_type, nal, result);
            }
            self.fragment_state = .idle;
        }
    }

    fn shouldAppend(self: *Depacketizer, nal_type: u5, result: *FeedResult) bool {
        if (nal_type == 7) {
            self.have_sps = true;
            self.access_unit_has_sps = true;
            return true;
        }
        if (nal_type == 8) {
            self.have_pps = true;
            self.access_unit_has_pps = true;
            return true;
        }
        if (nal_type == 5) {
            if (!self.have_sps or !self.have_pps) {
                result.requires_keyframe = 1;
                return false;
            }
            self.decode_epoch_ready = true;
            self.access_unit_has_idr = true;
            result.requires_keyframe = 0;
            return true;
        }
        if (!self.decode_epoch_ready) result.requires_keyframe = 1;
        return self.decode_epoch_ready;
    }

    fn countNal(_: *Depacketizer, nal_type: u5, result: *FeedResult) void {
        if (nal_type == 1 or nal_type == 5) {
            result.frame_nals += 1;
            if (nal_type == 5) result.idr_nals += 1;
        } else if (nal_type == 7 or nal_type == 8) {
            result.parameter_nals += 1;
        } else {
            result.auxiliary_nals += 1;
        }
    }

    fn observeParameterSet(
        self: *Depacketizer,
        nal_type: u5,
        nal: []const u8,
        result: *FeedResult,
    ) bool {
        if (nal.len == 0 or nal.len > parameter_set_capacity) {
            self.discardAccessUnit(result);
            return false;
        }
        if (!self.fresh_parameter_epoch) {
            self.fresh_parameter_epoch = true;
            self.fresh_sps = false;
            self.fresh_pps = false;
            self.have_sps = false;
            self.have_pps = false;
            self.decode_epoch_ready = false;
            self.bootstrap_pending = false;
            result.requires_keyframe = 1;
        }
        if (nal_type == 7 and self.fresh_sps and self.fresh_pps) {
            self.fresh_sps = false;
            self.fresh_pps = false;
            self.parameter_sets_dirty = false;
        }
        if (nal_type == 7) {
            @memcpy(self.sps[0..nal.len], nal);
            self.sps_length = nal.len;
            self.fresh_sps = true;
            self.have_sps = true;
            self.access_unit_has_sps = true;
        } else {
            @memcpy(self.pps[0..nal.len], nal);
            self.pps_length = nal.len;
            self.fresh_pps = true;
            self.have_pps = true;
            self.access_unit_has_pps = true;
        }
        if (self.fresh_sps and self.fresh_pps) self.parameter_sets_dirty = true;
        return true;
    }

    fn prependBootstrap(self: *Depacketizer, result: *FeedResult) bool {
        if (!self.bootstrap_pending) return true;
        if (!self.appendNal(self.sps[0..self.sps_length]) or
            !self.appendNal(self.pps[0..self.pps_length]))
        {
            self.discardAccessUnit(result);
            return false;
        }
        self.access_unit_has_sps = true;
        self.access_unit_has_pps = true;
        self.bootstrap_pending = false;
        return true;
    }

    fn appendNal(self: *Depacketizer, nal: []const u8) bool {
        if (start_code.len + nal.len > access_unit_capacity - self.access_unit_length)
            return false;
        @memcpy(
            self.access_unit[self.access_unit_length .. self.access_unit_length + start_code.len],
            &start_code,
        );
        self.access_unit_length += start_code.len;
        return self.appendBytes(nal);
    }

    fn appendStartCodeAndHeader(self: *Depacketizer, nal_header: u8) bool {
        if (start_code.len + 1 > access_unit_capacity - self.access_unit_length) return false;
        @memcpy(
            self.access_unit[self.access_unit_length .. self.access_unit_length + start_code.len],
            &start_code,
        );
        self.access_unit_length += start_code.len;
        self.access_unit[self.access_unit_length] = nal_header;
        self.access_unit_length += 1;
        return true;
    }

    fn appendBytes(self: *Depacketizer, bytes: []const u8) bool {
        if (bytes.len > access_unit_capacity - self.access_unit_length) return false;
        @memcpy(self.access_unit[self.access_unit_length .. self.access_unit_length + bytes.len], bytes);
        self.access_unit_length += bytes.len;
        return true;
    }

    fn emitAccessUnit(
        self: *Depacketizer,
        timestamp: u32,
        callback: ?AccessUnitCallback,
        context: ?*anyopaque,
        result: *FeedResult,
    ) void {
        if (self.access_unit_length == 0) return;
        const info = AccessUnitInfo{
            .timestamp = timestamp,
            .has_idr = @intFromBool(self.access_unit_has_idr),
            .has_sps = @intFromBool(self.access_unit_has_sps),
            .has_pps = @intFromBool(self.access_unit_has_pps),
        };
        if (callback) |emit|
            emit(context, self.access_unit[0..self.access_unit_length].ptr, self.access_unit_length, &info);
        result.access_units += 1;
        self.resetAccessUnit();
    }

    fn discardAccessUnit(self: *Depacketizer, result: *FeedResult) void {
        self.resetAccessUnit();
        result.discontinuities += 1;
        result.requires_keyframe = 1;
    }

    fn resetAccessUnit(self: *Depacketizer) void {
        self.access_unit_length = 0;
        self.access_unit_has_idr = false;
        self.access_unit_has_sps = false;
        self.access_unit_has_pps = false;
        self.fragment_state = .idle;
    }
};

const StartCode = struct {
    offset: usize,
    length: usize,
};

fn findStartCode(data: []const u8, offset: usize) ?StartCode {
    var index = offset;
    while (index + 3 <= data.len) : (index += 1) {
        if (data[index] != 0 or data[index + 1] != 0) continue;
        if (data[index + 2] == 1) return .{ .offset = index, .length = 3 };
        if (index + 4 <= data.len and data[index + 2] == 0 and data[index + 3] == 1)
            return .{ .offset = index, .length = 4 };
    }
    return null;
}

pub export fn go_h264_depacketizer_create(expected_payload_type: u8) ?*Depacketizer {
    if (expected_payload_type > 127) return null;
    const depacketizer = std.heap.page_allocator.create(Depacketizer) catch return null;
    depacketizer.* = Depacketizer.init(@intCast(expected_payload_type));
    return depacketizer;
}

pub export fn go_h264_depacketizer_destroy(depacketizer: ?*Depacketizer) void {
    if (depacketizer) |value| std.heap.page_allocator.destroy(value);
}

pub export fn go_h264_depacketizer_set_bootstrap(
    depacketizer: ?*Depacketizer,
    data: ?[*]const u8,
    length: usize,
) c_int {
    const state = depacketizer orelse return -1;
    const bytes = data orelse return -1;
    return if (state.setBootstrap(bytes[0..length])) 0 else -1;
}

pub export fn go_h264_depacketizer_take_bootstrap(
    depacketizer: ?*Depacketizer,
    output: ?[*]u8,
    capacity: usize,
    length: ?*usize,
) c_int {
    const state = depacketizer orelse return -1;
    const destination = output orelse return -1;
    const output_length = length orelse return -1;
    const written = state.takeBootstrap(destination[0..capacity]) orelse return -1;
    output_length.* = written;
    return if (written > 0) 1 else 0;
}

pub export fn go_h264_depacketizer_feed(
    depacketizer: ?*Depacketizer,
    packet: ?[*]const u8,
    length: usize,
    callback: ?AccessUnitCallback,
    context: ?*anyopaque,
) FeedResult {
    const state = depacketizer orelse return .{};
    const bytes = packet orelse return .{};
    return state.feed(bytes[0..length], callback, context);
}

const TestCollector = struct {
    calls: usize = 0,
    lengths: [4]usize = .{0} ** 4,
    timestamps: [4]u32 = .{0} ** 4,
    data: [1024]u8 = undefined,
    data_length: usize = 0,
};

fn collectAccessUnit(
    context: ?*anyopaque,
    data: [*]const u8,
    length: usize,
    info: *const AccessUnitInfo,
) callconv(.c) void {
    const collector: *TestCollector = @ptrCast(@alignCast(context.?));
    collector.lengths[collector.calls] = length;
    collector.timestamps[collector.calls] = info.timestamp;
    collector.calls += 1;
    if (length <= collector.data.len) {
        @memcpy(collector.data[0..length], data[0..length]);
        collector.data_length = length;
    }
}

fn makeRtp(sequence: u16, timestamp: u32, marker: bool, payload: []const u8) [256]u8 {
    var packet: [256]u8 = undefined;
    packet[0] = 0x80;
    packet[1] = 102 | (if (marker) @as(u8, 0x80) else 0);
    std.mem.writeInt(u16, packet[2..4], sequence, .big);
    std.mem.writeInt(u32, packet[4..8], timestamp, .big);
    std.mem.writeInt(u32, packet[8..12], 0x12345678, .big);
    @memcpy(packet[12 .. 12 + payload.len], payload);
    return packet;
}

const bootstrap = [_]u8{
    0, 0, 0, 1, 0x67, 0x42,
    0, 0, 0, 1, 0x68, 0xce,
};

test "cached parameter sets bootstrap the first slice" {
    var depacketizer = Depacketizer.init(102);
    try std.testing.expect(depacketizer.setBootstrap(&bootstrap));
    var collector = TestCollector{};
    const slice = [_]u8{ 0x61, 0xaa };
    const packet = makeRtp(1, 3600, true, &slice);

    const result = depacketizer.feed(packet[0 .. 12 + slice.len], collectAccessUnit, &collector);

    try std.testing.expectEqual(@as(u32, 1), result.accepted);
    try std.testing.expectEqual(@as(usize, 1), collector.calls);
    try std.testing.expectEqualSlices(u8, &bootstrap, collector.data[0..bootstrap.len]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0x61, 0xaa }, collector.data[bootstrap.len..collector.data_length]);
}

test "STAP-A supplies a fresh decode epoch and persisted bootstrap" {
    var depacketizer = Depacketizer.init(102);
    var collector = TestCollector{};
    const payload = [_]u8{
        0x78,
        0x00,
        0x02,
        0x67,
        0x42,
        0x00,
        0x02,
        0x68,
        0xce,
        0x00,
        0x02,
        0x65,
        0xbb,
    };
    const packet = makeRtp(1, 3600, true, &payload);

    const result = depacketizer.feed(packet[0 .. 12 + payload.len], collectAccessUnit, &collector);
    var persisted: [64]u8 = undefined;
    const persisted_length = depacketizer.takeBootstrap(&persisted).?;

    try std.testing.expectEqual(@as(u32, 1), result.access_units);
    try std.testing.expectEqual(@as(u32, 1), result.idr_nals);
    try std.testing.expectEqual(@as(u32, 2), result.parameter_nals);
    try std.testing.expectEqual(@as(u32, 0), result.requires_keyframe);
    try std.testing.expectEqualSlices(u8, &bootstrap, persisted[0..persisted_length]);
    try std.testing.expectEqual(@as(?usize, 0), depacketizer.takeBootstrap(&persisted));
}

test "FU-A reassembles one NAL without packet allocations" {
    var depacketizer = Depacketizer.init(102);
    try std.testing.expect(depacketizer.setBootstrap(&bootstrap));
    var collector = TestCollector{};
    const first = [_]u8{ 0x7c, 0x85, 0xde, 0xad };
    const second = [_]u8{ 0x7c, 0x45, 0xbe, 0xef };
    const packet1 = makeRtp(1, 3600, false, &first);
    const packet2 = makeRtp(2, 3600, true, &second);

    _ = depacketizer.feed(packet1[0 .. 12 + first.len], collectAccessUnit, &collector);
    const result = depacketizer.feed(packet2[0 .. 12 + second.len], collectAccessUnit, &collector);

    try std.testing.expectEqual(@as(u32, 1), result.access_units);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0x65, 0xde, 0xad, 0xbe, 0xef }, collector.data[bootstrap.len..collector.data_length]);
}

test "sequence gap discards a partial access unit" {
    var depacketizer = Depacketizer.init(102);
    try std.testing.expect(depacketizer.setBootstrap(&bootstrap));
    var collector = TestCollector{};
    const partial = [_]u8{ 0x61, 0xaa };
    const idr = [_]u8{ 0x65, 0xbb };
    const packet1 = makeRtp(10, 3600, false, &partial);
    const packet2 = makeRtp(12, 3960, true, &idr);

    _ = depacketizer.feed(packet1[0 .. 12 + partial.len], collectAccessUnit, &collector);
    const result = depacketizer.feed(packet2[0 .. 12 + idr.len], collectAccessUnit, &collector);

    try std.testing.expectEqual(@as(u32, 1), result.missing_packets);
    try std.testing.expectEqual(@as(u32, 1), result.discontinuities);
    try std.testing.expectEqual(@as(u32, 0), result.requires_keyframe);
    try std.testing.expectEqual(@as(usize, 1), collector.calls);
    try std.testing.expectEqual(@as(u32, 3960), collector.timestamps[0]);
}

test "late packet is ignored and sequence wrap is accepted" {
    var depacketizer = Depacketizer.init(102);
    try std.testing.expect(depacketizer.setBootstrap(&bootstrap));
    var collector = TestCollector{};
    const nal = [_]u8{ 0x61, 0xaa };
    const before_wrap = makeRtp(65535, 3600, true, &nal);
    const after_wrap = makeRtp(0, 3960, true, &nal);
    const late = makeRtp(65535, 4320, true, &nal);

    _ = depacketizer.feed(before_wrap[0 .. 12 + nal.len], collectAccessUnit, &collector);
    const wrapped = depacketizer.feed(after_wrap[0 .. 12 + nal.len], collectAccessUnit, &collector);
    const ignored = depacketizer.feed(late[0 .. 12 + nal.len], collectAccessUnit, &collector);

    try std.testing.expectEqual(@as(u32, 0), wrapped.discontinuities);
    try std.testing.expectEqual(@as(u32, 1), ignored.late_packets);
    try std.testing.expectEqual(@as(usize, 2), collector.calls);
}

test "timestamp boundary can emit two access units from one packet" {
    var depacketizer = Depacketizer.init(102);
    try std.testing.expect(depacketizer.setBootstrap(&bootstrap));
    var collector = TestCollector{};
    const nal = [_]u8{ 0x61, 0xaa };
    const packet1 = makeRtp(1, 3600, false, &nal);
    const packet2 = makeRtp(2, 3960, true, &nal);

    _ = depacketizer.feed(packet1[0 .. 12 + nal.len], collectAccessUnit, &collector);
    const result = depacketizer.feed(packet2[0 .. 12 + nal.len], collectAccessUnit, &collector);

    try std.testing.expectEqual(@as(u32, 2), result.access_units);
    try std.testing.expectEqual(@as(usize, 2), collector.calls);
    try std.testing.expectEqualSlices(u32, &.{ 3600, 3960 }, collector.timestamps[0..2]);
}

test "malformed aggregation and orphan fragment are discarded" {
    var depacketizer = Depacketizer.init(102);
    var collector = TestCollector{};
    const malformed_stap = [_]u8{ 0x78, 0x00, 0x04, 0x67 };
    const orphan_fragment = [_]u8{ 0x7c, 0x45, 0xaa };
    const packet1 = makeRtp(1, 3600, true, &malformed_stap);
    const packet2 = makeRtp(2, 3960, true, &orphan_fragment);

    const first = depacketizer.feed(packet1[0 .. 12 + malformed_stap.len], collectAccessUnit, &collector);
    const second = depacketizer.feed(packet2[0 .. 12 + orphan_fragment.len], collectAccessUnit, &collector);

    try std.testing.expectEqual(@as(u32, 1), first.discontinuities);
    try std.testing.expectEqual(@as(u32, 1), second.discontinuities);
    try std.testing.expectEqual(@as(usize, 0), collector.calls);
}

test "wrong payload type is rejected without changing sequence state" {
    var depacketizer = Depacketizer.init(102);
    const nal = [_]u8{ 0x61, 0xaa };
    var packet = makeRtp(1, 3600, true, &nal);
    packet[1] = 96;

    const rejected = depacketizer.feed(packet[0 .. 12 + nal.len], null, null);

    try std.testing.expectEqual(@as(u32, 0), rejected.accepted);
    try std.testing.expectEqual(@as(?u16, null), depacketizer.last_sequence);
}

test "invalid bootstrap does not replace the active parameter sets" {
    var depacketizer = Depacketizer.init(102);
    try std.testing.expect(depacketizer.setBootstrap(&bootstrap));
    try std.testing.expect(!depacketizer.setBootstrap(&.{ 0, 0, 1, 0x67, 0x42 }));
    var output: [64]u8 = undefined;
    depacketizer.parameter_sets_dirty = true;

    const length = depacketizer.takeBootstrap(&output).?;

    try std.testing.expectEqualSlices(u8, &bootstrap, output[0..length]);
}
