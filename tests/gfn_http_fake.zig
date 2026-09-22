const std = @import("std");

const Response = extern struct {
    data: ?[*]u8,
    len: usize,
    status: c_long,
};

pub var requests: usize = 0;
pub var polls: usize = 0;
pub var cancelled = false;
pub var cancel_on_poll: usize = 1;
pub var response: ?*Response = null;

pub fn reset() void {
    requests = 0;
    polls = 0;
    cancelled = false;
    cancel_on_poll = 1;
    response = null;
}

var no_content = Response{ .data = null, .len = 0, .status = 204 };
var json_response: Response = undefined;

pub fn replyJson(data: []const u8) void {
    json_response = .{ .data = @constCast(data.ptr), .len = data.len, .status = 200 };
    response = &json_response;
}

pub fn replyNoContent() void {
    response = &no_content;
}

pub fn authClient(comptime Client: type) Client {
    return .{
        .allocator = std.testing.allocator,
        .ui = @ptrFromInt(1),
        .oauth_client_id = @constCast("test-client"),
        .protocol_client_id = @constCast("test-protocol"),
        .credential_path = @constCast("unused"),
        .key_path = @constCast("unused"),
        .device_id_path = @constCast("unused"),
        .device_id = [_]u8{0} ** 37,
        .tokens = .{
            .allocator = std.testing.allocator,
            .access_token = @constCast("header.eyJzdWIiOiJ0ZXN0LXVzZXIifQ.signature"),
            .refresh_token = null,
            .id_token = null,
            .client_token = null,
            .expires_at = 0,
        },
    };
}

export fn go_http_request_bounded_cancelable(
    _: [*:0]const u8,
    _: [*:0]const u8,
    _: ?[*:0]const u8,
    _: ?[*]const [*:0]const u8,
    _: c_int,
    _: usize,
    cancel: ?*const fn (?*anyopaque) callconv(.c) c_int,
    context: ?*anyopaque,
) ?*Response {
    requests += 1;
    if (cancel) |check| {
        if (check(context) != 0) return null;
    }
    return response;
}

export fn go_http_response_destroy(_: ?*Response) void {}

export fn go_http_response_succeeded(value: ?*const Response) c_int {
    const result = value orelse return 0;
    return @intFromBool(result.status >= 200 and result.status < 300);
}

export fn go_http_request_bounded(
    _: [*:0]const u8,
    _: [*:0]const u8,
    _: ?[*:0]const u8,
    _: ?[*]const [*:0]const u8,
    _: c_int,
    _: usize,
) ?*Response {
    requests += 1;
    return response;
}

export fn go_handheld_ui_cancel_requested(_: ?*anyopaque) c_int {
    polls += 1;
    if (cancelled or polls < cancel_on_poll) return 0;
    cancelled = true;
    return 1;
}

export fn go_handheld_ui_cancelled(_: ?*anyopaque) c_int {
    return @intFromBool(cancelled);
}

export fn go_handheld_ui_wait(_: ?*anyopaque, _: u32) c_int {
    return 0;
}

export fn go_handheld_ui_draw_loading(_: ?*anyopaque, _: [*:0]const u8, _: [*:0]const u8, _: c_int) void {}
