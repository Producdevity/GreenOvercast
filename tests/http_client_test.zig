const std = @import("std");
const c = @cImport({
    @cInclude("http_client.h");
    @cInclude("curl/curl.h");
});

const Receiver = struct {
    server: *std.net.Server,
    method: ?std.http.Method = null,
    body: [256]u8 = undefined,
    body_length: usize = 0,
    failure: ?anyerror = null,

    fn run(self: *Receiver) void {
        self.receive() catch |err| {
            self.failure = err;
        };
    }

    fn receive(self: *Receiver) !void {
        var descriptors = [_]std.posix.pollfd{.{
            .fd = self.server.stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&descriptors, 5000) == 0) return error.AcceptTimedOut;
        const connection = try self.server.accept();
        defer connection.stream.close();
        const timeout = std.posix.timeval{ .sec = 5, .usec = 0 };
        try std.posix.setsockopt(connection.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));
        var buffer: [4096]u8 = undefined;
        var http = std.http.Server.init(connection, &buffer);
        var request = try http.receiveHead();
        self.method = request.head.method;
        const reader = try request.reader();
        self.body_length = try reader.readAll(&self.body);
        try request.respond("ok", .{ .keep_alive = false });
    }
};

fn checkRequest(method: [:0]const u8, body: ?[:0]const u8, expected: std.http.Method) !void {
    const loopback = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try loopback.listen(.{});
    defer server.deinit();
    const address = try std.fmt.allocPrintZ(std.testing.allocator, "http://127.0.0.1:{d}/session", .{server.listen_address.getPort()});
    defer std.testing.allocator.free(address);
    var receiver = Receiver{ .server = &server };
    const thread = try std.Thread.spawn(.{}, Receiver.run, .{&receiver});
    const response = c.go_http_request_bounded(method.ptr, address.ptr, if (body) |value| value.ptr else null, null, 0, 256);
    thread.join();
    defer c.go_http_response_destroy(response);
    if (receiver.failure) |err| return err;
    try std.testing.expect(response != null);
    try std.testing.expectEqual(@as(c_long, 200), response.*.status);
    try std.testing.expectEqual(expected, receiver.method.?);
    try std.testing.expectEqualStrings(body orelse "", receiver.body[0..receiver.body_length]);
    try std.testing.expectEqualStrings("ok", response.*.data[0..response.*.len]);
}

test "HTTP request methods preserve their bodies on the wire" {
    try std.testing.expect(c.curl_global_init(c.CURL_GLOBAL_DEFAULT) == c.CURLE_OK);
    defer c.curl_global_cleanup();
    try checkRequest("PUT", "{\"action\":6,\"adUpdates\":[]}", .PUT);
    try checkRequest("PATCH", "{\"value\":true}", .PATCH);
    try checkRequest("POST", "{\"appId\":1}", .POST);
    try checkRequest("POST", null, .POST);
    try checkRequest("GET", null, .GET);
    try checkRequest("GET", "query body", .GET);
    try checkRequest("DELETE", null, .DELETE);
}
