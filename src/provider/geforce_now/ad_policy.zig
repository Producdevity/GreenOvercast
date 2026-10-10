const std = @import("std");
const vast = @import("vast.zig");

pub fn selectAds(allocator: std.mem.Allocator, ads: []const vast.Ad, allow_multiple: bool, follow_wrappers: bool) ![]const vast.Ad {
    var selected = std.ArrayList(vast.Ad).init(allocator);
    errdefer selected.deinit();
    const has_pod = allow_multiple and for (ads) |ad| {
        if (ad.sequence != null) break true;
    } else false;
    for (ads) |ad| {
        if (!follow_wrappers and ad.body == .wrapper) continue;
        if ((has_pod and ad.sequence == null) or (!has_pod and ad.sequence != null)) continue;
        try selected.append(ad);
        if (!has_pod) break;
    }
    return selected.toOwnedSlice();
}

pub fn errorCode(err: anyerror) u16 {
    return switch (err) {
        error.InvalidXml, error.InvalidVastRoot, error.XmlDoctypeForbidden => 100,
        error.VastWrapperLimit => 302,
        error.VastEmptyResponse, error.VastNoAdsAfterWrapper => 303,
        error.UnsupportedMedia, error.UnsupportedCodec, error.UnsupportedPixelFormat => 403,
        error.UnsupportedInteractiveAd => 409,
        error.AdDownloadFailed, error.AdDownloadRejected => 401,
        else => 405,
    };
}

pub fn merge(comptime T: type, allocator: std.mem.Allocator, left: []const T, right: []const T) ![]const T {
    if (left.len + right.len > 256) return error.VastLimitExceeded;
    const result = try allocator.alloc(T, left.len + right.len);
    @memcpy(result[0..left.len], left);
    @memcpy(result[left.len..], right);
    return result;
}
pub fn selectMedia(files: []const vast.Media) ?vast.Media {
    var result: ?vast.Media = null;
    for (files) |file| {
        if (result == null or @as(u32, file.width) * file.height < @as(u32, result.?.width) * result.?.height)
            result = file;
    }
    return result;
}
pub fn due(track: vast.Track, played: u64, length: u64, finished: bool) bool {
    if (std.mem.eql(u8, track.event, "complete")) return finished;
    const threshold: u64 = if (std.mem.eql(u8, track.event, "start") or std.mem.eql(u8, track.event, "creativeView")) 0 else if (std.mem.eql(u8, track.event, "firstQuartile")) length / 4 else if (std.mem.eql(u8, track.event, "midpoint")) length / 2 else if (std.mem.eql(u8, track.event, "thirdQuartile")) length * 3 / 4 else if (std.mem.eql(u8, track.event, "progress")) track.offset_ms orelse length * (track.offset_percent orelse return false) / 100 else return false;
    return played >= threshold;
}
pub fn iconVisible(icon: vast.Icon, played: u64) bool {
    return played >= icon.offset_ms and (icon.duration_ms == null or played - icon.offset_ms < icon.duration_ms.?);
}
pub fn iconPosition(position: vast.Position, extent: c_int, size: u16) c_int {
    return switch (position) {
        .start => 0,
        .end => @max(0, extent - size),
        .pixel => |value| @min(value, @max(0, extent - size)),
    };
}
pub fn expand(allocator: std.mem.Allocator, url: []const u8, played: u64, error_code: u16, verification: u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();
    var buffer: [64]u8 = undefined;
    const macros = [_][]const u8{ "[CACHEBUSTING]", "[ERRORCODE]", "[CONTENTPLAYHEAD]", "[REASON]", "[TIMESTAMP]", "[ADPLAYHEAD]", "[MEDIAPLAYHEAD]" };
    var cursor: usize = 0;
    while (cursor < url.len) {
        var replaced = false;
        for (macros, 0..) |macro, index| {
            if (!std.mem.startsWith(u8, url[cursor..], macro)) continue;
            const value = switch (index) {
                0 => try std.fmt.bufPrint(&buffer, "{d:0>8}", .{std.crypto.random.intRangeAtMost(u32, 10000000, 99999999)}),
                1 => try std.fmt.bufPrint(&buffer, "{d}", .{error_code}),
                2, 6 => "00%3A00%3A00.000",
                3 => try std.fmt.bufPrint(&buffer, "{d}", .{verification}),
                4 => try timestamp(&buffer, std.time.milliTimestamp()),
                5 => try std.fmt.bufPrint(&buffer, "{d:0>2}%3A{d:0>2}%3A{d:0>2}.{d:0>3}", .{ played / 3600000, played / 60000 % 60, played / 1000 % 60, played % 1000 }),
                else => return error.UnsupportedTrackingMacro,
            };
            try result.appendSlice(value);
            cursor += macro.len;
            replaced = true;
            break;
        }
        if (!replaced) {
            if (url[cursor] == '[') return error.UnsupportedTrackingMacro;
            try result.append(url[cursor]);
            cursor += 1;
        }
        if (result.items.len > 8192) return error.InvalidAdUrl;
    }
    return result.toOwnedSlice();
}

fn timestamp(buffer: []u8, milliseconds: i64) ![]const u8 {
    if (milliseconds < 0) return error.InvalidTimestamp;
    const seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(@divTrunc(milliseconds, 1000)) };
    const day = seconds.getEpochDay().calculateYearDay();
    const month = day.calculateMonthDay();
    const time = seconds.getDaySeconds();
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}%3A{d:0>2}%3A{d:0>2}.{d:0>3}Z", .{ day.year, month.month.numeric(), month.day_index + 1, time.getHoursIntoDay(), time.getMinutesIntoHour(), time.getSecondsIntoMinute(), @as(u16, @intCast(@mod(milliseconds, 1000))) });
}

pub fn tagUrl(allocator: std.mem.Allocator, url: []const u8, app_id: []const u8) ![]u8 {
    try vast.validateUrl(url);
    for (app_id) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidAppId;
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();
    const query = std.mem.indexOfScalar(u8, url, '?');
    try result.appendSlice(url[0 .. query orelse url.len]);
    try result.append('?');
    var buffer: [512]u8 = undefined;
    const supplied = try std.fmt.bufPrint(&buffer, "correlator={d}&scor={d}&description_url=https%253A%252F%252Fplay.geforcenow.com%252Fgames%253Fgame-id%253D{s}&url=https%3A%2F%2Fgithub.com%2FProducdevity%2FGreenOvercast&plcmt=1&vpmute=0&dth=6", .{ std.crypto.random.intRangeAtMost(u64, 1, 9007199254740991), std.time.milliTimestamp(), app_id });
    var defaults = std.mem.splitScalar(u8, supplied, '&');
    const existing = if (query) |index| url[index + 1 ..] else "";
    var original_fields = std.mem.splitScalar(u8, existing, '&');
    while (original_fields.next()) |field| {
        if (field.len == 0) continue;
        const key_end = std.mem.indexOfScalar(u8, field, '=') orelse field.len;
        const empty = key_end == field.len or key_end + 1 == field.len;
        var replace_empty = false;
        var default_fields = std.mem.splitScalar(u8, supplied, '&');
        while (default_fields.next()) |replacement| {
            const end = std.mem.indexOfScalar(u8, replacement, '=').?;
            if (empty and std.mem.eql(u8, field[0..key_end], replacement[0..end])) replace_empty = true;
        }
        if (!replace_empty) {
            try result.appendSlice(field);
            try result.append('&');
        }
    }
    while (defaults.next()) |field| {
        const key_end = std.mem.indexOfScalar(u8, field, '=').?;
        var fields = std.mem.splitScalar(u8, existing, '&');
        var present = false;
        while (fields.next()) |candidate| {
            const end = std.mem.indexOfScalar(u8, candidate, '=') orelse candidate.len;
            if (end + 1 < candidate.len and std.mem.eql(u8, candidate[0..end], field[0..key_end])) {
                present = true;
                break;
            }
        }
        if (!present) {
            try result.appendSlice(field);
            try result.append('&');
        }
    }
    if (result.items[result.items.len - 1] == '&') result.items.len -= 1;
    if (result.items.len > 8192) return error.InvalidAdUrl;
    return result.toOwnedSlice();
}

test "empty request-context fields are populated without changing consent" {
    const address = try tagUrl(std.testing.allocator, "https://example.invalid/?correlator=&scor&gdpr_consent=&npa=1", "12");
    defer std.testing.allocator.free(address);
    try std.testing.expect(std.mem.indexOf(u8, address, "gdpr_consent=&npa=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, address, "correlator=&") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, address, "correlator="));
}

test "pod selection excludes the buffet and honors wrapper restrictions" {
    const creative = vast.Creative{ .duration_ms = 5000, .media = &.{}, .tracks = &.{}, .icons = &.{} };
    const ads = [_]vast.Ad{
        .{ .sequence = 1, .impressions = &.{}, .errors = &.{}, .body = .{ .inline_ad = creative } },
        .{ .sequence = 2, .impressions = &.{}, .errors = &.{}, .body = .{ .inline_ad = creative } },
        .{ .sequence = null, .impressions = &.{}, .errors = &.{}, .body = .{ .inline_ad = creative } },
    };
    const pod = try selectAds(std.testing.allocator, &ads, true, true);
    defer std.testing.allocator.free(pod);
    try std.testing.expectEqual(@as(usize, 2), pod.len);
    const single = try selectAds(std.testing.allocator, &ads, false, true);
    defer std.testing.allocator.free(single);
    try std.testing.expectEqual(@as(usize, 1), single.len);
    try std.testing.expect(single[0].sequence == null);
    const wrapper = [_]vast.Ad{.{ .sequence = null, .impressions = &.{}, .errors = &.{}, .body = .{ .wrapper = .{ .url = "https://example.invalid", .follow_wrappers = true, .allow_multiple = false, .fallback_on_no_ad = false } } }};
    const ignored = try selectAds(std.testing.allocator, &wrapper, true, false);
    defer std.testing.allocator.free(ignored);
    try std.testing.expectEqual(@as(usize, 0), ignored.len);
}

test "progress thresholds and completion follow playback, not wall time" {
    const quarter = vast.Track{ .event = "firstQuartile", .url = "https://example.invalid" };
    try std.testing.expect(!due(quarter, 1249, 5000, false));
    try std.testing.expect(due(quarter, 1250, 5000, false));
    const complete = vast.Track{ .event = "complete", .url = "https://example.invalid" };
    try std.testing.expect(!due(complete, 10000, 5000, false));
    try std.testing.expect(due(complete, 5000, 5000, true));
    const offset = vast.Track{ .event = "progress", .url = "https://example.invalid", .offset_percent = 75 };
    try std.testing.expect(!due(offset, 3749, 5000, false));
    try std.testing.expect(due(offset, 3750, 5000, false));
}

test "tracking macros distinguish ad time from the unstarted game" {
    const encoded = try expand(std.testing.allocator, "https://example.invalid/?ad=[ADPLAYHEAD]&game=[MEDIAPLAYHEAD]&error=[ERRORCODE]&reason=[REASON]", 1250, 303, 2);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("https://example.invalid/?ad=00%3A00%3A01.250&game=00%3A00%3A00.000&error=303&reason=2", encoded);
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("1970-01-01T00%3A00%3A00.000Z", try timestamp(&buffer, 0));
    try std.testing.expectError(error.UnsupportedTrackingMacro, expand(std.testing.allocator, "https://example.invalid/?x=[UNKNOWN]", 0, 0, 0));
}

test "tag preparation preserves supplied consent, targeting and request identity" {
    const address = try tagUrl(std.testing.allocator, "https://example.invalid/tag?npa=1&ltd=1&correlator=123&url=supplied", "12345");
    defer std.testing.allocator.free(address);
    try std.testing.expect(std.mem.indexOf(u8, address, "npa=1&ltd=1&correlator=123&url=supplied") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, address, "correlator="));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, address, "&url="));
    try std.testing.expect(std.mem.indexOf(u8, address, "sdkv") == null);
    try std.testing.expect(std.mem.indexOf(u8, address, "game-id%253D12345") != null);
}
