// xHome console list: GET /v6/servers/home with the home token/host that
// xbox_auth discovers at login, parsed into fixed-size Console records that
// the app shows on the CONSOLES tab. Failure or "home streaming unavailable
// for this account" is never an error for the caller - it just means no
// consoles, and cloud streaming is unaffected. Prints the list when
// GREENOVERCAST_DEBUG is set.
const std = @import("std");
const parser = @import("consoles_parser.zig");

const c = @cImport({
    @cInclude("consoles.h");
    @cInclude("handheld_ui.h");
    @cInclude("http_client.h");
    @cInclude("xbox_auth.h");
});

comptime {
    if (@sizeOf(parser.Console) != @sizeOf(c.GoConsole))
        @compileError("console ABI mismatch");
}

fn cString(pointer: [*c]const u8) ?[]const u8 {
    if (pointer == null) return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(pointer)));
}

fn debugEnabled() bool {
    return std.posix.getenv("GREENOVERCAST_DEBUG") != null;
}

fn debug(comptime format: []const u8, args: anytype) void {
    if (debugEnabled()) std.debug.print(format, args);
}

// This is a best-effort lookup (no consoles just hides the CONSOLES tab), so
// it must never delay the return to the cloud UI by the full 30s HTTP
// timeout if the xHome service is unreachable or slow.
const fetch_timeout_seconds: c_long = 5;

// Mirrors cloud_session.zig's private request() (same headers, same
// X-MS-Device-Info shape) but against the home base URL/token discovered by
// xbox_auth's refresh(). go_cloud_session_request is offering-aware (it
// already switches between the cloud and home token/base URL), but this
// lookup is built directly on top of the HTTP client instead of going
// through it: it is best-effort and needs its own short timeout
// (fetch_timeout_seconds) so an unreachable xHome service never holds up
// the cloud sign-in flow, which go_cloud_session_request does not support.
fn fetchConsolesJson(
    auth: *c.GoXboxAuth,
    ui: ?*c.GoHandheldUi,
    url_buffer: []u8,
) ?[*c]c.GoHttpResponse {
    const home_token = cString(c.go_xbox_auth_home_gssv_token(auth)) orelse return null;
    const home_base_url = cString(c.go_xbox_auth_home_base_url(auth)) orelse return null;
    const url = std.fmt.bufPrintZ(url_buffer, "{s}/v6/servers/home", .{home_base_url}) catch return null;

    var auth_header_buffer: [16384]u8 = undefined;
    const auth_header = std.fmt.bufPrintZ(
        &auth_header_buffer,
        "Authorization: Bearer {s}",
        .{home_token},
    ) catch return null;

    const stream_width = if (ui) |handle| c.go_handheld_ui_stream_width(handle) else 1280;
    const stream_height = if (ui) |handle| c.go_handheld_ui_stream_height(handle) else 720;
    var device_info_buffer: [1024]u8 = undefined;
    const device_info_header = std.fmt.bufPrintZ(
        &device_info_buffer,
        "X-MS-Device-Info: {{\"appInfo\":{{\"env\":{{\"clientAppId\":\"www.xbox.com\"," ++
            "\"clientAppType\":\"browser\",\"clientAppVersion\":\"26.1.97\"," ++
            "\"clientSdkVersion\":\"10.3.7\",\"httpEnvironment\":\"prod\",\"sdkInstallId\":\"\"}}}}," ++
            "\"dev\":{{\"hw\":{{\"make\":\"Microsoft\",\"model\":\"unknown\",\"sdktype\":\"web\"}}," ++
            "\"os\":{{\"name\":\"android\",\"ver\":\"22631.2715\",\"platform\":\"desktop\"}}," ++
            "\"displayInfo\":{{\"dimensions\":{{\"widthInPixels\":{d},\"heightInPixels\":{d}}}," ++
            "\"pixelDensity\":{{\"dpiX\":1,\"dpiY\":1}}}},\"browser\":{{\"browserName\":\"chrome\"," ++
            "\"browserVersion\":\"140.0.3485.54\"}}}}}}",
        .{ stream_width, stream_height },
    ) catch return null;

    var headers: [3][*c]const u8 = .{
        auth_header.ptr,
        "Accept: application/json",
        device_info_header.ptr,
    };
    return c.go_http_request_with_timeout(
        "GET",
        url.ptr,
        null,
        @ptrCast(&headers),
        headers.len,
        fetch_timeout_seconds,
    );
}

fn fetchConsoles(auth: *c.GoXboxAuth, ui: ?*c.GoHandheldUi, consoles: []parser.Console) !usize {
    var url_buffer: [512]u8 = undefined;
    const response = fetchConsolesJson(auth, ui, &url_buffer) orelse {
        debug("Home streaming unavailable - no console list\n", .{});
        return 0;
    };
    defer c.go_http_response_destroy(response);
    if (c.go_http_response_succeeded(response) == 0) return error.RequestFailed;
    if (response == null or response.*.data == null) return error.InvalidResponse;

    const count = try parser.parseConsoles(response.*.data[0..response.*.len], consoles);
    debug("Consoles found: {d}\n", .{count});
    for (consoles[0..count]) |console| {
        debug(
            "  - {s} ({s}) power={s} type={s}{s}\n",
            .{
                parser.cString(&console.device_name),
                parser.cString(&console.server_id),
                parser.cString(&console.power_state),
                parser.cString(&console.console_type),
                if (console.wireless_warning) " [wireless]" else "",
            },
        );
    }
    return count;
}

// Returns the number of consoles written to `out` (0 when home streaming is
// unavailable), or -1 if the request failed. Callers should treat both as
// "no consoles to show" - never as a reason to block the cloud library.
pub export fn go_consoles_fetch(
    auth: ?*c.GoXboxAuth,
    ui: ?*c.GoHandheldUi,
    out: [*]parser.Console,
    capacity: usize,
) c_int {
    const handle = auth orelse return -1;
    const count = fetchConsoles(handle, ui, out[0..capacity]) catch |err| {
        debug("Console list failed: {s}\n", .{@errorName(err)});
        return -1;
    };
    return @intCast(count);
}
