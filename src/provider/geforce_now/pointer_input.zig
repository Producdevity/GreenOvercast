const std = @import("std");
const protocol = @import("input_protocol.zig");
const Button = protocol.Button;

pub const State = struct {
    enabled: bool = false,
    x: f32 = 0.5,
    y: f32 = 0.5,
    buttons: u2 = 0,
    chord_held: bool = false,
    wait_for_release: bool = false,
    previous_time: ?u64 = null,
    next_scroll: u64 = 0,

    pub const Update = struct {
        gamepad: protocol.GamepadState,
        moved: bool = false,
        changed_buttons: u2 = 0,
        wheel: i16 = 0,
        toggled: bool = false,
    };

    pub fn update(self: *State, gamepad: protocol.GamepadState) Update {
        const now = gamepad.timestamp_us;
        const elapsed = if (self.previous_time) |previous| @min(now -| previous, 50_000) else 0;
        self.previous_time = now;
        const chord_mask = Button.back | Button.y;
        const chord = gamepad.buttons & chord_mask == chord_mask;
        var result = Update{ .gamepad = gamepad };
        if (chord and !self.chord_held) {
            self.enabled = !self.enabled;
            self.wait_for_release = true;
            result.toggled = true;
            result.moved = self.enabled;
        }
        self.chord_held = chord;
        if (self.wait_for_release and gamepad.buttons == 0) self.wait_for_release = false;
        const old_buttons = self.buttons;
        self.buttons = 0;
        if (self.enabled or self.wait_for_release) {
            result.gamepad = .{ .timestamp_us = now };
            if (self.enabled and !self.wait_for_release) {
                const dx = direction(gamepad.left_x, gamepad.buttons, Button.dpad_left, Button.dpad_right);
                const dy = direction(-@as(i32, gamepad.left_y), gamepad.buttons, Button.dpad_up, Button.dpad_down);
                const seconds = @as(f32, @floatFromInt(elapsed)) / 1_000_000;
                const x = std.math.clamp(self.x + dx * seconds * 0.7, 0, 1);
                const y = std.math.clamp(self.y + dy * seconds * 0.7, 0, 1);
                result.moved = result.moved or x != self.x or y != self.y;
                self.x = x;
                self.y = y;
                if (gamepad.buttons & Button.a != 0) self.buttons |= 1;
                if (gamepad.buttons & Button.b != 0) self.buttons |= 2;
                const scroll: i16 = @as(i16, @intFromBool(gamepad.buttons & Button.left_shoulder != 0)) -
                    @as(i16, @intFromBool(gamepad.buttons & Button.right_shoulder != 0));
                if (scroll == 0) self.next_scroll = 0 else if (now >= self.next_scroll) {
                    result.wheel = scroll * 120;
                    self.next_scroll = now +| 150_000;
                }
            }
        }
        result.changed_buttons = old_buttons ^ self.buttons;
        return result;
    }
};

fn direction(axis: i32, buttons: u16, negative: u16, positive: u16) f32 {
    const digital = @as(i32, @intFromBool(buttons & positive != 0)) - @as(i32, @intFromBool(buttons & negative != 0));
    if (digital != 0) return @floatFromInt(digital);
    const magnitude = @abs(axis);
    if (magnitude <= 6000) return 0;
    const strength = @as(f32, @floatFromInt(@min(magnitude, 32767) - 6000)) / 26767;
    return (if (axis < 0) -strength else strength) * strength;
}

test "pointer chord toggles once and consumes controls until release" {
    var pointer = State{};
    const chord = protocol.GamepadState{ .buttons = Button.back | Button.y };
    try std.testing.expect(pointer.update(chord).toggled);
    try std.testing.expect(pointer.enabled);
    try std.testing.expect(!pointer.update(chord).toggled);
    try std.testing.expectEqual(@as(u16, 0), pointer.update(.{ .buttons = Button.y }).gamepad.buttons);
    _ = pointer.update(.{});
    const click = pointer.update(.{ .buttons = Button.a });
    try std.testing.expectEqual(@as(u2, 1), click.changed_buttons);
    try std.testing.expectEqual(@as(u16, 0), click.gamepad.buttons);
    const exit = pointer.update(chord);
    try std.testing.expect(!pointer.enabled);
    try std.testing.expectEqual(@as(u2, 1), exit.changed_buttons);
    _ = pointer.update(.{});
    try std.testing.expectEqual(Button.a, pointer.update(.{ .buttons = Button.a }).gamepad.buttons);
}

test "pointer motion is time based, bounded and has a deadzone" {
    var pointer = State{ .enabled = true };
    _ = pointer.update(.{ .left_x = 5000 });
    try std.testing.expect(!pointer.update(.{ .left_x = 5000, .timestamp_us = 20_000 }).moved);
    _ = pointer.update(.{ .left_x = 32767, .left_y = 32767, .timestamp_us = 40_000 });
    try std.testing.expect(pointer.x > 0.5 and pointer.y < 0.5);
    const previous = pointer.x;
    _ = pointer.update(.{ .left_x = 32767, .timestamp_us = 60_000_000 });
    try std.testing.expect(pointer.x - previous <= 0.036);
    pointer.x = 1;
    _ = pointer.update(.{ .buttons = Button.dpad_right, .timestamp_us = 60_020_000 });
    try std.testing.expectEqual(@as(f32, 1), pointer.x);
}

test "scroll repeats are bounded and disconnected controls release mouse buttons" {
    var pointer = State{ .enabled = true };
    try std.testing.expectEqual(@as(i16, -120), pointer.update(.{ .buttons = Button.right_shoulder }).wheel);
    try std.testing.expectEqual(@as(i16, 0), pointer.update(.{ .buttons = Button.right_shoulder, .timestamp_us = 10_000 }).wheel);
    try std.testing.expectEqual(@as(i16, -120), pointer.update(.{ .buttons = Button.right_shoulder, .timestamp_us = 150_000 }).wheel);
    _ = pointer.update(.{ .buttons = Button.a | Button.b });
    try std.testing.expectEqual(@as(u2, 3), pointer.update(.{}).changed_buttons);
}
