const std = @import("std");

pub const Direction = enum {
    none,
    up,
    down,
    left,
    right,
};

pub const AxisLatch = struct {
    direction: i8 = 0,

    pub fn update(self: *AxisLatch, value: i16) i8 {
        if (value <= -16000) self.direction = -1;
        if (value >= 16000) self.direction = 1;
        if (value > -8000 and value < 8000) self.direction = 0;
        return self.direction;
    }
};

pub const Repeater = struct {
    direction: Direction = .none,
    started_at: u32 = 0,
    next_at: u32 = 0,

    pub fn reset(self: *Repeater) void {
        self.* = .{};
    }

    pub fn begin(self: *Repeater, direction: Direction, now: u32) void {
        if (direction == .none) {
            self.reset();
            return;
        }
        self.direction = direction;
        self.started_at = now;
        self.next_at = now +% 325;
    }

    pub fn update(self: *Repeater, direction: Direction, now: u32) bool {
        if (direction == .none) {
            self.reset();
            return false;
        }
        if (direction != self.direction) {
            self.begin(direction, now);
            return true;
        }
        if (@as(i32, @bitCast(now -% self.next_at)) < 0) return false;

        const held_for = now -% self.started_at;
        self.next_at = now +% if (held_for >= 1500) @as(u32, 50) else 90;
        return true;
    }
};

test "repeat starts immediately and accelerates" {
    var repeat = Repeater{};
    try std.testing.expect(repeat.update(.down, 1000));
    try std.testing.expect(!repeat.update(.down, 1324));
    try std.testing.expect(repeat.update(.down, 1325));
    try std.testing.expect(!repeat.update(.down, 1414));
    try std.testing.expect(repeat.update(.down, 1415));
    try std.testing.expect(repeat.update(.down, 2500));
    try std.testing.expect(!repeat.update(.down, 2549));
    try std.testing.expect(repeat.update(.down, 2550));
}

test "direction changes and release reset repeat" {
    var repeat = Repeater{};
    try std.testing.expect(repeat.update(.down, 100));
    try std.testing.expect(repeat.update(.up, 120));
    try std.testing.expect(!repeat.update(.none, 130));
    try std.testing.expect(repeat.update(.up, 140));
}

test "an event-driven press starts the hold delay without moving twice" {
    var repeat = Repeater{};
    repeat.begin(.down, 100);
    try std.testing.expect(!repeat.update(.down, 424));
    try std.testing.expect(repeat.update(.down, 425));
}

test "axis latch uses hysteresis" {
    var latch = AxisLatch{};
    try std.testing.expectEqual(@as(i8, 0), latch.update(-12000));
    try std.testing.expectEqual(@as(i8, -1), latch.update(-17000));
    try std.testing.expectEqual(@as(i8, -1), latch.update(-9000));
    try std.testing.expectEqual(@as(i8, 0), latch.update(-7000));
    try std.testing.expectEqual(@as(i8, 1), latch.update(17000));
    try std.testing.expectEqual(@as(i8, 0), latch.update(0));
}
