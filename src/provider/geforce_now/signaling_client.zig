const std = @import("std");
const protocol = @import("signaling_protocol.zig");

const c = @cImport({
    @cInclude("websocket_client.h");
});

const origin = "https://play.geforcenow.com";
const user_agent = "Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36 Chrome/128.0.0.0 Safari/537.36";
const maximum_message_size = 128 * 1024;
const maximum_send_attempts = 500;

pub const Client = struct {
    allocator: std.mem.Allocator,
    socket: *c.GoWebSocket,
    peer_name: []u8,
    receive_buffer: std.ArrayList(u8),
    local_peer_id: u32 = 0,
    remote_peer_id: u32 = 1,
    acknowledgement_counter: u32 = 0,
    last_heartbeat_ms: i64,
    receiving_fragmented_text: bool = false,
    received_messages: u32 = 0,
    peer_assigned: bool = false,
    assignment_acknowledged: bool = false,
    heartbeat_seen: bool = false,

    pub fn connect(
        allocator: std.mem.Allocator,
        signaling_url: []const u8,
        session_id: []const u8,
        peer_name: []const u8,
        width: u16,
        height: u16,
    ) !*Client {
        const url = try protocol.buildSignInUrl(allocator, signaling_url, session_id, peer_name);
        defer allocator.free(url);
        const subprotocol = try protocol.buildSubprotocol(allocator, session_id);
        defer allocator.free(subprotocol);
        const url_z = try allocator.dupeZ(u8, url);
        defer allocator.free(url_z);
        const subprotocol_z = try allocator.dupeZ(u8, subprotocol);
        defer allocator.free(subprotocol_z);

        var error_buffer: [256]u8 = [_]u8{0} ** 256;
        const socket = c.go_websocket_open(
            url_z.ptr,
            origin,
            subprotocol_z.ptr,
            user_agent,
            &error_buffer,
            error_buffer.len,
        ) orelse {
            const message = std.mem.sliceTo(&error_buffer, 0);
            if (message.len > 0) std.debug.print("GeForce NOW signaling: {s}\n", .{message});
            return error.SignalingConnectionFailed;
        };
        errdefer c.go_websocket_close(socket);

        const client = try allocator.create(Client);
        errdefer allocator.destroy(client);
        client.* = .{
            .allocator = allocator,
            .socket = socket,
            .peer_name = try allocator.dupe(u8, peer_name),
            .receive_buffer = std.ArrayList(u8).init(allocator),
            .last_heartbeat_ms = std.time.milliTimestamp(),
        };
        errdefer allocator.free(client.peer_name);
        try client.sendPeerInfo(width, height);
        return client;
    }

    pub fn destroy(self: *Client) void {
        c.go_websocket_close(self.socket);
        self.receive_buffer.deinit();
        self.allocator.free(self.peer_name);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn poll(self: *Client) !?protocol.DecodedMessage {
        if (std.time.milliTimestamp() - self.last_heartbeat_ms >= 5000) {
            const heartbeat = try protocol.encodeHeartbeat(self.allocator);
            defer self.allocator.free(heartbeat);
            try self.sendText(heartbeat);
            self.last_heartbeat_ms = std.time.milliTimestamp();
        }

        var chunk: [4096]u8 = undefined;
        var frame: c.GoWebSocketFrame = undefined;
        var frames: usize = 0;
        while (frames < 64) : (frames += 1) {
            const result = c.go_websocket_receive(self.socket, &chunk, chunk.len, &frame);
            if (result == 0) return null;
            if (result == -2) return error.SignalingClosed;
            if (result < 0) {
                std.debug.print("GeForce NOW signaling: {s}\n", .{
                    std.mem.span(c.go_websocket_last_error(self.socket)),
                });
                return error.SignalingReceiveFailed;
            }
            if (frame.flags & c.GO_WEBSOCKET_TEXT != 0 and
                frame.offset == 0 and !self.receiving_fragmented_text)
                self.receive_buffer.clearRetainingCapacity();
            if (frame.flags & c.GO_WEBSOCKET_TEXT == 0) {
                continue;
            }
            if (frame.length > maximum_message_size - self.receive_buffer.items.len)
                return error.SignalingMessageTooLarge;
            try self.receive_buffer.appendSlice(chunk[0..frame.length]);
            if (frame.bytes_left != 0) continue;
            if (frame.flags & c.GO_WEBSOCKET_CONTINUATION != 0) {
                self.receiving_fragmented_text = true;
                continue;
            }
            self.receiving_fragmented_text = false;

            var message = try protocol.decode(self.allocator, self.receive_buffer.items);
            errdefer message.deinit();
            self.received_messages +|= 1;
            var assignment_received = false;
            if (message.peer_info) |peer| {
                if (peer.name) |name| {
                    if (std.mem.eql(u8, name, self.peer_name)) {
                        self.local_peer_id = peer.id;
                        self.peer_assigned = true;
                        self.assignment_acknowledged = false;
                        assignment_received = true;
                    }
                }
            }
            if (message.peer_from) |from| {
                if (self.peer_assigned and from == self.local_peer_id) {
                    message.deinit();
                    continue;
                }
                self.remote_peer_id = from;
            }
            if (message.acknowledgement_id) |id| {
                const acknowledgement = try protocol.encodeAcknowledgement(self.allocator, id);
                defer self.allocator.free(acknowledgement);
                try self.sendText(acknowledgement);
                if (assignment_received) self.assignment_acknowledged = true;
            }
            if (message.heartbeat) {
                self.heartbeat_seen = true;
                const heartbeat = try protocol.encodeHeartbeat(self.allocator);
                defer self.allocator.free(heartbeat);
                try self.sendText(heartbeat);
                self.last_heartbeat_ms = std.time.milliTimestamp();
            }
            return message;
        }
        return null;
    }

    pub fn sendAnswer(self: *Client, sdp: []const u8, nvst_sdp: []const u8) !void {
        const message = try protocol.encodeAnswer(
            self.allocator,
            sdp,
            nvst_sdp,
            self.local_peer_id,
            self.remote_peer_id,
            self.nextAcknowledgement(),
        );
        defer self.allocator.free(message);
        try self.sendText(message);
    }

    pub fn sendIceCandidate(
        self: *Client,
        candidate: []const u8,
        sdp_mid: ?[]const u8,
    ) !void {
        if (protocol.isTcpIceCandidate(candidate)) return;
        const message = try protocol.encodeIceCandidate(
            self.allocator,
            candidate,
            sdp_mid,
            null,
            null,
            self.local_peer_id,
            self.remote_peer_id,
            self.nextAcknowledgement(),
        );
        defer self.allocator.free(message);
        try self.sendText(message);
    }

    fn sendPeerInfo(self: *Client, width: u16, height: u16) !void {
        const message = try protocol.encodePeerInfo(
            self.allocator,
            self.peer_name,
            self.local_peer_id,
            self.nextAcknowledgement(),
            width,
            height,
        );
        defer self.allocator.free(message);
        try self.sendText(message);
    }

    fn sendText(self: *Client, message: []const u8) !void {
        var offset: usize = 0;
        var attempts: usize = 0;
        while (offset < message.len and attempts < maximum_send_attempts) : (attempts += 1) {
            var sent: usize = 0;
            const result = c.go_websocket_send(
                self.socket,
                message.ptr + offset,
                message.len - offset,
                c.GO_WEBSOCKET_TEXT,
                &sent,
            );
            offset += sent;
            if (result < 0) {
                std.debug.print("GeForce NOW signaling: {s}\n", .{
                    std.mem.span(c.go_websocket_last_error(self.socket)),
                });
                return error.SignalingSendFailed;
            }
            if (offset < message.len) std.Thread.sleep(std.time.ns_per_ms);
        }
        if (offset != message.len) return error.SignalingSendTimeout;
    }

    fn nextAcknowledgement(self: *Client) u32 {
        self.acknowledgement_counter +%= 1;
        if (self.acknowledgement_counter == 0) self.acknowledgement_counter = 1;
        return self.acknowledgement_counter;
    }
};

const assignment = "{\"ackid\":7,\"peer_info\":{\"id\":3,\"name\":\"peer-test\"}}";
const remote_offer = "{\"ackid\":8,\"peer_msg\":{\"from\":1,\"to\":3,\"msg\":\"{\\\"type\\\":\\\"offer\\\",\\\"sdp\\\":\\\"v=0\\\"}\"}}";

fn testClient() !*Client {
    return Client.connect(std.testing.allocator, "wss://example.invalid/nvst/", "test-session", "peer-test", 640, 480);
}

test "peer assignment is acknowledged before the server offers a stream" {
    const socket = @import("gfn_websocket_fake");
    socket.reset();
    socket.incoming = &.{.{ .text = assignment }};
    socket.gated_offer = remote_offer;
    const client = try testClient();
    defer client.destroy();
    var assigned = (try client.poll()).?;
    defer assigned.deinit();
    try std.testing.expectEqual(@as(u32, 3), client.local_peer_id);
    try std.testing.expect(socket.assignment_acknowledged);
    var offer = (try client.poll()) orelse return error.OfferNotReceived;
    defer offer.deinit();
    try std.testing.expectEqualStrings("v=0", offer.payload.offer);
    try std.testing.expectEqualStrings("{\"ack\":8}", socket.message(2));
}

test "repeated assignments and remote peer announcements are acknowledged" {
    const socket = @import("gfn_websocket_fake");
    socket.reset();
    socket.incoming = &.{ .{ .text = assignment }, .{ .text = assignment }, .{ .text = "{\"ackid\":9,\"peer_info\":{\"id\":1,\"name\":\"server\"}}" } };
    const client = try testClient();
    defer client.destroy();
    for (0..3) |_| {
        var message = (try client.poll()).?;
        message.deinit();
    }
    try std.testing.expectEqual(@as(usize, 4), socket.sent_count);
    try std.testing.expectEqualStrings("{\"ack\":7}", socket.message(1));
    try std.testing.expectEqualStrings("{\"ack\":7}", socket.message(2));
    try std.testing.expectEqualStrings("{\"ack\":9}", socket.message(3));
    try std.testing.expectEqual(@as(u32, 3), client.local_peer_id);
}

test "echoed local peer messages neither change the remote peer nor generate ACKs" {
    const socket = @import("gfn_websocket_fake");
    socket.reset();
    socket.incoming = &.{ .{ .text = assignment }, .{ .text = "{\"ackid\":10,\"peer_msg\":{\"from\":3,\"to\":1,\"msg\":\"{\\\"type\\\":\\\"answer\\\"}\"}}" } };
    const client = try testClient();
    defer client.destroy();
    var assigned = (try client.poll()).?;
    defer assigned.deinit();
    try std.testing.expect((try client.poll()) == null);
    try std.testing.expectEqual(@as(u32, 1), client.remote_peer_id);
    try std.testing.expectEqual(@as(usize, 2), socket.sent_count);
    try client.sendAnswer("answer", "nvst");
    try std.testing.expect(std.mem.indexOf(u8, socket.message(2), "\"to\":1") != null);
}

test "assignment and offer assembly survives partial frames and fragmented messages" {
    const socket = @import("gfn_websocket_fake");
    socket.reset();
    const split = assignment.len / 2;
    const offer_split = remote_offer.len / 2;
    socket.incoming = &.{
        .{ .text = assignment[0..split], .bytes_left = assignment.len - split },
        .{ .text = assignment[split..], .offset = split },
        .{ .text = remote_offer[0..offer_split], .flags = 1 | 4 },
        .{ .text = remote_offer[offer_split..] },
    };
    const client = try testClient();
    defer client.destroy();
    var assigned = (try client.poll()).?;
    defer assigned.deinit();
    try std.testing.expect(socket.assignment_acknowledged);
    var offer = (try client.poll()).?;
    defer offer.deinit();
    try std.testing.expectEqualStrings("v=0", offer.payload.offer);
    try std.testing.expectEqual(@as(usize, 3), socket.sent_count);
}

test "server rejection and transport closure do not become offer timeouts" {
    const socket = @import("gfn_websocket_fake");
    socket.reset();
    socket.incoming = &.{.{ .text = "{\"error\":\"requestRejected\"}" }};
    const client = try testClient();
    defer client.destroy();
    try std.testing.expectError(error.SignalingRejected, client.poll());
    socket.closed = true;
    try std.testing.expectError(error.SignalingClosed, client.poll());
}

test "a queued WebSocket close frame is reported immediately" {
    const socket = @import("gfn_websocket_fake");
    socket.reset();
    socket.incoming = &.{.{ .text = "", .flags = c.GO_WEBSOCKET_CLOSE }};
    const client = try testClient();
    defer client.destroy();
    try std.testing.expectError(error.SignalingClosed, client.poll());
}

test "failed assignment acknowledgements release the decoded message" {
    const socket = @import("gfn_websocket_fake");
    socket.reset();
    socket.incoming = &.{.{ .text = assignment }};
    const client = try testClient();
    defer client.destroy();
    socket.fail_send = true;
    try std.testing.expectError(error.SignalingSendFailed, client.poll());
}

test "echo floods leave time for cancellation and keep the peer identity" {
    const socket = @import("gfn_websocket_fake");
    socket.reset();
    var frames: [80]socket.Incoming = undefined;
    @memset(&frames, .{ .text = "{\"peer_msg\":{\"from\":3,\"msg\":\"{\\\"type\\\":\\\"answer\\\"}\"}}" });
    frames[0] = .{ .text = assignment };
    frames[79] = .{ .text = remote_offer };
    socket.incoming = &frames;
    const client = try testClient();
    defer client.destroy();
    var assigned = (try client.poll()).?;
    defer assigned.deinit();
    try std.testing.expect((try client.poll()) == null);
    try std.testing.expectEqual(@as(u32, 65), client.received_messages);
    var offer = (try client.poll()).?;
    defer offer.deinit();
    try std.testing.expect(offer.payload == .offer);
    try std.testing.expectEqual(@as(u32, 1), client.remote_peer_id);
}

test "peer removal is acknowledged and reported as a remote close" {
    const socket = @import("gfn_websocket_fake");
    socket.reset();
    socket.incoming = &.{.{ .text = "{\"error\":\"peerRemoved\",\"ackid\":7}" }};
    const client = try testClient();
    defer client.destroy();
    var message = (try client.poll()).?;
    defer message.deinit();
    try std.testing.expect(message.peer_removed);
    try std.testing.expectEqualStrings("{\"ack\":7}", socket.message(1));
}

test "signaling setup and ACK exchange release partial allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const socket = @import("gfn_websocket_fake");
            socket.reset();
            socket.incoming = &.{.{ .text = assignment }};
            socket.gated_offer = remote_offer;
            const client = try Client.connect(allocator, "wss://example.invalid/nvst/", "test-session", "peer-test", 640, 480);
            defer client.destroy();
            var assigned = (try client.poll()).?;
            defer assigned.deinit();
            var offer = (try client.poll()).?;
            defer offer.deinit();
            try std.testing.expect(offer.payload == .offer);
        }
    }.run, .{});
}
