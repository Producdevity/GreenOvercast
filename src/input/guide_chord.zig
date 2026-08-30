const std = @import("std");

pub const Buttons = struct {
    left: bool = false,
    right: bool = false,
};

pub const State = struct {
    active: bool = false,
    pulse_packets: u8 = 0,

    pub fn reset(self: *State) void {
        self.* = .{};
    }

    pub fn update(self: *State, left: bool, right: bool) Buttons {
        if (self.active) {
            if (self.pulse_packets > 0) {
                self.pulse_packets -= 1;
                return .{ .left = true, .right = true };
            }
            if (!left and !right) {
                self.active = false;
                return .{};
            }
            if (left != right) return .{ .left = left, .right = right };
            return .{};
        }
        if (left and right) {
            self.active = true;
            self.pulse_packets = 7;
            return .{ .left = true, .right = true };
        }
        return .{ .left = left, .right = right };
    }
};

test "the guide chord pulses once and restores a held stick" {
    var state = State{};
    var buttons = state.update(true, true);
    try std.testing.expect(buttons.left and buttons.right);
    for (0..7) |_| {
        buttons = state.update(true, true);
        try std.testing.expect(buttons.left and buttons.right);
    }
    buttons = state.update(true, true);
    try std.testing.expect(!buttons.left and !buttons.right);
    buttons = state.update(true, false);
    try std.testing.expect(buttons.left and !buttons.right);
    buttons = state.update(true, true);
    try std.testing.expect(!buttons.left and !buttons.right);
    _ = state.update(false, false);
    buttons = state.update(true, true);
    try std.testing.expect(buttons.left and buttons.right);
}
