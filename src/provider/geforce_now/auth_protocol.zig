const std = @import("std");
const form = @import("form_writer");

pub const device_authorization_endpoint = "https://login.nvidia.com/device/authorize";
pub const token_endpoint = "https://login.nvidia.com/token";
pub const client_token_endpoint = "https://login.nvidia.com/client_token";
pub const user_info_endpoint = "https://login.nvidia.com/userinfo";
pub const scope = "openid consent email tk_client age";
pub const token_refresh_window_seconds: i64 = 10 * 60;

const default_token_lifetime_seconds: u32 = 24 * 60 * 60;

pub const DeviceAuthorization = struct {
    client_id: []const u8,
    device_id: []const u8,
    display_name: []const u8,
    idp_id: ?[]const u8 = null,
};

pub const DeviceChallenge = struct {
    allocator: std.mem.Allocator,
    device_code: []u8,
    user_code: []u8,
    verification_uri: []u8,
    verification_uri_complete: ?[]u8,
    expires_in: u32,
    interval: u32,

    pub fn secondsRemaining(self: *const DeviceChallenge, started: u32, now: u32) u32 {
        return self.expires_in -| ((now -% started) / 1000);
    }

    pub fn deinit(self: *DeviceChallenge) void {
        secureFree(self.allocator, self.device_code);
        secureFree(self.allocator, self.user_code);
        self.allocator.free(self.verification_uri);
        if (self.verification_uri_complete) |uri| self.allocator.free(uri);
        self.* = undefined;
    }
};

pub const Tokens = struct {
    allocator: std.mem.Allocator,
    access_token: []u8,
    refresh_token: ?[]u8,
    id_token: ?[]u8,
    client_token: ?[]u8,
    expires_at: i64,

    pub fn deinit(self: *Tokens) void {
        secureFree(self.allocator, self.access_token);
        if (self.refresh_token) |token| secureFree(self.allocator, token);
        if (self.id_token) |token| secureFree(self.allocator, token);
        if (self.client_token) |token| secureFree(self.allocator, token);
        self.* = undefined;
    }

    pub fn bearer(self: *const Tokens) []const u8 {
        return self.id_token orelse self.access_token;
    }

    pub fn needsRefresh(self: *const Tokens, now: i64) bool {
        if (now < 0 or self.expires_at <= now) return true;
        return self.expires_at - now <= token_refresh_window_seconds;
    }
};

pub const PollError = enum {
    authorization_pending,
    slow_down,
    expired_token,
    access_denied,
    invalid_grant,
    other,
};

pub fn buildDeviceAuthorizationForm(
    request: DeviceAuthorization,
    output: []u8,
) ![:0]u8 {
    if (request.idp_id) |idp_id| {
        return form.build(&.{
            .{ .name = "client_id", .value = request.client_id },
            .{ .name = "scope", .value = scope },
            .{ .name = "device_id", .value = request.device_id },
            .{ .name = "display_name", .value = request.display_name },
            .{ .name = "idp_id", .value = idp_id },
        }, output);
    }
    return form.build(&.{
        .{ .name = "client_id", .value = request.client_id },
        .{ .name = "scope", .value = scope },
        .{ .name = "device_id", .value = request.device_id },
        .{ .name = "display_name", .value = request.display_name },
    }, output);
}

pub fn buildDeviceTokenForm(
    client_id: []const u8,
    device_code: []const u8,
    output: []u8,
) ![:0]u8 {
    return form.build(&.{
        .{ .name = "client_id", .value = client_id },
        .{ .name = "device_code", .value = device_code },
        .{ .name = "grant_type", .value = "urn:ietf:params:oauth:grant-type:device_code" },
    }, output);
}

pub fn buildRefreshTokenForm(
    client_id: []const u8,
    refresh_token: []const u8,
    output: []u8,
) ![:0]u8 {
    return form.build(&.{
        .{ .name = "client_id", .value = client_id },
        .{ .name = "grant_type", .value = "refresh_token" },
        .{ .name = "refresh_token", .value = refresh_token },
        .{ .name = "scope", .value = scope },
    }, output);
}

pub fn buildClientTokenForm(
    client_id: []const u8,
    client_token: []const u8,
    subject: []const u8,
    output: []u8,
) ![:0]u8 {
    return form.build(&.{
        .{ .name = "client_id", .value = client_id },
        .{ .name = "grant_type", .value = "urn:ietf:params:oauth:grant-type:client_token" },
        .{ .name = "client_token", .value = client_token },
        .{ .name = "sub", .value = subject },
    }, output);
}

pub fn parseDeviceChallenge(
    allocator: std.mem.Allocator,
    data: []const u8,
) !DeviceChallenge {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    const object = try rootObject(parsed.value);

    const device_code = try duplicateRequiredString(allocator, object, "device_code");
    errdefer secureFree(allocator, device_code);
    const user_code = try duplicateRequiredString(allocator, object, "user_code");
    errdefer secureFree(allocator, user_code);
    const verification_uri = try duplicateRequiredString(allocator, object, "verification_uri");
    errdefer allocator.free(verification_uri);
    const verification_uri_complete = try duplicateOptionalString(
        allocator,
        object,
        "verification_uri_complete",
    );
    errdefer if (verification_uri_complete) |uri| allocator.free(uri);

    return .{
        .allocator = allocator,
        .device_code = device_code,
        .user_code = user_code,
        .verification_uri = verification_uri,
        .verification_uri_complete = verification_uri_complete,
        .expires_in = try requiredUnsigned(object, "expires_in"),
        .interval = optionalUnsigned(object, "interval") orelse 5,
    };
}

pub fn parseGrantTokens(
    allocator: std.mem.Allocator,
    data: []const u8,
    issued_at: i64,
) !Tokens {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    const object = try rootObject(parsed.value);

    const lifetime = try tokenLifetime(object);
    return parseTokensObject(allocator, object, try expiryFromLifetime(issued_at, lifetime));
}

pub fn parseStoredTokens(allocator: std.mem.Allocator, data: []const u8) !Tokens {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    const object = try rootObject(parsed.value);
    return parseTokensObject(allocator, object, try requiredSigned(object, "expires_at"));
}

fn parseTokensObject(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    expires_at: i64,
) !Tokens {
    const access_token = try duplicateRequiredString(allocator, object, "access_token");
    errdefer secureFree(allocator, access_token);
    const refresh_token = try duplicateOptionalString(allocator, object, "refresh_token");
    errdefer if (refresh_token) |token| secureFree(allocator, token);
    const id_token = try duplicateOptionalString(allocator, object, "id_token");
    errdefer if (id_token) |token| secureFree(allocator, token);
    const client_token = try duplicateOptionalString(allocator, object, "client_token");
    errdefer if (client_token) |token| secureFree(allocator, token);

    return .{
        .allocator = allocator,
        .access_token = access_token,
        .refresh_token = refresh_token,
        .id_token = id_token,
        .client_token = client_token,
        .expires_at = expires_at,
    };
}

pub fn parseClientToken(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    return duplicateRequiredString(allocator, try rootObject(parsed.value), "client_token");
}

pub fn jwtSubject(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next() orelse return error.InvalidJwt;
    const encoded = parts.next() orelse return error.InvalidJwt;
    _ = parts.next() orelse return error.InvalidJwt;
    if (parts.next() != null or encoded.len == 0) return error.InvalidJwt;

    const decoded_length = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded);
    const decoded = try allocator.alloc(u8, decoded_length);
    defer allocator.free(decoded);
    try std.base64.url_safe_no_pad.Decoder.decode(decoded, encoded);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, decoded, .{});
    defer parsed.deinit();
    return duplicateRequiredString(allocator, try rootObject(parsed.value), "sub");
}

pub fn parseUserAge(allocator: std.mem.Allocator, data: []const u8, subject: []const u8) !u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    const object = try rootObject(parsed.value);
    const account = object.get("sub") orelse return error.MissingSubject;
    if (account != .string or !std.mem.eql(u8, account.string, subject))
        return error.AccountMismatch;
    const age = object.get("age") orelse return error.MissingUserAge;
    if (age != .integer) return error.InvalidUserAge;
    return std.math.cast(u8, age.integer) orelse error.InvalidUserAge;
}

test "reads account age without substituting a default" {
    for ([_]u8{ 0, 17, 37, 100 }) |age| {
        var buffer: [64]u8 = undefined;
        const data = try std.fmt.bufPrint(&buffer, "{{\"sub\":\"user-one\",\"age\":{d}}}", .{age});
        try std.testing.expectEqual(age, try parseUserAge(std.testing.allocator, data, "user-one"));
    }
    try std.testing.expectError(error.MissingUserAge, parseUserAge(std.testing.allocator, "{\"sub\":\"user-one\"}", "user-one"));
    try std.testing.expectError(error.AccountMismatch, parseUserAge(std.testing.allocator, "{\"sub\":\"user-two\",\"age\":37}", "user-one"));
    for ([_][]const u8{ "-1", "256", "null", "true", "37.5", "\"37\"" }) |value| {
        var buffer: [64]u8 = undefined;
        const data = try std.fmt.bufPrint(&buffer, "{{\"sub\":\"user-one\",\"age\":{s}}}", .{value});
        try std.testing.expectError(error.InvalidUserAge, parseUserAge(std.testing.allocator, data, "user-one"));
    }
}

pub fn mergeRefreshedTokens(
    allocator: std.mem.Allocator,
    previous: *const Tokens,
    data: []const u8,
    issued_at: i64,
) !Tokens {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    const object = try rootObject(parsed.value);

    const access_token = try duplicateRequiredString(allocator, object, "access_token");
    errdefer secureFree(allocator, access_token);
    const refresh_token = try duplicateResponseOrPrevious(
        allocator,
        object,
        "refresh_token",
        previous.refresh_token,
    );
    errdefer if (refresh_token) |token| secureFree(allocator, token);
    const id_token = try duplicateOptionalString(allocator, object, "id_token");
    errdefer if (id_token) |token| secureFree(allocator, token);
    const client_token = try duplicateResponseOrPrevious(
        allocator,
        object,
        "client_token",
        previous.client_token,
    );
    errdefer if (client_token) |token| secureFree(allocator, token);
    const lifetime = try tokenLifetime(object);

    return .{
        .allocator = allocator,
        .access_token = access_token,
        .refresh_token = refresh_token,
        .id_token = id_token,
        .client_token = client_token,
        .expires_at = try expiryFromLifetime(issued_at, lifetime),
    };
}

pub fn classifyPollError(allocator: std.mem.Allocator, data: []const u8) !PollError {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    const object = try rootObject(parsed.value);
    const code = try requiredString(object, "error");

    if (std.mem.eql(u8, code, "authorization_pending")) return .authorization_pending;
    if (std.mem.eql(u8, code, "slow_down")) return .slow_down;
    if (std.mem.eql(u8, code, "expired_token")) return .expired_token;
    if (std.mem.eql(u8, code, "access_denied")) return .access_denied;
    if (std.mem.eql(u8, code, "invalid_grant")) return .invalid_grant;
    return .other;
}

pub fn writePollErrorCode(
    allocator: std.mem.Allocator,
    data: []const u8,
    output: []u8,
) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return null;
    defer parsed.deinit();
    const code = requiredString(rootObject(parsed.value) catch return null, "error") catch return null;
    if (code.len == 0 or code.len > output.len) return null;
    for (code, 0..) |byte, index| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '.')
            return null;
        output[index] = byte;
    }
    return output[0..code.len];
}

fn rootObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.ExpectedObject,
    };
}

fn requiredString(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = object.get(name) orelse return error.MissingField;
    return switch (value) {
        .string => |text| if (text.len == 0) error.MissingField else text,
        else => error.InvalidField,
    };
}

fn duplicateRequiredString(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    name: []const u8,
) ![]u8 {
    return allocator.dupe(u8, try requiredString(object, name));
}

fn duplicateOptionalString(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    name: []const u8,
) !?[]u8 {
    const value = object.get(name) orelse return null;
    const text = switch (value) {
        .string => |candidate| candidate,
        .null => return null,
        else => return error.InvalidField,
    };
    if (text.len == 0) return null;
    return try allocator.dupe(u8, text);
}

fn duplicateResponseOrPrevious(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    name: []const u8,
    previous: ?[]const u8,
) !?[]u8 {
    if (try duplicateOptionalString(allocator, object, name)) |value| return value;
    if (previous) |value| return try allocator.dupe(u8, value);
    return null;
}

fn requiredUnsigned(object: std.json.ObjectMap, name: []const u8) !u32 {
    return optionalUnsigned(object, name) orelse error.MissingField;
}

fn requiredSigned(object: std.json.ObjectMap, name: []const u8) !i64 {
    const value = object.get(name) orelse return error.MissingField;
    return switch (value) {
        .integer => |number| number,
        else => error.InvalidField,
    };
}

fn optionalUnsigned(object: std.json.ObjectMap, name: []const u8) ?u32 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |number| if (number >= 0 and number <= std.math.maxInt(u32))
            @intCast(number)
        else
            null,
        else => null,
    };
}

fn tokenLifetime(object: std.json.ObjectMap) !u32 {
    if (!object.contains("expires_in")) return default_token_lifetime_seconds;
    return optionalUnsigned(object, "expires_in") orelse error.InvalidField;
}

fn secureFree(allocator: std.mem.Allocator, value: []u8) void {
    std.crypto.secureZero(u8, value);
    allocator.free(value);
}

fn expiryFromLifetime(issued_at: i64, lifetime: u32) !i64 {
    if (issued_at < 0) return error.InvalidTimestamp;
    return std.math.add(i64, issued_at, @as(i64, lifetime)) catch error.InvalidTimestamp;
}

test "builds NVIDIA device authorization and token forms" {
    var output: [512]u8 = undefined;
    const authorization = try buildDeviceAuthorizationForm(.{
        .client_id = "client id",
        .device_id = "device/1",
        .display_name = "GreenOvercast",
        .idp_id = "provider",
    }, &output);
    try std.testing.expectEqualStrings(
        "client_id=client+id&scope=openid+consent+email+tk_client+age&device_id=device%2F1&display_name=GreenOvercast&idp_id=provider",
        authorization,
    );

    const token = try buildDeviceTokenForm("client", "code+value", &output);
    try std.testing.expectEqualStrings(
        "client_id=client&device_code=code%2Bvalue&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code",
        token,
    );

    const client_token = try buildClientTokenForm("client", "device token", "user/id", &output);
    try std.testing.expectEqualStrings(
        "client_id=client&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Aclient_token&client_token=device+token&sub=user%2Fid",
        client_token,
    );
}

test "parses a device challenge" {
    var challenge = try parseDeviceChallenge(std.testing.allocator,
        \\{"device_code":"secret","user_code":"ABCD-EFGH","verification_uri":"https://example.test/link","expires_in":900}
    );
    defer challenge.deinit();

    try std.testing.expectEqualStrings("secret", challenge.device_code);
    try std.testing.expectEqualStrings("ABCD-EFGH", challenge.user_code);
    try std.testing.expectEqualStrings("https://example.test/link", challenge.verification_uri);
    try std.testing.expectEqual(@as(u32, 900), challenge.expires_in);
    try std.testing.expectEqual(@as(u32, 5), challenge.interval);
}

test "device challenge expiry handles delayed draws and tick wrap" {
    var challenge = try parseDeviceChallenge(std.testing.allocator,
        \\{"device_code":"test","user_code":"1234","verification_uri":"https://example.test/link","expires_in":2,"interval":5}
    );
    defer challenge.deinit();
    const started: u32 = std.math.maxInt(u32) - 500;
    try std.testing.expectEqual(@as(u32, 2), challenge.secondsRemaining(started, started));
    try std.testing.expectEqual(@as(u32, 1), challenge.secondsRemaining(started, started +% 1000));
    try std.testing.expectEqual(@as(u32, 0), challenge.secondsRemaining(started, started +% 2000));
    try std.testing.expectEqual(@as(u32, 0), challenge.secondsRemaining(started, started +% 4000));
}

test "refresh retains renewal credentials but never reuses an old bearer" {
    var previous = try parseGrantTokens(
        std.testing.allocator,
        "{\"access_token\":\"access-one\",\"refresh_token\":\"refresh-one\",\"id_token\":\"id-one\",\"client_token\":\"client-one\",\"expires_in\":3600}",
        1_000,
    );
    defer previous.deinit();

    var refreshed = try mergeRefreshedTokens(
        std.testing.allocator,
        &previous,
        "{\"access_token\":\"access-two\",\"expires_in\":7200}",
        2_000,
    );
    defer refreshed.deinit();

    try std.testing.expectEqualStrings("access-two", refreshed.access_token);
    try std.testing.expectEqualStrings("refresh-one", refreshed.refresh_token.?);
    try std.testing.expect(refreshed.id_token == null);
    try std.testing.expectEqualStrings("client-one", refreshed.client_token.?);
    try std.testing.expectEqualStrings("access-two", refreshed.bearer());
    try std.testing.expectEqual(@as(i64, 9_200), refreshed.expires_at);
}

test "stored tokens retain their absolute expiry" {
    var tokens = try parseStoredTokens(std.testing.allocator,
        \\{"access_token":"access","expires_at":1234567890}
    );
    defer tokens.deinit();

    try std.testing.expectEqual(@as(i64, 1_234_567_890), tokens.expires_at);
    try std.testing.expect(!tokens.needsRefresh(1_234_566_000));
    try std.testing.expect(tokens.needsRefresh(1_234_567_400));
    try std.testing.expect(tokens.needsRefresh(1_234_567_890));
}

test "token lifetime defaults only when omitted in grant and refresh responses" {
    var previous = try parseGrantTokens(std.testing.allocator, "{\"access_token\":\"old\"}", 1000);
    defer previous.deinit();
    try std.testing.expectEqual(1000 + @as(i64, default_token_lifetime_seconds), previous.expires_at);

    var refreshed = try mergeRefreshedTokens(std.testing.allocator, &previous, "{\"access_token\":\"new\"}", 2000);
    defer refreshed.deinit();
    try std.testing.expectEqual(2000 + @as(i64, default_token_lifetime_seconds), refreshed.expires_at);

    for ([_]u32{ 0, 3600, std.math.maxInt(u32) }) |lifetime| {
        var buffer: [128]u8 = undefined;
        const data = try std.fmt.bufPrint(&buffer, "{{\"access_token\":\"new\",\"expires_in\":{d}}}", .{lifetime});
        var grant = try parseGrantTokens(std.testing.allocator, data, 2000);
        defer grant.deinit();
        var refresh = try mergeRefreshedTokens(std.testing.allocator, &previous, data, 2000);
        defer refresh.deinit();
        try std.testing.expectEqual(2000 + @as(i64, lifetime), grant.expires_at);
        try std.testing.expectEqual(grant.expires_at, refresh.expires_at);
    }
    for ([_][]const u8{ "-1", "4294967296", "3600.5", "null", "true", "\"3600\"" }) |value| {
        var buffer: [128]u8 = undefined;
        const data = try std.fmt.bufPrint(&buffer, "{{\"access_token\":\"new\",\"expires_in\":{s}}}", .{value});
        try std.testing.expectError(error.InvalidField, parseGrantTokens(std.testing.allocator, data, 2000));
        try std.testing.expectError(error.InvalidField, mergeRefreshedTokens(std.testing.allocator, &previous, data, 2000));
    }
}

test "stored tokens require an expiry" {
    try std.testing.expectError(
        error.MissingField,
        parseStoredTokens(std.testing.allocator, "{\"access_token\":\"access\"}"),
    );
}

test "rejects incomplete responses and classifies polling errors" {
    try std.testing.expectError(
        error.MissingField,
        parseDeviceChallenge(std.testing.allocator, "{\"user_code\":\"ABCD\"}"),
    );
    try std.testing.expectEqual(
        PollError.authorization_pending,
        try classifyPollError(std.testing.allocator, "{\"error\":\"authorization_pending\"}"),
    );
    try std.testing.expectEqual(
        PollError.other,
        try classifyPollError(std.testing.allocator, "{\"error\":\"server_error\"}"),
    );

    var error_buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "invalid_client",
        writePollErrorCode(
            std.testing.allocator,
            "{\"error\":\"invalid_client\",\"error_description\":\"details omitted\"}",
            &error_buffer,
        ).?,
    );
    try std.testing.expect(writePollErrorCode(
        std.testing.allocator,
        "{\"error\":\"unsafe value\"}",
        &error_buffer,
    ) == null);
}

test "parses a client token and JWT subject" {
    const client_token = try parseClientToken(
        std.testing.allocator,
        "{\"client_token\":\"device-credential\",\"expires_in\":86400}",
    );
    defer std.testing.allocator.free(client_token);
    try std.testing.expectEqualStrings("device-credential", client_token);

    const subject = try jwtSubject(
        std.testing.allocator,
        "eyJhbGciOiJub25lIn0.eyJzdWIiOiJ1c2VyLTEyMyJ9.signature",
    );
    defer std.testing.allocator.free(subject);
    try std.testing.expectEqualStrings("user-123", subject);
}
