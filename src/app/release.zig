const std = @import("std");
const catalog_service = @import("../catalog/service.zig");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("curl/curl.h");
    @cInclude("audio_pipeline.h");
    @cInclude("cloud_session.h");
    @cInclude("controller.h");
    @cInclude("handheld_ui.h");
    @cInclude("sdl_platform.h");
    @cInclude("video_pipeline.h");
    @cInclude("webrtc_session.h");
    @cInclude("xbox_auth.h");
});

pub const Result = enum {
    ok,
    cancelled,
    session_ended,
    missing_credentials,
    reauth_required,
    signed_out,
    failed,
};

var stop_requested: c_int = 0;

fn handleStopSignal(_: c_int) callconv(.c) void {
    const requested: *volatile c_int = &stop_requested;
    requested.* = 1;
}

fn stopRequested() bool {
    const requested: *volatile c_int = &stop_requested;
    return requested.* != 0;
}

fn uiStopRequested(_: ?*anyopaque) callconv(.c) c_int {
    return @intFromBool(stopRequested());
}

fn webrtcWait(context: ?*anyopaque, milliseconds: c_uint) callconv(.c) c_int {
    const ui: ?*c.GoHandheldUi = @ptrCast(@alignCast(context));
    return c.go_handheld_ui_wait(ui, milliseconds);
}

fn debugEnabled() bool {
    return std.posix.getenv("GREENOVERCAST_DEBUG") != null;
}

fn debug(comptime format: []const u8, args: anytype) void {
    if (debugEnabled()) std.debug.print(format, args);
}

pub const Release = struct {
    platform: ?*c.GoSdlPlatform = null,
    video: ?*c.GoVideoPipeline = null,
    audio: ?*c.GoAudioPipeline = null,
    auth: ?*c.GoXboxAuth = null,
    cloud: ?*c.GoCloudSession = null,
    webrtc: ?*c.GoWebrtcSession = null,
    catalog: ?*catalog_service.Service = null,
    curl_initialized: bool = false,
    requested_title: [128]u8 = [_]u8{0} ** 128,
    title_id: [128]u8 = [_]u8{0} ** 128,

    fn initializeMedia(self: *Release) bool {
        const bootstrap_path = std.posix.getenv("GREENOVERCAST_H264_BOOTSTRAP_FILE");
        const decoder_value = std.posix.getenv("GREENOVERCAST_VIDEO_DECODER");
        var decoder_preference: c.GoVideoDecoderPreference = c.GO_VIDEO_DECODER_PREFERENCE_AUTO;
        if (c.go_video_decoder_preference_parse(
            if (decoder_value) |value| value.ptr else null,
            &decoder_preference,
        ) != 0) {
            std.debug.print("Invalid GREENOVERCAST_VIDEO_DECODER value\n", .{});
            return false;
        }
        const config = c.GoVideoPipelineConfig{
            .renderer = c.go_sdl_platform_renderer(self.platform),
            .bootstrap_path = if (bootstrap_path) |path| path.ptr else null,
            .max_width = 1280,
            .max_height = 720,
            .decoder_preference = decoder_preference,
        };
        self.video = c.go_video_pipeline_create(&config);
        if (self.video == null or c.go_video_pipeline_start(self.video) < 0) {
            std.debug.print("H.264 pipeline initialization failed\n", .{});
            _ = c.go_video_pipeline_destroy(self.video);
            self.video = null;
            return false;
        }

        self.audio = c.go_audio_pipeline_create(c.go_sdl_platform_audio_device(self.platform));
        if (self.audio == null) {
            std.debug.print("Opus decoder initialization failed\n", .{});
            _ = c.go_video_pipeline_destroy(self.video);
            self.video = null;
            return false;
        }
        return true;
    }

    fn destroyMedia(self: *Release) void {
        c.go_audio_pipeline_destroy(self.audio);
        self.audio = null;
        if (c.go_video_pipeline_destroy(self.video) != 0)
            std.debug.print("H.264 bootstrap could not be updated\n", .{});
        self.video = null;
    }

    pub fn open(requested_title: []const u8) ?*Release {
        if (requested_title.len >= 128) return null;

        const release = std.heap.c_allocator.create(Release) catch return null;
        release.* = .{};
        @memcpy(release.requested_title[0..requested_title.len], requested_title);
        release.requested_title[requested_title.len] = 0;

        stop_requested = 0;
        const action = std.posix.Sigaction{
            .handler = .{ .handler = handleStopSignal },
            .mask = std.posix.empty_sigset,
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &action, null);
        std.posix.sigaction(std.posix.SIG.TERM, &action, null);

        debug("GreenOvercast streaming client\n", .{});
        debug("Initializing display\n", .{});
        release.platform = c.go_sdl_platform_create(uiStopRequested, null);
        if (release.platform == null) {
            std.debug.print("Platform initialization failed\n", .{});
            release.close();
            return null;
        }

        if (!release.initializeMedia()) {
            release.close();
            return null;
        }

        if (c.curl_global_init(c.CURL_GLOBAL_DEFAULT) != c.CURLE_OK) {
            std.debug.print("libcurl initialization failed\n", .{});
            release.close();
            return null;
        }
        release.curl_initialized = true;

        release.auth = c.go_xbox_auth_create();
        if (release.auth == null) {
            std.debug.print("Xbox authentication configuration is incomplete\n", .{});
            release.close();
            return null;
        }

        release.cloud = c.go_cloud_session_create(release.auth, release.ui());
        if (release.cloud == null) {
            std.debug.print("Cloud session service could not be initialized\n", .{});
            release.close();
            return null;
        }
        return release;
    }

    fn ui(self: *const Release) ?*c.GoHandheldUi {
        return c.go_sdl_platform_ui(self.platform);
    }

    fn controller(self: *const Release) ?*c.GoControllerInput {
        return c.go_sdl_platform_controller(self.platform);
    }

    fn drawLoading(self: *Release, heading: [*c]const u8, detail: [*c]const u8, action: c.GoHandheldUiAction) void {
        c.go_handheld_ui_draw_loading(self.ui(), heading, detail, action);
    }

    pub fn loadCredentials(self: *Release) Result {
        const result = c.go_xbox_auth_load_credentials(self.auth);
        if (result < 0) {
            std.debug.print("Credential store could not be read\n", .{});
            return .failed;
        }
        if (result == 0) return .missing_credentials;
        debug("Credentials loaded\n", .{});
        return .ok;
    }

    pub fn deviceSignIn(self: *Release) Result {
        const result = c.go_xbox_auth_device_sign_in(self.auth, self.ui());
        if (result == 0) return .cancelled;
        if (result < 0) {
            std.debug.print("Device-code sign-in could not be completed\n", .{});
            return .failed;
        }
        debug("Credentials loaded\n", .{});
        return .ok;
    }

    pub fn refreshAuth(self: *Release) Result {
        self.drawLoading("SIGNING IN", "REFRESHING XBOX SESSION", c.GO_HANDHELD_UI_ACTION_NONE);
        debug("Refreshing auth\n", .{});
        return switch (c.go_xbox_auth_refresh(self.auth)) {
            c.GO_XBOX_AUTH_OK => .ok,
            c.GO_XBOX_AUTH_REAUTH_REQUIRED => result: {
                self.drawLoading("SIGN IN EXPIRED", "REQUESTING A NEW DEVICE CODE", c.GO_HANDHELD_UI_ACTION_NONE);
                c.SDL_Delay(700);
                break :result .reauth_required;
            },
            else => result: {
                std.debug.print("Auth failed\n", .{});
                break :result .failed;
            },
        };
    }

    pub fn loadCatalog(self: *Release) Result {
        const cloud = self.cloud orelse return .failed;
        const ui_handle = self.ui() orelse return .failed;
        const base_url_pointer = c.go_cloud_session_base_url(cloud);
        if (base_url_pointer == null) return .failed;
        const base_url = std.mem.span(@as([*:0]const u8, @ptrCast(base_url_pointer)));
        const cache_path = std.posix.getenv("GREENOVERCAST_CATALOG_FILE");
        self.catalog = catalog_service.Service.create(
            std.heap.c_allocator,
            base_url,
            if (cache_path) |path| path else null,
            @ptrCast(cloud),
            @ptrCast(ui_handle),
        ) catch {
            std.debug.print("Catalog service could not be initialized\n", .{});
            return .failed;
        };
        self.drawLoading("LOADING LIBRARY", "CHECKING YOUR CLOUD GAMES", c.GO_HANDHELD_UI_ACTION_BACK);
        debug("Loading cloud catalog\n", .{});
        const result = self.catalog.?.load() catch |err| {
            if (err == error.EmptyCatalog)
                std.debug.print("Catalog contained no playable titles\n", .{});
            std.debug.print("Xbox cloud catalog could not be loaded\n", .{});
            return .failed;
        };
        if (result == .cancelled) return .cancelled;
        debug("Playable titles: {d}\n", .{self.catalog.?.titleCount()});
        return .ok;
    }

    pub fn pickTitle(self: *Release) Result {
        if (self.catalog == null) return .failed;
        const requested = std.mem.sliceTo(&self.requested_title, 0);
        const selection = self.catalog.?.pick(requested) catch return .failed;
        @memset(&self.requested_title, 0);
        const selected = switch (selection) {
            .title_id => |value| value,
            .cancelled => return .cancelled,
            .sign_out => return .signed_out,
        };
        if (selected.len >= self.title_id.len) return .failed;
        @memset(&self.title_id, 0);
        @memcpy(self.title_id[0..selected.len], selected);
        return .ok;
    }

    pub fn signOut(self: *Release) Result {
        self.drawLoading("SIGNING OUT", "REMOVING XBOX CREDENTIALS", c.GO_HANDHELD_UI_ACTION_NONE);
        if (c.go_xbox_auth_sign_out(self.auth) != 0) {
            std.debug.print("Xbox credentials could not be removed\n", .{});
            return .failed;
        }
        if (self.catalog) |catalog| catalog.destroy();
        self.catalog = null;
        @memset(&self.title_id, 0);
        return .ok;
    }

    pub fn createSession(self: *Release) Result {
        if (self.title_id[0] == 0) return .failed;
        self.drawLoading("STARTING GAME", "ALLOCATING CLOUD SESSION", c.GO_HANDHELD_UI_ACTION_CANCEL);
        debug("Creating session ({s})\n", .{std.mem.sliceTo(&self.title_id, 0)});
        if (c.go_cloud_session_start_game(self.cloud, @ptrCast(&self.title_id)) < 0) {
            std.debug.print("Session creation failed\n", .{});
            return .failed;
        }
        return .ok;
    }

    pub fn waitReady(self: *Release) Result {
        debug("Waiting for ReadyToConnect\n", .{});
        if (c.go_cloud_session_wait_for_state(self.cloud, "ReadyToConnect", 100) < 0) {
            if (c.go_handheld_ui_cancelled(self.ui()) != 0) return .cancelled;
            std.debug.print("Session never became ready\n", .{});
            return .failed;
        }
        return .ok;
    }

    pub fn connect(self: *Release) Result {
        debug("Connecting\n", .{});
        if (c.go_cloud_session_connect(self.cloud) < 0) {
            std.debug.print("Connect failed\n", .{});
            return .failed;
        }
        return .ok;
    }

    pub fn waitProvisioned(self: *Release) Result {
        debug("Waiting for Provisioned\n", .{});
        if (c.go_cloud_session_wait_for_state(self.cloud, "Provisioned", 100) < 0) {
            if (c.go_handheld_ui_cancelled(self.ui()) != 0) return .cancelled;
            std.debug.print("Provisioning failed\n", .{});
            return .failed;
        }
        return .ok;
    }

    pub fn setupWebrtc(self: *Release) Result {
        if (self.webrtc != null) return .failed;
        debug("Setting up WebRTC\n", .{});
        const stream_width = c.go_handheld_ui_stream_width(self.ui());
        const stream_height = c.go_handheld_ui_stream_height(self.ui());
        self.webrtc = c.go_webrtc_session_create(
            self.cloud,
            self.video,
            self.audio,
            self.controller(),
            webrtcWait,
            self.ui(),
            stream_width,
            stream_height,
        );
        if (self.webrtc == null or c.go_webrtc_session_setup(self.webrtc) < 0) {
            if (c.go_handheld_ui_cancelled(self.ui()) != 0) return .cancelled;
            std.debug.print("WebRTC setup failed\n", .{});
            return .failed;
        }
        return .ok;
    }

    pub fn waitConnected(self: *Release) Result {
        if (self.webrtc == null) return .failed;
        debug("Waiting for WebRTC connection\n", .{});
        var seconds: usize = 0;
        while (seconds < 60 and c.go_webrtc_session_connected(self.webrtc) == 0 and
            c.go_webrtc_session_failed(self.webrtc) == 0 and
            c.go_webrtc_session_closed(self.webrtc) == 0 and !stopRequested()) : (seconds += 1)
        {
            if (c.go_handheld_ui_wait(self.ui(), 1000) != 0) break;
        }
        if (c.go_handheld_ui_cancelled(self.ui()) != 0 or stopRequested()) return .cancelled;
        if (c.go_webrtc_session_closed(self.webrtc) != 0) return .session_ended;
        if (c.go_webrtc_session_connected(self.webrtc) == 0) {
            std.debug.print("Connection timeout\n", .{});
            return .failed;
        }

        debug("Connected; waiting for HandshakeAck\n", .{});
        var attempts: usize = 0;
        while (attempts < 50 and c.go_webrtc_session_handshake_complete(self.webrtc) == 0 and
            c.go_webrtc_session_failed(self.webrtc) == 0 and
            c.go_webrtc_session_closed(self.webrtc) == 0) : (attempts += 1)
        {
            if (c.go_handheld_ui_wait(self.ui(), 100) != 0) return .cancelled;
        }
        if (c.go_webrtc_session_closed(self.webrtc) != 0) return .session_ended;
        if (c.go_webrtc_session_failed(self.webrtc) != 0) return .failed;
        if (c.go_webrtc_session_handshake_complete(self.webrtc) == 0)
            std.debug.print("Message-channel handshake is still pending\n", .{});
        c.go_webrtc_session_request_keyframe(self.webrtc);
        return .ok;
    }

    pub fn stream(self: *Release) Result {
        if (self.webrtc == null) return .failed;
        debug("Streaming (hold Select + Start for 1s to exit)\n", .{});
        const stream_started = c.SDL_GetTicks();
        var last_stats = stream_started;
        var last_keyframe_request = stream_started;
        var next_loop = stream_started;
        var pacing_remainder: u32 = 0;

        if (c.go_audio_pipeline_start(self.audio) < 0) {
            std.debug.print("Audio worker failed to start\n", .{});
            return .failed;
        }
        if (c.go_cloud_session_start_keepalive(self.cloud) < 0) {
            std.debug.print("Session keepalive worker failed to start\n", .{});
            return .failed;
        }

        const controller_input = self.controller();
        while (true) {
            var event: c.SDL_Event = undefined;
            while (c.SDL_PollEvent(&event) != 0) {
                c.go_controller_input_handle_event(controller_input, &event);
                if (event.type == c.SDL_QUIT or
                    (event.type == c.SDL_KEYDOWN and event.key.keysym.sym == c.SDLK_ESCAPE))
                    return .cancelled;
            }
            if (c.go_controller_input_exit_held(controller_input, 1000) != 0 or stopRequested())
                return .cancelled;
            if (c.go_webrtc_session_failed(self.webrtc) != 0) {
                std.debug.print("WebRTC connection failed\n", .{});
                return .failed;
            }
            if (c.go_webrtc_session_closed(self.webrtc) != 0) {
                std.debug.print("Cloud game ended\n", .{});
                return .session_ended;
            }
            if (c.go_video_pipeline_failed(self.video) != 0)
                return .failed;

            c.go_webrtc_session_send_gamepad(self.webrtc);
            c.go_video_pipeline_render(self.video);
            c.go_webrtc_session_request_video_bitrate(self.webrtc, 2_000_000);
            const now = c.SDL_GetTicks();
            if (c.go_video_pipeline_needs_keyframe(self.video) != 0 and
                now -% last_keyframe_request >= 500)
            {
                c.go_webrtc_session_request_keyframe(self.webrtc);
                last_keyframe_request = now;
            }
            if (now -% last_stats >= 1000) {
                self.printStats(now -% stream_started);
                last_stats = now;
            }

            next_loop +%= 16;
            pacing_remainder += 40;
            if (pacing_remainder >= 60) {
                next_loop +%= 1;
                pacing_remainder -= 60;
            }
            const remaining: i32 = @bitCast(next_loop -% c.SDL_GetTicks());
            if (remaining > 0)
                c.SDL_Delay(@intCast(remaining))
            else if (remaining < -50)
                next_loop = c.SDL_GetTicks();
        }
    }

    fn printStats(self: *Release, elapsed_ms: u32) void {
        if (!debugEnabled()) return;
        const video = c.go_video_pipeline_stats(self.video);
        const audio = c.go_audio_pipeline_stats(self.audio);
        const cloud = c.go_cloud_session_stats(self.cloud);
        std.debug.print(
            "[{d}s] video_rtp={d} payload={d} rejected={d}/pt{d} aus={d} frames={d}/{d} source={d}x{d} " ++
                "nals={d}/{d}/{d}/{d} ts={d} synced={d} gaps={d} missing={d} late_rtp={d} " ++
                "decoder={d} init_failures={d} fallbacks={d} backpressure={d} corrupt={d} " ++
                "info_changes={d} decode_errors={d}/{d}/{d} keyframes={d} queue={d}/{d}\n",
            .{
                elapsed_ms / 1000,
                video.rtp_packets,
                video.payload_packets,
                video.rejected_packets,
                video.last_rejected_payload_type,
                video.access_units,
                video.decoded_frames,
                video.rendered_frames,
                video.source_width,
                video.source_height,
                video.frame_nals,
                video.idr_nals,
                video.parameter_nals,
                video.auxiliary_nals,
                video.last_timestamp,
                video.synced,
                video.discontinuities,
                video.missing_packets,
                video.late_packets,
                video.decoder_backend,
                video.decoder_init_failures,
                video.decoder_runtime_fallbacks,
                video.decoder_backpressure_events,
                video.decoder_corrupt_frames,
                video.decoder_info_changes,
                video.decoder_send_errors,
                video.decoder_receive_errors,
                video.last_decoder_error,
                video.keyframe_requests,
                video.pending_packets,
                video.dropped_packets,
            },
        );
        std.debug.print(
            "[{d}s] audio_rtp={d} decoded={d} dropped={d} late={d} pending={d} " ++
                "queued_ms={d} resets={d} keepalive={d}/{d}\n",
            .{
                elapsed_ms / 1000,
                audio.rtp_packets,
                audio.decoded_packets,
                audio.dropped_packets,
                audio.late_packets,
                audio.pending_packets,
                audio.queued_milliseconds,
                audio.queue_resets,
                cloud.keepalive_successes,
                cloud.keepalive_failures,
            },
        );
    }

    fn closeSession(self: *Release) void {
        c.go_cloud_session_stop_keepalive(self.cloud);
        c.go_webrtc_session_destroy(self.webrtc);
        self.webrtc = null;
        c.go_video_pipeline_stop(self.video);
        c.go_audio_pipeline_stop(self.audio);
        c.go_cloud_session_end(self.cloud);
    }

    pub fn resetSession(self: *Release) Result {
        self.closeSession();
        self.destroyMedia();
        @memset(&self.title_id, 0);
        if (stopRequested()) return .cancelled;
        if (!self.initializeMedia()) return .failed;
        return .ok;
    }

    pub fn close(self: *Release) void {
        debug("Cleanup\n", .{});
        self.closeSession();
        if (self.catalog) |catalog| catalog.destroy();
        c.go_cloud_session_destroy(self.cloud);
        c.go_xbox_auth_destroy(self.auth);
        self.destroyMedia();
        c.go_sdl_platform_destroy(self.platform);
        if (self.curl_initialized) c.curl_global_cleanup();
        std.crypto.secureZero(u8, std.mem.asBytes(self));
        std.heap.c_allocator.destroy(self);
    }
};
