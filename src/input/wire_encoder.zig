const std = @import("std");

pub const Button = struct {
    pub const nexus: u16 = 0x0002;
    pub const menu: u16 = 0x0004;
    pub const view: u16 = 0x0008;
    pub const a: u16 = 0x0010;
    pub const b: u16 = 0x0020;
    pub const x: u16 = 0x0040;
    pub const y: u16 = 0x0080;
    pub const dpad_up: u16 = 0x0100;
    pub const dpad_down: u16 = 0x0200;
    pub const dpad_left: u16 = 0x0400;
    pub const dpad_right: u16 = 0x0800;
    pub const left_shoulder: u16 = 0x1000;
    pub const right_shoulder: u16 = 0x2000;
    pub const left_stick: u16 = 0x4000;
    pub const right_stick: u16 = 0x8000;
};

pub const SourceButton = struct {
    pub const a: u32 = 1 << 0;
    pub const b: u32 = 1 << 1;
    pub const x: u32 = 1 << 2;
    pub const y: u32 = 1 << 3;
    pub const left_shoulder: u32 = 1 << 4;
    pub const right_shoulder: u32 = 1 << 5;
    pub const back: u32 = 1 << 6;
    pub const start: u32 = 1 << 7;
    pub const dpad_up: u32 = 1 << 8;
    pub const dpad_down: u32 = 1 << 9;
    pub const dpad_left: u32 = 1 << 10;
    pub const dpad_right: u32 = 1 << 11;
    pub const left_stick: u32 = 1 << 12;
    pub const right_stick: u32 = 1 << 13;
};

pub const GamepadState = struct {
    buttons: u16 = 0,
    left_x: f32 = 0, // [-1, 1]
    left_y: f32 = 0,
    right_x: f32 = 0,
    right_y: f32 = 0,
    left_trigger: f32 = 0, // [0, 1]
    right_trigger: f32 = 0,
};

pub const PACKET_SIZE: usize = 38;

const report_type_gamepad: u16 = 0x0002;

pub fn buttonMask(source: u32) u16 {
    var mask: u16 = 0;
    const mappings = [_]struct { u32, u16 }{
        .{ SourceButton.a, Button.a },
        .{ SourceButton.b, Button.b },
        .{ SourceButton.x, Button.x },
        .{ SourceButton.y, Button.y },
        .{ SourceButton.left_shoulder, Button.left_shoulder },
        .{ SourceButton.right_shoulder, Button.right_shoulder },
        .{ SourceButton.back, Button.view },
        .{ SourceButton.start, Button.menu },
        .{ SourceButton.dpad_up, Button.dpad_up },
        .{ SourceButton.dpad_down, Button.dpad_down },
        .{ SourceButton.dpad_left, Button.dpad_left },
        .{ SourceButton.dpad_right, Button.dpad_right },
    };
    for (mappings) |mapping| {
        if (source & mapping[0] != 0) mask |= mapping[1];
    }

    const stick_chord = SourceButton.left_stick | SourceButton.right_stick;
    if (source & stick_chord == stick_chord) {
        mask |= Button.nexus;
    } else {
        if (source & SourceButton.left_stick != 0) mask |= Button.left_stick;
        if (source & SourceButton.right_stick != 0) mask |= Button.right_stick;
    }
    return mask;
}

pub export fn go_xcloud_button_mask(source: u32) u16 {
    return buttonMask(source);
}

fn clampF32(v: f32, lo: f32, hi: f32) f32 {
    return @max(lo, @min(hi, v));
}

fn axisToI16(v: f32) i16 {
    const clamped = clampF32(v, -1.0, 1.0);
    return @intFromFloat(@round(clamped * 32767.0));
}

fn triggerToU16(v: f32) u16 {
    const clamped = clampF32(v, 0.0, 1.0);
    return @intFromFloat(@round(clamped * 65535.0));
}

pub fn encodeGamepad(buf: []u8, sequence: u32, timestamp_ms: f64, state: GamepadState) void {
    std.debug.assert(buf.len >= PACKET_SIZE);

    encodeGamepadRaw(buf, sequence, timestamp_ms, state.buttons, axisToI16(state.left_x), axisToI16(state.left_y), axisToI16(state.right_x), axisToI16(state.right_y), triggerToU16(state.left_trigger), triggerToU16(state.right_trigger));
}

fn encodeGamepadRaw(buf: []u8, sequence: u32, timestamp_ms: f64, buttons: u16, left_x: i16, left_y: i16, right_x: i16, right_y: i16, left_trigger: u16, right_trigger: u16) void {
    std.debug.assert(buf.len >= PACKET_SIZE);

    std.mem.writeInt(u16, buf[0..2], report_type_gamepad, .little);
    std.mem.writeInt(u32, buf[2..6], sequence, .little);
    std.mem.writeInt(u64, buf[6..14], @bitCast(timestamp_ms), .little);

    buf[14] = 1;
    buf[15] = 0;
    std.mem.writeInt(u16, buf[16..18], buttons, .little);
    std.mem.writeInt(i16, buf[18..20], left_x, .little);
    std.mem.writeInt(i16, buf[20..22], left_y, .little);
    std.mem.writeInt(i16, buf[22..24], right_x, .little);
    std.mem.writeInt(i16, buf[24..26], right_y, .little);
    std.mem.writeInt(u16, buf[26..28], left_trigger, .little);
    std.mem.writeInt(u16, buf[28..30], right_trigger, .little);
    std.mem.writeInt(u32, buf[30..34], 1, .little);
    std.mem.writeInt(u32, buf[34..38], 1, .big);
}

pub export fn go_xcloud_encode_gamepad(buf: [*]u8, sequence: u32, timestamp_ms: f64, buttons: u16, left_x: i16, left_y: i16, right_x: i16, right_y: i16, left_trigger: u16, right_trigger: u16) void {
    encodeGamepadRaw(buf[0..PACKET_SIZE], sequence, timestamp_ms, buttons, left_x, left_y, right_x, right_y, left_trigger, right_trigger);
}

test "neutral state produces known bytes" {
    var buf: [PACKET_SIZE]u8 = undefined;
    encodeGamepad(&buf, 0, 0.0, .{});

    try std.testing.expectEqual(@as(u16, 0x0002), std.mem.readInt(u16, buf[0..2], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[2..6], .little));
    const ts_raw = std.mem.readInt(u64, buf[6..14], .little);
    try std.testing.expectEqual(@as(f64, 0.0), @as(f64, @bitCast(ts_raw)));
    try std.testing.expectEqual(@as(u8, 1), buf[14]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, buf[16..18], .little));
    for (buf[18..30]) |b| try std.testing.expectEqual(@as(u8, 0), b);
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0, 0, 0, 0, 1 }, buf[30..38]);
}

test "every physical control maps to the xCloud mask" {
    const cases = [_]struct { u32, u16 }{
        .{ SourceButton.a, Button.a },
        .{ SourceButton.b, Button.b },
        .{ SourceButton.x, Button.x },
        .{ SourceButton.y, Button.y },
        .{ SourceButton.left_shoulder, Button.left_shoulder },
        .{ SourceButton.right_shoulder, Button.right_shoulder },
        .{ SourceButton.back, Button.view },
        .{ SourceButton.start, Button.menu },
        .{ SourceButton.dpad_up, Button.dpad_up },
        .{ SourceButton.dpad_down, Button.dpad_down },
        .{ SourceButton.dpad_left, Button.dpad_left },
        .{ SourceButton.dpad_right, Button.dpad_right },
        .{ SourceButton.left_stick, Button.left_stick },
        .{ SourceButton.right_stick, Button.right_stick },
    };
    for (cases) |case| try std.testing.expectEqual(case[1], buttonMask(case[0]));
}

test "L3 and R3 together produce only Nexus" {
    const chord = SourceButton.left_stick | SourceButton.right_stick;
    try std.testing.expectEqual(Button.nexus, buttonMask(chord));
    try std.testing.expectEqual(Button.a | Button.nexus, buttonMask(SourceButton.a | chord));
}

test "button A encodes correctly" {
    var buf: [PACKET_SIZE]u8 = undefined;
    encodeGamepad(&buf, 1, 100.0, .{ .buttons = Button.a });

    try std.testing.expectEqual(@as(u16, 0x0010), std.mem.readInt(u16, buf[16..18], .little));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, buf[2..6], .little));
}

test "multiple buttons combine" {
    var buf: [PACKET_SIZE]u8 = undefined;
    const mask = Button.a | Button.b | Button.x | Button.y | Button.menu;
    encodeGamepad(&buf, 0, 0.0, .{ .buttons = mask });

    try std.testing.expectEqual(mask, std.mem.readInt(u16, buf[16..18], .little));
}

test "axis full range" {
    var buf: [PACKET_SIZE]u8 = undefined;

    encodeGamepad(&buf, 0, 0.0, .{ .left_x = 1.0 });
    try std.testing.expectEqual(@as(i16, 32767), std.mem.readInt(i16, buf[18..20], .little));

    encodeGamepad(&buf, 0, 0.0, .{ .left_x = -1.0 });
    try std.testing.expectEqual(@as(i16, -32767), std.mem.readInt(i16, buf[18..20], .little));

    encodeGamepad(&buf, 0, 0.0, .{ .left_x = 0.0 });
    try std.testing.expectEqual(@as(i16, 0), std.mem.readInt(i16, buf[18..20], .little));
}

test "trigger full range" {
    var buf: [PACKET_SIZE]u8 = undefined;

    encodeGamepad(&buf, 0, 0.0, .{ .left_trigger = 1.0 });
    try std.testing.expectEqual(@as(u16, 65535), std.mem.readInt(u16, buf[26..28], .little));

    encodeGamepad(&buf, 0, 0.0, .{ .right_trigger = 0.5 });
    try std.testing.expectEqual(@as(u16, 32768), std.mem.readInt(u16, buf[28..30], .little));
}

test "clamping" {
    var buf: [PACKET_SIZE]u8 = undefined;

    encodeGamepad(&buf, 0, 0.0, .{ .left_x = 5.0 });
    try std.testing.expectEqual(@as(i16, 32767), std.mem.readInt(i16, buf[18..20], .little));

    encodeGamepad(&buf, 0, 0.0, .{ .left_x = -5.0 });
    try std.testing.expectEqual(@as(i16, -32767), std.mem.readInt(i16, buf[18..20], .little));

    encodeGamepad(&buf, 0, 0.0, .{ .left_trigger = 2.0 });
    try std.testing.expectEqual(@as(u16, 65535), std.mem.readInt(u16, buf[26..28], .little));
}

test "sequence wrap" {
    var buf: [PACKET_SIZE]u8 = undefined;
    encodeGamepad(&buf, 0xFFFFFFFF, 0.0, .{});
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), std.mem.readInt(u32, buf[2..6], .little));
}

test "timestamp encoding" {
    var buf: [PACKET_SIZE]u8 = undefined;
    const ts: f64 = 12345.678;
    encodeGamepad(&buf, 0, ts, .{});
    const decoded_raw = std.mem.readInt(u64, buf[6..14], .little);
    const decoded: f64 = @bitCast(decoded_raw);
    try std.testing.expectApproxEqAbs(ts, decoded, 0.001);
}
