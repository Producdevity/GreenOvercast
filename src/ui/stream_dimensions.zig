const std = @import("std");

pub const Dimensions = struct {
    width: u32,
    height: u32,
};

const minimum = Dimensions{ .width = 640, .height = 360 };
const maximum = Dimensions{ .width = 1280, .height = 720 };
const fallback = Dimensions{ .width = 640, .height = 480 };

pub fn forDisplay(display_width: u32, display_height: u32) Dimensions {
    if (display_width == 0 or display_height == 0) return fallback;

    var width: u64 = display_width;
    var height: u64 = display_height;

    if (width < minimum.width) {
        height = roundedScale(height, minimum.width, width);
        width = minimum.width;
    }
    if (height < minimum.height) {
        width = roundedScale(width, minimum.height, height);
        height = minimum.height;
    }
    if (width > maximum.width) {
        height = roundedScale(height, maximum.width, width);
        width = maximum.width;
    }
    if (height > maximum.height) {
        width = roundedScale(width, maximum.height, height);
        height = maximum.height;
    }

    if (width < minimum.width or height < minimum.height) return fallback;

    return .{
        .width = alignDown(@intCast(width)),
        .height = alignDown(@intCast(height)),
    };
}

fn roundedScale(value: u64, numerator: u64, denominator: u64) u64 {
    return (value * numerator + denominator / 2) / denominator;
}

fn alignDown(value: u32) u32 {
    return value & ~@as(u32, 7);
}

test "uses a 640 by 480 display without scaling" {
    try std.testing.expectEqual(Dimensions{ .width = 640, .height = 480 }, forDisplay(640, 480));
}

test "scales smaller displays to the Xbox minimum" {
    try std.testing.expectEqual(Dimensions{ .width = 640, .height = 424 }, forDisplay(480, 320));
    try std.testing.expectEqual(Dimensions{ .width = 720, .height = 360 }, forDisplay(640, 320));
}

test "fits larger displays within decoder limits" {
    try std.testing.expectEqual(Dimensions{ .width = 960, .height = 720 }, forDisplay(1024, 768));
    try std.testing.expectEqual(Dimensions{ .width = 1280, .height = 720 }, forDisplay(1920, 1080));
}

test "aligns dimensions to eight pixels" {
    try std.testing.expectEqual(Dimensions{ .width = 848, .height = 480 }, forDisplay(854, 480));
}

test "uses the handheld fallback for invalid or unsupported shapes" {
    try std.testing.expectEqual(fallback, forDisplay(0, 480));
    try std.testing.expectEqual(fallback, forDisplay(480, 800));
}
