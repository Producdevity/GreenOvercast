const std = @import("std");
const cloudmatch = @import("cloudmatch_protocol.zig");
const input_protocol = @import("input_protocol.zig");
const pointer_input = @import("pointer_input.zig");
const sdp_protocol = @import("sdp_protocol.zig");
const signaling_client = @import("signaling_client.zig");
const signaling_protocol = @import("signaling_protocol.zig");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("rtc/rtc.h");
    @cInclude("audio_pipeline.h");
    @cInclude("controller.h");
    @cInclude("handheld_ui.h");
    @cInclude("video_pipeline.h");
});

const event_capacity = 64;
const maximum_tracks = 8;
const maximum_channels = 8;
const maximum_bitrate_kbps = 6000;

fn debugEnabled() bool {
    return std.posix.getenv("GREENOVERCAST_DEBUG") != null;
}

fn debug(comptime format: []const u8, args: anytype) void {
    if (debugEnabled()) std.debug.print(format, args);
}

const EventKind = enum {
    description,
    candidate,
    state,
    track,
    data_channel,
    channel_open,
    channel_message,
};

const Event = struct {
    kind: EventKind,
    id: c_int = -1,
    state: c.rtcState = 0,
    first: ?[:0]u8 = null,
    second: ?[:0]u8 = null,
    data: ?[]u8 = null,

    fn deinit(self: *Event) void {
        if (self.first) |value| std.heap.c_allocator.free(value);
        if (self.second) |value| std.heap.c_allocator.free(value);
        if (self.data) |value| std.heap.c_allocator.free(value);
        self.* = undefined;
    }
};

const EventQueue = struct {
    events: [event_capacity]Event = undefined,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    mutex: std.Thread.Mutex = .{},
    overflowed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn push(self: *EventQueue, event: Event) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.count == self.events.len) {
            var dropped = event;
            dropped.deinit();
            self.overflowed.store(true, .release);
            return;
        }
        self.events[self.tail] = event;
        self.tail = (self.tail + 1) % self.events.len;
        self.count += 1;
    }

    fn pop(self: *EventQueue) ?Event {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.count == 0) return null;
        const event = self.events[self.head];
        self.head = (self.head + 1) % self.events.len;
        self.count -= 1;
        return event;
    }

    fn deinit(self: *EventQueue) void {
        while (self.pop()) |event_value| {
            var event = event_value;
            event.deinit();
        }
    }
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    video: *c.GoVideoPipeline,
    audio: *c.GoAudioPipeline,
    controller: *c.GoControllerInput,
    ui: *c.GoHandheldUi,
    cloud: *const cloudmatch.Session,
    width: u16,
    height: u16,
    frames_per_second: u16,
    peer: c_int = -1,
    input_channel: c_int = -1,
    video_track: c_int = -1,
    audio_track: c_int = -1,
    tracks: [maximum_tracks]c_int = [_]c_int{-1} ** maximum_tracks,
    track_count: usize = 0,
    channels: [maximum_channels]c_int = [_]c_int{-1} ** maximum_channels,
    channel_count: usize = 0,
    signaling: ?*signaling_client.Client = null,
    offer: ?[]u8 = null,
    events: EventQueue = .{},
    encoder: input_protocol.Encoder = .{},
    pointer: pointer_input.State = .{},
    answer_sent: bool = false,
    input_ready: bool = false,
    connected: bool = false,
    closed: bool = false,
    failed: bool = false,
    shutting_down: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    started_at: u32 = 0,
    last_input_heartbeat: u32 = 0,
    bitrate_requested: bool = false,
    video_packets: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    audio_packets: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    gamepad_logged: bool = false,

    pub fn create(
        allocator: std.mem.Allocator,
        video_pointer: *anyopaque,
        audio_pointer: *anyopaque,
        controller_pointer: *anyopaque,
        ui_pointer: *anyopaque,
        cloud: *const cloudmatch.Session,
        width: u16,
        height: u16,
        frames_per_second: u16,
    ) !*Session {
        if (cloud.signaling_url == null or cloud.id.len == 0) return error.MissingSignalingData;
        const session = try allocator.create(Session);
        session.* = .{
            .allocator = allocator,
            .video = @ptrCast(video_pointer),
            .audio = @ptrCast(audio_pointer),
            .controller = @ptrCast(controller_pointer),
            .ui = @ptrCast(ui_pointer),
            .cloud = cloud,
            .width = width,
            .height = height,
            .frames_per_second = frames_per_second,
        };
        return session;
    }

    pub fn setup(self: *Session) !void {
        var peer_name_buffer: [48]u8 = undefined;
        var random: [8]u8 = undefined;
        std.crypto.random.bytes(&random);
        const peer_name = try std.fmt.bufPrint(
            &peer_name_buffer,
            "peer-{x:0>16}",
            .{std.mem.readInt(u64, &random, .little)},
        );
        self.signaling = try signaling_client.Client.connect(
            self.allocator,
            self.cloud.signaling_url.?,
            self.cloud.id,
            peer_name,
            self.width,
            self.height,
        );

        const offer = try self.waitForOffer();
        defer self.allocator.free(offer);
        const sanitized = try sdp_protocol.sanitizeOffer(
            self.allocator,
            offer,
            self.cloud.media_ip,
        );
        self.offer = sanitized;

        const video_payload = sdp_protocol.codecPayloadType(sanitized, "H264/") orelse
            return error.H264NotOffered;
        const audio_payload = sdp_protocol.codecPayloadType(sanitized, "OPUS/") orelse
            return error.OpusNotOffered;
        debug("GeForce NOW offer: {d} bytes, H.264 PT {d}, Opus PT {d}\n", .{
            sanitized.len,
            video_payload,
            audio_payload,
        });
        if (c.go_video_pipeline_set_payload_type(self.video, video_payload) != 0 or
            c.go_audio_pipeline_set_payload_type(self.audio, audio_payload) != 0)
            return error.MediaPipelineAlreadyActive;

        try self.createPeer();
        const offer_z = try self.allocator.dupeZ(u8, sanitized);
        defer self.allocator.free(offer_z);
        if (c.rtcSetRemoteDescription(self.peer, offer_z.ptr, "offer") < 0)
            return error.RemoteDescriptionFailed;
        if (self.cloud.media_ip != null and self.cloud.media_port != null) {
            if (try sdp_protocol.mediaHostCandidate(
                self.allocator,
                self.cloud.media_ip.?,
                self.cloud.media_port.?,
            )) |candidate| {
                defer self.allocator.free(candidate);
                if (c.rtcAddRemoteCandidate(self.peer, candidate.ptr, "0") < 0)
                    std.debug.print("GeForce NOW media ICE candidate was rejected\n", .{});
            }
        }
        self.input_channel = c.rtcCreateDataChannel(self.peer, "input_channel_v1");
        if (self.input_channel < 0) return error.InputChannelFailed;
        try self.rememberChannel(self.input_channel);
        c.rtcSetUserPointer(self.input_channel, self);
        _ = c.rtcSetOpenCallback(self.input_channel, onChannelOpen);
        _ = c.rtcSetMessageCallback(self.input_channel, onChannelMessage);
        if (c.rtcSetLocalDescription(self.peer, "answer") < 0)
            return error.LocalDescriptionFailed;

        const deadline = c.SDL_GetTicks() +% 15_000;
        while (!self.answer_sent and !self.failed and !self.closed) {
            try self.pump();
            if (deadlineReached(c.SDL_GetTicks(), deadline)) return error.AnswerTimeout;
            if (c.go_handheld_ui_wait(self.ui, 16) != 0) return error.Cancelled;
        }
        if (!self.answer_sent) return error.AnswerFailed;
        self.started_at = c.SDL_GetTicks();
        self.last_input_heartbeat = self.started_at;
    }

    pub fn pump(self: *Session) !void {
        if (self.events.overflowed.swap(false, .acq_rel)) return error.WebrtcEventOverflow;
        var processed: usize = 0;
        while (processed < event_capacity) : (processed += 1) {
            const value = self.events.pop() orelse break;
            var event = value;
            defer event.deinit();
            try self.handleEvent(&event);
        }
        var signaling_messages: usize = 0;
        while (signaling_messages < 32) : (signaling_messages += 1) {
            var message = (try self.signaling.?.poll()) orelse break;
            defer message.deinit();
            try self.handleSignaling(&message);
        }

        const now = c.SDL_GetTicks();
        if (self.input_ready and now -% self.last_input_heartbeat >= 2000) {
            var packet: [input_protocol.maximum_packet_size]u8 = undefined;
            const heartbeat = try self.encoder.encodeHeartbeat(&packet);
            if (c.rtcSendMessage(self.input_channel, @ptrCast(heartbeat.ptr), @intCast(heartbeat.len)) < 0)
                return error.InputHeartbeatFailed;
            self.last_input_heartbeat = now;
        }
    }

    pub fn isConnected(self: *const Session) bool {
        return self.connected;
    }

    pub fn isClosed(self: *const Session) bool {
        return self.closed;
    }

    pub fn hasFailed(self: *const Session) bool {
        return self.failed;
    }

    pub fn sendInput(self: *Session) !void {
        if (!self.input_ready or self.input_channel < 0) return;
        var controller_state = std.mem.zeroes(c.GoControllerState);
        _ = c.go_controller_input_sample(self.controller, &controller_state);
        const timestamp_us: u64 = @as(u64, c.SDL_GetTicks() -% self.started_at) * 1000;
        var packet_buffer: [input_protocol.maximum_packet_size]u8 = undefined;
        const update = self.pointer.update(.{
            .buttons = geforceButtons(controller_state.buttons),
            .left_trigger = scaleTrigger(controller_state.left_trigger),
            .right_trigger = scaleTrigger(controller_state.right_trigger),
            .left_x = controller_state.left_x,
            .left_y = controller_state.left_y,
            .right_x = controller_state.right_x,
            .right_y = controller_state.right_y,
            .timestamp_us = timestamp_us,
        });
        try self.sendInputPacket(try self.encoder.encodeReliableGamepad(&packet_buffer, update.gamepad));
        if (update.moved) try self.sendInputPacket(try self.encoder.encodeMousePosition(
            &packet_buffer,
            @intFromFloat(self.pointer.x * @as(f32, @floatFromInt(self.width - 1))),
            @intFromFloat(self.pointer.y * @as(f32, @floatFromInt(self.height - 1))),
            self.width,
            self.height,
            timestamp_us,
        ));
        for ([_]input_protocol.MouseButton{ .left, .right }, 0..) |button, index| {
            const mask = @as(u2, 1) << @as(u1, @intCast(index));
            if (update.changed_buttons & mask != 0)
                try self.sendInputPacket(try self.encoder.encodeMouseButton(
                    &packet_buffer,
                    button,
                    self.pointer.buttons & mask != 0,
                    timestamp_us,
                ));
        }
        if (update.wheel != 0) try self.sendInputPacket(try self.encoder.encodeMouseWheel(&packet_buffer, update.wheel, timestamp_us));
        if (update.toggled) debug("GeForce NOW input mode: {s}\n", .{if (self.pointer.enabled) "mouse" else "gamepad"});
        if (!self.gamepad_logged and controllerStateIsActive(controller_state)) {
            debug("GeForce NOW gamepad input active: protocol {d}, buttons 0x{x}\n", .{
                self.encoder.protocol_version,
                controller_state.buttons,
            });
            self.gamepad_logged = true;
        }
    }

    fn sendInputPacket(self: *Session, packet: []const u8) !void {
        if (c.rtcSendMessage(self.input_channel, @ptrCast(packet.ptr), @intCast(packet.len)) < 0)
            return error.InputSendFailed;
    }

    pub fn requestKeyframe(self: *Session) void {
        if (self.video_track >= 0) {
            _ = c.rtcRequestKeyframe(self.video_track);
            c.go_video_pipeline_note_keyframe_request(self.video);
        }
    }

    pub fn requestBitrate(self: *Session) void {
        if (self.bitrate_requested or self.video_track < 0 or
            c.go_video_pipeline_has_media(self.video) == 0) return;
        if (c.rtcRequestBitrate(self.video_track, maximum_bitrate_kbps * 1000) >= 0)
            self.bitrate_requested = true;
    }

    pub fn destroy(self: *Session) void {
        self.shutting_down.store(true, .release);
        if (self.peer >= 0) {
            _ = c.rtcClosePeerConnection(self.peer);
            for (self.channels[0..self.channel_count]) |channel| _ = c.rtcDeleteDataChannel(channel);
            for (self.tracks[0..self.track_count]) |track| _ = c.rtcDeleteTrack(track);
            _ = c.rtcDeletePeerConnection(self.peer);
            c.rtcCleanup();
        }
        if (self.signaling) |signaling| signaling.destroy();
        if (self.offer) |offer| self.allocator.free(offer);
        self.events.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    fn waitForOffer(self: *Session) ![]u8 {
        const deadline = c.SDL_GetTicks() +% 30_000;
        while (!deadlineReached(c.SDL_GetTicks(), deadline)) {
            if (try self.signaling.?.poll()) |message_value| {
                var message = message_value;
                defer message.deinit();
                if (message.peer_removed) return error.RemotePeerRemoved;
                switch (message.payload) {
                    .offer => |offer| return self.allocator.dupe(u8, offer),
                    .bye => return error.SignalingClosed,
                    else => {},
                }
            }
            if (c.go_handheld_ui_wait(self.ui, 16) != 0) return error.Cancelled;
        }
        return error.OfferTimeout;
    }

    fn createPeer(self: *Session) !void {
        const ice_urls = try buildIceUrls(self.allocator, self.cloud.ice_servers);
        defer freeIceUrls(self.allocator, ice_urls);
        var pointers = try self.allocator.alloc([*c]const u8, ice_urls.len);
        defer self.allocator.free(pointers);
        for (ice_urls, 0..) |url, index| pointers[index] = url.ptr;

        var configuration = std.mem.zeroes(c.rtcConfiguration);
        configuration.iceServers = if (pointers.len > 0) @ptrCast(pointers.ptr) else null;
        configuration.iceServersCount = @intCast(pointers.len);
        configuration.disableAutoNegotiation = true;
        configuration.maxMessageSize = 262_144;
        self.peer = c.rtcCreatePeerConnection(&configuration);
        if (self.peer < 0) return error.PeerCreationFailed;
        c.rtcSetUserPointer(self.peer, self);
        _ = c.rtcSetLocalDescriptionCallback(self.peer, onDescription);
        _ = c.rtcSetLocalCandidateCallback(self.peer, onCandidate);
        _ = c.rtcSetStateChangeCallback(self.peer, onStateChange);
        _ = c.rtcSetTrackCallback(self.peer, onTrack);
        _ = c.rtcSetDataChannelCallback(self.peer, onDataChannel);
    }

    fn handleEvent(self: *Session, event: *Event) !void {
        switch (event.kind) {
            .description => {
                const sdp = event.first orelse return;
                const kind = event.second orelse return;
                if (!std.mem.eql(u8, std.mem.sliceTo(kind, 0), "answer")) return;
                const narrowed_sdp = try sdp_protocol.narrowAnswerToH264Opus(
                    self.allocator,
                    std.mem.sliceTo(sdp, 0),
                    self.offer.?,
                );
                defer self.allocator.free(narrowed_sdp);
                const nvst = try sdp_protocol.buildNvstAnswer(
                    self.allocator,
                    narrowed_sdp,
                    self.offer.?,
                    self.width,
                    self.height,
                    self.frames_per_second,
                    maximum_bitrate_kbps,
                );
                defer self.allocator.free(nvst);
                try self.signaling.?.sendAnswer(narrowed_sdp, nvst);
                self.answer_sent = true;
            },
            .candidate => {
                const candidate = event.first orelse return;
                try self.signaling.?.sendIceCandidate(
                    std.mem.sliceTo(candidate, 0),
                    if (event.second) |mid| std.mem.sliceTo(mid, 0) else null,
                );
            },
            .state => switch (event.state) {
                c.RTC_CONNECTED => {
                    self.connected = true;
                    self.logTransport();
                },
                c.RTC_FAILED => {
                    self.connected = false;
                    self.failed = true;
                },
                c.RTC_CLOSED => {
                    self.connected = false;
                    self.closed = true;
                },
                else => {},
            },
            .track => try self.configureTrack(event.id),
            .data_channel => try self.configureIncomingChannel(event.id),
            .channel_open => {
                if (event.id == self.input_channel) {
                    debug("GeForce NOW input channel open\n", .{});
                }
            },
            .channel_message => if (event.id == self.input_channel and event.data != null) {
                if (input_protocol.parseHandshakeVersion(event.data.?)) |version| {
                    self.encoder.setProtocolVersion(version);
                    self.input_ready = true;
                    debug("GeForce NOW input handshake: protocol {d}\n", .{version});
                }
            },
        }
    }

    fn handleSignaling(self: *Session, message: *const signaling_protocol.DecodedMessage) !void {
        if (message.peer_removed) {
            self.closed = true;
            return;
        }
        switch (message.payload) {
            .ice => |candidate| {
                if (signaling_protocol.isTcpIceCandidate(candidate.candidate)) return;
                const value = try self.allocator.dupeZ(u8, candidate.candidate);
                defer self.allocator.free(value);
                const mid_value = candidate.sdp_mid orelse "0";
                const mid = try self.allocator.dupeZ(u8, mid_value);
                defer self.allocator.free(mid);
                if (c.rtcAddRemoteCandidate(self.peer, value.ptr, mid.ptr) < 0)
                    return error.RemoteCandidateRejected;
            },
            .bye => self.closed = true,
            else => {},
        }
    }

    fn configureTrack(self: *Session, track: c_int) !void {
        if (track < 0) return;
        self.rememberTrack(track) catch |err| {
            _ = c.rtcDeleteTrack(track);
            return err;
        };
        c.rtcSetUserPointer(track, self);
        var description_buffer: [4096]u8 = undefined;
        const length = c.rtcGetTrackDescription(track, &description_buffer, description_buffer.len);
        if (length <= 0) return error.TrackDescriptionUnavailable;
        const description = description_buffer[0..@intCast(length - 1)];
        var mid_buffer: [64]u8 = undefined;
        const mid_length = c.rtcGetTrackMid(track, &mid_buffer, mid_buffer.len);
        const mid = if (mid_length > 0)
            std.mem.sliceTo(mid_buffer[0..@intCast(mid_length)], 0)
        else
            "?";
        if (std.ascii.indexOfIgnoreCase(description, "H264/") != null) {
            if (self.video_track >= 0) return error.MultipleVideoTracks;
            self.video_track = track;
            if (c.rtcChainRtcpReceivingSession(track) < 0) return error.VideoTrackFailed;
            _ = c.rtcSetMessageCallback(track, onVideoMessage);
            debug("GeForce NOW video track: mid {s}\n", .{mid});
        } else if (std.ascii.indexOfIgnoreCase(description, "opus/") != null) {
            const role = mediaStreamTrackId(description) orelse {
                debug("Ignoring GeForce NOW audio track without a role: mid {s}\n", .{mid});
                return;
            };
            if (!std.ascii.eqlIgnoreCase(role, "audio")) {
                debug("Ignoring GeForce NOW audio track {s}: mid {s}\n", .{ role, mid });
                return;
            }
            if (self.audio_track >= 0) return error.MultipleGameAudioTracks;
            self.audio_track = track;
            if (c.rtcChainRtcpReceivingSession(track) < 0) return error.AudioTrackFailed;
            _ = c.rtcSetMessageCallback(track, onAudioMessage);
            debug("GeForce NOW audio track: mid {s}\n", .{mid});
        } else {
            debug("GeForce NOW unhandled track: mid {s}\n", .{mid});
        }
    }

    fn configureIncomingChannel(self: *Session, channel: c_int) !void {
        if (channel < 0) return;
        self.rememberChannel(channel) catch |err| {
            _ = c.rtcDeleteDataChannel(channel);
            return err;
        };
        c.rtcSetUserPointer(channel, self);
        _ = c.rtcSetOpenCallback(channel, onChannelOpen);
        _ = c.rtcSetMessageCallback(channel, onChannelMessage);
    }

    fn rememberTrack(self: *Session, track: c_int) !void {
        for (self.tracks[0..self.track_count]) |existing| if (existing == track) return;
        if (self.track_count == self.tracks.len) return error.TooManyTracks;
        self.tracks[self.track_count] = track;
        self.track_count += 1;
    }

    fn rememberChannel(self: *Session, channel: c_int) !void {
        for (self.channels[0..self.channel_count]) |existing| if (existing == channel) return;
        if (self.channel_count == self.channels.len) return error.TooManyChannels;
        self.channels[self.channel_count] = channel;
        self.channel_count += 1;
    }

    fn logTransport(self: *Session) void {
        if (!debugEnabled() or self.peer < 0) return;
        var local = [_]u8{0} ** 128;
        var remote = [_]u8{0} ** 128;
        const result = c.rtcGetSelectedCandidatePair(
            self.peer,
            &local,
            local.len,
            &remote,
            remote.len,
        );
        if (result >= 0) {
            debug("GeForce NOW transport connected: {s} -> {s}\n", .{
                std.mem.sliceTo(&local, 0),
                std.mem.sliceTo(&remote, 0),
            });
        } else {
            debug("GeForce NOW transport connected; selected ICE pair unavailable\n", .{});
        }
    }
};

fn sessionFromContext(context: ?*anyopaque) ?*Session {
    return @ptrCast(@alignCast(context orelse return null));
}

fn enqueueStrings(session: *Session, kind: EventKind, first: [*c]const u8, second: [*c]const u8) void {
    if (session.shutting_down.load(.acquire) or first == null) return;
    const first_copy = std.heap.c_allocator.dupeZ(u8, std.mem.span(first)) catch return;
    const second_copy = if (second != null)
        std.heap.c_allocator.dupeZ(u8, std.mem.span(second)) catch {
            std.heap.c_allocator.free(first_copy);
            return;
        }
    else
        null;
    session.events.push(.{ .kind = kind, .first = first_copy, .second = second_copy });
}

fn onDescription(_: c_int, sdp: [*c]const u8, kind: [*c]const u8, context: ?*anyopaque) callconv(.c) void {
    const session = sessionFromContext(context) orelse return;
    enqueueStrings(session, .description, sdp, kind);
}

fn onCandidate(_: c_int, candidate: [*c]const u8, mid: [*c]const u8, context: ?*anyopaque) callconv(.c) void {
    const session = sessionFromContext(context) orelse return;
    enqueueStrings(session, .candidate, candidate, mid);
}

fn onStateChange(_: c_int, state: c.rtcState, context: ?*anyopaque) callconv(.c) void {
    const session = sessionFromContext(context) orelse return;
    if (!session.shutting_down.load(.acquire))
        session.events.push(.{ .kind = .state, .state = state });
}

fn onTrack(_: c_int, track: c_int, context: ?*anyopaque) callconv(.c) void {
    const session = sessionFromContext(context) orelse return;
    if (!session.shutting_down.load(.acquire))
        session.events.push(.{ .kind = .track, .id = track });
}

fn onDataChannel(_: c_int, channel: c_int, context: ?*anyopaque) callconv(.c) void {
    const session = sessionFromContext(context) orelse return;
    if (!session.shutting_down.load(.acquire))
        session.events.push(.{ .kind = .data_channel, .id = channel });
}

fn onChannelOpen(channel: c_int, context: ?*anyopaque) callconv(.c) void {
    const session = sessionFromContext(context) orelse return;
    if (!session.shutting_down.load(.acquire))
        session.events.push(.{ .kind = .channel_open, .id = channel });
}

fn onChannelMessage(channel: c_int, data: [*c]const u8, size: c_int, context: ?*anyopaque) callconv(.c) void {
    const session = sessionFromContext(context) orelse return;
    if (session.shutting_down.load(.acquire) or data == null or size == 0) return;
    const signed_size: i64 = size;
    const length: usize = @intCast(if (signed_size < 0) -signed_size else signed_size);
    if (length > 4096) return;
    const copy = std.heap.c_allocator.dupe(u8, data[0..length]) catch return;
    session.events.push(.{ .kind = .channel_message, .id = channel, .data = copy });
}

fn onVideoMessage(track: c_int, data: [*c]const u8, size: c_int, context: ?*anyopaque) callconv(.c) void {
    const session = sessionFromContext(context) orelse return;
    if (session.shutting_down.load(.acquire) or track != session.video_track or data == null or size <= 0) return;
    if (session.video_packets.fetchAdd(1, .monotonic) == 0)
        debug("GeForce NOW first video RTP packet: {d} bytes\n", .{size});
    c.go_video_pipeline_push_rtp(session.video, @ptrCast(data), @intCast(size));
}

fn onAudioMessage(track: c_int, data: [*c]const u8, size: c_int, context: ?*anyopaque) callconv(.c) void {
    const session = sessionFromContext(context) orelse return;
    if (session.shutting_down.load(.acquire) or track != session.audio_track or data == null or size <= 0) return;
    if (session.audio_packets.fetchAdd(1, .monotonic) == 0)
        debug("GeForce NOW first audio RTP packet: {d} bytes\n", .{size});
    c.go_audio_pipeline_push_rtp(session.audio, @ptrCast(data), @intCast(size));
}

fn deadlineReached(now: u32, deadline: u32) bool {
    return @as(i32, @bitCast(now -% deadline)) >= 0;
}

fn mediaStreamTrackId(description: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, description, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, "a=msid:")) continue;
        var fields = std.mem.tokenizeAny(u8, line["a=msid:".len..], " \t");
        const stream_id = fields.next() orelse continue;
        return fields.next() orelse stream_id;
    }
    return null;
}

fn scaleTrigger(value: u16) u8 {
    return @intCast((@as(u32, value) * 255 + 32767) / 65535);
}

fn geforceButtons(source: u32) u16 {
    var result: u16 = 0;
    const mappings = [_]struct { u32, u16 }{
        .{ c.GO_CONTROLLER_BUTTON_DPAD_UP, input_protocol.Button.dpad_up },
        .{ c.GO_CONTROLLER_BUTTON_DPAD_DOWN, input_protocol.Button.dpad_down },
        .{ c.GO_CONTROLLER_BUTTON_DPAD_LEFT, input_protocol.Button.dpad_left },
        .{ c.GO_CONTROLLER_BUTTON_DPAD_RIGHT, input_protocol.Button.dpad_right },
        .{ c.GO_CONTROLLER_BUTTON_START, input_protocol.Button.start },
        .{ c.GO_CONTROLLER_BUTTON_BACK, input_protocol.Button.back },
        .{ c.GO_CONTROLLER_BUTTON_LEFT_STICK, input_protocol.Button.left_stick },
        .{ c.GO_CONTROLLER_BUTTON_RIGHT_STICK, input_protocol.Button.right_stick },
        .{ c.GO_CONTROLLER_BUTTON_LEFT_SHOULDER, input_protocol.Button.left_shoulder },
        .{ c.GO_CONTROLLER_BUTTON_RIGHT_SHOULDER, input_protocol.Button.right_shoulder },
        .{ c.GO_CONTROLLER_BUTTON_GUIDE, input_protocol.Button.guide },
        .{ c.GO_CONTROLLER_BUTTON_A, input_protocol.Button.a },
        .{ c.GO_CONTROLLER_BUTTON_B, input_protocol.Button.b },
        .{ c.GO_CONTROLLER_BUTTON_X, input_protocol.Button.x },
        .{ c.GO_CONTROLLER_BUTTON_Y, input_protocol.Button.y },
    };
    for (mappings) |mapping| {
        if (source & mapping[0] != 0) result |= mapping[1];
    }
    return result;
}

fn controllerStateIsActive(state: c.GoControllerState) bool {
    return state.buttons != 0 or state.left_trigger != 0 or state.right_trigger != 0 or
        state.left_x != 0 or state.left_y != 0 or state.right_x != 0 or state.right_y != 0;
}

fn buildIceUrls(
    allocator: std.mem.Allocator,
    servers: []const cloudmatch.IceServer,
) ![][:0]u8 {
    var result = std.ArrayList([:0]u8).init(allocator);
    errdefer {
        for (result.items) |url| allocator.free(url);
        result.deinit();
    }
    for (servers) |server| {
        for (server.urls) |url| {
            const configured = if (server.username != null and server.credential != null and
                (std.ascii.startsWithIgnoreCase(url, "turn:") or
                    std.ascii.startsWithIgnoreCase(url, "turns:")))
                try addIceCredentials(allocator, url, server.username.?, server.credential.?)
            else
                try allocator.dupeZ(u8, url);
            errdefer allocator.free(configured);
            try result.append(configured);
        }
    }
    return result.toOwnedSlice();
}

fn freeIceUrls(allocator: std.mem.Allocator, urls: [][:0]u8) void {
    for (urls) |url| allocator.free(url);
    allocator.free(urls);
}

fn addIceCredentials(
    allocator: std.mem.Allocator,
    url: []const u8,
    username: []const u8,
    credential: []const u8,
) ![:0]u8 {
    const separator = std.mem.indexOfScalar(u8, url, ':') orelse return error.InvalidIceUrl;
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();
    try result.appendSlice(url[0 .. separator + 1]);
    try writeUrlComponent(result.writer(), username);
    try result.append(':');
    try writeUrlComponent(result.writer(), credential);
    try result.append('@');
    try result.appendSlice(url[separator + 1 ..]);
    return result.toOwnedSliceSentinel(0);
}

fn writeUrlComponent(writer: anytype, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try writer.writeByte(byte);
        } else {
            try writer.writeByte('%');
            try writer.writeByte(hex[byte >> 4]);
            try writer.writeByte(hex[byte & 0x0f]);
        }
    }
}

test "controller state maps to XInput masks used by GeForce NOW" {
    const source = c.GO_CONTROLLER_BUTTON_A | c.GO_CONTROLLER_BUTTON_DPAD_LEFT |
        c.GO_CONTROLLER_BUTTON_GUIDE;
    try std.testing.expectEqual(
        input_protocol.Button.a | input_protocol.Button.dpad_left | input_protocol.Button.guide,
        geforceButtons(source),
    );
    try std.testing.expectEqual(@as(u8, 255), scaleTrigger(65535));
}

test "controller activity ignores neutral samples" {
    try std.testing.expect(!controllerStateIsActive(std.mem.zeroes(c.GoControllerState)));

    var state = std.mem.zeroes(c.GoControllerState);
    state.right_x = 1;
    try std.testing.expect(controllerStateIsActive(state));
}

test "TURN credentials are percent encoded into the libdatachannel URL" {
    const result = try addIceCredentials(
        std.testing.allocator,
        "turn:example.com:3478?transport=udp",
        "user@example",
        "p:a ss",
    );
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(
        "turn:user%40example:p%3Aa%20ss@example.com:3478?transport=udp",
        result,
    );
}

test "GeForce NOW media track roles come from msid" {
    try std.testing.expectEqualStrings(
        "audio",
        mediaStreamTrackId("m=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=msid:second_stream_id audio\r\n").?,
    );
    try std.testing.expectEqualStrings(
        "mic",
        mediaStreamTrackId("m=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=msid:third_stream_id mic\r\n").?,
    );
    try std.testing.expectEqualStrings(
        "audio",
        mediaStreamTrackId("m=audio 0 RTP/AVP\r\na=msid:audio\r\n").?,
    );
    try std.testing.expect(mediaStreamTrackId("m=audio 0 RTP/AVP\r\n") == null);
}

test "ICE URL construction releases partial allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var stun = "stun:example.invalid:3478".*;
            var turn = "turn:example.invalid:3478".*;
            var username = "user".*;
            var credential = "test".*;
            var urls = [_][]u8{ &stun, &turn };
            const servers = [_]cloudmatch.IceServer{.{
                .urls = &urls,
                .username = &username,
                .credential = &credential,
            }};
            const result = try buildIceUrls(allocator, &servers);
            defer freeIceUrls(allocator, result);
        }
    }.run, .{});
}
