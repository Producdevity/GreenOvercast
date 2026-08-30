const std = @import("std");
const json_reader = @import("json_reader");
const json_writer = @import("json_writer");
const message_protocol = @import("message_protocol.zig");

const c = @cImport({
    @cInclude("rtc/rtc.h");
    @cInclude("audio_pipeline.h");
    @cInclude("cloud_session.h");
    @cInclude("controller.h");
    @cInclude("http_client.h");
    @cInclude("video_pipeline.h");
});

const audio_payload_type = 111;
const Wait = *const fn (?*anyopaque, c_uint) callconv(.c) c_int;

const Session = struct {
    cloud: *c.GoCloudSession,
    video: *c.GoVideoPipeline,
    audio: *c.GoAudioPipeline,
    controller: *c.GoControllerInput,
    wait: Wait,
    wait_context: ?*anyopaque,
    peer: c_int = -1,
    input_channel: c_int = -1,
    control_channel: c_int = -1,
    message_channel: c_int = -1,
    chat_channel: c_int = -1,
    video_track: c_int = -1,
    audio_track: c_int = -1,
    stream_width: c_uint,
    stream_height: c_uint,
    install_id: [37]u8 = [_]u8{0} ** 37,
    connected: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    gathering_complete: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    handshake_complete: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    peer_closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    peer_failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    expected_disconnect: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    shutting_down: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    input_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    video_bitrate_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn debug(comptime format: []const u8, args: anytype) void {
    if (std.posix.getenv("GREENOVERCAST_DEBUG") != null) std.debug.print(format, args);
}

fn sessionFromContext(context: ?*anyopaque) ?*Session {
    const pointer = context orelse return null;
    return @ptrCast(@alignCast(pointer));
}

fn cString(pointer: [*c]const u8) ?[]const u8 {
    if (pointer == null) return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(pointer)));
}

fn responseData(response: [*c]c.GoHttpResponse) ?[]const u8 {
    if (response == null or response.*.data == null) return null;
    return response.*.data[0..response.*.len];
}

fn messageData(data: [*c]const u8, size: c_int) ?[]const u8 {
    if (data == null) return null;
    const signed_length: i64 = size;
    const length: usize = @intCast(if (signed_length < 0) -signed_length else signed_length);
    return data[0..length];
}

fn generateInstallId(output: *[37]u8) void {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    _ = std.fmt.bufPrintZ(
        output,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-" ++
            "{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15],
        },
    ) catch {
        @memcpy(output, "00000000-0000-4000-8000-000000000000\x00");
    };
}

fn onDescription(_: c_int, sdp: [*c]const u8, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    if (cString(sdp)) |value| debug("Local SDP ready ({d} bytes)\n", .{value.len});
}

fn onGatheringState(_: c_int, state: c.rtcGatheringState, context: ?*anyopaque) callconv(.c) void {
    const session = sessionFromContext(context) orelse return;
    debug("ICE gathering: {d}\n", .{state});
    if (state == c.RTC_GATHERING_COMPLETE) session.gathering_complete.store(true, .release);
}

fn onConnectionState(_: c_int, state: c.rtcState, context: ?*anyopaque) callconv(.c) void {
    const session = sessionFromContext(context) orelse return;
    debug("WebRTC state: {d}\n", .{state});
    switch (state) {
        c.RTC_CONNECTED => {
            session.connected.store(true, .release);
            debug("WebRTC connected\n", .{});
        },
        c.RTC_FAILED => {
            session.connected.store(false, .release);
            if (session.expected_disconnect.load(.acquire))
                session.peer_closed.store(true, .release)
            else
                session.peer_failed.store(true, .release);
        },
        c.RTC_CLOSED => {
            session.connected.store(false, .release);
            if (!session.shutting_down.load(.acquire)) {
                session.peer_closed.store(true, .release);
                if (session.expected_disconnect.load(.acquire))
                    debug("Xbox ended the cloud session\n", .{});
            }
        },
        else => {},
    }
}

fn onDataChannel(_: c_int, channel: c_int, _: ?*anyopaque) callconv(.c) void {
    debug("Data channel received: {d}\n", .{channel});
}

fn onInputMessage(_: c_int, data: [*c]const u8, size: c_int, _: ?*anyopaque) callconv(.c) void {
    const packet = messageData(data, size) orelse return;
    if (packet.len < 10) return;
    const report_type = std.mem.readInt(u16, packet[0..2], .little);
    if (report_type != 16) return;
    const height = std.mem.readInt(u32, packet[2..6], .little);
    const width = std.mem.readInt(u32, packet[6..10], .little);
    debug("Server input coordinate space: {d}x{d}\n", .{ width, height });
}

fn onAudioMessage(_: c_int, data: [*c]const u8, size: c_int, context: ?*anyopaque) callconv(.c) void {
    const session = sessionFromContext(context) orelse return;
    if (session.shutting_down.load(.acquire) or size <= 0 or data == null) return;
    c.go_audio_pipeline_push_rtp(session.audio, @ptrCast(data), @intCast(size));
}

fn onVideoMessage(_: c_int, data: [*c]const u8, size: c_int, context: ?*anyopaque) callconv(.c) void {
    const session = sessionFromContext(context) orelse return;
    if (session.shutting_down.load(.acquire) or size <= 0 or data == null) return;
    c.go_video_pipeline_push_rtp(session.video, @ptrCast(data), @intCast(size));
}

fn sendInputMetadata(session: *Session) void {
    var packet: [15]u8 = undefined;
    const length = c.go_controller_input_encode_metadata(session.controller, &packet, packet.len);
    if (length == 0) return;
    const result = c.rtcSendMessage(session.input_channel, @ptrCast(&packet), @intCast(length));
    debug("Sent input metadata: {d}\n", .{result});
    if (result >= 0) session.input_ready.store(true, .release);
}

fn sendStartupMessages(session: *Session) void {
    debug("Requesting stream dimensions: {d}x{d}\n", .{ session.stream_width, session.stream_height });
    var install_buffer: [256]u8 = undefined;
    const install = std.fmt.bufPrintZ(
        &install_buffer,
        "{{\"type\":\"Message\",\"content\":\"{{\\\"clientAppInstallId\\\":" ++
            "\\\"{s}\\\"}}\",\"id\":\"greenovercast-install\"," ++
            "\"target\":\"/streaming/properties/clientappinstallidchanged\",\"cv\":\"\"}}",
        .{std.mem.sliceTo(&session.install_id, 0)},
    ) catch return;
    var capabilities_buffer: [768]u8 = undefined;
    const capabilities = std.fmt.bufPrintZ(
        &capabilities_buffer,
        "{{\"type\":\"Message\",\"content\":\"{{\\\"supportsCustomResolution\\\":true," ++
            "\\\"supportsHevc\\\":false,\\\"supportsHdr\\\":false,\\\"supportsFps\\\":30," ++
            "\\\"maxWidth\\\":{d},\\\"maxHeight\\\":{d},\\\"maxBitrateKbps\\\":2000," ++
            "\\\"video\\\":{{\\\"width\\\":{d},\\\"height\\\":{d}," ++
            "\\\"maxWidth\\\":{d},\\\"maxHeight\\\":{d}," ++
            "\\\"maxBitrateKbps\\\":2000}}}}\",\"id\":\"greenovercast-capabilities\"," ++
            "\"target\":\"/streaming/characteristics/clientdevicecapabilities\",\"cv\":\"\"}}",
        .{
            session.stream_width, session.stream_height,
            session.stream_width, session.stream_height,
            session.stream_width, session.stream_height,
        },
    ) catch return;
    var dimensions_buffer: [768]u8 = undefined;
    const dimensions = std.fmt.bufPrintZ(
        &dimensions_buffer,
        "{{\"type\":\"Message\",\"content\":\"{{\\\"horizontal\\\":{d}," ++
            "\\\"vertical\\\":{d},\\\"preferredWidth\\\":{d}," ++
            "\\\"preferredHeight\\\":{d},\\\"safeAreaLeft\\\":0," ++
            "\\\"safeAreaTop\\\":0,\\\"safeAreaRight\\\":{d}," ++
            "\\\"safeAreaBottom\\\":{d},\\\"supportsCustomResolution\\\":true}}\"," ++
            "\"id\":\"greenovercast-dimensions\"," ++
            "\"target\":\"/streaming/characteristics/dimensionschanged\",\"cv\":\"\"}}",
        .{
            session.stream_width, session.stream_height,
            session.stream_width, session.stream_height,
            session.stream_width, session.stream_height,
        },
    ) catch return;
    const messages = [_][*:0]const u8{
        "{\"type\":\"Message\",\"content\":\"{\\\"version\\\":[0,2,0],\\\"systemUis\\\":[]}\"," ++
            "\"id\":\"greenovercast-ui\",\"target\":\"/streaming/systemUi/configuration\",\"cv\":\"\"}",
        install.ptr,
        "{\"type\":\"Message\",\"content\":\"{\\\"orientation\\\":0}\"," ++
            "\"id\":\"greenovercast-orientation\"," ++
            "\"target\":\"/streaming/characteristics/orientationchanged\",\"cv\":\"\"}",
        "{\"type\":\"Message\",\"content\":\"{\\\"touchInputEnabled\\\":false}\"," ++
            "\"id\":\"greenovercast-touch\"," ++
            "\"target\":\"/streaming/characteristics/touchinputenabledchanged\",\"cv\":\"\"}",
        capabilities.ptr,
        dimensions.ptr,
    };
    for (messages) |message| _ = c.rtcSendMessage(session.message_channel, message, -1);
}

pub export fn go_webrtc_session_request_keyframe(session_pointer: ?*Session) void {
    const session = session_pointer orelse return;
    var pli_result: c_int = -1;
    var control_result: c_int = -1;
    if (session.video_track > 0) pli_result = c.rtcRequestKeyframe(session.video_track);
    if (session.control_channel > 0) {
        control_result = c.rtcSendMessage(
            session.control_channel,
            "{\"message\":\"videoKeyframeRequested\",\"ifrRequested\":true}",
            -1,
        );
    }
    c.go_video_pipeline_note_keyframe_request(session.video);
    if (pli_result < 0 or control_result < 0)
        std.debug.print("Keyframe request failed (PLI={d} control={d})\n", .{ pli_result, control_result });
}

fn onChannelOpen(channel: c_int, context: ?*anyopaque) callconv(.c) void {
    const session = sessionFromContext(context) orelse return;
    debug("Channel open: {d}\n", .{channel});
    if (channel == session.message_channel) {
        const result = c.rtcSendMessage(
            channel,
            "{\"type\":\"Handshake\",\"version\":\"messageV1\"," ++
                "\"id\":\"greenovercast-handshake\",\"cv\":\"0\"}",
            -1,
        );
        debug("rtcSendMessage(handshake) = {d}\n", .{result});
    } else if (channel == session.input_channel) {
        sendInputMetadata(session);
    }
}

fn onMessageChannel(_: c_int, data: [*c]const u8, size: c_int, context: ?*anyopaque) callconv(.c) void {
    const session = sessionFromContext(context) orelse return;
    const incoming = messageData(data, size) orelse return;
    var message: [4096]u8 = [_]u8{0} ** 4096;
    const copy_length = @min(incoming.len, message.len - 1);
    @memcpy(message[0..copy_length], incoming[0..copy_length]);
    debug("message channel << {s}\n", .{message[0..copy_length]});

    var acknowledgement: [1024]u8 = undefined;
    const acknowledgement_length = message_protocol.buildDisconnectAck(
        message[0..copy_length],
        &acknowledgement,
    ) catch {
        std.debug.print("Xbox disconnect acknowledgement could not be built\n", .{});
        return;
    };
    if (acknowledgement_length) |length| {
        session.expected_disconnect.store(true, .release);
        const result = c.rtcSendMessage(
            session.message_channel,
            @ptrCast(&acknowledgement),
            @intCast(length),
        );
        if (result >= 0)
            debug("Acknowledged Xbox session disconnect\n", .{})
        else
            std.debug.print("Xbox disconnect acknowledgement failed: {d}\n", .{result});
        return;
    }
    if (std.mem.indexOf(u8, message[0..copy_length], "HandshakeAck") == null) return;
    session.handshake_complete.store(true, .release);
    _ = c.rtcSendMessage(
        session.control_channel,
        "{\"message\":\"authorizationRequest\"," ++
            "\"accessKey\":\"4BDB3609-C1F1-4195-9B37-FEFF45DA8B8E\"}",
        -1,
    );
    _ = c.rtcSendMessage(
        session.control_channel,
        "{\"message\":\"gamepadChanged\",\"gamepadIndex\":0,\"wasAdded\":true}",
        -1,
    );
    sendStartupMessages(session);
    go_webrtc_session_request_keyframe(session);
}

fn onControlMessage(_: c_int, data: [*c]const u8, size: c_int, _: ?*anyopaque) callconv(.c) void {
    const message = messageData(data, size) orelse return;
    debug("control channel << {s}\n", .{message[0..@min(message.len, 200)]});
}

pub export fn go_webrtc_session_create(
    cloud_pointer: ?*c.GoCloudSession,
    video_pointer: ?*c.GoVideoPipeline,
    audio_pointer: ?*c.GoAudioPipeline,
    controller_pointer: ?*c.GoControllerInput,
    wait_pointer: ?Wait,
    wait_context: ?*anyopaque,
    stream_width: c_uint,
    stream_height: c_uint,
) ?*Session {
    const cloud = cloud_pointer orelse return null;
    const video = video_pointer orelse return null;
    const audio = audio_pointer orelse return null;
    const controller = controller_pointer orelse return null;
    const wait = wait_pointer orelse return null;
    if (stream_width < 640 or stream_width > 1920 or stream_height < 360 or stream_height > 1080)
        return null;
    const session = std.heap.c_allocator.create(Session) catch return null;
    session.* = .{
        .cloud = cloud,
        .video = video,
        .audio = audio,
        .controller = controller,
        .wait = wait,
        .wait_context = wait_context,
        .stream_width = stream_width,
        .stream_height = stream_height,
    };
    generateInstallId(&session.install_id);
    return session;
}

fn configurePeer(session: *Session) !void {
    var configuration = std.mem.zeroes(c.rtcConfiguration);
    configuration.disableAutoNegotiation = true;
    session.peer = c.rtcCreatePeerConnection(&configuration);
    if (session.peer < 0) {
        std.debug.print("rtcCreatePeerConnection failed: {d}\n", .{session.peer});
        return error.PeerCreationFailed;
    }
    c.rtcSetUserPointer(session.peer, session);
    _ = c.rtcSetLocalDescriptionCallback(session.peer, onDescription);
    _ = c.rtcSetStateChangeCallback(session.peer, onConnectionState);
    _ = c.rtcSetDataChannelCallback(session.peer, onDataChannel);
    _ = c.rtcSetGatheringStateChangeCallback(session.peer, onGatheringState);

    var video_configuration = std.mem.zeroes(c.rtcTrackInit);
    video_configuration.direction = c.RTC_DIRECTION_RECVONLY;
    video_configuration.codec = c.RTC_CODEC_H264;
    video_configuration.payloadType = c.GO_VIDEO_PAYLOAD_TYPE;
    video_configuration.mid = "video";
    session.video_track = c.rtcAddTrackEx(session.peer, &video_configuration);
    if (session.video_track < 0 or c.rtcChainRtcpReceivingSession(session.video_track) < 0) {
        std.debug.print("Failed to configure the video receiver\n", .{});
        return error.VideoTrackFailed;
    }
    c.rtcSetUserPointer(session.video_track, session);
    _ = c.rtcSetMessageCallback(session.video_track, onVideoMessage);
    debug("Video track: {d}\n", .{session.video_track});

    var audio_configuration = std.mem.zeroes(c.rtcTrackInit);
    audio_configuration.direction = c.RTC_DIRECTION_RECVONLY;
    audio_configuration.codec = c.RTC_CODEC_OPUS;
    audio_configuration.payloadType = audio_payload_type;
    audio_configuration.mid = "audio";
    session.audio_track = c.rtcAddTrackEx(session.peer, &audio_configuration);
    if (session.audio_track < 0 or c.rtcChainRtcpReceivingSession(session.audio_track) < 0) {
        std.debug.print("Failed to configure the audio receiver\n", .{});
        return error.AudioTrackFailed;
    }
    c.rtcSetUserPointer(session.audio_track, session);
    _ = c.rtcSetMessageCallback(session.audio_track, onAudioMessage);
    debug("Audio track: {d}\n", .{session.audio_track});

    var channel_configuration = std.mem.zeroes(c.rtcDataChannelInit);
    channel_configuration.protocol = "chatV1";
    session.chat_channel = c.rtcCreateDataChannelEx(session.peer, "chat", &channel_configuration);
    channel_configuration.protocol = "controlV1";
    session.control_channel = c.rtcCreateDataChannelEx(session.peer, "control", &channel_configuration);
    channel_configuration.reliability.unordered = true;
    channel_configuration.reliability.unreliable = true;
    channel_configuration.reliability.maxRetransmits = 0;
    channel_configuration.protocol = "1.0";
    session.input_channel = c.rtcCreateDataChannelEx(session.peer, "input", &channel_configuration);
    channel_configuration.reliability.unordered = false;
    channel_configuration.reliability.unreliable = false;
    channel_configuration.protocol = "messageV1";
    session.message_channel = c.rtcCreateDataChannelEx(session.peer, "message", &channel_configuration);
    if (session.chat_channel < 0 or session.control_channel < 0 or
        session.input_channel < 0 or session.message_channel < 0)
    {
        std.debug.print("Failed to create Xbox data channels\n", .{});
        return error.DataChannelFailed;
    }
    debug("Channels: chat={d} input={d} control={d} message={d}\n", .{
        session.chat_channel,
        session.input_channel,
        session.control_channel,
        session.message_channel,
    });

    const channels = [_]c_int{
        session.chat_channel,
        session.control_channel,
        session.input_channel,
        session.message_channel,
    };
    for (channels) |channel| c.rtcSetUserPointer(channel, session);
    _ = c.rtcSetOpenCallback(session.message_channel, onChannelOpen);
    _ = c.rtcSetMessageCallback(session.message_channel, onMessageChannel);
    _ = c.rtcSetOpenCallback(session.control_channel, onChannelOpen);
    _ = c.rtcSetMessageCallback(session.control_channel, onControlMessage);
    _ = c.rtcSetOpenCallback(session.input_channel, onChannelOpen);
    _ = c.rtcSetMessageCallback(session.input_channel, onInputMessage);
    if (c.rtcSetLocalDescription(session.peer, "offer") < 0) return error.LocalDescriptionFailed;
}

fn sdpToken(sdp: []const u8, marker: []const u8) ?[]const u8 {
    const start = (std.mem.indexOf(u8, sdp, marker) orelse return null) + marker.len;
    var end = start;
    while (end < sdp.len and !std.ascii.isWhitespace(sdp[end])) : (end += 1) {}
    if (end == start) return null;
    return sdp[start..end];
}

fn buildCompatibleOffer(full_sdp: []const u8, output: []u8) ![:0]u8 {
    const ice_ufrag = sdpToken(full_sdp, "ice-ufrag:") orelse return error.MissingIceUfrag;
    const ice_password = sdpToken(full_sdp, "ice-pwd:") orelse return error.MissingIcePassword;
    const fingerprint = sdpToken(full_sdp, "fingerprint:sha-256 ") orelse
        return error.MissingFingerprint;
    return std.fmt.bufPrintZ(
        output,
        "v=0\r\n" ++
            "o=- 4611731400430051 2 IN IP4 127.0.0.1\r\n" ++
            "s=-\r\nt=0 0\r\n" ++
            "a=group:BUNDLE video audio 0\r\n" ++
            "a=ice-ufrag:{s}\r\n" ++
            "a=ice-pwd:{s}\r\n" ++
            "a=fingerprint:sha-256 {s}\r\n" ++
            "a=setup:actpass\r\n" ++
            "m=video 9 UDP/TLS/RTP/SAVPF 102\r\n" ++
            "c=IN IP4 0.0.0.0\r\na=mid:video\r\na=recvonly\r\n" ++
            "a=rtpmap:102 H264/90000\r\n" ++
            "a=fmtp:102 level-asymmetry-allowed=0;packetization-mode=1;" ++
            "profile-level-id=42e020;max-fs=3600;max-mbps=108000\r\n" ++
            "a=rtcp-fb:102 goog-remb\r\na=rtcp-fb:102 ccm fir\r\n" ++
            "a=rtcp-fb:102 nack\r\na=rtcp-fb:102 nack pli\r\na=rtcp-mux\r\n" ++
            "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\n" ++
            "c=IN IP4 0.0.0.0\r\na=mid:audio\r\na=recvonly\r\n" ++
            "a=rtpmap:111 opus/48000/2\r\na=rtcp-mux\r\n" ++
            "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n" ++
            "c=IN IP4 0.0.0.0\r\na=mid:0\r\na=sctp-port:5000\r\n" ++
            "a=max-message-size:262144\r\n",
        .{ ice_ufrag, ice_password, fingerprint },
    );
}

fn reportRemoteH264Format(sdp: []const u8) void {
    const prefix = "a=fmtp:102 ";
    const start = (std.mem.indexOf(u8, sdp, prefix) orelse {
        debug("Remote H.264 format parameters: absent\n", .{});
        return;
    }) + prefix.len;
    var end = std.mem.indexOfAnyPos(u8, sdp, start, "\r\n") orelse sdp.len;
    if (std.mem.indexOfPos(u8, sdp, start, "\\r")) |escaped| end = @min(end, escaped);
    if (std.mem.indexOfPos(u8, sdp, start, "\\n")) |escaped| end = @min(end, escaped);
    debug("Remote H.264 format parameters: {s}\n", .{sdp[start..end]});
}

fn exchangeSdp(session: *Session, clean_sdp: [:0]const u8) !void {
    const base_url = cString(c.go_cloud_session_base_url(session.cloud)) orelse return error.MissingCloudUrl;
    const session_path = cString(c.go_cloud_session_path(session.cloud)) orelse return error.MissingSessionPath;
    var url_buffer: [512]u8 = undefined;
    const url = try std.fmt.bufPrintZ(&url_buffer, "{s}/{s}/sdp", .{ base_url, session_path });
    var escaped_sdp_buffer: [8192]u8 = undefined;
    const escaped_length = json_writer.escape(clean_sdp, &escaped_sdp_buffer) catch
        return error.SdpEscapeFailed;
    const escaped_sdp = escaped_sdp_buffer[0..escaped_length];
    var body_buffer: [16384]u8 = undefined;
    const body = try std.fmt.bufPrintZ(
        &body_buffer,
        "{{\"messageType\":\"offer\",\"sdp\":\"{s}\",\"requestId\":\"1\"," ++
            "\"configuration\":{{" ++
            "\"chat\":{{\"minVersion\":1,\"maxVersion\":1}}," ++
            "\"control\":{{\"minVersion\":1,\"maxVersion\":3}}," ++
            "\"input\":{{\"minVersion\":1,\"maxVersion\":9}}," ++
            "\"message\":{{\"minVersion\":1,\"maxVersion\":1}}}}}}",
        .{escaped_sdp},
    );
    var headers = [_][*c]const u8{"Content-Type: application/json"};
    var response = c.go_cloud_session_request(session.cloud, "POST", url.ptr, body.ptr, @ptrCast(&headers), 1);
    if (c.go_http_response_succeeded(response) == 0) {
        c.go_http_response_destroy(response);
        return error.SdpPostFailed;
    }
    c.go_http_response_destroy(response);

    debug("Polling for server answer...\n", .{});
    var server_sdp_buffer: [16384]u8 = undefined;
    var server_sdp: ?[]const u8 = null;
    var attempt: usize = 0;
    while (attempt < 20) : (attempt += 1) {
        if (session.wait(session.wait_context, if (attempt == 0) 10000 else 5000) != 0)
            return error.Cancelled;
        response = c.go_cloud_session_request(session.cloud, "GET", url.ptr, null, @ptrCast(&headers), 1);
        defer c.go_http_response_destroy(response);
        if (c.go_http_response_succeeded(response) == 0) continue;
        const data = responseData(response) orelse continue;
        if (data.len == 0) continue;
        if (std.mem.indexOf(u8, data, "ConnectionExchangeFailed") != null and
            std.mem.indexOf(u8, data, "Exclusive") == null)
        {
            std.debug.print("  SDP exchange failed: {s}\n", .{data[0..@min(data.len, 200)]});
            return error.SdpExchangeFailed;
        }
        if (json_reader.parseString(data, "sdp", &server_sdp_buffer)) |length| {
            server_sdp = server_sdp_buffer[0..length];
            debug("Server SDP: {d} chars\n", .{server_sdp.?.len});
            break;
        } else |_| {}
        debug("poll {d}: no SDP in {d} bytes\n", .{ attempt + 1, data.len });
    }
    const remote_sdp = server_sdp orelse {
        std.debug.print("SDP exchange timed out\n", .{});
        return error.SdpTimeout;
    };
    reportRemoteH264Format(remote_sdp);
    debug("Setting remote description ({d} bytes)...\n", .{remote_sdp.len});
    const result = c.rtcSetRemoteDescription(session.peer, @ptrCast(remote_sdp.ptr), "answer");
    debug("SetRemoteDescription: {d}\n", .{result});
    if (result < 0) return error.RemoteDescriptionFailed;
}

fn exchangeIceCandidates(session: *Session) !void {
    const base_url = cString(c.go_cloud_session_base_url(session.cloud)) orelse return error.MissingCloudUrl;
    const session_path = cString(c.go_cloud_session_path(session.cloud)) orelse return error.MissingSessionPath;
    var url_buffer: [512]u8 = undefined;
    const url = try std.fmt.bufPrintZ(&url_buffer, "{s}/{s}/ice", .{ base_url, session_path });
    var headers = [_][*c]const u8{"Content-Type: application/json"};
    var local_description_buffer: [16384]u8 = undefined;
    const description_length = c.rtcGetLocalDescription(
        session.peer,
        &local_description_buffer,
        local_description_buffer.len,
    );
    var local_candidate_count: usize = 0;
    if (description_length > 0) {
        const local_description = local_description_buffer[0..@intCast(description_length)];
        var lines = std.mem.splitScalar(u8, local_description, '\n');
        while (lines.next()) |untrimmed_line| {
            const line = std.mem.trimRight(u8, untrimmed_line, "\r\x00");
            if (!std.mem.startsWith(u8, line, "a=candidate:")) continue;
            const candidate = line[2..];
            var body_buffer: [4096]u8 = undefined;
            const body = try std.fmt.bufPrintZ(&body_buffer, "{{\"candidate\":\"{s}\"}}", .{candidate});
            const response = c.go_cloud_session_request(
                session.cloud,
                "POST",
                url.ptr,
                body.ptr,
                @ptrCast(&headers),
                1,
            );
            defer c.go_http_response_destroy(response);
            if (c.go_http_response_succeeded(response) == 0) return error.LocalCandidatePostFailed;
            local_candidate_count += 1;
        }
    }
    debug("Posted {d} local ICE candidate(s)\n", .{local_candidate_count});
    if (session.wait(session.wait_context, 3000) != 0) return error.Cancelled;

    const response = c.go_cloud_session_request(session.cloud, "GET", url.ptr, null, @ptrCast(&headers), 1);
    defer c.go_http_response_destroy(response);
    var remote_candidate_count: usize = 0;
    if (c.go_http_response_succeeded(response) != 0) {
        if (responseData(response)) |data| {
            var search_index: usize = 0;
            while (std.mem.indexOfPos(u8, data, search_index, "a=candidate:")) |match| {
                const candidate_start = match + "a=candidate:".len;
                const slash = std.mem.indexOfScalarPos(u8, data, candidate_start, '\\') orelse data.len;
                const quote = std.mem.indexOfScalarPos(u8, data, candidate_start, '"') orelse data.len;
                const candidate_end = @min(slash, quote);
                if (candidate_end == data.len) break;
                const value = std.mem.trimRight(u8, data[candidate_start..candidate_end], " \n\r");
                if (value.len > 0 and value.len < 510) {
                    var candidate_buffer: [512]u8 = undefined;
                    const candidate = std.fmt.bufPrintZ(
                        &candidate_buffer,
                        "candidate:{s}",
                        .{value},
                    ) catch return error.CandidateTooLong;
                    if (c.rtcAddRemoteCandidate(session.peer, candidate.ptr, "0") >= 0)
                        remote_candidate_count += 1;
                }
                search_index = candidate_end + 1;
            }
        }
    }
    debug("Added {d} remote ICE candidate(s); waiting 5s for ICE...\n", .{remote_candidate_count});
    if (session.wait(session.wait_context, 5000) != 0) return error.Cancelled;
}

pub export fn go_webrtc_session_setup(session_pointer: ?*Session) c_int {
    const session = session_pointer orelse return -1;
    if (session.peer >= 0) return -1;
    c.rtcInitLogger(if (std.posix.getenv("GREENOVERCAST_DEBUG") != null) c.RTC_LOG_INFO else c.RTC_LOG_WARNING, null);
    configurePeer(session) catch return -1;
    debug("Waiting for ICE gathering...\n", .{});
    var attempt: usize = 0;
    while (attempt < 120 and !session.gathering_complete.load(.acquire)) : (attempt += 1) {
        if (session.wait(session.wait_context, 500) != 0) return -1;
    }

    var full_sdp_buffer: [16384]u8 = undefined;
    const sdp_length = c.rtcGetLocalDescription(session.peer, &full_sdp_buffer, full_sdp_buffer.len);
    if (sdp_length <= 0) {
        std.debug.print("Failed to get local description\n", .{});
        return -1;
    }
    debug("Full local SDP: {d} bytes (gathering {s})\n", .{
        sdp_length,
        if (session.gathering_complete.load(.acquire)) "complete" else "incomplete",
    });
    var clean_sdp_buffer: [4096]u8 = undefined;
    const clean_sdp = buildCompatibleOffer(
        full_sdp_buffer[0..@intCast(sdp_length)],
        &clean_sdp_buffer,
    ) catch {
        std.debug.print("Local SDP is missing ICE credentials or its DTLS fingerprint\n", .{});
        return -1;
    };
    debug("Exchanging SDP ({d} bytes)...\n", .{clean_sdp.len});
    exchangeSdp(session, clean_sdp) catch return -1;
    exchangeIceCandidates(session) catch return -1;
    return 0;
}

pub export fn go_webrtc_session_connected(session: ?*const Session) c_int {
    return if (session) |value| @intFromBool(value.connected.load(.acquire)) else 0;
}

pub export fn go_webrtc_session_closed(session: ?*const Session) c_int {
    return if (session) |value| @intFromBool(value.peer_closed.load(.acquire)) else 0;
}

pub export fn go_webrtc_session_failed(session: ?*const Session) c_int {
    return if (session) |value| @intFromBool(value.peer_failed.load(.acquire)) else 1;
}

pub export fn go_webrtc_session_handshake_complete(session: ?*const Session) c_int {
    return if (session) |value| @intFromBool(value.handshake_complete.load(.acquire)) else 0;
}

pub export fn go_webrtc_session_send_gamepad(session_pointer: ?*Session) void {
    const session = session_pointer orelse return;
    if (session.input_channel < 0 or !session.input_ready.load(.acquire)) return;
    var packet: [38]u8 = undefined;
    const length = c.go_controller_input_encode(session.controller, &packet, packet.len);
    if (length > 0)
        _ = c.rtcSendMessage(session.input_channel, @ptrCast(&packet), @intCast(length));
}

pub export fn go_webrtc_session_request_video_bitrate(
    session_pointer: ?*Session,
    bits_per_second: c_uint,
) void {
    const session = session_pointer orelse return;
    if (session.video_track <= 0 or c.go_video_pipeline_has_media(session.video) == 0) return;
    if (session.video_bitrate_requested.cmpxchgStrong(false, true, .acq_rel, .acquire) != null)
        return;
    const result = c.rtcRequestBitrate(session.video_track, bits_per_second);
    debug("Requested video bitrate: {d} kbps (result={d})\n", .{ bits_per_second / 1000, result });
}

pub export fn go_webrtc_session_destroy(session_pointer: ?*Session) void {
    const session = session_pointer orelse return;
    session.shutting_down.store(true, .release);
    if (session.peer >= 0) {
        _ = c.rtcClosePeerConnection(session.peer);
        if (session.chat_channel >= 0) _ = c.rtcDeleteDataChannel(session.chat_channel);
        if (session.control_channel >= 0) _ = c.rtcDeleteDataChannel(session.control_channel);
        if (session.input_channel >= 0) _ = c.rtcDeleteDataChannel(session.input_channel);
        if (session.message_channel >= 0) _ = c.rtcDeleteDataChannel(session.message_channel);
        if (session.video_track >= 0) _ = c.rtcDeleteTrack(session.video_track);
        if (session.audio_track >= 0) _ = c.rtcDeleteTrack(session.audio_track);
        _ = c.rtcDeletePeerConnection(session.peer);
        c.rtcCleanup();
    }
    std.heap.c_allocator.destroy(session);
}
