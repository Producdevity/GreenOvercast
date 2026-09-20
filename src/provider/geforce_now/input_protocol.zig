const std = @import("std");

pub const Button = struct {
    pub const dpad_up: u16 = 0x0001;
    pub const dpad_down: u16 = 0x0002;
    pub const dpad_left: u16 = 0x0004;
    pub const dpad_right: u16 = 0x0008;
    pub const start: u16 = 0x0010;
    pub const back: u16 = 0x0020;
    pub const left_stick: u16 = 0x0040;
    pub const right_stick: u16 = 0x0080;
    pub const left_shoulder: u16 = 0x0100;
    pub const right_shoulder: u16 = 0x0200;
    pub const guide: u16 = 0x0400;
    pub const a: u16 = 0x1000;
    pub const b: u16 = 0x2000;
    pub const x: u16 = 0x4000;
    pub const y: u16 = 0x8000;
};

pub const GamepadState = struct {
    controller_id: u8 = 0,
    gamepad_bitmap: u16 = 0x0101,
    buttons: u16 = 0,
    left_trigger: u8 = 0,
    right_trigger: u8 = 0,
    left_x: i16 = 0,
    left_y: i16 = 0,
    right_x: i16 = 0,
    right_y: i16 = 0,
    timestamp_us: u64 = 0,
};

pub const Encoder = struct {
    protocol_version: u16 = 2,

    pub fn setProtocolVersion(self: *Encoder, version: u16) void {
        self.protocol_version = version;
    }

    pub fn encodeHeartbeat(_: *const Encoder, output: []u8) ![]const u8 {
        if (output.len < heartbeat_size) return error.NoSpace;
        std.mem.writeInt(u32, output[0..heartbeat_size], 2, .little);
        return output[0..heartbeat_size];
    }

    pub fn encodeMousePosition(self: *const Encoder, output: []u8, x: u16, y: u16, width: u16, height: u16, timestamp_us: u64) ![]const u8 {
        if (width == 0 or height == 0) return error.InvalidPointerDimensions;
        const body = try self.mousePacket(output, 26, true, timestamp_us);
        std.mem.writeInt(u32, body[0..4], 5, .little);
        std.mem.writeInt(u16, body[4..6], @min(x, width - 1), .big);
        std.mem.writeInt(u16, body[6..8], @min(y, height - 1), .big);
        std.mem.writeInt(u16, body[10..12], width, .big);
        std.mem.writeInt(u16, body[12..14], height, .big);
        std.mem.writeInt(u64, body[18..26], timestamp_us, .big);
        return output[0..self.mousePacketSize(26, true)];
    }

    pub fn encodeMouseButton(self: *const Encoder, output: []u8, button: MouseButton, down: bool, timestamp_us: u64) ![]const u8 {
        const body = try self.mousePacket(output, 18, false, timestamp_us);
        std.mem.writeInt(u32, body[0..4], if (down) 8 else 9, .little);
        body[4] = @intFromEnum(button);
        std.mem.writeInt(u64, body[10..18], timestamp_us, .big);
        return output[0..self.mousePacketSize(18, false)];
    }

    pub fn encodeMouseWheel(self: *const Encoder, output: []u8, delta: i16, timestamp_us: u64) ![]const u8 {
        const body = try self.mousePacket(output, 22, false, timestamp_us);
        std.mem.writeInt(u32, body[0..4], 10, .little);
        std.mem.writeInt(i16, body[6..8], delta, .big);
        std.mem.writeInt(u64, body[14..22], timestamp_us, .big);
        return output[0..self.mousePacketSize(22, false)];
    }

    fn mousePacketSize(self: *const Encoder, body_size: usize, batch: bool) usize {
        return body_size + if (self.protocol_version >= 3) @as(usize, if (batch) 12 else 10) else 0;
    }

    fn mousePacket(self: *const Encoder, output: []u8, body_size: u16, batch: bool, timestamp_us: u64) ![]u8 {
        const size = self.mousePacketSize(body_size, batch);
        if (output.len < size) return error.NoSpace;
        @memset(output[0..size], 0);
        if (self.protocol_version >= 3) {
            output[0] = 0x23;
            std.mem.writeInt(u64, output[1..9], timestamp_us, .big);
            output[9] = if (batch) 0x21 else 0x22;
            if (batch) std.mem.writeInt(u16, output[10..12], body_size, .big);
        }
        return output[size - body_size .. size];
    }

    pub fn encodeReliableGamepad(
        self: *const Encoder,
        output: []u8,
        state: GamepadState,
    ) ![]const u8 {
        const payload_offset: usize = if (self.protocol_version >= 3) reliable_wrapper_size else 0;
        const packet_size = payload_offset + gamepad_packet_size;
        if (output.len < packet_size) return error.NoSpace;
        @memset(output[0..packet_size], 0);

        if (self.protocol_version >= 3) {
            output[0] = 0x23;
            std.mem.writeInt(u64, output[1..9], state.timestamp_us, .big);
            output[9] = 0x21;
            std.mem.writeInt(u16, output[10..12], gamepad_packet_size, .big);
        }
        encodeGamepadBody(output[payload_offset..packet_size], state);
        return output[0..packet_size];
    }
};

pub const heartbeat_size: usize = 4;
pub const MouseButton = enum(u8) { left = 1, right = 3 };
pub const gamepad_packet_size: usize = 38;
pub const maximum_packet_size: usize = reliable_wrapper_size + gamepad_packet_size;

const reliable_wrapper_size: usize = 12;

pub fn parseHandshakeVersion(data: []const u8) ?u16 {
    if (data.len < 2) return null;
    const first_word = std.mem.readInt(u16, data[0..2], .little);
    if (first_word == 526) {
        if (data.len < 4) return 2;
        const version = std.mem.readInt(u16, data[2..4], .little);
        return if (version == 2 or version == 3) version else null;
    }
    if (data[0] == 0x0e and (data[1] == 2 or data[1] == 3)) return data[1];
    return null;
}

fn encodeGamepadBody(output: []u8, state: GamepadState) void {
    std.debug.assert(output.len >= gamepad_packet_size);
    std.mem.writeInt(u32, output[0..4], 12, .little);
    std.mem.writeInt(u16, output[4..6], 26, .little);
    std.mem.writeInt(u16, output[6..8], state.controller_id & 3, .little);
    std.mem.writeInt(u16, output[8..10], state.gamepad_bitmap, .little);
    std.mem.writeInt(u16, output[10..12], 20, .little);
    std.mem.writeInt(u16, output[12..14], state.buttons, .little);
    output[14] = state.left_trigger;
    output[15] = state.right_trigger;
    std.mem.writeInt(i16, output[16..18], state.left_x, .little);
    std.mem.writeInt(i16, output[18..20], state.left_y, .little);
    std.mem.writeInt(i16, output[20..22], state.right_x, .little);
    std.mem.writeInt(i16, output[22..24], state.right_y, .little);
    output[26] = 0x55;
    std.mem.writeInt(u64, output[30..38], state.timestamp_us, .little);
}

test "heartbeat remains unwrapped for protocol version three" {
    var encoder = Encoder{};
    encoder.setProtocolVersion(3);
    var output: [maximum_packet_size]u8 = undefined;
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x02, 0x00, 0x00, 0x00 },
        try encoder.encodeHeartbeat(&output),
    );
}

test "protocol version two gamepad fields use the expected byte order" {
    const encoder = Encoder{};
    var output: [maximum_packet_size]u8 = undefined;
    const packet = try encoder.encodeReliableGamepad(&output, .{
        .controller_id = 7,
        .gamepad_bitmap = 0x0305,
        .buttons = 0xa55a,
        .left_trigger = 0x12,
        .right_trigger = 0xfe,
        .left_x = -2,
        .left_y = 0x1234,
        .right_x = std.math.minInt(i16),
        .right_y = std.math.maxInt(i16),
        .timestamp_us = 0x0102030405060708,
    });

    try std.testing.expectEqual(gamepad_packet_size, packet.len);
    try std.testing.expectEqual(@as(u32, 12), std.mem.readInt(u32, packet[0..4], .little));
    try std.testing.expectEqual(@as(u16, 26), std.mem.readInt(u16, packet[4..6], .little));
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, packet[6..8], .little));
    try std.testing.expectEqual(@as(u16, 0x0305), std.mem.readInt(u16, packet[8..10], .little));
    try std.testing.expectEqual(@as(u16, 0xa55a), std.mem.readInt(u16, packet[12..14], .little));
    try std.testing.expectEqual(@as(i16, -2), std.mem.readInt(i16, packet[16..18], .little));
    try std.testing.expectEqual(@as(u8, 0x55), packet[26]);
    try std.testing.expectEqual(
        @as(u64, 0x0102030405060708),
        std.mem.readInt(u64, packet[30..38], .little),
    );
    for ([_]usize{ 24, 25, 27, 28, 29 }) |index|
        try std.testing.expectEqual(@as(u8, 0), packet[index]);
}

test "default gamepad state identifies the first connected controller" {
    const encoder = Encoder{};
    var output: [maximum_packet_size]u8 = undefined;
    const packet = try encoder.encodeReliableGamepad(&output, .{});

    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, packet[6..8], .little));
    try std.testing.expectEqual(@as(u16, 0x0101), std.mem.readInt(u16, packet[8..10], .little));
}

test "protocol version three reliable gamepad wraps the complete legacy packet" {
    var encoder = Encoder{};
    encoder.setProtocolVersion(3);
    var output: [maximum_packet_size]u8 = undefined;
    const packet = try encoder.encodeReliableGamepad(&output, .{
        .buttons = Button.a,
        .timestamp_us = 0x0102030405060708,
    });

    try std.testing.expectEqual(@as(usize, 50), packet.len);
    try std.testing.expectEqual(@as(u8, 0x23), packet[0]);
    try std.testing.expectEqual(
        @as(u64, 0x0102030405060708),
        std.mem.readInt(u64, packet[1..9], .big),
    );
    try std.testing.expectEqual(@as(u8, 0x21), packet[9]);
    try std.testing.expectEqual(@as(u16, 38), std.mem.readInt(u16, packet[10..12], .big));
    try std.testing.expectEqual(@as(u32, 12), std.mem.readInt(u32, packet[12..16], .little));
}

test "parses both observed input-channel handshake formats" {
    try std.testing.expectEqual(@as(?u16, 3), parseHandshakeVersion(&.{ 0x0e, 0x02, 0x03, 0x00 }));
    try std.testing.expectEqual(@as(?u16, 2), parseHandshakeVersion(&.{ 0x0e, 0x02 }));
    try std.testing.expectEqual(@as(?u16, 3), parseHandshakeVersion(&.{ 0x0e, 0x03 }));
    try std.testing.expectEqual(@as(?u16, null), parseHandshakeVersion(&.{ 0x0e, 0xff }));
    try std.testing.expectEqual(@as(?u16, null), parseHandshakeVersion(&.{ 0x01, 0x00 }));
}

test "absolute mouse packet uses big endian coordinates inside the legacy header" {
    var output: [maximum_packet_size]u8 = undefined;
    const encoder = Encoder{};
    const packet = try encoder.encodeMousePosition(&output, 320, 240, 640, 480, 17);
    try std.testing.expectEqual(@as(usize, 26), packet.len);
    try std.testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, packet[0..4], .little));
    try std.testing.expectEqual(@as(u16, 320), std.mem.readInt(u16, packet[4..6], .big));
    try std.testing.expectEqual(@as(u16, 240), std.mem.readInt(u16, packet[6..8], .big));
    try std.testing.expectEqual(@as(u16, 640), std.mem.readInt(u16, packet[10..12], .big));
    try std.testing.expectEqual(@as(u16, 480), std.mem.readInt(u16, packet[12..14], .big));
    try std.testing.expectEqual(@as(u64, 17), std.mem.readInt(u64, packet[18..26], .big));
    for ([_]usize{ 8, 9, 14, 15, 16, 17 }) |i| try std.testing.expectEqual(@as(u8, 0), packet[i]);
    try std.testing.expectError(error.InvalidPointerDimensions, encoder.encodeMousePosition(&output, 0, 0, 0, 1, 0));
    try std.testing.expectError(error.NoSpace, encoder.encodeMousePosition(output[0..25], 0, 0, 1, 1, 0));
}

test "v3 wraps mouse motion as a batch and button edges as single events" {
    const encoder = Encoder{ .protocol_version = 3 };
    var output: [maximum_packet_size]u8 = undefined;
    const position = try encoder.encodeMousePosition(&output, 65535, 65535, 640, 480, 7);
    try std.testing.expectEqual(@as(usize, 38), position.len);
    try std.testing.expectEqual(@as(u8, 0x23), position[0]);
    try std.testing.expectEqual(@as(u8, 0x21), position[9]);
    try std.testing.expectEqual(@as(u16, 26), std.mem.readInt(u16, position[10..12], .big));
    try std.testing.expectEqual(@as(u16, 639), std.mem.readInt(u16, position[16..18], .big));
    try std.testing.expectEqual(@as(u16, 479), std.mem.readInt(u16, position[18..20], .big));
    for ([_]bool{ true, false }) |down| {
        const button = try encoder.encodeMouseButton(&output, .right, down, 123);
        try std.testing.expectEqual(@as(usize, 28), button.len);
        try std.testing.expectEqual(@as(u8, 0x22), button[9]);
        try std.testing.expectEqual(@as(u32, if (down) 8 else 9), std.mem.readInt(u32, button[10..14], .little));
        try std.testing.expectEqual(@as(u8, 3), button[14]);
        try std.testing.expectEqual(@as(u64, 123), std.mem.readInt(u64, button[20..28], .big));
    }
    const wheel = try encoder.encodeMouseWheel(&output, -120, 321);
    try std.testing.expectEqual(@as(usize, 32), wheel.len);
    try std.testing.expectEqual(@as(i16, -120), std.mem.readInt(i16, wheel[16..18], .big));
    try std.testing.expectEqual(@as(u64, 321), std.mem.readInt(u64, wheel[24..32], .big));
}
