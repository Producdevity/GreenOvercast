const std = @import("std");
const auth_client = @import("auth_client.zig");
const protocol = @import("cloudmatch_protocol.zig");
const subscription = @import("subscription_protocol.zig");
const uuid = @import("uuid");

const c = @cImport({
    @cInclude("handheld_ui.h");
    @cInclude("http_client.h");
});

const maximum_create_attempts = 6;
const client_version = "2.0.80.173";
const user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " ++
    "(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 NVIDIACEFClient/HEAD/debb5919f6 " ++
    "GFN-PC/" ++ client_version;

const fallback_stream_width: u16 = 1024;
const fallback_stream_height: u16 = 768;
const preferred_frames_per_second: u16 = 30;
const maximum_stream_width: u16 = 1280;
const maximum_stream_height: u16 = 768;
const maximum_bearer_length = 64 * 1024;

pub const Client = struct {
    allocator: std.mem.Allocator,
    auth: *auth_client.Client,
    ui: *c.GoHandheldUi,
    client_id: [uuid.string_length + 1]u8,
    session: ?protocol.Session = null,
    streaming_url: ?[]u8 = null,
    last_http_status: c_long = 0,
    last_response_retryable: ?bool = null,
    stream_width: u16 = fallback_stream_width,
    stream_height: u16 = fallback_stream_height,
    stream_frames_per_second: u16 = preferred_frames_per_second,

    pub fn create(
        allocator: std.mem.Allocator,
        auth: *auth_client.Client,
        ui_pointer: *anyopaque,
    ) !*Client {
        const client = try allocator.create(Client);
        client.* = .{
            .allocator = allocator,
            .auth = auth,
            .ui = @ptrCast(ui_pointer),
            .client_id = undefined,
        };
        uuid.generate(&client.client_id);
        return client;
    }

    pub fn destroy(self: *Client) void {
        if (self.session) |*session| session.deinit();
        if (self.streaming_url) |url| self.allocator.free(url);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn start(
        self: *Client,
        app_id: []const u8,
        internal_title: []const u8,
        width: u16,
        height: u16,
    ) !void {
        if (self.session != null) return error.SessionAlreadyActive;
        uuid.generate(&self.client_id);
        const bearer = self.auth.bearer() orelse return error.MissingCredentials;
        const provider_url = self.auth.streamingUrl() orelse return error.MissingProvider;
        const user_age = try self.auth.fetchUserAge();
        try self.selectStreamMode(provider_url, bearer, width, height);
        if (self.streaming_url) |url| self.allocator.free(url);
        self.streaming_url = null;
        self.streaming_url = self.resolveStreamingUrl(provider_url, bearer) catch |err| fallback: {
            std.debug.print("GeForce NOW region discovery failed: {s}\n", .{@errorName(err)});
            break :fallback try self.allocator.dupe(u8, provider_url);
        };
        const local_url = self.streaming_url.?;
        if (!std.mem.eql(u8, local_url, provider_url))
            std.debug.print("GeForce NOW local streaming region selected\n", .{});

        const body = try protocol.buildSessionRequest(
            self.allocator,
            app_id,
            internal_title,
            self.auth.stableDeviceId(),
            self.stream_width,
            self.stream_height,
            self.stream_frames_per_second,
            user_age,
        );
        defer self.allocator.free(body);
        self.session = self.createSessionWithRetry(local_url, body, bearer) catch |err| retry: {
            if (err == error.Cancelled) return err;
            if (std.mem.eql(u8, local_url, provider_url) or
                !retryableRequestFailure(
                    err,
                    self.last_http_status,
                    self.last_response_retryable,
                ))
            {
                self.logActiveSessions(provider_url, bearer, app_id);
                return err;
            }
            std.debug.print("GeForce NOW local region rejected the session; retrying provider endpoint\n", .{});
            const fallback_url = try self.allocator.dupe(u8, provider_url);
            self.allocator.free(self.streaming_url.?);
            self.streaming_url = fallback_url;
            break :retry self.createSession(provider_url, body, bearer) catch |provider_error| {
                self.logActiveSessions(provider_url, bearer, app_id);
                return provider_error;
            };
        };
    }

    pub fn waitUntilReady(self: *Client) !void {
        var consecutive_server_errors: usize = 0;
        while (true) {
            const current = if (self.session) |*session| session else return error.MissingSession;
            if (current.ended()) return error.SessionEnded;
            if (current.ready() and current.signaling_url != null) return;
            self.drawProgress(current);
            if (c.go_handheld_ui_wait(self.ui, pollDelay(consecutive_server_errors)) != 0)
                return error.Cancelled;

            const bearer = self.auth.bearer() orelse return error.MissingCredentials;
            const base = self.streaming_url orelse return error.MissingProvider;
            var url_buffer: [768]u8 = undefined;
            const url = try std.fmt.bufPrintZ(
                &url_buffer,
                "{s}v2/session/{s}",
                .{ base, current.id },
            );
            const response = self.request("GET", url, null, bearer) catch |err| {
                if (!retryableRequestFailure(err, self.last_http_status, self.last_response_retryable))
                    return err;
                consecutive_server_errors += 1;
                if (consecutive_server_errors > 12) return error.SessionPollFailed;
                continue;
            };
            defer c.go_http_response_destroy(response);
            consecutive_server_errors = 0;
            const next = try protocol.parseSession(
                self.allocator,
                response.*.data[0..response.*.len],
            );
            current.deinit();
            self.session = next;
        }
    }

    pub fn stop(self: *Client) !void {
        const session = if (self.session) |*value| value else return;
        defer {
            session.deinit();
            self.session = null;
        }
        const bearer = self.auth.bearer() orelse return error.MissingCredentials;
        const base = self.streaming_url orelse return error.MissingProvider;
        var url_buffer: [768]u8 = undefined;
        const url = try std.fmt.bufPrintZ(
            &url_buffer,
            "{s}v2/session/{s}",
            .{ base, session.id },
        );
        const response = try self.request("DELETE", url, null, bearer);
        c.go_http_response_destroy(response);
    }

    pub fn sessionInfo(self: *Client) ?*const protocol.Session {
        return if (self.session) |*session| session else null;
    }

    pub fn clientId(self: *const Client) []const u8 {
        return std.mem.sliceTo(&self.client_id, 0);
    }

    pub fn streamWidth(self: *const Client) u16 {
        return self.stream_width;
    }

    pub fn streamHeight(self: *const Client) u16 {
        return self.stream_height;
    }

    pub fn streamFramesPerSecond(self: *const Client) u16 {
        return self.stream_frames_per_second;
    }

    fn request(
        self: *Client,
        method: [*:0]const u8,
        url: [:0]const u8,
        body: ?[]const u8,
        bearer: []const u8,
    ) ![*c]c.GoHttpResponse {
        const terminated_body = if (body) |value| try self.allocator.dupeZ(u8, value) else null;
        defer if (terminated_body) |value| self.allocator.free(value);
        const authorization = try authorizationHeader(self.allocator, bearer);
        defer secureFree(self.allocator, authorization);
        var dynamic_headers: [2][256]u8 = undefined;
        var headers = [_][*c]const u8{
            authorization.ptr,
            try header(&dynamic_headers[0], "nv-client-id", null, self.clientId()),
            try header(&dynamic_headers[1], "x-device-id", null, self.auth.stableDeviceId()),
            "Accept: application/json",
            "Content-Type: application/json",
            "Connection: close",
            "Origin: https://play.geforcenow.com",
            "Referer: https://play.geforcenow.com/",
            "nv-browser-type: CHROME",
            "nv-client-streamer: NVIDIA-CLASSIC",
            "nv-client-type: NATIVE",
            "nv-client-version: 30.0",
            "nv-device-make: UNKNOWN",
            "nv-device-model: UNKNOWN",
            "nv-device-os: WINDOWS",
            "nv-device-type: DESKTOP",
            "User-Agent: " ++ user_agent,
        };
        self.last_http_status = 0;
        self.last_response_retryable = null;
        // Session deletion must finish after a local stop request.
        const cancelable = !std.mem.eql(u8, std.mem.span(method), "DELETE");
        const response = c.go_http_request_bounded_cancelable(
            method,
            url.ptr,
            if (terminated_body) |value| value.ptr else null,
            @ptrCast(&headers),
            headers.len,
            8 * 1024 * 1024,
            if (cancelable) requestCancelled else null,
            self,
        );
        if (response == null) {
            if (cancelable and c.go_handheld_ui_cancelled(self.ui) != 0) return error.Cancelled;
            return error.HttpRequestFailed;
        }
        self.last_http_status = response.*.status;
        if (response.*.status < 200 or response.*.status >= 300 or
            (cancelable and response.*.data == null))
        {
            const status = response.*.status;
            std.debug.print("GeForce NOW session request failed: HTTP {d}\n", .{status});
            if (response.*.data != null) {
                self.last_response_retryable = protocol.sessionFailureIsRetryable(
                    self.allocator,
                    response.*.data[0..response.*.len],
                );
                var summary_buffer: [384]u8 = undefined;
                if (protocol.writeErrorSummary(
                    self.allocator,
                    response.*.data[0..response.*.len],
                    &summary_buffer,
                )) |summary| std.debug.print("GeForce NOW session error: {s}\n", .{summary});
            }
            c.go_http_response_destroy(response);
            return error.HttpRequestRejected;
        }
        return response;
    }

    fn createSession(
        self: *Client,
        base: []const u8,
        body: []const u8,
        bearer: []const u8,
    ) !protocol.Session {
        var url_buffer: [768]u8 = undefined;
        const url = try buildCreateSessionUrl(&url_buffer, base);
        const response = try self.request("POST", url, body, bearer);
        defer c.go_http_response_destroy(response);
        return protocol.parseSession(
            self.allocator,
            response.*.data[0..response.*.len],
        );
    }

    fn createSessionWithRetry(
        self: *Client,
        base: []const u8,
        body: []const u8,
        bearer: []const u8,
    ) !protocol.Session {
        var attempt: usize = 0;
        while (attempt < maximum_create_attempts) : (attempt += 1) {
            if (self.createSession(base, body, bearer)) |session| {
                return session;
            } else |err| {
                if (err == error.Cancelled or
                    attempt + 1 >= maximum_create_attempts or
                    !retryableRequestFailure(
                        err,
                        self.last_http_status,
                        self.last_response_retryable,
                    ))
                    return err;

                const delay = createRetryDelay(attempt);
                std.debug.print(
                    "GeForce NOW session creation retry {d}/{d} in {d} seconds\n",
                    .{ attempt + 2, maximum_create_attempts, delay / 1000 },
                );
                c.go_handheld_ui_draw_loading(
                    self.ui,
                    "NVIDIA SERVER BUSY",
                    "RETRYING SESSION REQUEST",
                    c.GO_HANDHELD_UI_ACTION_CANCEL,
                );
                if (c.go_handheld_ui_wait(self.ui, delay) != 0)
                    return error.Cancelled;
            }
        }
        unreachable;
    }

    fn logActiveSessions(
        self: *Client,
        base: []const u8,
        bearer: []const u8,
        app_id: []const u8,
    ) void {
        var url_buffer: [768]u8 = undefined;
        const url = std.fmt.bufPrintZ(&url_buffer, "{s}v2/session", .{base}) catch return;
        const response = self.request("GET", url, null, bearer) catch return;
        defer c.go_http_response_destroy(response);
        const summary = protocol.parseActiveSessionSummary(
            self.allocator,
            response.*.data[0..response.*.len],
            self.auth.stableDeviceId(),
            app_id,
        ) catch return;
        std.debug.print(
            "GeForce NOW active sessions: {d} total, {d} from this device, {d} for this game\n",
            .{ summary.active, summary.same_device, summary.matching_app },
        );
    }

    fn selectStreamMode(
        self: *Client,
        provider_url: []const u8,
        bearer: []const u8,
        display_width: u16,
        display_height: u16,
    ) !void {
        self.stream_width = fallback_stream_width;
        self.stream_height = fallback_stream_height;
        self.stream_frames_per_second = preferred_frames_per_second;
        const summary = self.fetchSubscriptionStatus(provider_url, bearer) catch |err| {
            if (err == error.Cancelled) return err;
            std.debug.print("GeForce NOW membership check unavailable: {s}\n", .{@errorName(err)});
            return;
        };
        std.debug.print(
            "GeForce NOW membership: {s}, state: {s}, gameplay allowed: {s}, entitled resolutions: {d}\n",
            .{
                summary.tier(),
                summary.state(),
                if (summary.gameplay_allowed) |allowed|
                    if (allowed) "yes" else "no"
                else
                    "unknown",
                summary.entitled_resolutions,
            },
        );
        if (summary.bestForDisplayWithin(
            display_width,
            display_height,
            preferred_frames_per_second,
            maximum_stream_width,
            maximum_stream_height,
        )) |selected| {
            self.stream_width = selected.width;
            self.stream_height = selected.height;
            self.stream_frames_per_second = selected.frames_per_second;
            std.debug.print(
                "GeForce NOW stream mode: {d}x{d}@{d} for {d}x{d} display\n",
                .{
                    selected.width,
                    selected.height,
                    selected.frames_per_second,
                    display_width,
                    display_height,
                },
            );
        }
    }

    fn fetchSubscriptionStatus(
        self: *Client,
        provider_url: []const u8,
        bearer: []const u8,
    ) !subscription.Summary {
        const user_id = try self.auth.userId(self.allocator);
        defer self.allocator.free(user_id);
        if (!validQueryValue(user_id)) return error.InvalidUserId;

        var server_info_url_buffer: [768]u8 = undefined;
        const server_info_url = try std.fmt.bufPrintZ(
            &server_info_url_buffer,
            "{s}v2/serverInfo",
            .{provider_url},
        );
        const server_info_response = try self.request("GET", server_info_url, null, bearer);
        defer c.go_http_response_destroy(server_info_response);
        const vpc_id = try protocol.parseVpcId(
            self.allocator,
            server_info_response.*.data[0..server_info_response.*.len],
        );
        defer self.allocator.free(vpc_id);
        if (!validQueryValue(vpc_id)) return error.InvalidVpcId;

        var url_buffer: [1024]u8 = undefined;
        const url = try std.fmt.bufPrintZ(
            &url_buffer,
            "https://mes.geforcenow.com/v4/subscriptions?serviceName=gfn_pc&languageCode=en_US&vpcId={s}&userId={s}",
            .{ vpc_id, user_id },
        );
        const authorization = try authorizationHeader(self.allocator, bearer);
        defer secureFree(self.allocator, authorization);
        var client_id_buffer: [256]u8 = undefined;
        var headers = [_][*c]const u8{
            authorization.ptr,
            try header(&client_id_buffer, "nv-client-id", null, self.auth.protocolClientId()),
            "Accept: application/json",
            "nv-client-streamer: NVIDIA-CLASSIC",
            "nv-client-type: NATIVE",
            "nv-client-version: " ++ client_version,
            "nv-device-os: LINUX",
            "nv-device-type: DESKTOP",
            "User-Agent: " ++ user_agent,
        };
        const response = c.go_http_request_bounded(
            "GET",
            url.ptr,
            null,
            @ptrCast(&headers),
            headers.len,
            1024 * 1024,
        );
        defer c.go_http_response_destroy(response);
        if (response == null or response.*.status < 200 or response.*.status >= 300 or
            response.*.data == null)
        {
            const status = if (response) |value| value.*.status else 0;
            std.debug.print("GeForce NOW membership check failed: HTTP {d}\n", .{status});
            return error.SubscriptionRequestFailed;
        }
        return subscription.parse(
            self.allocator,
            response.*.data[0..response.*.len],
        );
    }

    fn resolveStreamingUrl(
        self: *Client,
        provider_url: []const u8,
        bearer: []const u8,
    ) ![]u8 {
        var url_buffer: [768]u8 = undefined;
        const url = try std.fmt.bufPrintZ(&url_buffer, "{s}v2/serverInfo", .{provider_url});
        const authorization = try authorizationHeader(self.allocator, bearer);
        defer secureFree(self.allocator, authorization);
        var dynamic_headers: [2][256]u8 = undefined;
        var headers = [_][*c]const u8{
            authorization.ptr,
            try header(&dynamic_headers[0], "nv-client-id", null, self.clientId()),
            try header(&dynamic_headers[1], "x-device-id", null, self.auth.stableDeviceId()),
            "Accept: application/json",
            "nv-client-streamer: NVIDIA-CLASSIC",
            "nv-client-type: NATIVE",
            "nv-client-version: " ++ client_version,
            "nv-device-os: LINUX",
            "nv-device-type: DESKTOP",
            "User-Agent: " ++ user_agent,
        };
        const response = c.go_http_request_bounded(
            "GET",
            url.ptr,
            null,
            @ptrCast(&headers),
            headers.len,
            1024 * 1024,
        );
        defer c.go_http_response_destroy(response);
        if (response == null or response.*.status < 200 or response.*.status >= 300 or
            response.*.data == null)
            return error.ServerInfoRequestFailed;
        return (try protocol.parseLocalRegionUrl(
            self.allocator,
            response.*.data[0..response.*.len],
        )) orelse self.allocator.dupe(u8, provider_url);
    }

    fn drawProgress(self: *Client, session: *const protocol.Session) void {
        var detail_buffer: [96]u8 = undefined;
        const detail = if (session.queue_position) |position|
            std.fmt.bufPrintZ(&detail_buffer, "QUEUE POSITION {d}", .{position}) catch return
        else switch (session.setup_step orelse 0) {
            1 => std.fmt.bufPrintZ(&detail_buffer, "WAITING FOR A STREAMING RIG", .{}) catch return,
            5 => std.fmt.bufPrintZ(&detail_buffer, "CLOSING THE PREVIOUS SESSION", .{}) catch return,
            6 => std.fmt.bufPrintZ(&detail_buffer, "PREPARING GAME STORAGE", .{}) catch return,
            else => std.fmt.bufPrintZ(&detail_buffer, "PREPARING THE GAME", .{}) catch return,
        };
        c.go_handheld_ui_draw_loading(
            self.ui,
            "STARTING GEFORCE NOW",
            detail.ptr,
            c.GO_HANDHELD_UI_ACTION_CANCEL,
        );
    }
};

fn requestCancelled(context: ?*anyopaque) callconv(.c) c_int {
    const client: *Client = @ptrCast(@alignCast(context orelse return 1));
    return c.go_handheld_ui_cancel_requested(client.ui);
}

fn retryableRequestFailure(err: anyerror, status: c_long, service_retryable: ?bool) bool {
    if (err == error.HttpRequestFailed) return true;
    if (err != error.HttpRequestRejected) return false;
    if (service_retryable) |retryable| return retryable;
    return switch (status) {
        408, 425, 429, 500, 502, 503, 504 => true,
        else => false,
    };
}

fn createRetryDelay(attempt: usize) c_uint {
    return switch (attempt) {
        0 => 4000,
        1 => 8000,
        else => 16000,
    };
}

fn pollDelay(consecutive_errors: usize) c_uint {
    if (consecutive_errors == 0) return 2000;
    const shift: u4 = @intCast(@min(consecutive_errors - 1, 3));
    return @min(@as(c_uint, 2000) << shift, 15000);
}

fn buildCreateSessionUrl(output: []u8, streaming_url: []const u8) ![:0]u8 {
    return std.fmt.bufPrintZ(
        output,
        "{s}v2/session?keyboardLayout=en-US_qwerty&languageCode=en_US",
        .{streaming_url},
    );
}

fn header(
    output: []u8,
    name: []const u8,
    scheme: ?[]const u8,
    value: []const u8,
) ![*c]const u8 {
    const result = if (scheme) |prefix|
        try std.fmt.bufPrintZ(output, "{s}: {s} {s}", .{ name, prefix, value })
    else
        try std.fmt.bufPrintZ(output, "{s}: {s}", .{ name, value });
    return result.ptr;
}

fn authorizationHeader(allocator: std.mem.Allocator, bearer: []const u8) ![:0]u8 {
    if (bearer.len == 0 or bearer.len > maximum_bearer_length)
        return error.InvalidBearerToken;
    return std.fmt.allocPrintZ(allocator, "Authorization: GFNJWT {s}", .{bearer});
}

fn secureFree(allocator: std.mem.Allocator, value: [:0]u8) void {
    std.crypto.secureZero(u8, value);
    allocator.free(value);
}

fn validQueryValue(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.')
            return false;
    }
    return true;
}

test "session polling backs off after server failures" {
    try std.testing.expectEqual(@as(c_uint, 2000), pollDelay(0));
    try std.testing.expectEqual(@as(c_uint, 2000), pollDelay(1));
    try std.testing.expectEqual(@as(c_uint, 4000), pollDelay(2));
    try std.testing.expectEqual(@as(c_uint, 15000), pollDelay(9));
}

test "session requests retry only temporary transport and server failures" {
    try std.testing.expect(retryableRequestFailure(error.HttpRequestFailed, 0, null));
    try std.testing.expect(retryableRequestFailure(error.HttpRequestRejected, 429, null));
    try std.testing.expect(retryableRequestFailure(error.HttpRequestRejected, 500, true));
    try std.testing.expect(!retryableRequestFailure(error.HttpRequestRejected, 500, false));
    try std.testing.expect(!retryableRequestFailure(error.HttpRequestRejected, 401, null));
    try std.testing.expect(!retryableRequestFailure(error.RequestRejected, 200, null));
    try std.testing.expect(!retryableRequestFailure(error.Cancelled, 0, null));
}

test "session creation retry delay is bounded" {
    try std.testing.expectEqual(@as(c_uint, 4000), createRetryDelay(0));
    try std.testing.expectEqual(@as(c_uint, 8000), createRetryDelay(1));
    try std.testing.expectEqual(@as(c_uint, 16000), createRetryDelay(2));
    try std.testing.expectEqual(@as(c_uint, 16000), createRetryDelay(9));
}

test "session creation uses the resolved streaming endpoint" {
    var output: [256]u8 = undefined;
    const url = try buildCreateSessionUrl(
        &output,
        "https://np-ams-01.cloudmatchbeta.nvidiagrid.net/",
    );
    try std.testing.expectEqualStrings(
        "https://np-ams-01.cloudmatchbeta.nvidiagrid.net/v2/session?keyboardLayout=en-US_qwerty&languageCode=en_US",
        url,
    );
}

test "accepts only query-safe service identifiers" {
    try std.testing.expect(validQueryValue("NP-AMS-08"));
    try std.testing.expect(validQueryValue("12345678-1234-4abc-8def-123456789abc"));
    try std.testing.expect(!validQueryValue("value&other=1"));
}

test "authorization header accepts realistic token lengths" {
    const bearer = try std.testing.allocator.alloc(u8, 16 * 1024);
    defer std.testing.allocator.free(bearer);
    @memset(bearer, 'a');
    const value = try authorizationHeader(std.testing.allocator, bearer);
    defer secureFree(std.testing.allocator, value);
    try std.testing.expect(std.mem.endsWith(u8, value, bearer));
}

test "queue polling preserves cancellation without retrying the request" {
    const http = @import("gfn_http_fake");
    http.reset();
    var auth = http.authClient(auth_client.Client);
    var client = Client{
        .allocator = std.testing.allocator,
        .auth = &auth,
        .ui = @ptrCast(auth.ui),
        .client_id = [_]u8{0} ** 37,
        .streaming_url = @constCast("https://example.invalid/"),
        .session = try protocol.parseSession(std.testing.allocator,
            \\{"requestStatus":{"statusCode":1},"session":{"sessionId":"test-session","status":1}}
        ),
    };
    defer client.session.?.deinit();
    try std.testing.expectError(error.Cancelled, client.waitUntilReady());
    try std.testing.expectEqual(@as(usize, 1), http.requests);
    try std.testing.expectEqual(@as(usize, 1), http.polls);

    http.reset();
    try std.testing.expectError(error.Cancelled, client.selectStreamMode(
        "https://example.invalid/",
        auth.bearer().?,
        640,
        480,
    ));
    try std.testing.expectEqual(@as(usize, 1), http.requests);
    try std.testing.expectEqual(@as(usize, 1), http.polls);
}

test "ended sessions stop polling and deletion accepts an empty success response" {
    const http = @import("gfn_http_fake");
    http.reset();
    var auth = http.authClient(auth_client.Client);
    var client = Client{
        .allocator = std.testing.allocator,
        .auth = &auth,
        .ui = @ptrCast(auth.ui),
        .client_id = [_]u8{0} ** 37,
        .streaming_url = @constCast("https://example.invalid/"),
        .session = try protocol.parseSession(std.testing.allocator,
            \\{"requestStatus":{"statusCode":1},"session":{"sessionId":"test-session","status":4}}
        ),
    };
    defer if (client.session) |*session| session.deinit();
    try std.testing.expectError(error.SessionEnded, client.waitUntilReady());
    try std.testing.expectEqual(@as(usize, 0), http.requests);

    http.cancelled = true;
    http.replyNoContent();
    try client.stop();
    try std.testing.expect(client.session == null);
    try std.testing.expectEqual(@as(usize, 1), http.requests);
    try std.testing.expectEqual(@as(usize, 0), http.polls);
}
