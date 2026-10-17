const std = @import("std");
const endpoint = @import("endpoint.zig");

pub const Opportunity = struct {
    id: []const u8,
    url: []const u8,
    state: u8,
    duration_ms: u64,
};

pub const Admission = struct {
    arena: std.heap.ArenaAllocator,
    required: bool,
    provider: u8,
    control_base: ?[]const u8,
    opportunities: []const Opportunity,

    pub fn deinit(self: *Admission) void {
        self.arena.deinit();
    }
};

pub const Action = enum(u8) { start = 1, pause = 2, resume_playback = 3, finish = 4, cancel = 5, event = 6 };
pub const Update = struct {
    action: Action,
    watched_ms: u64 = 0,
    paused_ms: u64 = 0,
    duration_ms: u64 = 0,
    reason: ?[]const u8 = null,
    event: ?[]const u8 = null,
};

pub fn parse(allocator: std.mem.Allocator, session: std.json.ObjectMap) !Admission {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const storage = arena.allocator();
    const required = if (session.get("sessionAdsRequired")) |value| switch (value) {
        .bool => |flag| flag,
        .null => false,
        else => return error.InvalidAdsRequired,
    } else false;
    if (!required) return .{ .arena = arena, .required = false, .provider = 0, .control_base = null, .opportunities = &.{} };
    const provider = if (session.get("adProvider")) |value| if (value == .null) 0 else try unsigned(u8, value) else 0;
    const control_base = try controlBase(storage, session.get("sessionControlInfo"));
    var ads = std.ArrayList(Opportunity).init(storage);
    if (session.get("sessionAds")) |values| {
        if (values != .array and values != .null) return error.InvalidAdList;
        if (values == .array and values.array.items.len > 16) return error.InvalidAdList;
        if (values == .array) for (values.array.items) |value| {
            if (value != .object) return error.InvalidAd;
            const fields = value.object;
            const state = if (fields.get("adState")) |number| try unsigned(u8, number) else 0;
            if (state > 6) return error.InvalidAdState;
            if (state == 5 or state == 6) continue;
            const id = fields.get("adId") orelse return error.MissingAdId;
            const url = fields.get("adUrl") orelse return error.MissingAdUrl;
            if (id != .string or id.string.len == 0 or id.string.len > 256 or
                url != .string or url.string.len == 0 or url.string.len > 8192)
                return error.InvalidAd;
            const seconds = if (fields.get("adLengthInSeconds")) |number| try unsigned(u16, number) else 0;
            if (seconds > 120) return error.InvalidAdDuration;
            try ads.append(.{ .id = try storage.dupe(u8, id.string), .url = try storage.dupe(u8, url.string), .state = state, .duration_ms = @as(u64, seconds) * 1000 });
        };
    }
    return .{ .arena = arena, .required = required, .provider = provider, .control_base = control_base, .opportunities = try ads.toOwnedSlice() };
}

fn controlBase(allocator: std.mem.Allocator, control: ?std.json.Value) !?[]const u8 {
    const value = control orelse return null;
    if (value != .object) return null;
    const host = value.object.get("ip") orelse return null;
    if (host != .string or std.mem.indexOfAny(u8, host.string, "/@%?#\\") != null) return null;
    if (value.object.get("port")) |port| {
        if ((unsigned(u16, port) catch return null) != 443) return null;
    }
    const address = try std.fmt.allocPrint(allocator, "https://{s}/", .{host.string});
    return endpoint.normalizeCloudMatchBase(allocator, address) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    };
}

test "nullable ad metadata is not an invalid session while provisioning" {
    const json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"sessionAds\":null,\"sessionAdsRequired\":null,\"adProvider\":null,\"sessionControlInfo\":null}", .{});
    defer json.deinit();
    var admission = try parse(std.testing.allocator, json.value.object);
    defer admission.deinit();
    try std.testing.expect(!admission.required);
    try std.testing.expectEqual(@as(usize, 0), admission.opportunities.len);
    try std.testing.expectEqual(@as(u8, 0), admission.provider);
}

fn unsigned(comptime T: type, value: std.json.Value) !T {
    if (value != .integer or value.integer < 0 or value.integer > std.math.maxInt(T)) return error.InvalidAdNumber;
    return @intCast(value.integer);
}

pub fn buildUpdate(allocator: std.mem.Allocator, id: []const u8, update: Update, timestamp: i64) ![]u8 {
    if (id.len == 0 or id.len > 256 or timestamp < 0) return error.InvalidAdUpdate;
    if (update.action == .cancel and update.reason == null) return error.MissingCancelReason;
    if (update.action == .event and update.event == null) return error.MissingEvent;
    return std.json.stringifyAlloc(allocator, .{ .action = 6, .adUpdates = &.{.{
        .adId = id,
        .adAction = @intFromEnum(update.action),
        .clientTimestamp = timestamp,
        .watchedTimeInMs = update.watched_ms,
        .pausedTimeInMs = update.paused_ms,
        .adDurationInMs = update.duration_ms,
        .cancelReason = update.reason,
        .eventName = update.event,
    }} }, .{ .emit_null_optional_fields = false });
}

test "no-fill cancellation uses the original pod ID and no fabricated playback" {
    const body = try buildUpdate(std.testing.allocator, "opaque-pod", .{ .action = .cancel, .reason = "VAST_EMPTY_RESPONSE" }, 123);
    defer std.testing.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const update = parsed.value.object.get("adUpdates").?.array.items[0].object;
    try std.testing.expectEqualStrings("opaque-pod", update.get("adId").?.string);
    try std.testing.expectEqual(@as(i64, 5), update.get("adAction").?.integer);
    try std.testing.expectEqual(@as(i64, 123), update.get("clientTimestamp").?.integer);
    try std.testing.expectEqual(@as(i64, 0), update.get("watchedTimeInMs").?.integer);
    try std.testing.expect(update.get("eventName") == null);
}

test "ad metadata is owned and finished opportunities are excluded" {
    const json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"sessionAdsRequired\":true,\"adProvider\":1,\"sessionControlInfo\":{\"ip\":\"np.example.nvidiagrid.net\",\"port\":443},\"sessionAds\":[{\"adId\":\"pod\",\"adState\":1,\"adLengthInSeconds\":30,\"adUrl\":\"https://example.invalid/tag\"},{\"adState\":5}]}", .{});
    var admission = try parse(std.testing.allocator, json.value.object);
    json.deinit();
    defer admission.deinit();
    try std.testing.expect(admission.required);
    try std.testing.expectEqual(@as(usize, 1), admission.opportunities.len);
    try std.testing.expectEqualStrings("pod", admission.opportunities[0].id);
    try std.testing.expectEqualStrings("https://np.example.nvidiagrid.net/", admission.control_base.?);
}

test "untrusted ad control hosts cannot receive account credentials" {
    const json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"sessionAdsRequired\":true,\"sessionControlInfo\":{\"ip\":\"evil.invalid\",\"port\":443}}", .{});
    defer json.deinit();
    var admission = try parse(std.testing.allocator, json.value.object);
    defer admission.deinit();
    try std.testing.expect(admission.control_base == null);
}

test "unsupported control addresses leave ad reporting on the trusted session endpoint" {
    for ([_][]const u8{ "null", "123", "{\"ip\":123}", "{\"ip\":null}", "{\"ip\":{\"address\":\"192.0.2.1\"}}", "{\"ip\":\"192.0.2.1\"}", "{\"ip\":\"np.example.nvidiagrid.net\",\"port\":80}", "{\"ip\":\"np.example.nvidiagrid.net\",\"port\":\"invalid\"}" }) |control| {
        const bytes = try std.fmt.allocPrint(std.testing.allocator, "{{\"sessionAdsRequired\":true,\"sessionControlInfo\":{s}}}", .{control});
        defer std.testing.allocator.free(bytes);
        const json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
        defer json.deinit();
        var admission = try parse(std.testing.allocator, json.value.object);
        defer admission.deinit();
        try std.testing.expect(admission.required and admission.control_base == null);
    }
}

test "irrelevant ad metadata does not reject an ad-free session" {
    const json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"sessionAdsRequired\":false,\"adProvider\":\"invalid\",\"sessionAds\":42}", .{});
    defer json.deinit();
    var admission = try parse(std.testing.allocator, json.value.object);
    defer admission.deinit();
    try std.testing.expect(!admission.required and admission.opportunities.len == 0);
}

test "malformed required ads cannot bypass admission" {
    const json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"sessionAdsRequired\":true,\"sessionAds\":42}", .{});
    defer json.deinit();
    try std.testing.expectError(error.InvalidAdList, parse(std.testing.allocator, json.value.object));
}

test "ad admission preserves allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const json = try std.json.parseFromSlice(std.json.Value, allocator, "{\"sessionAdsRequired\":true,\"sessionControlInfo\":{\"ip\":\"np.example.nvidiagrid.net\"},\"sessionAds\":[{\"adId\":\"one\",\"adUrl\":\"https://example.invalid/ad\"}]}", .{});
            defer json.deinit();
            var admission = try parse(allocator, json.value.object);
            defer admission.deinit();
        }
    }.run, .{});
}
