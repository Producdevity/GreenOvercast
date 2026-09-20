const std = @import("std");

const InputCapabilities = struct {
    threshold_ms: u32 = 300,
    hid_mask: u32 = std.math.maxInt(u32),
    gamepad_mask: u32 = 0x0f,
    partial_hid_mask: u32 = std.math.maxInt(u32),
};

const IceCredentials = struct {
    username_fragment: []const u8,
    password: []const u8,
    fingerprint: []const u8,
};

pub fn sanitizeOffer(
    allocator: std.mem.Allocator,
    offer: []const u8,
    media_ip: ?[]const u8,
) ![]u8 {
    if (offer.len == 0) return error.InvalidOffer;
    var lines = std.ArrayList([]const u8).init(allocator);
    defer lines.deinit();
    var iterator = std.mem.splitScalar(u8, offer, '\n');
    while (iterator.next()) |line| try lines.append(std.mem.trimRight(u8, line, "\r"));

    const first_media = for (lines.items, 0..) |line, index| {
        if (std.mem.startsWith(u8, line, "m=")) break index;
    } else return error.MissingMedia;
    var shared = std.ArrayList([]const u8).init(allocator);
    defer shared.deinit();
    for (lines.items[0..first_media]) |line| {
        if (isSharedAttribute(line)) try shared.append(line);
    }

    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();
    const writer = output.writer();
    for (lines.items, 0..) |line, index| {
        try writeFixedAddress(writer, line, media_ip);
        try writer.writeAll("\r\n");
        if (!std.mem.startsWith(u8, line, "m=")) continue;
        for (shared.items) |shared_attribute| {
            if (sectionHasAttribute(lines.items, index, shared_attribute)) continue;
            try writer.writeAll(shared_attribute);
            try writer.writeAll("\r\n");
        }
    }
    return output.toOwnedSlice();
}

pub fn buildNvstAnswer(
    allocator: std.mem.Allocator,
    answer: []const u8,
    offer: []const u8,
    width: u16,
    height: u16,
    frames_per_second: u16,
    maximum_bitrate_kbps: u32,
) ![]u8 {
    if (width < 320 or height < 240 or frames_per_second == 0 or maximum_bitrate_kbps < 4000)
        return error.InvalidStreamProfile;
    const credentials = try extractIceCredentials(answer);
    const input = parseInputCapabilities(offer);
    const minimum_bitrate: u32 = 4000;
    const initial_bitrate = @max(minimum_bitrate, maximum_bitrate_kbps / 4);
    return std.fmt.allocPrint(
        allocator,
        "v=0\r\n" ++
            "o=GreenOvercast 1 1 IN IP4 127.0.0.1\r\n" ++
            "s=-\r\nt=0 0\r\n" ++
            "a=general.icePassword:{s}\r\n" ++
            "a=general.iceUserNameFragment:{s}\r\n" ++
            "a=general.dtlsFingerprint:{s}\r\n" ++
            "m=video 0 RTP/AVP\r\n" ++
            "a=msid:fbc-video-0\r\n" ++
            "a=video.enableRtpNack:1\r\n" ++
            "a=video.packetSize:1140\r\n" ++
            "a=video.rtpNackQueueLength:1024\r\n" ++
            "a=video.rtpNackQueueMaxPackets:512\r\n" ++
            "a=video.rtpNackMaxPacketCount:25\r\n" ++
            "a=video.clientViewportWd:{d}\r\n" ++
            "a=video.clientViewportHt:{d}\r\n" ++
            "a=video.maxFPS:{d}\r\n" ++
            "a=video.maxNumReferenceFrames:4\r\n" ++
            "a=video.mapRtpTimestampsToFrames:1\r\n" ++
            "a=video.bitDepth:8\r\n" ++
            "a=video.initialBitrateKbps:{d}\r\n" ++
            "a=video.initialPeakBitrateKbps:{d}\r\n" ++
            "a=vqos.bw.minimumBitrateKbps:{d}\r\n" ++
            "a=vqos.bw.maximumBitrateKbps:{d}\r\n" ++
            "m=audio 0 RTP/AVP\r\n" ++
            "a=msid:audio\r\n" ++
            "m=application 0 RTP/AVP\r\n" ++
            "a=msid:input_1\r\n" ++
            "a=ri.partialReliableThresholdMs:{d}\r\n" ++
            "a=ri.hidDeviceMask:{d}\r\n" ++
            "a=ri.enablePartiallyReliableTransferGamepad:{d}\r\n" ++
            "a=ri.enablePartiallyReliableTransferHid:{d}\r\n",
        .{
            credentials.password,
            credentials.username_fragment,
            credentials.fingerprint,
            width,
            height,
            frames_per_second,
            initial_bitrate,
            initial_bitrate,
            minimum_bitrate,
            maximum_bitrate_kbps,
            input.threshold_ms,
            input.hid_mask,
            input.gamepad_mask,
            input.partial_hid_mask,
        },
    );
}

pub fn codecPayloadType(sdp: []const u8, codec: []const u8) ?u8 {
    var lines = std.mem.splitScalar(u8, sdp, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, "a=rtpmap:")) continue;
        const mapping = line["a=rtpmap:".len..];
        const separator = std.mem.indexOfScalar(u8, mapping, ' ') orelse continue;
        const payload_type = std.fmt.parseInt(u8, mapping[0..separator], 10) catch continue;
        const encoding = mapping[separator + 1 ..];
        if (std.ascii.startsWithIgnoreCase(encoding, codec)) return payload_type;
    }
    return null;
}

pub fn narrowAnswerToH264Opus(
    allocator: std.mem.Allocator,
    answer: []const u8,
    offer: []const u8,
) ![]u8 {
    const video_payload = codecPayloadType(offer, "H264/") orelse return error.H264NotOffered;
    const audio_payload = codecPayloadType(offer, "OPUS/") orelse return error.OpusNotOffered;

    const Media = enum { other, video, audio };
    var media = Media.other;
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();
    const writer = output.writer();

    var lines = std.mem.splitScalar(u8, answer, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "m=")) {
            if (std.mem.startsWith(u8, line, "m=video ")) {
                media = .video;
                try writeSinglePayloadMediaLine(writer, line, video_payload);
                continue;
            }
            if (std.mem.startsWith(u8, line, "m=audio ")) {
                media = .audio;
                try writeSinglePayloadMediaLine(writer, line, audio_payload);
                continue;
            }
            media = .other;
        }

        const selected_payload = switch (media) {
            .video => video_payload,
            .audio => audio_payload,
            .other => null,
        };
        if (selected_payload) |payload| {
            if (codecAttributePayload(line)) |attribute_payload| {
                if (attribute_payload != payload) continue;
            }
        }
        try writer.writeAll(line);
        try writer.writeAll("\r\n");
    }
    return output.toOwnedSlice();
}

fn writeSinglePayloadMediaLine(writer: anytype, line: []const u8, payload: u8) !void {
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    const kind = fields.next() orelse return error.InvalidMediaLine;
    const port = fields.next() orelse return error.InvalidMediaLine;
    const protocol = fields.next() orelse return error.InvalidMediaLine;
    try writer.print("{s} {s} {s} {d}\r\n", .{ kind, port, protocol, payload });
}

fn codecAttributePayload(line: []const u8) ?u8 {
    const prefixes = [_][]const u8{ "a=rtpmap:", "a=fmtp:", "a=rtcp-fb:" };
    for (prefixes) |prefix| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const value = line[prefix.len..];
        if (value.len == 0 or value[0] == '*') return null;
        const end = std.mem.indexOfAny(u8, value, " \t") orelse value.len;
        return std.fmt.parseUnsigned(u8, value[0..end], 10) catch null;
    }
    return null;
}

pub fn mediaHostCandidate(
    allocator: std.mem.Allocator,
    address: []const u8,
    port: u16,
) !?[:0]u8 {
    if (port <= 1024 or port == 443) return null;

    var address_buffer: [15]u8 = undefined;
    const ip = publicIpv4(address, &address_buffer) orelse return null;
    return try std.fmt.allocPrintZ(
        allocator,
        "candidate:1 1 UDP 2122260223 {s} {d} typ host",
        .{ ip, port },
    );
}

fn extractIceCredentials(sdp: []const u8) !IceCredentials {
    return .{
        .username_fragment = attribute(sdp, "a=ice-ufrag:") orelse
            return error.MissingIceUsername,
        .password = attribute(sdp, "a=ice-pwd:") orelse
            return error.MissingIcePassword,
        .fingerprint = attribute(sdp, "a=fingerprint:") orelse
            return error.MissingFingerprint,
    };
}

fn parseInputCapabilities(sdp: []const u8) InputCapabilities {
    var result = InputCapabilities{};
    result.threshold_ms = integerAttribute(sdp, "ri.partialReliableThresholdMs") orelse result.threshold_ms;
    result.hid_mask = integerAttribute(sdp, "ri.hidDeviceMask") orelse result.hid_mask;
    result.gamepad_mask = integerAttribute(sdp, "ri.enablePartiallyReliableTransferGamepad") orelse result.gamepad_mask;
    result.partial_hid_mask = integerAttribute(sdp, "ri.enablePartiallyReliableTransferHid") orelse result.partial_hid_mask;
    result.threshold_ms = std.math.clamp(result.threshold_ms, 1, 5000);
    return result;
}

fn integerAttribute(sdp: []const u8, name: []const u8) ?u32 {
    var lines = std.mem.splitScalar(u8, sdp, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, "a=")) continue;
        const value_start = 2 + name.len + 1;
        if (line.len <= value_start or !std.mem.eql(u8, line[2 .. 2 + name.len], name) or
            line[2 + name.len] != ':') continue;
        const value = std.mem.trim(u8, line[value_start..], " \t");
        if (std.mem.startsWith(u8, value, "0x") or std.mem.startsWith(u8, value, "0X"))
            return std.fmt.parseInt(u32, value[2..], 16) catch null;
        return std.fmt.parseInt(u32, value, 10) catch null;
    }
    return null;
}

fn attribute(sdp: []const u8, prefix: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, sdp, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.startsWith(u8, line, prefix) and line.len > prefix.len)
            return line[prefix.len..];
    }
    return null;
}

fn publicIpv4(address: []const u8, buffer: *[15]u8) ?[]const u8 {
    _ = std.net.Ip4Address.parse(address, 0) catch {
        const label_end = std.mem.indexOfScalar(u8, address, '.') orelse address.len;
        var parts = std.mem.splitScalar(u8, address[0..label_end], '-');
        var octets: [4]u8 = undefined;
        for (&octets) |*octet| {
            const part = parts.next() orelse return null;
            octet.* = std.fmt.parseInt(u8, part, 10) catch return null;
        }
        if (parts.next() != null) return null;
        return std.fmt.bufPrint(buffer, "{d}.{d}.{d}.{d}", .{
            octets[0], octets[1], octets[2], octets[3],
        }) catch return null;
    };
    return address;
}

fn isSharedAttribute(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "a=ice-ufrag:") or
        std.mem.startsWith(u8, line, "a=ice-pwd:") or
        std.mem.startsWith(u8, line, "a=fingerprint:") or
        std.mem.startsWith(u8, line, "a=setup:");
}

fn sectionHasAttribute(lines: []const []const u8, start: usize, attribute_line: []const u8) bool {
    const prefix = attribute_line[0 .. std.mem.indexOfScalar(u8, attribute_line, ':').? + 1];
    var index = start + 1;
    while (index < lines.len and !std.mem.startsWith(u8, lines[index], "m=")) : (index += 1) {
        if (std.mem.startsWith(u8, lines[index], prefix)) return true;
    }
    return false;
}

fn writeFixedAddress(writer: anytype, line: []const u8, media_ip: ?[]const u8) !void {
    const ip = media_ip orelse return writer.writeAll(line);
    if (std.mem.eql(u8, line, "c=IN IP4 0.0.0.0"))
        return writer.print("c=IN IP4 {s}", .{ip});
    if (!std.mem.startsWith(u8, line, "a=candidate:")) return writer.writeAll(line);

    var tokens = std.mem.tokenizeScalar(u8, line, ' ');
    var index: usize = 0;
    var first = true;
    while (tokens.next()) |token| : (index += 1) {
        if (!first) try writer.writeByte(' ');
        first = false;
        try writer.writeAll(if (index == 4 and std.mem.eql(u8, token, "0.0.0.0")) ip else token);
    }
}

test "offer sanitation fixes the media address and copies shared attributes" {
    const offer =
        "v=0\r\n" ++
        "a=ice-ufrag:remote\r\n" ++
        "a=ice-pwd:secret\r\n" ++
        "a=fingerprint:sha-256 AA:BB\r\n" ++
        "a=setup:actpass\r\n" ++
        "m=video 9 UDP/TLS/RTP/SAVPF 102\r\n" ++
        "c=IN IP4 0.0.0.0\r\n" ++
        "a=candidate:1 1 udp 1 0.0.0.0 5000 typ host\r\n";
    const result = try sanitizeOffer(std.testing.allocator, offer, "192.0.2.10");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "c=IN IP4 192.0.2.10") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, " 192.0.2.10 5000 ") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, result, "a=ice-ufrag:remote"));
}

test "media overrides preserve the remaining session attributes" {
    const offer = "v=0\r\n" ++
        "a=ice-ufrag:shared\r\na=ice-pwd:password\r\n" ++
        "a=fingerprint:sha-256 AA:BB\r\na=setup:actpass\r\n" ++
        "m=video 9 UDP/TLS/RTP/SAVPF 96\r\na=setup:passive\r\n" ++
        "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=ice-ufrag:audio\r\n";
    const result = try sanitizeOffer(std.testing.allocator, offer, null);
    defer std.testing.allocator.free(result);
    const video_start = std.mem.indexOf(u8, result, "m=video").?;
    const audio_start = std.mem.indexOf(u8, result, "m=audio").?;
    const video = result[video_start..audio_start];
    const audio = result[audio_start..];
    try std.testing.expect(std.mem.indexOf(u8, video, "a=setup:actpass") == null);
    try std.testing.expect(std.mem.indexOf(u8, video, "a=setup:passive") != null);
    try std.testing.expect(std.mem.indexOf(u8, video, "a=ice-ufrag:shared") != null);
    try std.testing.expect(std.mem.indexOf(u8, video, "a=ice-pwd:password") != null);
    try std.testing.expect(std.mem.indexOf(u8, video, "a=fingerprint:sha-256 AA:BB") != null);
    try std.testing.expect(std.mem.indexOf(u8, audio, "a=ice-ufrag:shared") == null);
    try std.testing.expect(std.mem.indexOf(u8, audio, "a=ice-ufrag:audio") != null);
    try std.testing.expect(std.mem.indexOf(u8, audio, "a=ice-pwd:password") != null);
    try std.testing.expect(std.mem.indexOf(u8, audio, "a=setup:actpass") != null);
}

test "NVST answer uses negotiated dimensions and remote input capabilities" {
    const answer =
        "v=0\r\na=ice-ufrag:local\r\na=ice-pwd:password\r\n" ++
        "a=fingerprint:sha-256 CC:DD\r\n";
    const offer = "a=ri.partialReliableThresholdMs:250\r\n" ++
        "a=ri.enablePartiallyReliableTransferGamepad:0x03\r\n";
    const result = try buildNvstAnswer(std.testing.allocator, answer, offer, 640, 480, 30, 6000);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "a=video.clientViewportWd:640") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "a=ri.partialReliableThresholdMs:250") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "a=ri.enablePartiallyReliableTransferGamepad:3") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "a=video.initialBitrateKbps:4000\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "a=video.initialPeakBitrateKbps:4000\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "a=vqos.bw.minimumBitrateKbps:4000\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "a=vqos.bw.maximumBitrateKbps:6000\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "enableBandwidthEstimation") == null);
    try std.testing.expectError(error.InvalidStreamProfile, buildNvstAnswer(std.testing.allocator, answer, offer, 640, 480, 30, 2000));
}

test "codec payload types are matched without assuming Xbox values" {
    const sdp = "a=rtpmap:96 H264/90000\r\na=rtpmap:109 opus/48000/2\r\n";
    try std.testing.expectEqual(@as(?u8, 96), codecPayloadType(sdp, "h264/"));
    try std.testing.expectEqual(@as(?u8, 109), codecPayloadType(sdp, "OPUS/"));
}

test "answer advertises only H264 and Opus payloads" {
    const offer =
        "m=video 9 UDP/TLS/RTP/SAVPF 96 97 98 99 100\r\n" ++
        "a=rtpmap:96 H264/90000\r\n" ++
        "a=rtpmap:97 rtx/90000\r\n" ++
        "a=fmtp:97 apt=96\r\n" ++
        "a=rtpmap:98 H265/90000\r\n" ++
        "a=rtpmap:99 rtx/90000\r\n" ++
        "a=fmtp:99 apt=98\r\n" ++
        "m=audio 9 UDP/TLS/RTP/SAVPF 111 63 0\r\n" ++
        "a=rtpmap:111 opus/48000/2\r\n";
    const answer =
        "v=0\r\n" ++
        "m=video 9 UDP/TLS/RTP/SAVPF 96 97 98 99 100\r\n" ++
        "a=mid:1\r\n" ++
        "a=rtpmap:96 H264/90000\r\n" ++
        "a=fmtp:96 packetization-mode=1\r\n" ++
        "a=rtcp-fb:96 nack pli\r\n" ++
        "a=rtpmap:98 H265/90000\r\n" ++
        "a=fmtp:99 apt=98\r\n" ++
        "a=rtcp-fb:* transport-cc\r\n" ++
        "m=audio 9 UDP/TLS/RTP/SAVPF 111 63 0\r\n" ++
        "a=mid:0\r\n" ++
        "a=rtpmap:111 opus/48000/2\r\n" ++
        "a=rtpmap:63 red/48000/2\r\n" ++
        "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n" ++
        "a=mid:2\r\n";
    const result = try narrowAnswerToH264Opus(std.testing.allocator, answer, offer);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "m=video 9 UDP/TLS/RTP/SAVPF 96\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "H265/") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "red/48000") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "a=rtcp-fb:* transport-cc") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "m=application 9 UDP/DTLS/SCTP webrtc-datachannel") != null);
}

test "media endpoint becomes a UDP host candidate" {
    const candidate = (try mediaHostCandidate(
        std.testing.allocator,
        "203.0.113.10",
        49005,
    )).?;
    defer std.testing.allocator.free(candidate);
    try std.testing.expectEqualStrings(
        "candidate:1 1 UDP 2122260223 203.0.113.10 49005 typ host",
        candidate,
    );
}

test "media candidate accepts an Alliance host and rejects control ports" {
    const candidate = (try mediaHostCandidate(
        std.testing.allocator,
        "203-0-113-10.cloudmatch.example",
        49005,
    )).?;
    defer std.testing.allocator.free(candidate);
    try std.testing.expectEqualStrings(
        "candidate:1 1 UDP 2122260223 203.0.113.10 49005 typ host",
        candidate,
    );
    try std.testing.expect((try mediaHostCandidate(
        std.testing.allocator,
        "203.0.113.10",
        443,
    )) == null);
    try std.testing.expect((try mediaHostCandidate(
        std.testing.allocator,
        "not-an-address",
        49005,
    )) == null);
}
