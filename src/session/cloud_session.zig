const std = @import("std");

const c = @cImport({
    @cInclude("handheld_ui.h");
    @cInclude("http_client.h");
    @cInclude("json_reader.h");
    @cInclude("xbox_auth.h");
});

const base_url = "https://weu.core.gssv-play-prod.xboxlive.com";
const device_info_header =
    "X-MS-Device-Info: {\"appInfo\":{\"env\":{\"clientAppId\":\"www.xbox.com\"," ++
    "\"clientAppType\":\"browser\",\"clientAppVersion\":\"26.1.97\"," ++
    "\"clientSdkVersion\":\"10.3.7\",\"httpEnvironment\":\"prod\",\"sdkInstallId\":\"\"}}," ++
    "\"dev\":{\"hw\":{\"make\":\"Microsoft\",\"model\":\"unknown\",\"sdktype\":\"web\"}," ++
    "\"os\":{\"name\":\"android\",\"ver\":\"22631.2715\",\"platform\":\"desktop\"}," ++
    "\"displayInfo\":{\"dimensions\":{\"widthInPixels\":1280,\"heightInPixels\":720}," ++
    "\"pixelDensity\":{\"dpiX\":1,\"dpiY\":1}},\"browser\":{\"browserName\":\"chrome\"," ++
    "\"browserVersion\":\"140.0.3485.54\"}}}";

const Stats = extern struct {
    keepalive_successes: c_int,
    keepalive_failures: c_int,
};

const Session = struct {
    auth: *c.GoXboxAuth,
    ui: *c.GoHandheldUi,
    session_path: [256]u8 = [_]u8{0} ** 256,
    keepalive_thread: ?std.Thread = null,
    keepalive_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    keepalive_successes: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    keepalive_failures: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    keepalive_mutex: std.Thread.Mutex = .{},
    keepalive_condition: std.Thread.Condition = .{},
};

fn cString(pointer: [*c]const u8) ?[]const u8 {
    if (pointer == null) return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(pointer)));
}

fn bufferString(buffer: []const u8) []const u8 {
    return buffer[0 .. std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len];
}

fn responseData(response: [*c]c.GoHttpResponse) ?[]const u8 {
    if (response == null or response.*.data == null) return null;
    return response.*.data[0..response.*.len];
}

fn jsonString(data: []const u8, key: [*:0]const u8, output: []u8) ![]const u8 {
    const length = c.go_json_copy_string(data.ptr, data.len, key, output.ptr, output.len);
    if (length < 0) return error.MissingField;
    return output[0..@intCast(length)];
}

fn debug(comptime format: []const u8, args: anytype) void {
    if (std.posix.getenv("GREENOVERCAST_DEBUG") != null) std.debug.print(format, args);
}

fn request(
    session: *Session,
    method: [*c]const u8,
    url: [*c]const u8,
    body: [*c]const u8,
    extra_headers: [*c][*c]const u8,
    extra_header_count: c_int,
) [*c]c.GoHttpResponse {
    if (method == null or url == null or extra_header_count < 0 or extra_header_count > 4)
        return null;
    const token = cString(c.go_xbox_auth_gssv_token(session.auth)) orelse return null;
    var auth_header_buffer: [16384]u8 = undefined;
    const auth_header = std.fmt.bufPrintZ(
        &auth_header_buffer,
        "Authorization: Bearer {s}",
        .{token},
    ) catch return null;
    var headers: [8][*c]const u8 = undefined;
    headers[0] = auth_header.ptr;
    headers[1] = "Accept: application/json";
    headers[2] = "x-gssv-client: XboxComBrowser";
    headers[3] = device_info_header;
    var header_count: usize = 4;
    var index: usize = 0;
    while (index < @as(usize, @intCast(extra_header_count))) : (index += 1) {
        if (extra_headers == null or extra_headers[index] == null) return null;
        headers[header_count] = extra_headers[index];
        header_count += 1;
    }
    return c.go_http_request(method, url, body, @ptrCast(&headers), @intCast(header_count));
}

fn startGame(session: *Session, title_id: []const u8) !void {
    if (title_id.len == 0) return error.InvalidTitle;
    if (bufferString(&session.session_path).len != 0) return error.ActiveSession;
    var url_buffer: [512]u8 = undefined;
    const url = try std.fmt.bufPrintZ(&url_buffer, "{s}/v5/sessions/cloud/play", .{base_url});
    var body_buffer: [4096]u8 = undefined;
    const body = try std.fmt.bufPrintZ(
        &body_buffer,
        "{{\"clientSessionId\":\"\",\"titleId\":\"{s}\",\"systemUpdateGroup\":\"\"," ++
            "\"settings\":{{\"nanoVersion\":\"V3;WebrtcTransport.dll\"," ++
            "\"enableOptionalDataCollection\":false,\"enableTextToSpeech\":false," ++
            "\"highContrast\":0,\"locale\":\"en-US\",\"useIceConnection\":false," ++
            "\"timezoneOffsetMinutes\":120,\"sdkType\":\"web\",\"osName\":\"android\"}}," ++
            "\"serverId\":\"\",\"fallbackRegionNames\":[]}}",
        .{title_id},
    );
    var headers = [_][*c]const u8{"Content-Type: application/json"};
    const response = request(session, "POST", url.ptr, body.ptr, @ptrCast(&headers), headers.len);
    defer c.go_http_response_destroy(response);
    if (c.go_http_response_succeeded(response) == 0) return error.StartFailed;
    const data = responseData(response) orelse return error.InvalidResponse;
    _ = try jsonString(data, "sessionPath", &session.session_path);
    debug("Session: {s}\n", .{bufferString(&session.session_path)});
}

fn waitForState(session: *Session, target: []const u8, max_polls: usize) !void {
    if (bufferString(&session.session_path).len == 0 or target.len == 0 or max_polls == 0)
        return error.InvalidStateRequest;
    var target_buffer: [64]u8 = [_]u8{0} ** 64;
    if (target.len >= target_buffer.len) return error.InvalidStateRequest;
    @memcpy(target_buffer[0..target.len], target);

    var poll: usize = 0;
    while (poll < max_polls) : (poll += 1) {
        var url_buffer: [512]u8 = undefined;
        const url = try std.fmt.bufPrintZ(
            &url_buffer,
            "{s}/{s}/state",
            .{ base_url, bufferString(&session.session_path) },
        );
        const response = request(session, "GET", url.ptr, null, null, 0);
        if (c.go_http_response_succeeded(response) == 0) {
            c.go_http_response_destroy(response);
            if (c.go_handheld_ui_wait(session.ui, 3000) != 0) return error.Cancelled;
            continue;
        }

        const data = responseData(response);
        var state_buffer: [128]u8 = undefined;
        var error_buffer: [1024]u8 = undefined;
        const state = if (data) |payload| jsonString(payload, "state", &state_buffer) catch null else null;
        const details = if (data) |payload| jsonString(payload, "errorDetails", &error_buffer) catch null else null;
        if (state) |value| debug("state: {s}\n", .{value});
        if (state != null and std.mem.eql(u8, state.?, target)) {
            c.go_http_response_destroy(response);
            return;
        }
        if (state != null and (std.mem.eql(u8, state.?, "Failed") or
            std.mem.eql(u8, state.?, "Expired")))
        {
            std.debug.print("Session failed: {s}\n", .{details orelse "unknown error"});
            c.go_http_response_destroy(response);
            return error.SessionFailed;
        }
        c.go_http_response_destroy(response);
        if (c.go_handheld_ui_wait(session.ui, 3000) != 0) return error.Cancelled;
    }
    return error.StateTimeout;
}

fn connect(session: *Session) !void {
    if (bufferString(&session.session_path).len == 0) return error.MissingSession;
    const passport_token = cString(c.go_xbox_auth_passport_token(session.auth)) orelse
        return error.MissingPassportToken;
    var url_buffer: [512]u8 = undefined;
    const url = try std.fmt.bufPrintZ(
        &url_buffer,
        "{s}/{s}/connect",
        .{ base_url, bufferString(&session.session_path) },
    );
    var body_buffer: [16384]u8 = undefined;
    const body = try std.fmt.bufPrintZ(&body_buffer, "{{\"userToken\":\"{s}\"}}", .{passport_token});
    var headers = [_][*c]const u8{"Content-Type: application/json"};
    const response = request(session, "POST", url.ptr, body.ptr, @ptrCast(&headers), headers.len);
    defer c.go_http_response_destroy(response);
    if (c.go_http_response_succeeded(response) == 0) return error.ConnectFailed;
}

fn sendKeepalive(session: *Session) !void {
    var url_buffer: [512]u8 = undefined;
    const url = try std.fmt.bufPrintZ(
        &url_buffer,
        "{s}/{s}/keepalive",
        .{ base_url, bufferString(&session.session_path) },
    );
    const response = request(session, "POST", url.ptr, null, null, 0);
    defer c.go_http_response_destroy(response);
    if (c.go_http_response_succeeded(response) == 0) return error.KeepaliveFailed;
    if (responseData(response)) |data| {
        if (std.mem.indexOf(u8, data, "SessionNotActive") != null or
            std.mem.indexOf(u8, data, "SessionNotFound") != null)
            return error.SessionInactive;
    }
}

fn keepaliveWorker(session: *Session) void {
    while (!session.keepalive_stop.load(.seq_cst)) {
        if (sendKeepalive(session)) |_| {
            _ = session.keepalive_successes.fetchAdd(1, .seq_cst);
        } else |_| {
            _ = session.keepalive_failures.fetchAdd(1, .seq_cst);
        }

        session.keepalive_mutex.lock();
        while (!session.keepalive_stop.load(.seq_cst)) {
            session.keepalive_condition.timedWait(
                &session.keepalive_mutex,
                30 * std.time.ns_per_s,
            ) catch break;
        }
        session.keepalive_mutex.unlock();
    }
}

fn startKeepalive(session: *Session) !void {
    if (bufferString(&session.session_path).len == 0 or session.keepalive_thread != null)
        return error.InvalidKeepaliveState;
    session.keepalive_stop.store(false, .seq_cst);
    session.keepalive_successes.store(0, .seq_cst);
    session.keepalive_failures.store(0, .seq_cst);
    session.keepalive_thread = try std.Thread.spawn(.{}, keepaliveWorker, .{session});
}

fn stopKeepalive(session: *Session) void {
    const thread = session.keepalive_thread orelse return;
    session.keepalive_stop.store(true, .seq_cst);
    session.keepalive_mutex.lock();
    session.keepalive_condition.broadcast();
    session.keepalive_mutex.unlock();
    thread.join();
    session.keepalive_thread = null;
}

fn end(session: *Session) void {
    stopKeepalive(session);
    const path = bufferString(&session.session_path);
    if (path.len == 0) return;

    var url_buffer: [512]u8 = undefined;
    if (std.fmt.bufPrintZ(&url_buffer, "{s}/{s}", .{ base_url, path })) |url| {
        const response = request(session, "DELETE", url.ptr, null, null, 0);
        c.go_http_response_destroy(response);
    } else |_| {}
    std.crypto.secureZero(u8, &session.session_path);
}

pub export fn go_cloud_session_create(auth: ?*c.GoXboxAuth, ui: ?*c.GoHandheldUi) ?*Session {
    const auth_handle = auth orelse return null;
    const ui_handle = ui orelse return null;
    const session = std.heap.c_allocator.create(Session) catch return null;
    session.* = .{ .auth = auth_handle, .ui = ui_handle };
    return session;
}

pub export fn go_cloud_session_base_url(session: ?*const Session) [*c]const u8 {
    if (session == null) return null;
    return base_url;
}

pub export fn go_cloud_session_path(session: ?*const Session) [*c]const u8 {
    const handle = session orelse return null;
    if (handle.session_path[0] == 0) return null;
    return @ptrCast(&handle.session_path);
}

pub export fn go_cloud_session_request(
    session: ?*Session,
    method: [*c]const u8,
    url: [*c]const u8,
    body: [*c]const u8,
    extra_headers: [*c][*c]const u8,
    extra_header_count: c_int,
) [*c]c.GoHttpResponse {
    return request(session orelse return null, method, url, body, extra_headers, extra_header_count);
}

pub export fn go_cloud_session_start_game(session: ?*Session, title_id: [*c]const u8) c_int {
    const handle = session orelse return -1;
    const title = cString(title_id) orelse return -1;
    startGame(handle, title) catch return -1;
    return 0;
}

pub export fn go_cloud_session_wait_for_state(
    session: ?*Session,
    target: [*c]const u8,
    max_polls: c_int,
) c_int {
    const handle = session orelse return -1;
    const target_state = cString(target) orelse return -1;
    if (max_polls <= 0) return -1;
    waitForState(handle, target_state, @intCast(max_polls)) catch return -1;
    return 0;
}

pub export fn go_cloud_session_connect(session: ?*Session) c_int {
    connect(session orelse return -1) catch return -1;
    return 0;
}

pub export fn go_cloud_session_start_keepalive(session: ?*Session) c_int {
    startKeepalive(session orelse return -1) catch return -1;
    return 0;
}

pub export fn go_cloud_session_stop_keepalive(session: ?*Session) void {
    stopKeepalive(session orelse return);
}

pub export fn go_cloud_session_end(session: ?*Session) void {
    end(session orelse return);
}

pub export fn go_cloud_session_stats(session: ?*const Session) Stats {
    const handle = session orelse return .{ .keepalive_successes = 0, .keepalive_failures = 0 };
    return .{
        .keepalive_successes = handle.keepalive_successes.load(.seq_cst),
        .keepalive_failures = handle.keepalive_failures.load(.seq_cst),
    };
}

pub export fn go_cloud_session_destroy(session: ?*Session) void {
    const handle = session orelse return;
    end(handle);
    std.heap.c_allocator.destroy(handle);
}
