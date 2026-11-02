const std = @import("std");
const endpoint = @import("endpoint.zig");
const ad_protocol = @import("ad_protocol.zig");

pub const IceServer = struct {
    urls: [][]u8,
    username: ?[]u8,
    credential: ?[]u8,

    fn deinit(self: *IceServer, allocator: std.mem.Allocator) void {
        for (self.urls) |value| allocator.free(value);
        allocator.free(self.urls);
        if (self.username) |value| allocator.free(value);
        if (self.credential) |value| allocator.free(value);
    }
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    id: []u8,
    status: u32,
    queue_position: ?u32,
    setup_step: ?u32,
    signaling_url: ?[]u8,
    signaling_from_connection: bool = false,
    media_ip: ?[]u8,
    media_port: ?u16,
    ice_servers: []IceServer,
    ads: ?ad_protocol.Admission = null,

    pub fn ready(self: *const Session) bool {
        return self.status == 2 or self.status == 3;
    }

    pub fn ended(self: *const Session) bool {
        // Status 6 is cleanup before provisioning can resume.
        return self.status > 3 and self.status != 6;
    }

    pub fn retainRouting(self: *Session, previous: *Session) void {
        if (!std.mem.eql(u8, self.id, previous.id) or self.status > 3 or previous.status > 3) return;
        if (self.media_ip != null and previous.media_ip != null and
            (!std.mem.eql(u8, self.media_ip.?, previous.media_ip.?) or self.media_port != previous.media_port)) return;
        if (self.signaling_url != null and previous.signaling_url != null) {
            if (!self.signaling_from_connection and previous.signaling_from_connection) {
                self.allocator.free(self.signaling_url.?);
                self.signaling_url = null;
            } else if (!std.mem.eql(u8, self.signaling_url.?, previous.signaling_url.?)) return;
        }

        if (self.signaling_url == null) {
            self.signaling_url = previous.signaling_url;
            self.signaling_from_connection = previous.signaling_from_connection;
            previous.signaling_url = null;
            previous.signaling_from_connection = false;
        }
        if (self.media_ip == null) {
            self.media_ip = previous.media_ip;
            self.media_port = previous.media_port;
            previous.media_ip = null;
            previous.media_port = null;
        }
        if (self.ice_servers.len == 0) std.mem.swap([]IceServer, &self.ice_servers, &previous.ice_servers);
    }

    pub fn deinit(self: *Session) void {
        if (self.ads) |*ads| ads.deinit();
        self.allocator.free(self.id);
        if (self.signaling_url) |value| self.allocator.free(value);
        if (self.media_ip) |value| self.allocator.free(value);
        for (self.ice_servers) |*server| server.deinit(self.allocator);
        self.allocator.free(self.ice_servers);
        self.* = undefined;
    }
};

pub const ActiveSessionSummary = struct {
    active: usize = 0,
    same_device: usize = 0,
    matching_app: usize = 0,
};

pub fn parseVpcId(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    const root = try object(parsed.value);
    const status = try object(root.get("requestStatus") orelse return error.MissingStatus);
    if ((optionalUnsigned(status, "statusCode") orelse 0) != 1) return error.RequestRejected;
    const server_id = try requiredString(status, "serverId");
    return allocator.dupe(u8, server_id);
}

pub fn parseLocalRegionUrl(allocator: std.mem.Allocator, data: []const u8) !?[]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    const root = try object(parsed.value);
    const metadata = array(root.get("metaData") orelse return null) catch return null;
    var local_region: ?[]const u8 = null;
    for (metadata.items) |entry_value| {
        const entry = object(entry_value) catch continue;
        const key = (optionalString(entry, "key") catch continue) orelse continue;
        if (!std.mem.eql(u8, key, "local-region")) continue;
        local_region = (optionalString(entry, "value") catch continue) orelse continue;
        break;
    }
    const region = local_region orelse return null;
    for (metadata.items) |entry_value| {
        const entry = object(entry_value) catch continue;
        const key = (optionalString(entry, "key") catch continue) orelse continue;
        if (!std.mem.eql(u8, key, region)) continue;
        const url = (optionalString(entry, "value") catch continue) orelse continue;
        return try endpoint.normalizeCloudMatchBase(allocator, url);
    }
    return null;
}

pub fn buildSessionRequest(
    allocator: std.mem.Allocator,
    app_id: []const u8,
    internal_title: []const u8,
    device_id: []const u8,
    width: u16,
    height: u16,
    frames_per_second: u16,
    user_age: u8,
) ![]u8 {
    if (app_id.len == 0 or device_id.len == 0 or
        width < 320 or height < 240 or frames_per_second == 0)
        return error.InvalidSessionRequest;
    const numeric_app_id = std.fmt.parseUnsigned(u64, app_id, 10) catch
        return error.InvalidSessionRequest;

    const title: ?[]const u8 = if (internal_title.len > 0) internal_title else null;

    return std.json.stringifyAlloc(allocator, .{
        .sessionRequestData = .{
            .appId = numeric_app_id,
            .cmsId = app_id,
            .internalTitle = title,
            .availableSupportedControllers = &[_]struct {}{},
            .networkTestSessionId = null,
            .parentSessionId = null,
            .clientIdentification = "GFN-PC",
            .deviceHashId = device_id,
            .clientVersion = "30.0",
            .sdkVersion = "1.0",
            .streamerVersion = 1,
            .clientPlatformName = "browser",
            .clientRequestMonitorSettings = &.{.{
                .monitorId = 0,
                .positionX = 0,
                .positionY = 0,
                .widthInPixels = width,
                .heightInPixels = height,
                .framesPerSecond = frames_per_second,
                .sdrHdrMode = 0,
                .displayData = null,
                .hdr10PlusGamingData = null,
                .dpi = 100,
            }},
            .useOps = true,
            .audioMode = 2,
            .metaData = &.{
                .{ .key = "SubSessionId", .value = device_id },
                .{ .key = "wssignaling", .value = "1" },
                .{ .key = "GSStreamerType", .value = "WebRTC" },
            },
            .sdrHdrMode = 0,
            .clientDisplayHdrCapabilities = null,
            .surroundAudioInfo = 0,
            .remoteControllersBitmap = 1,
            .clientTimezoneOffset = 0,
            .enhancedStreamMode = 1,
            .appLaunchMode = 1,
            .secureRTSPSupported = false,
            .partnerCustomData = "",
            // The catalog only exposes owned library variants.
            .accountLinked = true,
            .enablePersistingInGameSettings = false,
            .userAge = user_age,
            .requestedStreamingFeatures = .{
                .reflex = false,
                .bitDepth = 0,
                .cloudGsync = false,
                .enabledL4S = false,
                .mouseMovementFlags = 0,
                .trueHdr = false,
                .supportedHidDevices = 0,
                .profile = 0,
                .fallbackToLogicalResolution = false,
                .hidDevices = null,
                .chromaFormat = 0,
                .prefilterMode = 0,
                .prefilterSharpness = 0,
                .prefilterNoiseReduction = 0,
                .hudStreamingMode = 0,
                .sdrColorSpace = 2,
                .hdrColorSpace = 0,
            },
        },
    }, .{ .emit_null_optional_fields = true });
}

pub fn writeErrorSummary(
    allocator: std.mem.Allocator,
    data: []const u8,
    output: []u8,
) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return null;
    defer parsed.deinit();
    const root = object(parsed.value) catch return null;
    const request_status = object(root.get("requestStatus") orelse return null) catch return null;
    const description = (optionalString(request_status, "statusDescription") catch return null) orelse
        return null;
    const status_code = optionalUnsigned(request_status, "statusCode");
    const unified_code = optionalUnsigned(request_status, "unifiedErrorCode");
    const session_code = nestedUnsigned(root, "session.errorCode");

    var sanitized: [256]u8 = undefined;
    const description_length = @min(description.len, sanitized.len);
    for (description[0..description_length], 0..) |byte, index| {
        sanitized[index] = if (byte >= 0x20 and byte != 0x7f) byte else ' ';
    }

    return if (session_code) |session_error|
        std.fmt.bufPrint(output, "{s} (status {d}, code {d}, session code {d})", .{
            sanitized[0..description_length],
            status_code orelse 0,
            unified_code orelse 0,
            session_error,
        }) catch null
    else if (unified_code) |code|
        std.fmt.bufPrint(output, "{s} (status {d}, code {d})", .{
            sanitized[0..description_length],
            status_code orelse 0,
            code,
        }) catch null
    else if (status_code) |code|
        std.fmt.bufPrint(output, "{s} (status {d})", .{
            sanitized[0..description_length],
            code,
        }) catch null
    else
        std.fmt.bufPrint(output, "{s}", .{sanitized[0..description_length]}) catch null;
}

pub fn sessionFailureIsRetryable(allocator: std.mem.Allocator, data: []const u8) ?bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch
        return null;
    defer parsed.deinit();
    const root = object(parsed.value) catch return null;
    const request_status = object(root.get("requestStatus") orelse return null) catch return null;
    const status_code = optionalUnsigned(request_status, "statusCode") orelse return null;
    if (status_code == 1 or status_code >= 255) return false;

    const server_error_base: usize = 3_237_093_632;
    var code = server_error_base + status_code;
    if (status_code == 0 or status_code == 4) {
        if (optionalUnsigned(request_status, "unifiedErrorCode")) |unified| code = unified;
    }

    return switch (code) {
        3_237_089_282,
        3_237_093_635,
        3_237_093_636,
        3_237_093_683,
        3_237_093_690,
        3_237_093_717,
        3_237_101_584,
        3_237_101_585,
        3_237_101_586,
        => true,
        else => false,
    };
}

pub fn parseActiveSessionSummary(
    allocator: std.mem.Allocator,
    data: []const u8,
    device_id: []const u8,
    app_id: []const u8,
) !ActiveSessionSummary {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    const root = try object(parsed.value);
    const request_status = try object(root.get("requestStatus") orelse return error.MissingStatus);
    if ((optionalUnsigned(request_status, "statusCode") orelse 0) != 1)
        return error.RequestRejected;
    const sessions = try array(root.get("sessions") orelse return error.MissingSessions);

    var summary = ActiveSessionSummary{};
    for (sessions.items) |session_value| {
        const session = object(session_value) catch continue;
        const status = optionalUnsigned(session, "status") orelse continue;
        if (status < 1 or status > 3) continue;
        summary.active += 1;
        const request_data = object(session.get("sessionRequestData") orelse continue) catch continue;
        if (try identifierEquals(request_data.get("appId"), app_id))
            summary.matching_app += 1;
        if (try identifierEquals(request_data.get("deviceHashId"), device_id))
            summary.same_device += 1;
    }
    return summary;
}

pub fn parseSession(allocator: std.mem.Allocator, data: []const u8) !Session {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    const root = try object(parsed.value);
    const request_status = try object(root.get("requestStatus") orelse return error.MissingStatus);
    if ((optionalUnsigned(request_status, "statusCode") orelse 0) != 1)
        return error.RequestRejected;
    const session = try object(root.get("session") orelse return error.MissingSession);
    const id = try duplicateIdentifier(allocator, session.get("sessionId") orelse return error.MissingSessionId);
    errdefer allocator.free(id);

    const status = sessionStatus(session.get("status")) orelse return error.InvalidSessionStatus;
    const queue_position = nestedUnsigned(session, "queuePosition") orelse
        nestedUnsigned(session, "seatSetupInfo.queuePosition") orelse
        nestedUnsigned(session, "sessionProgress.queuePosition") orelse
        nestedUnsigned(session, "progressInfo.queuePosition") orelse
        nestedUnsigned(root, "queuePosition");
    const setup_step = nestedUnsigned(session, "seatSetupStep") orelse
        nestedUnsigned(session, "seatSetupInfo.seatSetupStep");

    var signaling_url: ?[]u8 = null;
    var signaling_from_connection = false;
    var signaling_uses_rtsp = false;
    var media_ip: ?[]u8 = null;
    var media_port: ?u16 = null;
    errdefer if (signaling_url) |value| allocator.free(value);
    errdefer if (media_ip) |value| allocator.free(value);
    if (session.get("connectionInfo")) |connections_value| {
        const connections = switch (connections_value) {
            .array => |values| values,
            else => null,
        };
        if (connections) |values| for (values.items) |connection_value| {
            const connection = object(connection_value) catch continue;
            const usage = optionalUnsigned(connection, "usage") orelse continue;
            var ip = if (connection.get("ip")) |value| duplicateIp(allocator, value) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => null,
            } else null;
            defer if (ip) |value| allocator.free(value);
            const port_value = optionalUnsigned(connection, "port");
            const port: ?u16 = if (port_value != null and port_value.? > 0 and port_value.? <= std.math.maxInt(u16)) @intCast(port_value.?) else null;
            if (usage == 14 and port_value != null and port == null) continue;
            const path = duplicateOptionalString(allocator, connection, "resourcePath") catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => null,
            };
            defer if (path) |value| allocator.free(value);
            if (usage == 14 and (signaling_url == null or signaling_uses_rtsp)) {
                if (ip == null and (path == null or std.mem.indexOf(u8, path.?, "://") == null)) continue;
                const uses_rtsp = if (path) |resource|
                    std.mem.startsWith(u8, resource, "rtsp://") or std.mem.startsWith(u8, resource, "rtsps://")
                else
                    false;
                if (signaling_url != null and uses_rtsp) continue;
                const url = try buildSignalingUrl(allocator, ip orelse "", port, path);
                if (signaling_url) |old| allocator.free(old);
                signaling_url = url;
                signaling_from_connection = true;
                signaling_uses_rtsp = uses_rtsp;
            } else if ((usage == 2 or usage == 17) and media_ip == null and ip != null and port != null) {
                media_ip = ip;
                media_port = port;
                ip = null;
            }
        };
    }
    if (signaling_url == null) {
        if (session.get("sessionControlInfo")) |control_value| {
            const control = object(control_value) catch null;
            if (control) |value| {
                if (value.get("ip")) |raw_ip| {
                    const ip = duplicateIp(allocator, raw_ip) catch |err| switch (err) {
                        error.OutOfMemory => return err,
                        else => null,
                    };
                    if (ip) |address| {
                        defer allocator.free(address);
                        signaling_url = try buildSignalingUrl(allocator, address, null, null);
                    }
                }
            }
        }
    }
    const ice_servers = try parseIceServers(allocator, session);
    errdefer {
        for (ice_servers) |*server| server.deinit(allocator);
        allocator.free(ice_servers);
    }

    return .{
        .allocator = allocator,
        .id = id,
        .status = status,
        .queue_position = boundedU32(queue_position),
        .setup_step = boundedU32(setup_step),
        .signaling_url = signaling_url,
        .signaling_from_connection = signaling_from_connection,
        .media_ip = media_ip,
        .media_port = media_port,
        .ice_servers = ice_servers,
        .ads = try ad_protocol.parse(allocator, session),
    };
}

fn boundedU32(value: ?u64) ?u32 {
    const number = value orelse return null;
    if (number > std.math.maxInt(u32)) return null;
    return @intCast(number);
}

fn buildSignalingUrl(
    allocator: std.mem.Allocator,
    ip: []const u8,
    port: ?u16,
    path: ?[]const u8,
) ![]u8 {
    const resource = path orelse "/nvst/";
    if (std.mem.indexOf(u8, resource, "://") != null) {
        var uri = std.Uri.parse(resource) catch return error.InvalidSignalingEndpoint;
        if (uri.host == null or uri.user != null or uri.password != null or uri.fragment != null or
            (uri.port != null and uri.port.? == 0) or
            (!std.mem.eql(u8, uri.scheme, "wss") and !std.mem.eql(u8, uri.scheme, "https") and
                !std.mem.eql(u8, uri.scheme, "rtsps") and !std.mem.eql(u8, uri.scheme, "rtsp")))
            return error.InvalidSignalingEndpoint;
        if (std.mem.eql(u8, uri.scheme, "rtsp") or std.mem.eql(u8, uri.scheme, "rtsps")) {
            // RTSP allocations share the seat host, not the WebRTC port or path.
            uri.port = 443;
            uri.path = .{ .raw = "/nvst/" };
            uri.query = null;
        } else uri.port = uri.port orelse 443;
        uri.scheme = "wss";
        if (uri.path.isEmpty()) uri.path = .{ .raw = "/nvst/" };
        return std.fmt.allocPrint(allocator, "{}", .{uri});
    }
    const normalized_path = if (resource.len == 0) "/nvst/" else resource;
    const slash: []const u8 = if (std.mem.startsWith(u8, normalized_path, "/")) "" else "/";
    return if (std.mem.indexOfScalar(u8, ip, ':') != null and !std.mem.startsWith(u8, ip, "["))
        std.fmt.allocPrint(allocator, "wss://[{s}]:{d}{s}{s}", .{ ip, port orelse 443, slash, normalized_path })
    else
        std.fmt.allocPrint(allocator, "wss://{s}:{d}{s}{s}", .{ ip, port orelse 443, slash, normalized_path });
}

fn parseIceServers(allocator: std.mem.Allocator, session: std.json.ObjectMap) ![]IceServer {
    const configuration_value = session.get("iceServerConfiguration") orelse
        return allocator.alloc(IceServer, 0);
    const configuration = object(configuration_value) catch return allocator.alloc(IceServer, 0);
    const servers_value = configuration.get("iceServers") orelse
        return allocator.alloc(IceServer, 0);
    const values = array(servers_value) catch return allocator.alloc(IceServer, 0);
    var result = std.ArrayList(IceServer).init(allocator);
    errdefer {
        for (result.items) |*server| server.deinit(allocator);
        result.deinit();
    }
    for (values.items) |server_value| {
        const server = object(server_value) catch continue;
        var urls = std.ArrayList([]u8).init(allocator);
        errdefer {
            for (urls.items) |url| allocator.free(url);
            urls.deinit();
        }
        if (server.get("urls")) |urls_value| switch (urls_value) {
            .string => |url| try appendIceUrl(allocator, &urls, url),
            .array => |array_value| for (array_value.items) |url_value| switch (url_value) {
                .string => |url| try appendIceUrl(allocator, &urls, url),
                else => {},
            },
            else => {},
        };
        if (urls.items.len == 0) {
            urls.deinit();
            continue;
        }
        const owned_urls = try urls.toOwnedSlice();
        errdefer {
            for (owned_urls) |url| allocator.free(url);
            allocator.free(owned_urls);
        }
        const username = try duplicateOptionalString(allocator, server, "username");
        errdefer if (username) |value| allocator.free(value);
        const credential = try duplicateOptionalString(allocator, server, "credential");
        errdefer if (credential) |value| allocator.free(value);
        try result.append(.{
            .urls = owned_urls,
            .username = username,
            .credential = credential,
        });
    }
    return result.toOwnedSlice();
}

fn appendIceUrl(allocator: std.mem.Allocator, urls: *std.ArrayList([]u8), url: []const u8) !void {
    if (url.len == 0) return;
    const owned = try allocator.dupe(u8, url);
    errdefer allocator.free(owned);
    try urls.append(owned);
}

fn nestedUnsigned(root: std.json.ObjectMap, path: []const u8) ?usize {
    var fields = std.mem.splitScalar(u8, path, '.');
    var current = root;
    while (fields.next()) |field| {
        const value = current.get(field) orelse return null;
        if (fields.peek() == null) return switch (value) {
            .integer => |number| if (number >= 0 and number <= std.math.maxInt(usize)) @intCast(number) else null,
            else => null,
        };
        current = object(value) catch return null;
    }
    return null;
}

fn sessionStatus(value: ?std.json.Value) ?u32 {
    const actual = value orelse return null;
    return switch (actual) {
        .integer => |number| if (number >= 0 and number <= std.math.maxInt(u32)) @intCast(number) else null,
        .string => |text| if (std.ascii.eqlIgnoreCase(text, "queued"))
            0
        else if (std.ascii.eqlIgnoreCase(text, "provisioning") or
            std.ascii.eqlIgnoreCase(text, "initializing") or
            std.ascii.eqlIgnoreCase(text, "setup") or
            std.ascii.eqlIgnoreCase(text, "setting_up") or
            std.ascii.eqlIgnoreCase(text, "launching") or
            std.ascii.eqlIgnoreCase(text, "launching_game"))
            1
        else if (std.ascii.eqlIgnoreCase(text, "active") or
            std.ascii.eqlIgnoreCase(text, "ready") or
            std.ascii.eqlIgnoreCase(text, "paused"))
            2
        else if (std.ascii.eqlIgnoreCase(text, "streaming") or
            std.ascii.eqlIgnoreCase(text, "playing") or
            std.ascii.eqlIgnoreCase(text, "connected"))
            3
        else
            null,
        else => null,
    };
}

fn duplicateIdentifier(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return switch (value) {
        .string => |text| if (text.len > 0) allocator.dupe(u8, text) else error.InvalidIdentifier,
        .integer => |number| if (number >= 0)
            std.fmt.allocPrint(allocator, "{d}", .{number})
        else
            error.InvalidIdentifier,
        else => error.InvalidIdentifier,
    };
}

fn identifierEquals(value: ?std.json.Value, expected: []const u8) !bool {
    const actual = value orelse return false;
    return switch (actual) {
        .string => |text| std.mem.eql(u8, text, expected),
        .integer => |number| if (number >= 0) result: {
            var buffer: [32]u8 = undefined;
            const text = try std.fmt.bufPrint(&buffer, "{d}", .{number});
            break :result std.mem.eql(u8, text, expected);
        } else false,
        else => false,
    };
}

fn duplicateIp(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return switch (value) {
        .string => |text| if (text.len > 0) allocator.dupe(u8, text) else error.InvalidIp,
        .integer => |number| if (number >= 0 and number <= std.math.maxInt(u32)) blk: {
            const ip: u32 = @intCast(number);
            break :blk std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{
                ip >> 24,
                (ip >> 16) & 0xff,
                (ip >> 8) & 0xff,
                ip & 0xff,
            });
        } else error.InvalidIp,
        .array => |values| if (values.items.len > 0) duplicateIp(allocator, values.items[0]) else error.InvalidIp,
        .object => |fields| if (fields.get("value")) |nested| duplicateIp(allocator, nested) else error.InvalidIp,
        else => error.InvalidIp,
    };
}

fn duplicateOptionalString(
    allocator: std.mem.Allocator,
    value: std.json.ObjectMap,
    key: []const u8,
) !?[]u8 {
    if (try optionalString(value, key)) |text| return try allocator.dupe(u8, text);
    return null;
}

fn object(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |result| result,
        else => error.ExpectedObject,
    };
}

fn array(value: std.json.Value) !std.json.Array {
    return switch (value) {
        .array => |result| result,
        else => error.ExpectedArray,
    };
}

fn requiredString(value: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return (try optionalString(value, key)) orelse error.MissingField;
}

fn optionalString(value: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const field = value.get(key) orelse return null;
    return switch (field) {
        .string => |text| if (text.len > 0) text else null,
        .null => null,
        else => error.InvalidField,
    };
}

fn optionalUnsigned(value: std.json.ObjectMap, key: []const u8) ?usize {
    const field = value.get(key) orelse return null;
    return switch (field) {
        .integer => |number| if (number >= 0 and number <= std.math.maxInt(usize)) @intCast(number) else null,
        else => null,
    };
}

test "parses VPC id from server info" {
    const id = try parseVpcId(std.testing.allocator,
        \\{"requestStatus":{"statusCode":1,"serverId":"GFN-PC"}}
    );
    defer std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("GFN-PC", id);
}

test "queue and cleanup states remain pending while terminal states end the wait" {
    for ([_]u32{ 0, 1, 2, 3, 4, 5, 6, 7 }) |status| {
        const data = try std.fmt.allocPrint(std.testing.allocator,
            \\{{"requestStatus":{{"statusCode":1}},"session":{{"sessionId":"test","status":{d}}}}}
        , .{status});
        defer std.testing.allocator.free(data);
        var session = try parseSession(std.testing.allocator, data);
        defer session.deinit();
        try std.testing.expectEqual(status == 2 or status == 3, session.ready());
        try std.testing.expectEqual(status == 4 or status == 5 or status == 7, session.ended());
    }
}

test "invalid session states are not treated as a queue" {
    for ([_][]const u8{ "null", "-1", "4294967296", "\"unrecognized\"" }) |status| {
        const data = try std.fmt.allocPrint(std.testing.allocator,
            \\{{"requestStatus":{{"statusCode":1}},"session":{{"sessionId":"test","status":{s}}}}}
        , .{status});
        defer std.testing.allocator.free(data);
        try std.testing.expectError(error.InvalidSessionStatus, parseSession(std.testing.allocator, data));
    }
}

test "parses and validates the advertised local CloudMatch region" {
    const url = (try parseLocalRegionUrl(std.testing.allocator,
        \\{"metaData":[
        \\  {"key":"local-region","value":"np-ams-06"},
        \\  {"key":"np-ams-06","value":"https://np-ams-06.cloudmatchbeta.nvidiagrid.net"}
        \\]}
    )).?;
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://np-ams-06.cloudmatchbeta.nvidiagrid.net/", url);

    try std.testing.expectError(
        error.UntrustedCloudMatchUrl,
        parseLocalRegionUrl(std.testing.allocator,
            \\{"metaData":[
            \\  {"key":"local-region","value":"np-ams-06"},
            \\  {"key":"np-ams-06","value":"https://example.invalid"}
            \\]}
        ),
    );
}

test "summarizes active sessions without retaining identifiers" {
    const summary = try parseActiveSessionSummary(
        std.testing.allocator,
        \\{"requestStatus":{"statusCode":1},"sessions":[
        \\  {"status":3,"sessionRequestData":{"appId":1001,"deviceHashId":"device-a"}},
        \\  {"status":1,"sessionRequestData":{"appId":"2002","deviceHashId":"device-b"}},
        \\  {"status":4,"sessionRequestData":{"appId":"1001","deviceHashId":"device-a"}}
        \\]}
    ,
        "device-a",
        "1001",
    );
    try std.testing.expectEqual(@as(usize, 2), summary.active);
    try std.testing.expectEqual(@as(usize, 1), summary.same_device);
    try std.testing.expectEqual(@as(usize, 1), summary.matching_app);
}

test "builds a display-matched WebRTC session request" {
    const body = try buildSessionRequest(
        std.testing.allocator,
        "202",
        "Test Game",
        "device-one",
        640,
        480,
        30,
        37,
    );
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"widthInPixels\":640") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"heightInPixels\":480") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "GSStreamerType") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"clientPlatformName\":\"browser\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"appId\":202") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"cmsId\":\"202\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"internalTitle\":\"Test Game\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"availableSupportedControllers\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"displayData\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"dpi\":100") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"remoteControllersBitmap\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"prefilterMode\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"sdrColorSpace\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"maxBitrateKbps\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"codec\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"userAge\":37") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"accountLinked\":true") != null);
}

test "writes a bounded CloudMatch error summary" {
    var output: [128]u8 = undefined;
    const summary = writeErrorSummary(
        std.testing.allocator,
        \\{"requestStatus":{"statusCode":0,"statusDescription":"Unsupported request\n","unifiedErrorCode":42}}
    ,
        &output,
    ) orelse return error.MissingSummary;
    try std.testing.expectEqualStrings("Unsupported request  (status 0, code 42)", summary);
}

test "includes a session error code in the CloudMatch summary" {
    var output: [160]u8 = undefined;
    const summary = writeErrorSummary(
        std.testing.allocator,
        \\{"requestStatus":{"statusCode":4,"statusDescription":"INTERNAL_ERROR_STATUS","unifiedErrorCode":0},"session":{"errorCode":2324439040}}
    ,
        &output,
    ) orelse return error.MissingSummary;
    try std.testing.expectEqualStrings(
        "INTERNAL_ERROR_STATUS (status 4, code 0, session code 2324439040)",
        summary,
    );
}

test "classifies CloudMatch session failures before retrying" {
    try std.testing.expectEqual(
        false,
        sessionFailureIsRetryable(std.testing.allocator,
            \\{"requestStatus":{"statusCode":81,"statusDescription":"STREAMING_NOT_ALLOWED_IN_LIMITED_MODE"}}
        ).?,
    );
    try std.testing.expectEqual(
        true,
        sessionFailureIsRetryable(std.testing.allocator,
            \\{"requestStatus":{"statusCode":58,"statusDescription":"INSUFFICIENT_VM_CAPACITY"}}
        ).?,
    );
    try std.testing.expectEqual(
        false,
        sessionFailureIsRetryable(std.testing.allocator,
            \\{"requestStatus":{"statusCode":4,"unifiedErrorCode":3237093713}}
        ).?,
    );
    try std.testing.expect(sessionFailureIsRetryable(std.testing.allocator, "not json") == null);
}

test "parses queue and connection state" {
    var session = try parseSession(std.testing.allocator,
        \\{
        \\  "requestStatus":{"statusCode":1},
        \\  "session":{
        \\    "sessionId":"session-one","status":2,
        \\    "seatSetupInfo":{"queuePosition":4,"seatSetupStep":1},
        \\    "connectionInfo":[
        \\      {"usage":14,"ip":{"value":"203.0.113.10"},"port":443,"resourcePath":"/nvst/"},
        \\      {"usage":2,"ip":3405803787,"port":49005}
        \\    ],
        \\    "iceServerConfiguration":{"iceServers":[{"urls":"stun:example.invalid:3478","username":"user","credential":"secret"}]}
        \\  }
        \\}
    );
    defer session.deinit();

    try std.testing.expect(session.ready());
    try std.testing.expectEqual(@as(?u32, 4), session.queue_position);
    try std.testing.expectEqual(@as(?u32, 1), session.setup_step);
    try std.testing.expectEqualStrings("wss://203.0.113.10:443/nvst/", session.signaling_url.?);
    try std.testing.expectEqualStrings("203.0.113.11", session.media_ip.?);
    try std.testing.expectEqual(@as(?u16, 49005), session.media_port);
    try std.testing.expectEqual(@as(usize, 1), session.ice_servers.len);
}

test "accepts a queued response before connection details are assigned" {
    var session = try parseSession(std.testing.allocator,
        \\{
        \\  "requestStatus":{"statusCode":1},
        \\  "queuePosition":42,
        \\  "session":{"sessionId":"session-one","status":"QUEUED","connectionInfo":null}
        \\}
    );
    defer session.deinit();

    try std.testing.expectEqual(@as(u32, 0), session.status);
    try std.testing.expectEqual(@as(?u32, 42), session.queue_position);
    try std.testing.expectEqual(@as(?[]u8, null), session.signaling_url);
}

test "numeric and structured control addresses preserve signaling and ad admission" {
    for ([_][]const u8{ "3405803787", "{\"value\":\"203.0.113.11\"}" }) |ip| {
        for ([_]bool{ false, true }) |required| {
            const bytes = try std.fmt.allocPrint(
                std.testing.allocator,
                "{{\"requestStatus\":{{\"statusCode\":1}},\"session\":{{\"sessionId\":\"one\",\"status\":2,\"sessionAdsRequired\":{},\"sessionControlInfo\":{{\"ip\":{s}}}}}}}",
                .{ required, ip },
            );
            defer std.testing.allocator.free(bytes);
            var session = try parseSession(std.testing.allocator, bytes);
            defer session.deinit();
            try std.testing.expectEqualStrings("wss://203.0.113.11:443/nvst/", session.signaling_url.?);
            try std.testing.expectEqual(required, session.ads.?.required);
            try std.testing.expect(session.ads.?.control_base == null);
        }
    }
}

test "ignores queue values outside the supported range" {
    var session = try parseSession(std.testing.allocator,
        \\{
        \\  "requestStatus":{"statusCode":1},
        \\  "session":{
        \\    "sessionId":"session-one","status":"QUEUED",
        \\    "queuePosition":4294967296,"seatSetupStep":4294967296
        \\  }
        \\}
    );
    defer session.deinit();

    try std.testing.expectEqual(@as(?u32, null), session.queue_position);
    try std.testing.expectEqual(@as(?u32, null), session.setup_step);
}

test "session parsing replaces incomplete signaling endpoints without leaking" {
    var session = try parseSession(std.testing.allocator,
        \\{"requestStatus":{"statusCode":1},"session":{
        \\"sessionId":"session-one","status":2,"connectionInfo":[
        \\  {"usage":14,"resourcePath":"/incomplete/"},
        \\  {"usage":14,"ip":"203.0.113.10","resourcePath":"/nvst/"}
        \\]}}
    );
    defer session.deinit();
    try std.testing.expectEqualStrings("wss://203.0.113.10:443/nvst/", session.signaling_url.?);
}

test "session parsing releases partial allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var session = try parseSession(allocator,
                \\{"requestStatus":{"statusCode":1},"session":{
                \\"sessionId":"session-one","status":2,
                \\"connectionInfo":[
                \\  {"usage":14,"ip":"203.0.113.10","resourcePath":"/nvst/"},
                \\  {"usage":2,"ip":3405803787,"port":49005}
                \\],
                \\"iceServerConfiguration":{"iceServers":[
                \\  {"urls":"stun:example.invalid:3478"},
                \\  {"urls":["turn:example.invalid:3478","turns:example.invalid:443"],"username":"user","credential":"test"}
                \\]}}}
            );
            defer session.deinit();
        }
    }.run, .{});
}

test "relative signaling paths preserve the assigned port" {
    var session = try parseSession(std.testing.allocator,
        \\{"requestStatus":{"statusCode":1},"session":{"sessionId":"one","status":2,"connectionInfo":[{"usage":14,"ip":"203.0.113.10","port":8443,"resourcePath":"/nvst/"}]}}
    );
    defer session.deinit();
    try std.testing.expectEqualStrings("wss://203.0.113.10:8443/nvst/", session.signaling_url.?);
}

test "WebSocket endpoints preserve their authority and RTSP allocations use the WebRTC route" {
    for ([_]struct { resource: []const u8, expected: []const u8 }{
        .{ .resource = "wss://seat.example.invalid:9443/nvst/", .expected = "wss://seat.example.invalid:9443/nvst/" },
        .{ .resource = "rtsps://seat.example.invalid:48322/custom/?token=test", .expected = "wss://seat.example.invalid:443/nvst/" },
        .{ .resource = "rtsp://seat.example.invalid:322/custom/", .expected = "wss://seat.example.invalid:443/nvst/" },
        .{ .resource = "https://seat.example.invalid/custom/", .expected = "wss://seat.example.invalid:443/custom/" },
    }) |case| {
        const bytes = try std.fmt.allocPrint(std.testing.allocator, "{{\"requestStatus\":{{\"statusCode\":1}},\"session\":{{\"sessionId\":\"one\",\"status\":2,\"connectionInfo\":[{{\"usage\":14,\"port\":8443,\"resourcePath\":\"{s}\"}}]}}}}", .{case.resource});
        defer std.testing.allocator.free(bytes);
        var session = try parseSession(std.testing.allocator, bytes);
        defer session.deinit();
        try std.testing.expectEqualStrings(case.expected, session.signaling_url.?);
    }
    const ipv6 = try buildSignalingUrl(std.testing.allocator, "2001:db8::1", 8443, "/nvst/");
    defer std.testing.allocator.free(ipv6);
    try std.testing.expectEqualStrings("wss://[2001:db8::1]:8443/nvst/", ipv6);
}

test "signaling endpoints reject insecure URLs and leave unassigned ports pending" {
    for ([_][]const u8{ "ws://example.invalid/nvst/", "wss://user@example.invalid/nvst/", "wss://example.invalid:0/nvst/" }) |resource|
        try std.testing.expectError(error.InvalidSignalingEndpoint, buildSignalingUrl(std.testing.allocator, "203.0.113.1", 443, resource));
    for ([_]u32{ 0, 65536 }) |port| {
        const bytes = try std.fmt.allocPrint(std.testing.allocator, "{{\"requestStatus\":{{\"statusCode\":1}},\"session\":{{\"sessionId\":\"one\",\"status\":2,\"connectionInfo\":[{{\"usage\":14,\"ip\":\"203.0.113.1\",\"port\":{d}}}]}}}}", .{port});
        defer std.testing.allocator.free(bytes);
        var session = try parseSession(std.testing.allocator, bytes);
        defer session.deinit();
        try std.testing.expect(session.signaling_url == null);
    }
}

test "an advertised DNS seat takes precedence over the control host" {
    var session = try parseSession(std.testing.allocator,
        \\{"requestStatus":{"statusCode":1},"session":{"sessionId":"one","status":2,"sessionControlInfo":{"ip":"np-example.cloudmatchbeta.nvidiagrid.net"},"connectionInfo":[{"usage":14,"port":322,"resourcePath":"rtsps://seat.cloudmatchbeta.nvidiagrid.net:322/session"},{"usage":14,"port":48322,"resourcePath":"rtsps://seat.cloudmatchbeta.nvidiagrid.net:48322/session"}]}}
    );
    defer session.deinit();
    try std.testing.expectEqualStrings("wss://seat.cloudmatchbeta.nvidiagrid.net:443/nvst/", session.signaling_url.?);
    try std.testing.expect(session.signaling_from_connection);
}

test "an explicit WebSocket endpoint takes precedence over RTSP-derived signaling" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var session = try parseSession(allocator,
                \\{"requestStatus":{"statusCode":1},"session":{"sessionId":"one","status":2,"connectionInfo":[{"usage":14,"port":322,"resourcePath":"rtsps://seat.example.invalid:322/session"},{"usage":14,"port":48322,"resourcePath":"rtsps://seat.example.invalid:48322/session"},{"usage":14,"port":8443,"resourcePath":"wss://webrtc.example.invalid:9443/nvst/"}]}}
            );
            defer session.deinit();
            try std.testing.expectEqualStrings("wss://webrtc.example.invalid:9443/nvst/", session.signaling_url.?);
        }
    }.run, .{});
}

test "a ready zone-only session retains its advertised signaling fallback" {
    var session = try parseSession(std.testing.allocator,
        \\{"requestStatus":{"statusCode":1},"session":{"sessionId":"one","status":2,"sessionAdsRequired":false,"sessionControlInfo":{"ip":"np-example.cloudmatchbeta.nvidiagrid.net","port":443}}}
    );
    defer session.deinit();
    try std.testing.expect(session.ready());
    try std.testing.expect(session.signaling_url != null);
    try std.testing.expectEqualStrings("wss://np-example.cloudmatchbeta.nvidiagrid.net:443/nvst/", session.signaling_url.?);
    try std.testing.expect(!session.signaling_from_connection);
}

const routed_session =
    \\{"requestStatus":{"statusCode":1},"session":{"sessionId":"one","status":1,"connectionInfo":[{"usage":14,"ip":"203.0.113.10","port":443,"resourcePath":"/nvst/"},{"usage":2,"ip":"203.0.113.11","port":49005}],"iceServerConfiguration":{"iceServers":[{"urls":"stun:example.invalid:3478"}]}}}
;

test "routing retention transfers ownership of omitted seat and ICE data" {
    var previous = try parseSession(std.testing.allocator, routed_session);
    defer previous.deinit();
    var next = try parseSession(std.testing.allocator,
        \\{"requestStatus":{"statusCode":1},"session":{"sessionId":"one","status":2,"connectionInfo":[]}}
    );
    defer next.deinit();
    next.retainRouting(&previous);
    try std.testing.expectEqualStrings("wss://203.0.113.10:443/nvst/", next.signaling_url.?);
    try std.testing.expectEqualStrings("203.0.113.11", next.media_ip.?);
    try std.testing.expectEqual(@as(?u16, 49005), next.media_port);
    try std.testing.expectEqual(@as(usize, 1), next.ice_servers.len);
    try std.testing.expect(previous.signaling_url == null and previous.media_ip == null);
    try std.testing.expect(next.signaling_from_connection);
    try std.testing.expect(!previous.signaling_from_connection);
    try std.testing.expectEqual(@as(usize, 0), previous.ice_servers.len);
}

test "a control fallback does not replace an advertised seat learned while queuing" {
    var previous = try parseSession(std.testing.allocator, routed_session);
    defer previous.deinit();
    var next = try parseSession(std.testing.allocator,
        \\{"requestStatus":{"statusCode":1},"session":{"sessionId":"one","status":2,"sessionControlInfo":{"ip":"np-example.cloudmatchbeta.nvidiagrid.net"}}}
    );
    defer next.deinit();
    next.retainRouting(&previous);
    try std.testing.expectEqualStrings("wss://203.0.113.10:443/nvst/", next.signaling_url.?);
    try std.testing.expectEqualStrings("203.0.113.11", next.media_ip.?);
    try std.testing.expectEqual(@as(usize, 1), next.ice_servers.len);
    try std.testing.expect(previous.signaling_url == null and previous.media_ip == null);
}

test "a control fallback with new media does not inherit an old seat" {
    var previous = try parseSession(std.testing.allocator, routed_session);
    defer previous.deinit();
    var next = try parseSession(std.testing.allocator,
        \\{"requestStatus":{"statusCode":1},"session":{"sessionId":"one","status":2,"sessionControlInfo":{"ip":"np-example.cloudmatchbeta.nvidiagrid.net"},"connectionInfo":[{"usage":2,"ip":"203.0.113.21","port":49005}]}}
    );
    defer next.deinit();
    next.retainRouting(&previous);
    try std.testing.expectEqualStrings("wss://np-example.cloudmatchbeta.nvidiagrid.net:443/nvst/", next.signaling_url.?);
    try std.testing.expectEqualStrings("203.0.113.21", next.media_ip.?);
    try std.testing.expectEqual(@as(usize, 0), next.ice_servers.len);
    try std.testing.expect(previous.signaling_url != null and previous.media_ip != null);
}

test "zone signaling fallback parsing releases partial allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var session = try parseSession(allocator,
                \\{"requestStatus":{"statusCode":1},"session":{"sessionId":"one","status":2,"sessionAdsRequired":false,"sessionControlInfo":{"ip":"np-example.cloudmatchbeta.nvidiagrid.net"}}}
            );
            defer session.deinit();
        }
    }.run, .{});
}

test "routing is not retained across new seats sessions or cleanup" {
    for ([_][]const u8{
        \\{"requestStatus":{"statusCode":1},"session":{"sessionId":"one","status":2,"connectionInfo":[{"usage":14,"ip":"203.0.113.20","port":443}]}}
        ,
        \\{"requestStatus":{"statusCode":1},"session":{"sessionId":"one","status":2,"connectionInfo":[{"usage":14,"port":48322,"resourcePath":"rtsps://seat.cloudmatchbeta.nvidiagrid.net:48322/session"}]}}
        ,
        \\{"requestStatus":{"statusCode":1},"session":{"sessionId":"one","status":2,"connectionInfo":[{"usage":2,"ip":"203.0.113.21","port":49005}]}}
        ,
        \\{"requestStatus":{"statusCode":1},"session":{"sessionId":"two","status":2}}
        ,
        \\{"requestStatus":{"statusCode":1},"session":{"sessionId":"one","status":4}}
        ,
        \\{"requestStatus":{"statusCode":1},"session":{"sessionId":"one","status":6}}
    }) |bytes| {
        var previous = try parseSession(std.testing.allocator, routed_session);
        defer previous.deinit();
        var next = try parseSession(std.testing.allocator, bytes);
        defer next.deinit();
        next.retainRouting(&previous);
        try std.testing.expect(previous.signaling_url != null and previous.media_ip != null);
        try std.testing.expectEqual(@as(usize, 0), next.ice_servers.len);
    }
    var previous = try parseSession(std.testing.allocator,
        \\{"requestStatus":{"statusCode":1},"session":{"sessionId":"one","status":6,"sessionControlInfo":{"ip":"203.0.113.10"}}}
    );
    defer previous.deinit();
    var next = try parseSession(std.testing.allocator,
        \\{"requestStatus":{"statusCode":1},"session":{"sessionId":"one","status":1}}
    );
    defer next.deinit();
    next.retainRouting(&previous);
    try std.testing.expect(next.signaling_url == null);
}

test "advertised route provenance survives an identical control fallback" {
    var previous = try parseSession(std.testing.allocator, routed_session);
    defer previous.deinit();
    var same = try parseSession(std.testing.allocator,
        \\{"requestStatus":{"statusCode":1},"session":{"sessionId":"one","status":1,"sessionControlInfo":{"ip":"203.0.113.10"}}}
    );
    defer same.deinit();
    same.retainRouting(&previous);
    try std.testing.expect(same.signaling_from_connection);
    var next = try parseSession(std.testing.allocator,
        \\{"requestStatus":{"statusCode":1},"session":{"sessionId":"one","status":2,"sessionControlInfo":{"ip":"control.example.invalid"}}}
    );
    defer next.deinit();
    next.retainRouting(&same);
    try std.testing.expectEqualStrings("wss://203.0.113.10:443/nvst/", next.signaling_url.?);
    try std.testing.expect(next.signaling_from_connection);
    try std.testing.expectEqualStrings("203.0.113.11", next.media_ip.?);
}
