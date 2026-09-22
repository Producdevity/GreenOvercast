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
        while (true) {
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
            if (message.peer_info) |peer| {
                if (peer.name) |name| {
                    if (std.mem.eql(u8, name, self.peer_name)) self.local_peer_id = peer.id;
                }
            }
            if (message.peer_from) |from| self.remote_peer_id = from;
            if (message.acknowledgement_id) |id| {
                const own_echo = if (message.peer_info) |peer|
                    peer.id == self.local_peer_id
                else
                    false;
                if (!own_echo) {
                    const acknowledgement = try protocol.encodeAcknowledgement(self.allocator, id);
                    defer self.allocator.free(acknowledgement);
                    try self.sendText(acknowledgement);
                }
            }
            if (message.heartbeat) {
                const heartbeat = try protocol.encodeHeartbeat(self.allocator);
                defer self.allocator.free(heartbeat);
                try self.sendText(heartbeat);
                self.last_heartbeat_ms = std.time.milliTimestamp();
            }
            return message;
        }
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
