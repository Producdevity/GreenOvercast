const std = @import("std");

const Frame = extern struct {
    length: usize,
    offset: c_longlong,
    bytes_left: c_longlong,
    flags: c_uint,
};

pub const Incoming = struct {
    text: []const u8,
    flags: c_uint = 1,
    offset: c_longlong = 0,
    bytes_left: c_longlong = 0,
};

pub var incoming: []const Incoming = &.{};
pub var gated_offer: ?[]const u8 = null;
pub var assignment_acknowledged = false;
pub var fail_send = false;
pub var closed = false;
pub var sent_count: usize = 0;
var sent: [16][8192]u8 = undefined;
var lengths: [16]usize = undefined;
var incoming_index: usize = 0;
var incoming_offset: usize = 0;

pub fn reset() void {
    incoming = &.{};
    gated_offer = null;
    assignment_acknowledged = false;
    fail_send = false;
    closed = false;
    sent_count = 0;
    incoming_index = 0;
    incoming_offset = 0;
}

pub fn message(index: usize) []const u8 {
    std.debug.assert(index < sent_count);
    return sent[index][0..lengths[index]];
}

export fn go_websocket_open(
    _: [*:0]const u8,
    _: [*:0]const u8,
    _: [*:0]const u8,
    _: [*:0]const u8,
    _: [*]u8,
    _: usize,
) ?*anyopaque {
    return @ptrFromInt(1);
}

export fn go_websocket_send(_: *anyopaque, data: [*]const u8, length: usize, _: c_uint, written: *usize) c_int {
    written.* = 0;
    if (fail_send or sent_count == sent.len or length > sent[0].len) return -1;
    @memcpy(sent[sent_count][0..length], data[0..length]);
    lengths[sent_count] = length;
    sent_count += 1;
    if (std.mem.eql(u8, data[0..length], "{\"ack\":7}")) assignment_acknowledged = true;
    written.* = length;
    return 1;
}

export fn go_websocket_receive(_: *anyopaque, output: [*]u8, capacity: usize, frame: *Frame) c_int {
    const next = if (incoming_index < incoming.len) incoming[incoming_index] else if (assignment_acknowledged and gated_offer != null) blk: {
        const offer = gated_offer.?;
        break :blk Incoming{ .text = offer };
    } else return if (closed) -2 else 0;
    const length = @min(capacity, next.text.len - incoming_offset);
    @memcpy(output[0..length], next.text[incoming_offset..][0..length]);
    frame.* = .{
        .length = length,
        .offset = next.offset + @as(c_longlong, @intCast(incoming_offset)),
        .bytes_left = next.bytes_left + @as(c_longlong, @intCast(next.text.len - incoming_offset - length)),
        .flags = next.flags,
    };
    incoming_offset += length;
    if (incoming_offset == next.text.len) {
        if (incoming_index < incoming.len) incoming_index += 1 else gated_offer = null;
        incoming_offset = 0;
    }
    return if (frame.flags & (1 << 3) != 0) -2 else 1;
}

export fn go_websocket_last_error(_: *const anyopaque) [*:0]const u8 {
    return "test transport error";
}

export fn go_websocket_close(_: *anyopaque) void {}
