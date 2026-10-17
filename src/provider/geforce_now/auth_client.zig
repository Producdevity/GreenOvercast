const std = @import("std");
const protocol = @import("auth_protocol.zig");
const provider_protocol = @import("provider_protocol.zig");
const uuid = @import("uuid");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("handheld_ui.h");
    @cInclude("http_client.h");
    @cInclude("token_store_adapter.h");
});

const max_config_length = 256;
const max_credential_length = 64 * 1024;

// Public identifiers for NVIDIA's device-code flow and game catalog.
const default_oauth_client_id = "q61ddeJrVt7O90Nl-P-N7I36yctih4Ml6FyXLrb6j-U";
const default_protocol_client_id = "ec7e38d4-03af-4b58-b131-cfb0495903ab";

pub const RefreshResult = enum {
    ok,
    reauth_required,
    failed,
};

const TokenGrantResult = union(enum) {
    ok: protocol.Tokens,
    rejected,
    failed,
};

const ClientTokenResult = enum {
    ok,
    rejected,
    failed,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    ui: *c.GoHandheldUi,
    oauth_client_id: []u8,
    protocol_client_id: []u8,
    credential_path: [:0]u8,
    key_path: [:0]u8,
    device_id_path: [:0]u8,
    device_id: [37]u8,
    provider: ?provider_protocol.Provider = null,
    tokens: ?protocol.Tokens = null,

    pub fn create(allocator: std.mem.Allocator, ui_pointer: *anyopaque) !*Client {
        const oauth_client_id = try loadConfig(
            allocator,
            std.posix.getenv("GREENOVERCAST_GFN_CLIENT_ID"),
            std.posix.getenv("GREENOVERCAST_GFN_CLIENT_ID_FILE"),
            default_oauth_client_id,
        );
        errdefer allocator.free(oauth_client_id);
        if (!validOpaqueId(oauth_client_id)) return error.InvalidClientId;

        const protocol_client_id = try loadConfig(
            allocator,
            std.posix.getenv("GREENOVERCAST_GFN_PROTOCOL_CLIENT_ID"),
            std.posix.getenv("GREENOVERCAST_GFN_PROTOCOL_CLIENT_ID_FILE"),
            default_protocol_client_id,
        );
        errdefer allocator.free(protocol_client_id);
        if (!validOpaqueId(protocol_client_id)) return error.InvalidClientId;

        const credential_path = try requiredEnvironmentCopy(allocator, "GREENOVERCAST_GFN_TOKEN_FILE");
        errdefer allocator.free(credential_path);
        const key_path = try requiredEnvironmentCopy(allocator, "GREENOVERCAST_GFN_TOKEN_KEY_FILE");
        errdefer allocator.free(key_path);
        const device_id_path = try requiredEnvironmentCopy(allocator, "GREENOVERCAST_GFN_DEVICE_ID_FILE");
        errdefer allocator.free(device_id_path);

        const client = try allocator.create(Client);
        errdefer allocator.destroy(client);
        client.* = .{
            .allocator = allocator,
            .ui = @ptrCast(ui_pointer),
            .oauth_client_id = oauth_client_id,
            .protocol_client_id = protocol_client_id,
            .credential_path = credential_path,
            .key_path = key_path,
            .device_id_path = device_id_path,
            .device_id = [_]u8{0} ** 37,
        };
        try client.loadOrCreateDeviceId();
        return client;
    }

    pub fn destroy(self: *Client) void {
        if (self.tokens) |*tokens| tokens.deinit();
        if (self.provider) |*provider| provider.deinit();
        self.allocator.free(self.oauth_client_id);
        self.allocator.free(self.protocol_client_id);
        self.allocator.free(self.credential_path);
        self.allocator.free(self.key_path);
        self.allocator.free(self.device_id_path);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn loadCredentials(self: *Client) !bool {
        var encrypted: [max_credential_length]u8 = [_]u8{0} ** max_credential_length;
        defer std.crypto.secureZero(u8, &encrypted);
        const result = c.go_token_store_load(
            @ptrCast(self.credential_path.ptr),
            @ptrCast(self.key_path.ptr),
            @ptrCast(&encrypted),
            encrypted.len,
        );
        if (result < 0) return error.CredentialLoadFailed;
        if (result == 0) return false;
        const data = std.mem.sliceTo(&encrypted, 0);
        var tokens = protocol.parseStoredTokens(self.allocator, data) catch |err| switch (err) {
            error.MissingField => return false,
            else => return err,
        };
        errdefer tokens.deinit();
        if (self.tokens) |*previous| previous.deinit();
        self.tokens = tokens;
        return true;
    }

    pub fn signIn(self: *Client) !bool {
        try self.discoverProvider();
        const provider = &self.provider.?;
        var form_buffer: [4096]u8 = undefined;
        const body = try protocol.buildDeviceAuthorizationForm(.{
            .client_id = self.oauth_client_id,
            .device_id = std.mem.sliceTo(&self.device_id, 0),
            .display_name = "GreenOvercast",
            .idp_id = provider.idp_id,
        }, &form_buffer);

        var dynamic_headers: [8][256]u8 = undefined;
        var headers = [_][*c]const u8{
            "Accept: application/json, text/plain, */*",
            "Content-Type: application/x-www-form-urlencoded",
            "Origin: https://play.geforcenow.com",
            "Referer: https://play.geforcenow.com/",
            try header(&dynamic_headers[0], "x-device-id", std.mem.sliceTo(&self.device_id, 0)),
            try header(&dynamic_headers[1], "nv-client-id", self.oauth_client_id),
            "nv-client-streamer: WEBRTC",
            "nv-client-type: BROWSER",
            "nv-client-platform-name: browser",
            "nv-browser-type: CHROME",
            "nv-device-os: STEAMOS",
            "nv-device-type: CONSOLE",
            "nv-device-model: STEAMDECK",
            "nv-device-make: VALVE",
            "User-Agent: Mozilla/5.0 (X11; Linux x86_64; Steam Deck) AppleWebKit/537.36 Chrome/128.0.0.0 Safari/537.36",
        };

        c.go_handheld_ui_draw_loading(
            self.ui,
            "GEFORCE NOW SIGN IN",
            "REQUESTING A DEVICE CODE",
            c.GO_HANDHELD_UI_ACTION_BACK,
        );
        var response = c.go_http_request(
            "POST",
            protocol.device_authorization_endpoint,
            body.ptr,
            @ptrCast(&headers),
            headers.len,
        );
        defer c.go_http_response_destroy(response);
        if (!successful(response)) return error.DeviceAuthorizationFailed;
        var challenge = try protocol.parseDeviceChallenge(self.allocator, responseData(response).?);
        defer challenge.deinit();
        c.go_http_response_destroy(response);
        response = null;

        const address_value = challenge.verification_uri;
        var address_buffer: [256]u8 = undefined;
        const address = try std.fmt.bufPrintZ(&address_buffer, "{s}", .{address_value});
        var code_buffer: [96]u8 = undefined;
        const user_code = try std.fmt.bufPrintZ(&code_buffer, "{s}", .{challenge.user_code});
        var interval = @max(challenge.interval, 1);
        const started = c.SDL_GetTicks();
        var last_poll = started;
        while (true) {
            const now = c.SDL_GetTicks();
            const remaining = challenge.secondsRemaining(started, now);
            if (remaining == 0) return error.CodeExpired;
            c.go_handheld_ui_draw_device_code_for(
                self.ui,
                "GEFORCE NOW SIGN IN",
                address.ptr,
                user_code.ptr,
                "WAITING FOR APPROVAL",
                remaining,
            );
            if (c.go_handheld_ui_sign_in_action(self.ui) < 0) return false;
            if ((now -% last_poll) / 1000 < interval) {
                c.SDL_Delay(16);
                continue;
            }

            const poll_body = try protocol.buildDeviceTokenForm(
                self.oauth_client_id,
                challenge.device_code,
                &form_buffer,
            );
            response = c.go_http_request(
                "POST",
                protocol.token_endpoint,
                poll_body.ptr,
                @ptrCast(&headers),
                headers.len,
            );
            last_poll = c.SDL_GetTicks();
            if (successful(response)) {
                var tokens = try protocol.parseGrantTokens(
                    self.allocator,
                    responseData(response).?,
                    std.time.timestamp(),
                );
                c.go_http_response_destroy(response);
                response = null;
                _ = self.fetchClientToken(&tokens, tokens.access_token);
                if (self.tokens) |*previous| previous.deinit();
                self.tokens = tokens;
                self.saveCredentials() catch |err| {
                    self.tokens = null;
                    tokens.deinit();
                    return err;
                };
                c.go_handheld_ui_draw_loading(
                    self.ui,
                    "SIGNED IN",
                    "OPENING YOUR GEFORCE NOW LIBRARY",
                    c.GO_HANDHELD_UI_ACTION_NONE,
                );
                c.SDL_Delay(700);
                return true;
            }

            const poll_error = if (responseData(response)) |data|
                protocol.classifyPollError(self.allocator, data) catch .other
            else
                .other;
            const status = if (response) |value| value.*.status else 0;
            var error_code_buffer: [64]u8 = undefined;
            const error_code = if (responseData(response)) |data|
                protocol.writePollErrorCode(self.allocator, data, &error_code_buffer)
            else
                null;
            c.go_http_response_destroy(response);
            response = null;
            switch (poll_error) {
                .authorization_pending => {},
                .slow_down => interval +|= 5,
                else => {
                    std.debug.print(
                        "GeForce NOW token exchange failed: HTTP {d} ({s})\n",
                        .{ status, error_code orelse @tagName(poll_error) },
                    );
                    return switch (poll_error) {
                        .expired_token => error.CodeExpired,
                        .access_denied => error.AccessDenied,
                        else => error.TokenRequestFailed,
                    };
                },
            }
        }
    }

    pub fn refresh(self: *Client) RefreshResult {
        const previous = if (self.tokens) |*tokens| tokens else return .reauth_required;
        if (self.provider == null) self.discoverProvider() catch return .failed;
        if (!previous.needsRefresh(std.time.timestamp())) return .ok;

        var form_buffer: [max_credential_length]u8 = undefined;
        if (previous.client_token == null) {
            const token_value = previous.id_token orelse previous.access_token;
            switch (self.fetchClientToken(previous, token_value)) {
                .ok => {},
                .rejected => if (previous.refresh_token == null) return .reauth_required,
                .failed => if (previous.refresh_token == null) return .failed,
            }
        }

        if (previous.client_token) |client_token| {
            const subject = protocol.jwtSubject(self.allocator, previous.bearer()) catch null;
            if (subject) |value| {
                defer self.allocator.free(value);
                const body = protocol.buildClientTokenForm(
                    self.oauth_client_id,
                    client_token,
                    value,
                    &form_buffer,
                ) catch return .failed;
                switch (self.performTokenGrant(body, previous)) {
                    .ok => |refreshed| return self.finishRefresh(refreshed),
                    .rejected, .failed => {},
                }
            }
        }

        const refresh_token = previous.refresh_token orelse return .reauth_required;
        const body = protocol.buildRefreshTokenForm(
            self.oauth_client_id,
            refresh_token,
            &form_buffer,
        ) catch return .failed;
        return switch (self.performTokenGrant(body, previous)) {
            .ok => |refreshed| self.finishRefresh(refreshed),
            .rejected => .reauth_required,
            .failed => .failed,
        };
    }

    pub fn signOut(self: *Client) !void {
        if (c.go_token_store_delete(
            @ptrCast(self.credential_path.ptr),
            @ptrCast(self.key_path.ptr),
        ) != 0) return error.CredentialDeleteFailed;
        if (self.tokens) |*tokens| tokens.deinit();
        self.tokens = null;
    }

    pub fn bearer(self: *const Client) ?[]const u8 {
        return if (self.tokens) |*tokens| tokens.bearer() else null;
    }

    pub fn userId(self: *const Client, allocator: std.mem.Allocator) ![]u8 {
        return protocol.jwtSubject(allocator, self.bearer() orelse return error.MissingCredentials);
    }

    pub fn fetchUserAge(self: *const Client) !u8 {
        const tokens = if (self.tokens) |*value| value else return error.MissingCredentials;
        const subject = try self.userId(self.allocator);
        defer self.allocator.free(subject);
        const authorization = try std.fmt.allocPrintZ(self.allocator, "Authorization: Bearer {s}", .{tokens.access_token});
        defer {
            std.crypto.secureZero(u8, authorization);
            self.allocator.free(authorization);
        }
        var headers = [_][*c]const u8{ authorization.ptr, "Accept: application/json" };
        const response = c.go_http_request_bounded_cancelable(
            "GET",
            protocol.user_info_endpoint,
            null,
            @ptrCast(&headers),
            headers.len,
            max_credential_length,
            cancelUserInfoRequest,
            self.ui,
        ) orelse {
            if (c.go_handheld_ui_cancelled(self.ui) != 0) return error.Cancelled;
            return error.UserInfoRequestFailed;
        };
        defer {
            if (responseData(response)) |data| std.crypto.secureZero(u8, @constCast(data));
            c.go_http_response_destroy(response);
        }
        if (response.*.status != 200) {
            std.debug.print("GeForce NOW account lookup failed: HTTP {d}\n", .{response.*.status});
            return error.UserInfoRequestFailed;
        }
        return protocol.parseUserAge(self.allocator, responseData(response) orelse return error.MissingUserAge, subject);
    }

    pub fn protocolClientId(self: *const Client) []const u8 {
        return self.protocol_client_id;
    }

    pub fn streamingUrl(self: *const Client) ?[]const u8 {
        return if (self.provider) |*provider| provider.streaming_url else null;
    }

    pub fn stableDeviceId(self: *const Client) []const u8 {
        return std.mem.sliceTo(&self.device_id, 0);
    }

    fn discoverProvider(self: *Client) !void {
        var headers = [_][*c]const u8{
            "Accept: application/json",
            "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/128.0.0.0 Safari/537.36",
        };
        const response = c.go_http_request(
            "GET",
            provider_protocol.service_urls_endpoint,
            null,
            @ptrCast(&headers),
            headers.len,
        );
        defer c.go_http_response_destroy(response);
        if (!successful(response)) return error.ProviderDiscoveryFailed;
        var provider = try provider_protocol.parsePreferredProvider(
            self.allocator,
            responseData(response).?,
        );
        errdefer provider.deinit();
        if (self.provider) |*previous| previous.deinit();
        self.provider = provider;
    }

    fn saveCredentials(self: *Client) !void {
        const tokens = if (self.tokens) |*value| value else return error.MissingCredentials;
        const serialized = try std.json.stringifyAlloc(self.allocator, .{
            .access_token = tokens.access_token,
            .refresh_token = tokens.refresh_token,
            .id_token = tokens.id_token,
            .client_token = tokens.client_token,
            .expires_at = tokens.expires_at,
        }, .{ .emit_null_optional_fields = true });
        defer {
            std.crypto.secureZero(u8, serialized);
            self.allocator.free(serialized);
        }
        const terminated = try self.allocator.allocSentinel(u8, serialized.len, 0);
        defer {
            std.crypto.secureZero(u8, terminated);
            self.allocator.free(terminated);
        }
        @memcpy(terminated[0..serialized.len], serialized);
        if (c.go_token_store_save(
            @ptrCast(self.credential_path.ptr),
            @ptrCast(self.key_path.ptr),
            terminated.ptr,
        ) != 0) return error.CredentialSaveFailed;
    }

    fn fetchClientToken(
        self: *Client,
        tokens: *protocol.Tokens,
        token_value: []const u8,
    ) ClientTokenResult {
        if (tokens.client_token != null) return .ok;
        const authorization = std.fmt.allocPrintZ(
            self.allocator,
            "Authorization: Bearer {s}",
            .{token_value},
        ) catch return .failed;
        defer {
            std.crypto.secureZero(u8, authorization);
            self.allocator.free(authorization);
        }
        var headers = [_][*c]const u8{
            authorization.ptr,
            "Accept: application/json, text/plain, */*",
            "Origin: https://play.geforcenow.com",
            "Referer: https://play.geforcenow.com/",
        };
        const response = c.go_http_request_bounded(
            "GET",
            protocol.client_token_endpoint,
            null,
            @ptrCast(&headers),
            headers.len,
            1024 * 1024,
        );
        defer c.go_http_response_destroy(response);
        if (!successful(response)) {
            if (response != null and (response.*.status == 401 or response.*.status == 403))
                return .rejected;
            return .failed;
        }
        tokens.client_token = protocol.parseClientToken(
            self.allocator,
            responseData(response).?,
        ) catch return .failed;
        return .ok;
    }

    fn performTokenGrant(
        self: *Client,
        body: [:0]const u8,
        previous: *const protocol.Tokens,
    ) TokenGrantResult {
        var headers = [_][*c]const u8{
            "Accept: application/json, text/plain, */*",
            "Content-Type: application/x-www-form-urlencoded",
            "Origin: https://play.geforcenow.com",
            "Referer: https://play.geforcenow.com/",
        };
        const response = c.go_http_request(
            "POST",
            protocol.token_endpoint,
            body.ptr,
            @ptrCast(&headers),
            headers.len,
        );
        defer c.go_http_response_destroy(response);
        if (!successful(response)) {
            const status = if (response) |value| value.*.status else 0;
            var error_code_buffer: [64]u8 = undefined;
            const error_code = if (responseData(response)) |data|
                protocol.writePollErrorCode(self.allocator, data, &error_code_buffer)
            else
                null;
            std.debug.print(
                "GeForce NOW token grant failed: HTTP {d} ({s})\n",
                .{ status, error_code orelse "unknown" },
            );
            const failure = if (responseData(response)) |data|
                protocol.classifyPollError(self.allocator, data) catch .other
            else
                .other;
            return if (failure == .invalid_grant or failure == .access_denied)
                .rejected
            else
                .failed;
        }
        const refreshed = protocol.mergeRefreshedTokens(
            self.allocator,
            previous,
            responseData(response).?,
            std.time.timestamp(),
        ) catch return .failed;
        return .{ .ok = refreshed };
    }

    fn finishRefresh(self: *Client, refreshed: protocol.Tokens) RefreshResult {
        if (self.tokens) |*previous| previous.deinit();
        self.tokens = refreshed;
        self.saveCredentials() catch return .failed;
        return .ok;
    }

    fn loadOrCreateDeviceId(self: *Client) !void {
        const file = std.fs.cwd().openFile(self.device_id_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return self.createDeviceId(),
            else => return err,
        };
        defer file.close();
        var contents: [64]u8 = undefined;
        const length = try file.readAll(&contents);
        const value = std.mem.trim(u8, contents[0..length], " \t\r\n");
        if (!uuid.valid(value)) return error.InvalidDeviceId;
        @memcpy(self.device_id[0..value.len], value);
    }

    fn createDeviceId(self: *Client) !void {
        uuid.generate(&self.device_id);
        const value = std.mem.sliceTo(&self.device_id, 0);
        var temporary_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const temporary_path = try std.fmt.bufPrint(
            &temporary_path_buffer,
            "{s}.tmp",
            .{self.device_id_path},
        );
        const cwd = std.fs.cwd();
        errdefer cwd.deleteFile(temporary_path) catch {};
        {
            var file = try cwd.createFile(temporary_path, .{
                .truncate = true,
                .mode = 0o600,
            });
            defer file.close();
            try file.writeAll(value);
            try file.writeAll("\n");
            try file.sync();
        }
        try cwd.rename(temporary_path, self.device_id_path);
    }
};

fn cancelUserInfoRequest(context: ?*anyopaque) callconv(.c) c_int {
    const ui: *c.GoHandheldUi = @ptrCast(@alignCast(context orelse return 1));
    return c.go_handheld_ui_cancel_requested(ui);
}

fn loadConfig(
    allocator: std.mem.Allocator,
    configured_value: ?[]const u8,
    configured_path: ?[]const u8,
    default_value: []const u8,
) ![]u8 {
    if (configured_value) |value| {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 0 or trimmed.len > max_config_length) return error.InvalidConfig;
        return allocator.dupe(u8, trimmed);
    }
    const path = configured_path orelse return allocator.dupe(u8, default_value);
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const data = try file.readToEndAlloc(allocator, max_config_length);
    defer allocator.free(data);
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidConfig;
    return allocator.dupe(u8, trimmed);
}

fn requiredEnvironmentCopy(allocator: std.mem.Allocator, name: []const u8) ![:0]u8 {
    const value = std.posix.getenv(name) orelse return error.MissingConfig;
    if (value.len == 0 or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidConfig;
    return allocator.dupeZ(u8, value);
}

fn validOpaqueId(value: []const u8) bool {
    if (value.len < 20 or value.len > 128) return false;
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
    }
    return true;
}

fn successful(response: [*c]c.GoHttpResponse) bool {
    return c.go_http_response_succeeded(response) != 0 and responseData(response) != null;
}

fn responseData(response: [*c]c.GoHttpResponse) ?[]const u8 {
    if (response == null or response.*.data == null) return null;
    return response.*.data[0..response.*.len];
}

fn header(output: []u8, name: []const u8, value: []const u8) ![*c]const u8 {
    const result = try std.fmt.bufPrintZ(output, "{s}: {s}", .{ name, value });
    return result.ptr;
}

test "validates opaque service identifiers" {
    try std.testing.expect(validOpaqueId(default_oauth_client_id));
    try std.testing.expect(validOpaqueId(default_protocol_client_id));
    try std.testing.expect(validOpaqueId("sample-client-id_0123456789"));
    try std.testing.expect(validOpaqueId("12345678-1234-4abc-8def-123456789abc"));
    try std.testing.expect(!validOpaqueId("short"));
    try std.testing.expect(!validOpaqueId("invalid value with spaces"));
}

test "service identifiers have defaults and explicit overrides take priority" {
    const allocator = std.testing.allocator;
    const fallback = try loadConfig(allocator, null, null, default_oauth_client_id);
    defer allocator.free(fallback);
    try std.testing.expectEqualStrings(default_oauth_client_id, fallback);

    const override = try loadConfig(allocator, "  configured-id  \n", "/nonexistent", default_oauth_client_id);
    defer allocator.free(override);
    try std.testing.expectEqualStrings("configured-id", override);
    try std.testing.expectError(error.InvalidConfig, loadConfig(allocator, " \n", null, default_oauth_client_id));
    try std.testing.expectError(error.FileNotFound, loadConfig(allocator, null, "/nonexistent", default_oauth_client_id));
}

test "service identifier files are trimmed and cannot silently replace invalid values with defaults" {
    const allocator = std.testing.allocator;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try directory.dir.writeFile(.{ .sub_path = "client-id", .data = " file-client-id\r\n" });
    const path = try directory.dir.realpathAlloc(allocator, "client-id");
    defer allocator.free(path);
    const value = try loadConfig(allocator, null, path, default_oauth_client_id);
    defer allocator.free(value);
    try std.testing.expectEqualStrings("file-client-id", value);
    try directory.dir.writeFile(.{ .sub_path = "client-id", .data = " \n" });
    try std.testing.expectError(error.InvalidConfig, loadConfig(allocator, null, path, default_oauth_client_id));
    try directory.dir.writeFile(.{ .sub_path = "client-id", .data = &([_]u8{'x'} ** (max_config_length + 1)) });
    try std.testing.expectError(error.FileTooBig, loadConfig(allocator, null, path, default_oauth_client_id));
}

test "validates stable device identifiers" {
    try std.testing.expect(uuid.valid("12345678-1234-4abc-8def-123456789abc"));
    try std.testing.expect(!uuid.valid("12345678-1234-4abc-8def"));
}

test "account lookup preserves cancellation consumed by the transfer callback" {
    const http = @import("gfn_http_fake");
    http.reset();
    const client = http.authClient(Client);
    try std.testing.expectError(error.Cancelled, client.fetchUserAge());
    try std.testing.expectEqual(@as(usize, 1), http.requests);
    try std.testing.expectEqual(@as(usize, 1), http.polls);
}
