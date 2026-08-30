const std = @import("std");
const form = @import("form_writer");
const json = @import("json_reader");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("handheld_ui.h");
    @cInclude("http_client.h");
    @cInclude("token_store_adapter.h");
});

const device_code_url = "https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode";
const oauth_token_url = "https://login.microsoftonline.com/consumers/oauth2/v2.0/token";
const oauth_scope = "xboxlive.signin openid profile offline_access";
const passport_scope = "service::http://Passport.NET/purpose::PURPOSE_XBOX_CLOUD_CONSOLE_TRANSFER_TOKEN";
const offering_url = "https://xgpuweb.gssv-play-prod.xboxlive.com/v2/login/user";
const xbox_web_client_id = "1f907974-e22b-4810-a9de-d9647380c97e";

const auth_failed: c_int = -1;
const auth_ok: c_int = 0;
const auth_reauth_required: c_int = 1;

const FormField = struct {
    key: []const u8,
    value: []const u8,
};

const Auth = struct {
    client_id: [128]u8 = [_]u8{0} ** 128,
    gssv_token: [8192]u8 = [_]u8{0} ** 8192,
    user_token: [8192]u8 = [_]u8{0} ** 8192,
    refresh_token: [8192]u8 = [_]u8{0} ** 8192,
    passport_token: [8192]u8 = [_]u8{0} ** 8192,
    token_path: [512]u8 = [_]u8{0} ** 512,
    token_key_path: [512]u8 = [_]u8{0} ** 512,
};

fn cString(buffer: []const u8) []const u8 {
    return buffer[0 .. std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len];
}

fn copyString(destination: []u8, source: []const u8) !void {
    if (source.len == 0 or source.len >= destination.len) return error.InvalidString;
    @memset(destination, 0);
    @memcpy(destination[0..source.len], source);
}

fn isClientId(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (byte != '-') return false;
        } else if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn readSmallFile(path: []const u8, output: []u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const length = try file.readAll(output);
    if (length == output.len) {
        var extra: [1]u8 = undefined;
        if (try file.read(&extra) != 0) return error.FileTooBig;
    }
    return output[0..length];
}

fn loadClientId(auth: *Auth) !void {
    if (std.posix.getenv("GREENOVERCAST_CLIENT_ID")) |configured| {
        const value = std.mem.trim(u8, configured, " \t\r\n");
        if (!isClientId(value)) return error.InvalidClientId;
        return copyString(&auth.client_id, value);
    }
    if (std.posix.getenv("GREENOVERCAST_CLIENT_ID_FILE")) |configured_file| {
        var contents: [128]u8 = undefined;
        const value = std.mem.trim(u8, try readSmallFile(configured_file, &contents), " \t\r\n");
        if (!isClientId(value)) return error.InvalidClientId;
        return copyString(&auth.client_id, value);
    }
    try copyString(&auth.client_id, xbox_web_client_id);
}

fn buildForm(output: []u8, fields: []const FormField) ![:0]u8 {
    if (output.len == 0) return error.NoSpaceLeft;
    var used: usize = 0;
    for (fields, 0..) |field, index| {
        const prefix = try std.fmt.bufPrint(
            output[used..],
            "{s}{s}=",
            .{ if (index == 0) "" else "&", field.key },
        );
        used += prefix.len;
        used += form.encode(field.value, output[used..]) catch return error.NoSpaceLeft;
    }
    if (used >= output.len) return error.NoSpaceLeft;
    output[used] = 0;
    return output[0..used :0];
}

fn responseData(response: [*c]c.GoHttpResponse) ?[]const u8 {
    if (response == null or response.*.data == null) return null;
    return response.*.data[0..response.*.len];
}

fn jsonString(data: []const u8, key: []const u8, output: []u8) ![]const u8 {
    const length = json.parseString(data, key, output) catch return error.MissingField;
    return output[0..length];
}

fn jsonUnsigned(data: []const u8, key: []const u8, fallback: c_uint) c_uint {
    return json.parseUnsigned(data, key) catch fallback;
}

fn requiresSignIn(response: [*c]c.GoHttpResponse) bool {
    const data = responseData(response) orelse return false;
    var error_buffer: [128]u8 = undefined;
    const message = jsonString(data, "error", &error_buffer) catch return false;
    return std.mem.eql(u8, message, "invalid_grant") or
        std.mem.eql(u8, message, "interaction_required") or
        std.mem.eql(u8, message, "consent_required");
}

fn logOauthError(stage: []const u8, response: [*c]c.GoHttpResponse) void {
    if (response == null) {
        std.debug.print("{s} failed without an HTTP response\n", .{stage});
        return;
    }
    var error_buffer: [128]u8 = undefined;
    const message = if (responseData(response)) |data|
        jsonString(data, "error", &error_buffer) catch null
    else
        null;
    if (message) |text|
        std.debug.print("{s} failed: HTTP {d} ({s})\n", .{ stage, response.*.status, text })
    else
        std.debug.print("{s} failed: HTTP {d}\n", .{ stage, response.*.status });
}

fn debug(comptime format: []const u8, args: anytype) void {
    if (std.posix.getenv("GREENOVERCAST_DEBUG") != null) std.debug.print(format, args);
}

fn saveRefreshToken(auth: *Auth) !void {
    if (c.go_token_store_save(
        @ptrCast(&auth.token_path),
        @ptrCast(&auth.token_key_path),
        @ptrCast(&auth.refresh_token),
    ) != 0) return error.TokenSaveFailed;
}

fn loadCredentials(auth: *Auth) !bool {
    const result = c.go_token_store_load(
        @ptrCast(&auth.token_path),
        @ptrCast(&auth.token_key_path),
        @ptrCast(&auth.refresh_token),
        auth.refresh_token.len,
    );
    if (result < 0) return error.TokenLoadFailed;
    return result == 1;
}

fn deviceSignIn(auth: *Auth, ui: *c.GoHandheldUi) !bool {
    var headers = [_][*c]const u8{"Content-Type: application/x-www-form-urlencoded"};
    while (true) {
        var body_buffer: [4096]u8 = undefined;
        const body = try buildForm(&body_buffer, &.{
            .{ .key = "client_id", .value = cString(&auth.client_id) },
            .{ .key = "scope", .value = oauth_scope },
        });
        c.go_handheld_ui_draw_loading(ui, "XBOX SIGN IN", "REQUESTING A DEVICE CODE", "B BACK");
        var response = c.go_http_request(
            "POST",
            device_code_url,
            body.ptr,
            @ptrCast(&headers),
            headers.len,
        );
        if (response == null or response.*.status != 200 or responseData(response) == null) {
            c.go_http_response_destroy(response);
            if (c.go_handheld_ui_wait_for_retry(ui, "SIGN IN UNAVAILABLE", "CHECK YOUR CONNECTION") == 0)
                return false;
            continue;
        }

        const data = responseData(response).?;
        var user_code_buffer: [64]u8 = [_]u8{0} ** 64;
        var device_code_buffer: [2048]u8 = [_]u8{0} ** 2048;
        const user_code = jsonString(data, "user_code", &user_code_buffer) catch null;
        const device_code = jsonString(data, "device_code", &device_code_buffer) catch null;
        var interval = jsonUnsigned(data, "interval", 5);
        var expires_in = jsonUnsigned(data, "expires_in", 900);
        c.go_http_response_destroy(response);
        if (user_code == null or device_code == null) {
            std.crypto.secureZero(u8, &device_code_buffer);
            if (c.go_handheld_ui_wait_for_retry(ui, "SIGN IN UNAVAILABLE", "INVALID SERVICE RESPONSE") == 0)
                return false;
            continue;
        }
        defer std.crypto.secureZero(u8, &device_code_buffer);
        interval = std.math.clamp(interval, 1, 30);
        if (expires_in < interval) expires_in = interval;

        const started = c.SDL_GetTicks();
        var next_poll = started +% interval * 1000;
        var restart = false;
        while ((c.SDL_GetTicks() -% started) / 1000 < expires_in) {
            const now = c.SDL_GetTicks();
            const elapsed = (now -% started) / 1000;
            c.go_handheld_ui_draw_device_code(
                ui,
                @ptrCast(&user_code_buffer),
                "WAITING FOR APPROVAL",
                expires_in - elapsed,
            );
            if (c.go_handheld_ui_sign_in_action(ui) < 0) return false;
            const until_poll: i32 = @bitCast(now -% next_poll);
            if (until_poll < 0) {
                c.SDL_Delay(16);
                continue;
            }

            const token_body = try buildForm(&body_buffer, &.{
                .{ .key = "grant_type", .value = "urn:ietf:params:oauth:grant-type:device_code" },
                .{ .key = "client_id", .value = cString(&auth.client_id) },
                .{ .key = "device_code", .value = device_code.? },
            });
            response = c.go_http_request(
                "POST",
                oauth_token_url,
                token_body.ptr,
                @ptrCast(&headers),
                headers.len,
            );
            next_poll = c.SDL_GetTicks() +% interval * 1000;
            const token_data = responseData(response) orelse {
                c.go_http_response_destroy(response);
                continue;
            };
            if (response.*.status == 200) {
                var refreshed: [8192]u8 = [_]u8{0} ** 8192;
                defer std.crypto.secureZero(u8, &refreshed);
                if (jsonString(token_data, "refresh_token", &refreshed)) |token| {
                    try copyString(&auth.refresh_token, token);
                    try saveRefreshToken(auth);
                    c.go_http_response_destroy(response);
                    c.go_handheld_ui_draw_loading(
                        ui,
                        "SIGNED IN",
                        "OPENING YOUR CLOUD LIBRARY",
                        null,
                    );
                    c.SDL_Delay(700);
                    return true;
                } else |_| {}
            }

            var error_buffer: [128]u8 = undefined;
            const message = jsonString(token_data, "error", &error_buffer) catch null;
            if (message) |value| {
                if (std.mem.eql(u8, value, "slow_down"))
                    interval = @min(interval + 5, 30)
                else if (!std.mem.eql(u8, value, "authorization_pending"))
                    restart = true;
            }
            c.go_http_response_destroy(response);
            if (restart) break;
        }

        const heading: [*:0]const u8 = if (restart) "SIGN IN FAILED" else "CODE EXPIRED";
        const detail: [*:0]const u8 = if (restart) "XBOX REJECTED THE REQUEST" else "REQUEST A NEW CODE";
        if (c.go_handheld_ui_wait_for_retry(ui, heading, detail) == 0) return false;
    }
}

fn refresh(auth: *Auth) !c_int {
    if (cString(&auth.refresh_token).len == 0) return auth_failed;
    std.crypto.secureZero(u8, &auth.gssv_token);
    std.crypto.secureZero(u8, &auth.user_token);
    std.crypto.secureZero(u8, &auth.passport_token);

    var body_buffer: [32768]u8 = undefined;
    var form_headers = [_][*c]const u8{"Content-Type: application/x-www-form-urlencoded"};
    var json_headers = [_][*c]const u8{
        "Content-Type: application/json",
        "x-xbl-contract-version: 1",
    };
    var gssv_headers = [_][*c]const u8{
        "Content-Type: application/json",
        "x-gssv-client: XboxComBrowser",
    };

    const refresh_body = try buildForm(&body_buffer, &.{
        .{ .key = "client_id", .value = cString(&auth.client_id) },
        .{ .key = "grant_type", .value = "refresh_token" },
        .{ .key = "refresh_token", .value = cString(&auth.refresh_token) },
        .{ .key = "scope", .value = oauth_scope },
    });
    var response = c.go_http_request(
        "POST",
        oauth_token_url,
        refresh_body.ptr,
        @ptrCast(&form_headers),
        form_headers.len,
    );
    if (response == null) return error.HttpRequestFailed;
    if (response.*.status != 200) logOauthError("Xbox Live token refresh", response);
    var reauth_required = requiresSignIn(response);
    const refresh_data = responseData(response);
    var access_token: [8192]u8 = [_]u8{0} ** 8192;
    defer std.crypto.secureZero(u8, &access_token);
    const access = if (refresh_data) |data| jsonString(data, "access_token", &access_token) catch null else null;
    if (refresh_data) |data| {
        var refreshed: [8192]u8 = [_]u8{0} ** 8192;
        defer std.crypto.secureZero(u8, &refreshed);
        if (jsonString(data, "refresh_token", &refreshed)) |token|
            try copyString(&auth.refresh_token, token)
        else |_| {}
    }
    c.go_http_response_destroy(response);
    if (access == null) {
        if (reauth_required) {
            std.crypto.secureZero(u8, &auth.refresh_token);
            return auth_reauth_required;
        }
        return auth_failed;
    }

    const user_body = try std.fmt.bufPrintZ(
        &body_buffer,
        "{{\"Properties\":{{\"AuthMethod\":\"RPS\",\"RpsTicket\":\"d={s}\"," ++
            "\"SiteName\":\"user.auth.xboxlive.com\"}}," ++
            "\"RelyingParty\":\"http://auth.xboxlive.com\",\"TokenType\":\"JWT\"}}",
        .{access.?},
    );
    response = c.go_http_request(
        "POST",
        "https://user.auth.xboxlive.com/user/authenticate",
        user_body.ptr,
        @ptrCast(&json_headers),
        json_headers.len,
    );
    const user_data = responseData(response) orelse {
        c.go_http_response_destroy(response);
        return auth_failed;
    };
    _ = jsonString(user_data, "Token", &auth.user_token) catch {
        c.go_http_response_destroy(response);
        return auth_failed;
    };
    c.go_http_response_destroy(response);
    debug("User token obtained\n", .{});

    const xsts_body = try std.fmt.bufPrintZ(
        &body_buffer,
        "{{\"Properties\":{{\"SandboxId\":\"RETAIL\",\"UserTokens\":[\"{s}\"]}}," ++
            "\"RelyingParty\":\"http://gssv.xboxlive.com/\",\"TokenType\":\"JWT\"}}",
        .{cString(&auth.user_token)},
    );
    response = c.go_http_request(
        "POST",
        "https://xsts.auth.xboxlive.com/xsts/authorize",
        xsts_body.ptr,
        @ptrCast(&json_headers),
        json_headers.len,
    );
    const xsts_data = responseData(response) orelse {
        c.go_http_response_destroy(response);
        return auth_failed;
    };
    var xsts_token: [8192]u8 = [_]u8{0} ** 8192;
    defer std.crypto.secureZero(u8, &xsts_token);
    const xsts = jsonString(xsts_data, "Token", &xsts_token) catch {
        c.go_http_response_destroy(response);
        return auth_failed;
    };
    c.go_http_response_destroy(response);

    const offering_body = try std.fmt.bufPrintZ(
        &body_buffer,
        "{{\"token\":\"{s}\",\"offeringId\":\"xgpuweb\"}}",
        .{xsts},
    );
    response = c.go_http_request(
        "POST",
        offering_url,
        offering_body.ptr,
        @ptrCast(&gssv_headers),
        gssv_headers.len,
    );
    const gssv_data = responseData(response) orelse {
        c.go_http_response_destroy(response);
        return auth_failed;
    };
    _ = jsonString(gssv_data, "gsToken", &auth.gssv_token) catch {
        c.go_http_response_destroy(response);
        return auth_failed;
    };
    c.go_http_response_destroy(response);
    debug("gsToken obtained\n", .{});

    const passport_body = try buildForm(&body_buffer, &.{
        .{ .key = "client_id", .value = cString(&auth.client_id) },
        .{ .key = "grant_type", .value = "refresh_token" },
        .{ .key = "refresh_token", .value = cString(&auth.refresh_token) },
        .{ .key = "scope", .value = passport_scope },
    });
    response = c.go_http_request(
        "POST",
        "https://login.live.com/oauth20_token.srf",
        passport_body.ptr,
        @ptrCast(&form_headers),
        form_headers.len,
    );
    if (response == null) return error.HttpRequestFailed;
    if (response.*.status != 200) logOauthError("Passport token exchange", response);
    reauth_required = requiresSignIn(response);
    const passport_data = responseData(response);
    if (passport_data) |data| {
        if (jsonString(data, "lpt", &auth.passport_token)) |_| {} else |_| {
            _ = jsonString(data, "access_token", &auth.passport_token) catch {};
        }
        var refreshed: [8192]u8 = [_]u8{0} ** 8192;
        defer std.crypto.secureZero(u8, &refreshed);
        if (jsonString(data, "refresh_token", &refreshed)) |token|
            try copyString(&auth.refresh_token, token)
        else |_| {}
    }
    c.go_http_response_destroy(response);
    if (cString(&auth.passport_token).len == 0) {
        if (reauth_required) {
            std.crypto.secureZero(u8, &auth.refresh_token);
            return auth_reauth_required;
        }
        return auth_failed;
    }
    debug("Passport token obtained\n", .{});
    try saveRefreshToken(auth);
    debug("Tokens saved\n", .{});
    return auth_ok;
}

pub export fn go_xbox_auth_create() ?*Auth {
    const auth = std.heap.c_allocator.create(Auth) catch return null;
    auth.* = .{};
    const token_path = std.posix.getenv("GREENOVERCAST_TOKEN_FILE") orelse {
        go_xbox_auth_destroy(auth);
        return null;
    };
    const token_key_path = std.posix.getenv("GREENOVERCAST_TOKEN_KEY_FILE") orelse {
        go_xbox_auth_destroy(auth);
        return null;
    };
    copyString(&auth.token_path, token_path) catch {
        go_xbox_auth_destroy(auth);
        return null;
    };
    copyString(&auth.token_key_path, token_key_path) catch {
        go_xbox_auth_destroy(auth);
        return null;
    };
    loadClientId(auth) catch {
        go_xbox_auth_destroy(auth);
        return null;
    };
    return auth;
}

pub export fn go_xbox_auth_load_credentials(auth: ?*Auth) c_int {
    const handle = auth orelse return -1;
    return @intFromBool(loadCredentials(handle) catch return -1);
}

pub export fn go_xbox_auth_device_sign_in(auth: ?*Auth, ui: ?*c.GoHandheldUi) c_int {
    const handle = auth orelse return -1;
    const ui_handle = ui orelse return -1;
    return @intFromBool(deviceSignIn(handle, ui_handle) catch return -1);
}

pub export fn go_xbox_auth_refresh(auth: ?*Auth) c_int {
    return refresh(auth orelse return auth_failed) catch auth_failed;
}

pub export fn go_xbox_auth_sign_out(auth: ?*Auth) c_int {
    const handle = auth orelse return -1;
    std.crypto.secureZero(u8, &handle.gssv_token);
    std.crypto.secureZero(u8, &handle.user_token);
    std.crypto.secureZero(u8, &handle.refresh_token);
    std.crypto.secureZero(u8, &handle.passport_token);
    return c.go_token_store_delete(
        @ptrCast(&handle.token_path),
        @ptrCast(&handle.token_key_path),
    );
}

pub export fn go_xbox_auth_gssv_token(auth: ?*const Auth) [*c]const u8 {
    const handle = auth orelse return null;
    return @ptrCast(&handle.gssv_token);
}

pub export fn go_xbox_auth_passport_token(auth: ?*const Auth) [*c]const u8 {
    const handle = auth orelse return null;
    return @ptrCast(&handle.passport_token);
}

pub export fn go_xbox_auth_destroy(auth: ?*Auth) void {
    const handle = auth orelse return;
    std.crypto.secureZero(u8, std.mem.asBytes(handle));
    std.heap.c_allocator.destroy(handle);
}
