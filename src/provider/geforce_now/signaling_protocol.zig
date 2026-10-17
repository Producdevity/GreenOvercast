const std = @import("std");

pub const PeerInfo = struct {
    id: u32,
    name: ?[]u8,
};

pub const IceCandidate = struct {
    candidate: []u8,
    sdp_mid: ?[]u8,
    sdp_m_line_index: ?u32,
    username_fragment: ?[]u8,
};

pub const Payload = union(enum) {
    none,
    bye,
    offer: []u8,
    ice: IceCandidate,
    unknown: ?[]u8,
};

pub const DecodedMessage = struct {
    allocator: std.mem.Allocator,
    peer_info: ?PeerInfo = null,
    acknowledgement_id: ?u32 = null,
    heartbeat: bool = false,
    peer_removed: bool = false,
    peer_from: ?u32 = null,
    payload: Payload = .none,

    pub fn deinit(self: *DecodedMessage) void {
        if (self.peer_info) |peer| {
            if (peer.name) |name| self.allocator.free(name);
        }
        switch (self.payload) {
            .offer => |sdp| self.allocator.free(sdp),
            .ice => |candidate| {
                self.allocator.free(candidate.candidate);
                if (candidate.sdp_mid) |mid| self.allocator.free(mid);
                if (candidate.username_fragment) |fragment| self.allocator.free(fragment);
            },
            .unknown => |message_type| {
                if (message_type) |value| self.allocator.free(value);
            },
            .none, .bye => {},
        }
        self.* = undefined;
    }
};

pub fn buildSignInUrl(
    allocator: std.mem.Allocator,
    signaling_url: []const u8,
    session_id: []const u8,
    peer_name: []const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, signaling_url, " \t\r\n");
    if (trimmed.len == 0 or session_id.len == 0 or peer_name.len == 0) return error.InvalidUrl;

    const query_index = std.mem.indexOfAny(u8, trimmed, "?#") orelse trimmed.len;
    const without_query = trimmed[0..query_index];
    var base = without_query;
    const scheme: []const u8 = "wss://";
    if (std.mem.startsWith(u8, base, "https://")) {
        base = base["https://".len..];
    } else if (std.mem.startsWith(u8, base, "wss://")) {
        base = base["wss://".len..];
    } else if (std.mem.startsWith(u8, base, "http://") or
        std.mem.startsWith(u8, base, "ws://"))
    {
        return error.InsecureUrl;
    }

    base = std.mem.trimRight(u8, base, "/");
    if (std.mem.endsWith(u8, base, "/sign_in"))
        base = std.mem.trimRight(u8, base[0 .. base.len - "/sign_in".len], "/");
    if (base.len == 0) return error.InvalidUrl;

    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();
    const writer = result.writer();
    try writer.print("{s}{s}/sign_in?peer_id=", .{ scheme, base });
    try writeQueryValue(writer, peer_name);
    try writer.writeAll("&version=2&peer_role=1&pairing_id=");
    try writeQueryValue(writer, session_id);

    const url = try result.toOwnedSlice();
    errdefer allocator.free(url);
    const parsed = std.Uri.parse(url) catch return error.InvalidUrl;
    if (parsed.host == null or parsed.user != null or parsed.password != null)
        return error.InvalidUrl;
    return url;
}

pub fn buildSubprotocol(allocator: std.mem.Allocator, session_id: []const u8) ![]u8 {
    if (session_id.len == 0) return error.InvalidSessionId;
    for (session_id) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.')
            return error.InvalidSessionId;
    }
    return std.fmt.allocPrint(allocator, "x-nv-sessionid.{s}", .{session_id});
}

pub fn decode(allocator: std.mem.Allocator, text: []const u8) !DecodedMessage {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    const root = try objectValue(parsed.value);

    var message = DecodedMessage{ .allocator = allocator };
    errdefer message.deinit();

    if (root.get("peer_info")) |raw_peer_info| {
        const peer_object = try objectValue(raw_peer_info);
        message.peer_info = .{
            .id = try requiredUnsigned(peer_object, "id"),
            .name = try duplicateOptionalString(allocator, peer_object, "name"),
        };
    }
    message.acknowledgement_id = try optionalUnsigned(root, "ackid");
    message.heartbeat = root.get("hb") != null;
    if (try optionalString(root, "error")) |error_name|
        message.peer_removed = std.mem.eql(u8, error_name, "peerRemoved");

    const raw_peer_message = root.get("peer_msg") orelse return message;
    const peer_message = try objectValue(raw_peer_message);
    message.peer_from = try optionalUnsigned(peer_message, "from");
    const nested_text = try requiredString(peer_message, "msg");
    const trimmed = std.mem.trim(u8, nested_text, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "BYE")) {
        message.payload = .bye;
        return message;
    }

    const nested = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch
        return error.InvalidPeerPayload;
    defer nested.deinit();
    const payload = objectValue(nested.value) catch return error.InvalidPeerPayload;
    const message_type = try optionalString(payload, "type");
    if (message_type != null and std.mem.eql(u8, message_type.?, "offer")) {
        message.payload = .{ .offer = try duplicateRequiredString(allocator, payload, "sdp") };
        return message;
    }
    if (payload.get("candidate") != null) {
        const candidate = try duplicateRequiredString(allocator, payload, "candidate");
        errdefer allocator.free(candidate);
        const sdp_mid = try duplicateOptionalString(allocator, payload, "sdpMid");
        errdefer if (sdp_mid) |mid| allocator.free(mid);
        const username_fragment = try duplicateOptionalString(
            allocator,
            payload,
            "usernameFragment",
        );
        errdefer if (username_fragment) |fragment| allocator.free(fragment);
        message.payload = .{ .ice = .{
            .candidate = candidate,
            .sdp_mid = sdp_mid,
            .sdp_m_line_index = try optionalUnsigned(payload, "sdpMLineIndex"),
            .username_fragment = username_fragment,
        } };
        return message;
    }

    message.payload = .{ .unknown = if (message_type) |value|
        try allocator.dupe(u8, value)
    else
        null };
    return message;
}

pub fn encodeHeartbeat(allocator: std.mem.Allocator) ![]u8 {
    return std.json.stringifyAlloc(allocator, .{ .hb = 1 }, .{});
}

pub fn encodeAcknowledgement(allocator: std.mem.Allocator, id: u32) ![]u8 {
    return std.json.stringifyAlloc(allocator, .{ .ack = id }, .{});
}

pub fn encodePeerInfo(
    allocator: std.mem.Allocator,
    peer_name: []const u8,
    peer_id: u32,
    acknowledgement_id: u32,
    width: u16,
    height: u16,
) ![]u8 {
    const resolution = try std.fmt.allocPrint(allocator, "{d}x{d}", .{ width, height });
    defer allocator.free(resolution);
    return std.json.stringifyAlloc(allocator, .{
        .ackid = acknowledgement_id,
        .peer_info = .{
            .browser = "Chrome",
            .browserVersion = "131",
            .connected = true,
            .id = peer_id,
            .name = peer_name,
            .peerRole = 0,
            .resolution = resolution,
            .version = 2,
        },
    }, .{});
}

pub fn encodeAnswer(
    allocator: std.mem.Allocator,
    sdp: []const u8,
    nvst_sdp: ?[]const u8,
    from: u32,
    to: u32,
    acknowledgement_id: u32,
) ![]u8 {
    if (nvst_sdp) |nvst| {
        return encodePeerPayload(allocator, .{
            .type = "answer",
            .sdp = sdp,
            .nvstSdp = nvst,
        }, from, to, acknowledgement_id);
    }
    return encodePeerPayload(allocator, .{
        .type = "answer",
        .sdp = sdp,
    }, from, to, acknowledgement_id);
}

pub fn encodeIceCandidate(
    allocator: std.mem.Allocator,
    candidate: []const u8,
    sdp_mid: ?[]const u8,
    sdp_m_line_index: ?u32,
    username_fragment: ?[]const u8,
    from: u32,
    to: u32,
    acknowledgement_id: u32,
) ![]u8 {
    var object = std.json.ObjectMap.init(allocator);
    defer object.deinit();
    try object.put("candidate", .{ .string = candidate });
    if (sdp_mid) |value| try object.put("sdpMid", .{ .string = value });
    if (sdp_m_line_index) |value| try object.put("sdpMLineIndex", .{ .integer = value });
    if (username_fragment) |value|
        try object.put("usernameFragment", .{ .string = value });
    return encodePeerPayload(
        allocator,
        std.json.Value{ .object = object },
        from,
        to,
        acknowledgement_id,
    );
}

pub fn isTcpIceCandidate(candidate: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, candidate, " \t\r\n");
    _ = tokens.next() orelse return false;
    _ = tokens.next() orelse return false;
    const transport = tokens.next() orelse return false;
    return std.ascii.eqlIgnoreCase(transport, "tcp");
}

fn encodePeerPayload(
    allocator: std.mem.Allocator,
    payload: anytype,
    from: u32,
    to: u32,
    acknowledgement_id: u32,
) ![]u8 {
    const payload_text = try std.json.stringifyAlloc(allocator, payload, .{});
    defer allocator.free(payload_text);
    return std.json.stringifyAlloc(allocator, .{
        .peer_msg = .{
            .from = from,
            .to = to,
            .msg = payload_text,
        },
        .ackid = acknowledgement_id,
    }, .{});
}

fn writeQueryValue(writer: anytype, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~') {
            try writer.writeByte(byte);
        } else {
            try writer.writeByte('%');
            try writer.writeByte(hex[byte >> 4]);
            try writer.writeByte(hex[byte & 0x0f]);
        }
    }
}

fn objectValue(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.ExpectedObject,
    };
}

fn requiredString(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    return (try optionalString(object, name)) orelse error.MissingField;
}

fn optionalString(object: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        .null => null,
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
    if (try optionalString(object, name)) |value| return try allocator.dupe(u8, value);
    return null;
}

fn requiredUnsigned(object: std.json.ObjectMap, name: []const u8) !u32 {
    return (try optionalUnsigned(object, name)) orelse error.MissingField;
}

fn optionalUnsigned(object: std.json.ObjectMap, name: []const u8) !?u32 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |number| if (number >= 0 and number <= std.math.maxInt(u32))
            @intCast(number)
        else
            error.InvalidField,
        .null => null,
        else => error.InvalidField,
    };
}

test "normalizes the sign-in URL and escapes identifiers" {
    const url = try buildSignInUrl(
        std.testing.allocator,
        "https://example.test/nvst/sign_in?old=1",
        "session/one",
        "peer name",
    );
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings(
        "wss://example.test/nvst/sign_in?peer_id=peer%20name&version=2&peer_role=1&pairing_id=session%2Fone",
        url,
    );

    const protocol = try buildSubprotocol(std.testing.allocator, "session-one");
    defer std.testing.allocator.free(protocol);
    try std.testing.expectEqualStrings("x-nv-sessionid.session-one", protocol);
    try std.testing.expectError(
        error.InvalidSessionId,
        buildSubprotocol(std.testing.allocator, "session one"),
    );
    try std.testing.expectError(
        error.InsecureUrl,
        buildSignInUrl(std.testing.allocator, "http://example.test/nvst", "session", "peer"),
    );
    try std.testing.expectError(
        error.InvalidUrl,
        buildSignInUrl(std.testing.allocator, "https://user@example.test/nvst", "session", "peer"),
    );
}

test "decodes offer and ICE peer messages" {
    var offer = try decode(std.testing.allocator,
        \\{"peer_msg":{"from":7,"to":2,"msg":"{\"type\":\"offer\",\"sdp\":\"v=0\\r\\n\"}"}}
    );
    defer offer.deinit();
    try std.testing.expectEqual(@as(?u32, 7), offer.peer_from);
    try std.testing.expectEqualStrings("v=0\r\n", offer.payload.offer);

    var ice = try decode(std.testing.allocator,
        \\{"peer_msg":{"from":7,"msg":"{\"candidate\":\"candidate:1 1 UDP 1 192.0.2.1 10000 typ host\",\"sdpMid\":\"video\",\"sdpMLineIndex\":2}"}}
    );
    defer ice.deinit();
    try std.testing.expectEqualStrings("video", ice.payload.ice.sdp_mid.?);
    try std.testing.expectEqual(@as(?u32, 2), ice.payload.ice.sdp_m_line_index);
}

test "decodes envelope metadata and disconnect messages" {
    var metadata = try decode(std.testing.allocator,
        \\{"peer_info":{"id":9,"name":"peer-nine"},"ackid":41,"hb":1}
    );
    defer metadata.deinit();
    try std.testing.expectEqual(@as(u32, 9), metadata.peer_info.?.id);
    try std.testing.expectEqualStrings("peer-nine", metadata.peer_info.?.name.?);
    try std.testing.expectEqual(@as(?u32, 41), metadata.acknowledgement_id);
    try std.testing.expect(metadata.heartbeat);

    var bye = try decode(std.testing.allocator, "{\"peer_msg\":{\"msg\":\"BYE\"}}");
    defer bye.deinit();
    try std.testing.expect(bye.payload == .bye);

    var removed = try decode(std.testing.allocator, "{\"error\":\"peerRemoved\"}");
    defer removed.deinit();
    try std.testing.expect(removed.peer_removed);
}

test "encodes answer and acknowledgement envelopes" {
    const peer_info = try encodePeerInfo(std.testing.allocator, "peer-one", 0, 1, 1280, 720);
    defer std.testing.allocator.free(peer_info);
    try std.testing.expect(std.mem.indexOf(u8, peer_info, "\"peerRole\":0") != null);

    const answer = try encodeAnswer(
        std.testing.allocator,
        "v=0\r\n",
        "nvst",
        2,
        1,
        8,
    );
    defer std.testing.allocator.free(answer);

    var decoded = try decode(std.testing.allocator, answer);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(?u32, 2), decoded.peer_from);
    try std.testing.expectEqual(@as(?u32, 8), decoded.acknowledgement_id);
    try std.testing.expect(decoded.payload == .unknown);

    const acknowledgement = try encodeAcknowledgement(std.testing.allocator, 41);
    defer std.testing.allocator.free(acknowledgement);
    try std.testing.expectEqualStrings("{\"ack\":41}", acknowledgement);
}

test "recognizes only TCP ICE transport tokens" {
    try std.testing.expect(isTcpIceCandidate(
        "candidate:1 1 TCP 1 192.0.2.1 9 typ host tcptype active",
    ));
    try std.testing.expect(!isTcpIceCandidate(
        "candidate:2 1 udp 1 192.0.2.1 10000 typ host",
    ));
    try std.testing.expect(!isTcpIceCandidate("tcp-but-not-a-candidate"));
}

test "rejects malformed and incomplete peer messages" {
    try std.testing.expectError(error.UnexpectedEndOfInput, decode(std.testing.allocator, "{"));
    try std.testing.expectError(
        error.MissingField,
        decode(std.testing.allocator, "{\"peer_info\":{}}"),
    );
    try std.testing.expectError(
        error.MissingField,
        decode(std.testing.allocator, "{\"peer_msg\":{}}"),
    );
    try std.testing.expectError(
        error.InvalidPeerPayload,
        decode(std.testing.allocator, "{\"peer_msg\":{\"msg\":\"{\"}}"),
    );
}
