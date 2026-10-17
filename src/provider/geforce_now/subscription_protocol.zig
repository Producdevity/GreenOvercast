const std = @import("std");

pub const maximum_resolutions = 64;

pub const Resolution = struct {
    width: u16,
    height: u16,
    frames_per_second: u16,
};

pub const Summary = struct {
    tier_buffer: [32]u8,
    tier_length: usize,
    state_buffer: [32]u8,
    state_length: usize,
    gameplay_allowed: ?bool,
    entitled_resolutions: usize,
    resolutions: [maximum_resolutions]Resolution,
    resolution_count: usize,

    pub fn tier(self: *const Summary) []const u8 {
        return self.tier_buffer[0..self.tier_length];
    }

    pub fn state(self: *const Summary) []const u8 {
        return self.state_buffer[0..self.state_length];
    }

    pub fn bestForDisplayWithin(
        self: *const Summary,
        display_width: u16,
        display_height: u16,
        preferred_frames_per_second: u16,
        maximum_width: u16,
        maximum_height: u16,
    ) ?Resolution {
        if (display_width == 0 or display_height == 0 or self.resolution_count == 0)
            return null;

        var result: ?Resolution = null;
        for (self.resolutions[0..self.resolution_count]) |resolution| {
            if (resolution.width > maximum_width or resolution.height > maximum_height) continue;
            if (resolution.frames_per_second != preferred_frames_per_second) continue;
            if (betterResolution(resolution, result, display_width, display_height))
                result = resolution;
        }
        if (result != null) return result;

        var fallback_frames_per_second: ?u16 = null;
        for (self.resolutions[0..self.resolution_count]) |resolution| {
            if (resolution.width > maximum_width or resolution.height > maximum_height) continue;
            if (fallback_frames_per_second == null or
                resolution.frames_per_second < fallback_frames_per_second.?)
                fallback_frames_per_second = resolution.frames_per_second;
        }
        const fallback_rate = fallback_frames_per_second orelse return null;
        for (self.resolutions[0..self.resolution_count]) |resolution| {
            if (resolution.width > maximum_width or resolution.height > maximum_height) continue;
            if (resolution.frames_per_second != fallback_rate) continue;
            if (betterResolution(resolution, result, display_width, display_height))
                result = resolution;
        }
        return result;
    }
};

fn betterResolution(
    candidate: Resolution,
    current: ?Resolution,
    display_width: u16,
    display_height: u16,
) bool {
    const previous = current orelse return true;
    const candidate_fits = candidate.width >= display_width and candidate.height >= display_height;
    const previous_fits = previous.width >= display_width and previous.height >= display_height;
    if (candidate_fits != previous_fits) return candidate_fits;

    const candidate_error = aspectError(candidate, display_width, display_height);
    const previous_error = aspectError(previous, display_width, display_height);
    const candidate_scaled_error = candidate_error * previous.height;
    const previous_scaled_error = previous_error * candidate.height;
    if (candidate_scaled_error != previous_scaled_error)
        return candidate_scaled_error < previous_scaled_error;

    const candidate_pixels = @as(u32, candidate.width) * candidate.height;
    const previous_pixels = @as(u32, previous.width) * previous.height;
    if (candidate_pixels != previous_pixels)
        return if (candidate_fits)
            candidate_pixels < previous_pixels
        else
            candidate_pixels > previous_pixels;
    return candidate.frames_per_second < previous.frames_per_second;
}

fn aspectError(resolution: Resolution, display_width: u16, display_height: u16) u64 {
    const scaled_width = @as(u64, resolution.width) * display_height;
    const scaled_height = @as(u64, display_width) * resolution.height;
    return if (scaled_width >= scaled_height)
        scaled_width - scaled_height
    else
        scaled_height - scaled_width;
}

pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Summary {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    const root = try object(parsed.value);
    var entitled: usize = 0;
    var entitled_modes = [_]Resolution{.{
        .width = 0,
        .height = 0,
        .frames_per_second = 0,
    }} ** maximum_resolutions;
    var resolution_count: usize = 0;
    if (optionalObject(root, "features")) |features| {
        if (optionalArray(features, "resolutions")) |resolutions| {
            for (resolutions.items) |value| {
                const resolution = object(value) catch continue;
                if (!(optionalBool(resolution, "isEntitled") orelse false)) continue;
                entitled += 1;
                if (resolution_count >= maximum_resolutions) continue;
                const width = optionalUnsigned(resolution, "widthInPixels") orelse continue;
                const height = optionalUnsigned(resolution, "heightInPixels") orelse continue;
                const frames_per_second = optionalUnsigned(resolution, "framesPerSecond") orelse continue;
                if (width == 0 or width > std.math.maxInt(u16) or
                    height == 0 or height > std.math.maxInt(u16) or
                    frames_per_second == 0 or frames_per_second > std.math.maxInt(u16))
                    continue;
                entitled_modes[resolution_count] = .{
                    .width = @intCast(width),
                    .height = @intCast(height),
                    .frames_per_second = @intCast(frames_per_second),
                };
                resolution_count += 1;
            }
        }
    }
    const current_state = optionalObject(root, "currentSubscriptionState");
    const gameplay_allowed = if (current_state) |state| optionalBool(state, "isGamePlayAllowed") else null;
    const state = if (current_state) |value| optionalString(value, "state") orelse "UNKNOWN" else "UNKNOWN";
    const tier = optionalString(root, "membershipTier") orelse "UNKNOWN";
    var summary = Summary{
        .tier_buffer = [_]u8{0} ** 32,
        .tier_length = @min(tier.len, 32),
        .state_buffer = [_]u8{0} ** 32,
        .state_length = @min(state.len, 32),
        .gameplay_allowed = gameplay_allowed,
        .entitled_resolutions = entitled,
        .resolutions = entitled_modes,
        .resolution_count = resolution_count,
    };
    @memcpy(summary.tier_buffer[0..summary.tier_length], tier[0..summary.tier_length]);
    @memcpy(summary.state_buffer[0..summary.state_length], state[0..summary.state_length]);
    return summary;
}

fn object(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |result| result,
        else => error.ExpectedObject,
    };
}

fn optionalString(value: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const field = value.get(key) orelse return null;
    return switch (field) {
        .string => |text| if (text.len > 0) text else null,
        else => null,
    };
}

fn optionalObject(value: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const field = value.get(key) orelse return null;
    return switch (field) {
        .object => |result| result,
        else => null,
    };
}

fn optionalArray(value: std.json.ObjectMap, key: []const u8) ?std.json.Array {
    const field = value.get(key) orelse return null;
    return switch (field) {
        .array => |result| result,
        else => null,
    };
}

fn optionalBool(value: std.json.ObjectMap, key: []const u8) ?bool {
    const field = value.get(key) orelse return null;
    return switch (field) {
        .bool => |result| result,
        else => null,
    };
}

fn optionalUnsigned(value: std.json.ObjectMap, key: []const u8) ?u64 {
    const field = value.get(key) orelse return null;
    return switch (field) {
        .integer => |result| if (result >= 0) @intCast(result) else null,
        else => null,
    };
}

test "summarizes membership state without retaining account data" {
    const summary = try parse(std.testing.allocator,
        \\{
        \\  "membershipTier":"FREE",
        \\  "currentSubscriptionState":{"state":"ACTIVE","isGamePlayAllowed":true},
        \\  "features":{"resolutions":[
        \\    {"widthInPixels":1280,"heightInPixels":720,"framesPerSecond":60,"isEntitled":true},
        \\    {"widthInPixels":1920,"heightInPixels":1080,"framesPerSecond":60,"isEntitled":false}
        \\  ]}
        \\}
    );
    try std.testing.expectEqualStrings("FREE", summary.tier());
    try std.testing.expectEqualStrings("ACTIVE", summary.state());
    try std.testing.expectEqual(@as(?bool, true), summary.gameplay_allowed);
    try std.testing.expectEqual(@as(usize, 1), summary.entitled_resolutions);
    try std.testing.expectEqualSlices(Resolution, &.{.{
        .width = 1280,
        .height = 720,
        .frames_per_second = 60,
    }}, summary.resolutions[0..summary.resolution_count]);
}

test "accepts subscriptions without optional state details" {
    const summary = try parse(std.testing.allocator, "{\"membershipTier\":\"FREE\"}");
    try std.testing.expectEqualStrings("FREE", summary.tier());
    try std.testing.expectEqualStrings("UNKNOWN", summary.state());
    try std.testing.expectEqual(@as(?bool, null), summary.gameplay_allowed);
    try std.testing.expectEqual(@as(usize, 0), summary.entitled_resolutions);
    try std.testing.expectEqual(@as(usize, 0), summary.resolution_count);
}

test "selects the lowest 30 fps mode matching the display" {
    var summary = try parse(std.testing.allocator,
        \\{
        \\  "features":{"resolutions":[
        \\    {"widthInPixels":1280,"heightInPixels":720,"framesPerSecond":30,"isEntitled":true},
        \\    {"widthInPixels":1920,"heightInPixels":1080,"framesPerSecond":30,"isEntitled":true},
        \\    {"widthInPixels":1024,"heightInPixels":768,"framesPerSecond":30,"isEntitled":true},
        \\    {"widthInPixels":800,"heightInPixels":600,"framesPerSecond":60,"isEntitled":true}
        \\  ]}
        \\}
    );

    try std.testing.expectEqual(Resolution{
        .width = 1024,
        .height = 768,
        .frames_per_second = 30,
    }, summary.bestForDisplayWithin(640, 480, 30, 1280, 768).?);
    try std.testing.expectEqual(Resolution{
        .width = 1280,
        .height = 720,
        .frames_per_second = 30,
    }, summary.bestForDisplayWithin(640, 360, 30, 1280, 768).?);
}

test "uses another frame rate only when the preferred rate is unavailable" {
    var summary = try parse(std.testing.allocator,
        \\{
        \\  "features":{"resolutions":[
        \\    {"widthInPixels":800,"heightInPixels":600,"framesPerSecond":120,"isEntitled":true},
        \\    {"widthInPixels":1024,"heightInPixels":768,"framesPerSecond":60,"isEntitled":true}
        \\  ]}
        \\}
    );

    try std.testing.expectEqual(Resolution{
        .width = 1024,
        .height = 768,
        .frames_per_second = 60,
    }, summary.bestForDisplayWithin(640, 480, 30, 1280, 768).?);
}

test "does not select a mode larger than the decoder supports" {
    var summary = try parse(std.testing.allocator,
        \\{
        \\  "features":{"resolutions":[
        \\    {"widthInPixels":1920,"heightInPixels":1080,"framesPerSecond":30,"isEntitled":true}
        \\  ]}
        \\}
    );

    try std.testing.expectEqual(
        @as(?Resolution, null),
        summary.bestForDisplayWithin(640, 360, 30, 1280, 768),
    );
}
