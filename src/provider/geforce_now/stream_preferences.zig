const std = @import("std");

pub const frames_per_second_choices = [_]u16{ 30, 60 };
pub const bitrate_choices_kbps = [_]u32{ 4000, 6000, 8000, 12000, 16000, 20000 };

pub const Preferences = struct {
    frames_per_second: u16 = 30,
    max_bitrate_kbps: u32 = 6000,

    pub fn validate(self: Preferences) !void {
        if (!validFramesPerSecond(self.frames_per_second) or !validBitrate(self.max_bitrate_kbps))
            return error.InvalidStreamPreferences;
    }
};

pub fn validFramesPerSecond(value: u16) bool {
    return std.mem.indexOfScalar(u16, &frames_per_second_choices, value) != null;
}

pub fn validBitrate(value: u32) bool {
    return std.mem.indexOfScalar(u32, &bitrate_choices_kbps, value) != null;
}

test "stream preferences accept every selectable combination" {
    for (frames_per_second_choices) |fps| {
        for (bitrate_choices_kbps) |bitrate| {
            try (Preferences{ .frames_per_second = fps, .max_bitrate_kbps = bitrate }).validate();
        }
    }
}

test "stream preferences reject unsupported and overflowing values" {
    try (Preferences{}).validate();
    for ([_]u16{ 0, 1, 59, 120, std.math.maxInt(u16) }) |fps|
        try std.testing.expectError(error.InvalidStreamPreferences, (Preferences{ .frames_per_second = fps }).validate());
    for ([_]u32{ 0, 3999, 7000, 20001, std.math.maxInt(u32) }) |bitrate|
        try std.testing.expectError(error.InvalidStreamPreferences, (Preferences{ .max_bitrate_kbps = bitrate }).validate());
}
