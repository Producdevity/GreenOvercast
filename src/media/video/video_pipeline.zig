const std = @import("std");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("libavutil/frame.h");
    @cInclude("libavutil/pixfmt.h");
    @cInclude("libswscale/swscale.h");
    @cInclude("stdlib.h");
    @cInclude("h264_depacketizer.h");
    @cInclude("video_decoder.h");
    @cInclude("video_frame_copy.h");
    @cInclude("video_pipeline.h");
});

const bootstrap_capacity = 4104;
const packet_capacity = 4096;
const queue_capacity = 128;
const backpressure_attempts = 64;

const VideoPacket = struct {
    length: u16 = 0,
    data: [packet_capacity]u8 = undefined,
};

const Pipeline = struct {
    renderer: *c.SDL_Renderer,
    depacketizer: ?*c.GoH264Depacketizer = null,
    bootstrap: [bootstrap_capacity]u8 = undefined,
    bootstrap_length: usize = 0,
    parameter_sets_dirty: bool = false,
    bootstrap_path: [512]u8 = [_]u8{0} ** 512,

    packet_queue: [queue_capacity]VideoPacket = undefined,
    packet_queue_head: usize = 0,
    packet_queue_tail: usize = 0,
    packet_queue_count: usize = 0,
    packet_mutex: std.Thread.Mutex = .{},
    packet_condition: std.Thread.Condition = .{},
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    accepting_packets: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    restart_epoch_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    decoders: c.GoVideoDecoderSelection = std.mem.zeroes(c.GoVideoDecoderSelection),
    decoded_frame: ?*c.AVFrame = null,
    max_width: c_int,
    max_height: c_int,
    decoder_failure: [256]u8 = [_]u8{0} ** 256,
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    texture: ?*c.SDL_Texture = null,
    scaler: ?*c.SwsContext = null,
    rgb_buffer: ?[*]u8 = null,
    rgb_linesize: c_int = 0,
    texture_width: c_int = 0,
    texture_height: c_int = 0,
    texture_format: c.Uint32 = c.SDL_PIXELFORMAT_UNKNOWN,
    direct_nv12_available: bool = true,
    upload_error_reported: bool = false,

    frame_mutex: std.Thread.Mutex = .{},
    display_frame: ?*c.AVFrame = null,
    render_frame: ?*c.AVFrame = null,
    frame_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    synced: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    keyframe_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    rtp_packets: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    payload_packets: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    rejected_packets: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    last_rejected_payload_type: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(-1),
    access_units: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    decoded_frames: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    rendered_frames: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    source_width: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    source_height: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    frame_nals: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    idr_nals: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    parameter_nals: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    auxiliary_nals: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    last_timestamp: std.atomic.Value(c_uint) = std.atomic.Value(c_uint).init(0),
    discontinuities: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    missing_packets: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    late_packets: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    decoder_send_errors: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    decoder_receive_errors: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    last_decoder_error: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    decoder_backend: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    decoder_init_failures: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    decoder_runtime_fallbacks: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    decoder_backpressure_events: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    decoder_corrupt_frames: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    decoder_info_changes: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    keyframe_requests: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    dropped_packets: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
};

pub const Stats = extern struct {
    rtp_packets: c_int = 0,
    payload_packets: c_int = 0,
    rejected_packets: c_int = 0,
    last_rejected_payload_type: c_int = 0,
    access_units: c_int = 0,
    decoded_frames: c_int = 0,
    rendered_frames: c_int = 0,
    source_width: c_int = 0,
    source_height: c_int = 0,
    frame_nals: c_int = 0,
    idr_nals: c_int = 0,
    parameter_nals: c_int = 0,
    auxiliary_nals: c_int = 0,
    last_timestamp: c_uint = 0,
    synced: c_int = 0,
    discontinuities: c_int = 0,
    missing_packets: c_int = 0,
    late_packets: c_int = 0,
    decoder_send_errors: c_int = 0,
    decoder_receive_errors: c_int = 0,
    last_decoder_error: c_int = 0,
    decoder_backend: c.GoVideoDecoderBackend = c.GO_VIDEO_DECODER_BACKEND_NONE,
    decoder_init_failures: c_int = 0,
    decoder_runtime_fallbacks: c_int = 0,
    decoder_backpressure_events: c_int = 0,
    decoder_corrupt_frames: c_int = 0,
    decoder_info_changes: c_int = 0,
    keyframe_requests: c_int = 0,
    pending_packets: c_int = 0,
    dropped_packets: c_int = 0,
};

fn debugEnabled() bool {
    return std.posix.getenv("GREENOVERCAST_DEBUG") != null;
}

fn copyZ(destination: []u8, message: []const u8) void {
    @memset(destination, 0);
    const length = @min(destination.len - 1, message.len);
    @memcpy(destination[0..length], message[0..length]);
}

fn zSlice(buffer: []const u8) []const u8 {
    return std.mem.sliceTo(buffer, 0);
}

fn loadBootstrap(pipeline: *Pipeline) c_int {
    const path = zSlice(&pipeline.bootstrap_path);
    if (path.len == 0) return 0;
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err != error.FileNotFound and debugEnabled())
            std.debug.print("Ignoring unreadable H.264 bootstrap cache: {s}\n", .{@errorName(err)});
        return 0;
    };
    defer file.close();
    const size = file.getEndPos() catch return 0;
    if (size == 0 or size > bootstrap_capacity) return 0;
    var data: [bootstrap_capacity]u8 = undefined;
    file.reader().readNoEof(data[0..@intCast(size)]) catch return 0;
    if (c.go_h264_depacketizer_set_bootstrap(pipeline.depacketizer, &data, @intCast(size)) != 0) {
        if (debugEnabled()) std.debug.print("Ignoring invalid H.264 bootstrap cache\n", .{});
        return 0;
    }
    if (debugEnabled()) std.debug.print("H.264 bootstrap loaded ({d} bytes)\n", .{size});
    return 0;
}

fn persistBootstrap(pipeline: *Pipeline) c_int {
    const path = zSlice(&pipeline.bootstrap_path);
    if (!pipeline.parameter_sets_dirty or path.len == 0 or pipeline.bootstrap_length == 0)
        return 0;
    var temporary_buffer: [517]u8 = undefined;
    const temporary = std.fmt.bufPrint(&temporary_buffer, "{s}.tmp", .{path}) catch return -1;
    const cwd = std.fs.cwd();
    var file = cwd.createFile(temporary, .{ .truncate = true, .mode = 0o600 }) catch return -1;
    var closed = false;
    defer if (!closed) file.close();
    file.writeAll(pipeline.bootstrap[0..pipeline.bootstrap_length]) catch {
        file.close();
        closed = true;
        cwd.deleteFile(temporary) catch {};
        return -1;
    };
    file.sync() catch {
        file.close();
        closed = true;
        cwd.deleteFile(temporary) catch {};
        return -1;
    };
    file.close();
    closed = true;
    cwd.rename(temporary, path) catch {
        cwd.deleteFile(temporary) catch {};
        return -1;
    };
    pipeline.parameter_sets_dirty = false;
    if (debugEnabled()) std.debug.print("H.264 bootstrap updated\n", .{});
    return 0;
}

fn publishFrame(pipeline: *Pipeline, frame: *c.AVFrame, decoder_name: [*c]const u8) void {
    _ = pipeline.decoded_frames.fetchAdd(1, .monotonic);
    pipeline.source_width.store(frame.width, .monotonic);
    pipeline.source_height.store(frame.height, .monotonic);
    pipeline.keyframe_pending.store(false, .release);
    if (!pipeline.synced.swap(true, .acq_rel) and debugEnabled()) {
        std.debug.print("Video output active: {d}x{d} format={d} decoder={s}\n", .{
            frame.width,
            frame.height,
            frame.format,
            std.mem.span(decoder_name),
        });
    }
    pipeline.frame_mutex.lock();
    defer pipeline.frame_mutex.unlock();
    c.av_frame_unref(pipeline.display_frame);
    if (c.av_frame_ref(pipeline.display_frame, frame) == 0)
        pipeline.frame_ready.store(true, .release);
}

fn publishDecodedFrame(pipeline: *Pipeline, frame: *const c.GoDecodedVideoFrame) c_int {
    const target = pipeline.decoded_frame orelse return -1;
    if (c.go_video_frame_validate(frame, pipeline.max_width, pipeline.max_height) != 0) return -1;
    const format: c_int = if (frame.format == c.GO_VIDEO_PIXEL_FORMAT_NV12)
        c.AV_PIX_FMT_NV12
    else if (frame.format == c.GO_VIDEO_PIXEL_FORMAT_YUV420P)
        c.AV_PIX_FMT_YUV420P
    else
        return -1;
    if (target.format != format or target.width != frame.width or target.height != frame.height) {
        c.av_frame_unref(target);
        target.format = format;
        target.width = frame.width;
        target.height = frame.height;
        if (c.av_frame_get_buffer(target, 32) < 0) return -1;
    }
    if (c.av_frame_make_writable(target) < 0) return -1;
    if (c.go_video_frame_copy(
        frame,
        pipeline.max_width,
        pipeline.max_height,
        @ptrCast(&target.data),
        @ptrCast(&target.linesize),
    ) != 0) return -1;
    target.color_range = if (frame.color_range == c.GO_VIDEO_COLOR_RANGE_FULL)
        c.AVCOL_RANGE_JPEG
    else
        c.AVCOL_RANGE_MPEG;
    target.colorspace = c.AVCOL_SPC_BT709;
    publishFrame(pipeline, target, c.go_video_decoder_name(pipeline.decoders.active));
    return 0;
}

fn drainDecoderFrames(pipeline: *Pipeline) c_int {
    while (true) {
        var frame: c.GoDecodedVideoFrame = undefined;
        const result = c.go_video_decoder_receive_frame(pipeline.decoders.active, &frame);
        if (result == c.GO_VIDEO_DECODER_RESULT_AGAIN) return 0;
        if (result == c.GO_VIDEO_DECODER_RESULT_FATAL) {
            _ = pipeline.decoder_receive_errors.fetchAdd(1, .monotonic);
            pipeline.last_decoder_error.store(-1, .monotonic);
            copyZ(&pipeline.decoder_failure, std.mem.span(c.go_video_decoder_last_error(pipeline.decoders.active)));
            return -1;
        }
        if (frame.corrupt != 0) {
            _ = pipeline.decoder_corrupt_frames.fetchAdd(1, .monotonic);
            c.go_video_decoder_release_frame(pipeline.decoders.active, &frame);
            continue;
        }
        if (frame.info_changed != 0) _ = pipeline.decoder_info_changes.fetchAdd(1, .monotonic);
        const publish_result = publishDecodedFrame(pipeline, &frame);
        c.go_video_decoder_release_frame(pipeline.decoders.active, &frame);
        if (publish_result != 0) {
            copyZ(&pipeline.decoder_failure, "decoder returned an invalid frame");
            return -1;
        }
    }
}

fn switchToSoftwareDecoder(pipeline: *Pipeline) c_int {
    if (pipeline.decoders.allow_runtime_fallback == 0 or pipeline.decoders.software == null or
        pipeline.decoders.active == pipeline.decoders.software) return -1;
    std.debug.print("{s} decoder disabled: {s}\n", .{
        std.mem.span(c.go_video_decoder_name(pipeline.decoders.active)),
        zSlice(&pipeline.decoder_failure),
    });
    if (c.go_video_decoder_selection_fallback(
        &pipeline.decoders,
        @ptrCast(&pipeline.decoder_failure),
        pipeline.decoder_failure.len,
    ) != 0) return -1;
    pipeline.decoder_backend.store(@intCast(c.go_video_decoder_backend(pipeline.decoders.active)), .monotonic);
    _ = pipeline.decoder_runtime_fallbacks.fetchAdd(1, .monotonic);
    c.go_h264_depacketizer_restart_decode_epoch(pipeline.depacketizer);
    pipeline.keyframe_pending.store(true, .release);
    pipeline.synced.store(false, .release);
    std.debug.print("Selected video decoder: {s}\n", .{
        std.mem.span(c.go_video_decoder_name(pipeline.decoders.active)),
    });
    return 0;
}

fn markDecoderFailed(pipeline: *Pipeline) void {
    if (pipeline.failed.swap(true, .acq_rel)) return;
    pipeline.accepting_packets.store(false, .release);
    std.debug.print("Video decoder failed: {s}\n", .{zSlice(&pipeline.decoder_failure)});
}

fn decodeWithActiveBackend(pipeline: *Pipeline, data: [*]const u8, length: usize) c_int {
    for (0..backpressure_attempts) |attempt| {
        if (pipeline.stop.load(.acquire)) return 0;
        const result = c.go_video_decoder_submit_access_unit(pipeline.decoders.active, data, length);
        if (result == c.GO_VIDEO_DECODER_RESULT_OK) return drainDecoderFrames(pipeline);
        if (result == c.GO_VIDEO_DECODER_RESULT_FATAL) {
            _ = pipeline.decoder_send_errors.fetchAdd(1, .monotonic);
            pipeline.last_decoder_error.store(-1, .monotonic);
            copyZ(&pipeline.decoder_failure, std.mem.span(c.go_video_decoder_last_error(pipeline.decoders.active)));
            return -1;
        }
        _ = pipeline.decoder_backpressure_events.fetchAdd(1, .monotonic);
        if (drainDecoderFrames(pipeline) != 0) return -1;
        if (attempt + 1 < backpressure_attempts) c.SDL_Delay(1);
    }
    copyZ(&pipeline.decoder_failure, "decoder made no progress after 64 submit attempts");
    return -1;
}

fn selectDecoder(pipeline: *Pipeline, preference: c.GoVideoDecoderPreference) c_int {
    const config = c.GoVideoDecoderSelectionConfig{
        .max_width = pipeline.max_width,
        .max_height = pipeline.max_height,
        .preference = preference,
    };
    if (c.go_video_decoder_selection_create(
        &config,
        &pipeline.decoders,
        @ptrCast(&pipeline.decoder_failure),
        pipeline.decoder_failure.len,
    ) != 0) return -1;
    pipeline.decoder_init_failures.store(@intCast(pipeline.decoders.init_failures), .monotonic);
    pipeline.decoder_backend.store(@intCast(c.go_video_decoder_backend(pipeline.decoders.active)), .monotonic);
    return 0;
}

fn decodeAccessUnit(
    context: ?*anyopaque,
    data: [*c]const u8,
    length: usize,
    _: [*c]const c.GoH264AccessUnit,
) callconv(.c) void {
    const pipeline: *Pipeline = @ptrCast(@alignCast(context orelse return));
    if (pipeline.decoders.active == null or pipeline.failed.load(.acquire)) return;
    if (decodeWithActiveBackend(pipeline, data, length) == 0) return;
    if (switchToSoftwareDecoder(pipeline) != 0) markDecoderFailed(pipeline);
}

fn processPacket(pipeline: *Pipeline, packet: []const u8) void {
    if (packet.len < 12 or pipeline.depacketizer == null) return;
    _ = pipeline.rtp_packets.fetchAdd(1, .monotonic);
    const result = c.go_h264_depacketizer_feed(
        pipeline.depacketizer,
        packet.ptr,
        packet.len,
        decodeAccessUnit,
        pipeline,
    );
    if (result.accepted == 0) {
        _ = pipeline.rejected_packets.fetchAdd(1, .monotonic);
        pipeline.last_rejected_payload_type.store(packet[1] & 0x7f, .monotonic);
        return;
    }
    _ = pipeline.payload_packets.fetchAdd(1, .monotonic);
    pipeline.last_timestamp.store(result.timestamp, .monotonic);
    _ = pipeline.missing_packets.fetchAdd(@intCast(result.missing_packets), .monotonic);
    _ = pipeline.late_packets.fetchAdd(@intCast(result.late_packets), .monotonic);
    _ = pipeline.discontinuities.fetchAdd(@intCast(result.discontinuities), .monotonic);
    _ = pipeline.access_units.fetchAdd(@intCast(result.access_units), .monotonic);
    _ = pipeline.frame_nals.fetchAdd(@intCast(result.frame_nals), .monotonic);
    _ = pipeline.idr_nals.fetchAdd(@intCast(result.idr_nals), .monotonic);
    _ = pipeline.parameter_nals.fetchAdd(@intCast(result.parameter_nals), .monotonic);
    _ = pipeline.auxiliary_nals.fetchAdd(@intCast(result.auxiliary_nals), .monotonic);
    if (result.requires_keyframe != 0) pipeline.keyframe_pending.store(true, .release);

    var bootstrap_length: usize = 0;
    const bootstrap_result = c.go_h264_depacketizer_take_bootstrap(
        pipeline.depacketizer,
        &pipeline.bootstrap,
        pipeline.bootstrap.len,
        &bootstrap_length,
    );
    if (bootstrap_result > 0) {
        pipeline.bootstrap_length = bootstrap_length;
        pipeline.parameter_sets_dirty = true;
    } else if (bootstrap_result < 0) {
        std.debug.print("H.264 parameter sets exceed the bootstrap limit\n", .{});
    }
}

fn worker(pipeline: *Pipeline) void {
    while (true) {
        pipeline.packet_mutex.lock();
        while (pipeline.packet_queue_count == 0 and !pipeline.stop.load(.acquire))
            pipeline.packet_condition.wait(&pipeline.packet_mutex);
        if (pipeline.stop.load(.acquire)) {
            pipeline.packet_mutex.unlock();
            break;
        }
        const packet = pipeline.packet_queue[pipeline.packet_queue_head];
        pipeline.packet_queue_head = (pipeline.packet_queue_head + 1) % queue_capacity;
        pipeline.packet_queue_count -= 1;
        pipeline.packet_mutex.unlock();
        if (pipeline.restart_epoch_pending.swap(false, .acq_rel))
            c.go_h264_depacketizer_restart_decode_epoch(pipeline.depacketizer);
        processPacket(pipeline, packet.data[0..packet.length]);
    }
}

fn destroyTexture(pipeline: *Pipeline) void {
    if (pipeline.texture) |texture| c.SDL_DestroyTexture(texture);
    pipeline.texture = null;
    pipeline.texture_format = c.SDL_PIXELFORMAT_UNKNOWN;
}

fn configureRenderer(pipeline: *Pipeline, frame: *const c.AVFrame) c_int {
    const width = frame.width;
    const height = frame.height;
    const source_format = frame.format;
    const source_full_range: c_int = @intFromBool(frame.color_range == c.AVCOL_RANGE_JPEG);
    if (width <= 0 or height <= 0 or width > 8192 or height > 8192) return -1;
    const direct_nv12 = source_format == c.AV_PIX_FMT_NV12 and pipeline.direct_nv12_available;
    var requested_format: c.Uint32 = if (direct_nv12) c.SDL_PIXELFORMAT_NV12 else c.SDL_PIXELFORMAT_RGB24;
    if (pipeline.texture != null and
        (width != pipeline.texture_width or height != pipeline.texture_height or
            requested_format != pipeline.texture_format)) destroyTexture(pipeline);
    if (pipeline.texture == null) {
        if (direct_nv12) {
            c.SDL_SetYUVConversionMode(c.SDL_YUV_CONVERSION_BT709);
            pipeline.texture = c.SDL_CreateTexture(
                pipeline.renderer,
                c.SDL_PIXELFORMAT_NV12,
                c.SDL_TEXTUREACCESS_STREAMING,
                width,
                height,
            );
            if (pipeline.texture == null) {
                std.debug.print("Direct NV12 texture unavailable: {s}\n", .{std.mem.span(c.SDL_GetError())});
                pipeline.direct_nv12_available = false;
                requested_format = c.SDL_PIXELFORMAT_RGB24;
            }
        }
        if (pipeline.texture == null) {
            pipeline.texture = c.SDL_CreateTexture(
                pipeline.renderer,
                c.SDL_PIXELFORMAT_RGB24,
                c.SDL_TEXTUREACCESS_STREAMING,
                width,
                height,
            );
        }
        if (pipeline.texture == null) {
            std.debug.print("SDL_CreateTexture: {s}\n", .{std.mem.span(c.SDL_GetError())});
            return -1;
        }
        pipeline.texture_width = width;
        pipeline.texture_height = height;
        pipeline.texture_format = requested_format;
        if (debugEnabled()) std.debug.print("Created {s} texture {d}x{d}\n", .{
            if (requested_format == c.SDL_PIXELFORMAT_NV12) "NV12" else "RGB24",
            width,
            height,
        });
    }
    if (pipeline.texture_format == c.SDL_PIXELFORMAT_NV12) return 0;

    const scaler = c.sws_getCachedContext(
        pipeline.scaler,
        width,
        height,
        @intCast(source_format),
        width,
        height,
        c.AV_PIX_FMT_RGB24,
        c.SWS_BILINEAR,
        null,
        null,
        null,
    );
    if (scaler == null) {
        std.debug.print("Failed to create YUV-to-RGB converter\n", .{});
        return -1;
    }
    pipeline.scaler = scaler;
    const coefficients = c.sws_getCoefficients(c.SWS_CS_ITU709);
    _ = c.sws_setColorspaceDetails(scaler, coefficients, source_full_range, coefficients, 1, 0, 1 << 16, 1 << 16);
    const required = std.math.mul(usize, @intCast(width), @intCast(height)) catch return -1;
    const byte_count = std.math.mul(usize, required, 3) catch return -1;
    const buffer = c.realloc(pipeline.rgb_buffer, byte_count) orelse {
        std.debug.print("Failed to allocate {d}-byte RGB frame\n", .{byte_count});
        return -1;
    };
    pipeline.rgb_buffer = @ptrCast(buffer);
    pipeline.rgb_linesize = width * 3;
    return 0;
}

fn uploadFrame(pipeline: *Pipeline, frame: *const c.AVFrame) c_int {
    if (configureRenderer(pipeline, frame) < 0) return -1;
    if (pipeline.texture_format == c.SDL_PIXELFORMAT_NV12) {
        if (c.SDL_UpdateNVTexture(
            pipeline.texture,
            null,
            frame.data[0],
            frame.linesize[0],
            frame.data[1],
            frame.linesize[1],
        ) == 0) return 0;
        std.debug.print("Direct NV12 upload disabled: {s}\n", .{std.mem.span(c.SDL_GetError())});
        pipeline.direct_nv12_available = false;
        destroyTexture(pipeline);
        if (configureRenderer(pipeline, frame) < 0) return -1;
    }
    var source = [4][*c]const u8{ frame.data[0], frame.data[1], frame.data[2], frame.data[3] };
    var destination = [4][*c]u8{ pipeline.rgb_buffer.?, null, null, null };
    var destination_linesize = [4]c_int{ pipeline.rgb_linesize, 0, 0, 0 };
    _ = c.sws_scale(
        pipeline.scaler,
        @ptrCast(&source),
        @ptrCast(&frame.linesize),
        0,
        frame.height,
        @ptrCast(&destination),
        &destination_linesize,
    );
    return c.SDL_UpdateTexture(
        pipeline.texture,
        null,
        pipeline.rgb_buffer,
        pipeline.rgb_linesize,
    );
}

pub export fn go_video_pipeline_create(config_pointer: ?*const c.GoVideoPipelineConfig) ?*Pipeline {
    const config = config_pointer orelse return null;
    if (config.renderer == null or config.max_width <= 0 or config.max_height <= 0 or
        config.max_width > 8192 or config.max_height > 8192 or
        config.decoder_preference < c.GO_VIDEO_DECODER_PREFERENCE_AUTO or
        config.decoder_preference > c.GO_VIDEO_DECODER_PREFERENCE_V4L2_REQUEST) return null;
    const pipeline = std.heap.c_allocator.create(Pipeline) catch return null;
    pipeline.* = .{
        .renderer = config.renderer.?,
        .max_width = config.max_width,
        .max_height = config.max_height,
    };
    errdefer _ = go_video_pipeline_destroy(pipeline);
    if (config.bootstrap_path != null) {
        const path = std.mem.span(config.bootstrap_path);
        if (path.len >= pipeline.bootstrap_path.len) return null;
        copyZ(&pipeline.bootstrap_path, path);
    }
    pipeline.depacketizer = c.go_h264_depacketizer_create(c.GO_VIDEO_PAYLOAD_TYPE);
    if (pipeline.depacketizer == null or loadBootstrap(pipeline) != 0) return null;
    pipeline.decoded_frame = c.av_frame_alloc();
    pipeline.display_frame = c.av_frame_alloc();
    pipeline.render_frame = c.av_frame_alloc();
    if (pipeline.decoded_frame == null or pipeline.display_frame == null or pipeline.render_frame == null)
        return null;
    if (selectDecoder(pipeline, config.decoder_preference) != 0) return null;
    return pipeline;
}

pub export fn go_video_pipeline_start(pipeline_pointer: ?*Pipeline) c_int {
    const pipeline = pipeline_pointer orelse return -1;
    if (pipeline.thread != null) return -1;
    pipeline.stop.store(false, .release);
    pipeline.accepting_packets.store(true, .release);
    pipeline.thread = std.Thread.spawn(.{}, worker, .{pipeline}) catch {
        pipeline.accepting_packets.store(false, .release);
        return -1;
    };
    return 0;
}

pub export fn go_video_pipeline_stop(pipeline_pointer: ?*Pipeline) void {
    const pipeline = pipeline_pointer orelse return;
    pipeline.accepting_packets.store(false, .release);
    const thread = pipeline.thread orelse return;
    pipeline.stop.store(true, .release);
    pipeline.packet_mutex.lock();
    pipeline.packet_condition.broadcast();
    pipeline.packet_mutex.unlock();
    thread.join();
    pipeline.thread = null;
    pipeline.packet_mutex.lock();
    pipeline.packet_queue_head = 0;
    pipeline.packet_queue_tail = 0;
    pipeline.packet_queue_count = 0;
    pipeline.packet_mutex.unlock();
}

pub export fn go_video_pipeline_push_rtp(
    pipeline_pointer: ?*Pipeline,
    packet_pointer: ?[*]const u8,
    length: usize,
) void {
    const pipeline = pipeline_pointer orelse return;
    const packet = packet_pointer orelse return;
    if (length < 12 or !pipeline.accepting_packets.load(.acquire)) return;
    if (length > packet_capacity) {
        _ = pipeline.dropped_packets.fetchAdd(1, .monotonic);
        pipeline.keyframe_pending.store(true, .release);
        pipeline.restart_epoch_pending.store(true, .release);
        return;
    }
    pipeline.packet_mutex.lock();
    defer pipeline.packet_mutex.unlock();
    if (pipeline.packet_queue_count == queue_capacity) {
        pipeline.packet_queue_head = (pipeline.packet_queue_head + 1) % queue_capacity;
        pipeline.packet_queue_count -= 1;
        _ = pipeline.dropped_packets.fetchAdd(1, .monotonic);
        pipeline.keyframe_pending.store(true, .release);
        pipeline.restart_epoch_pending.store(true, .release);
    }
    const target = &pipeline.packet_queue[pipeline.packet_queue_tail];
    target.length = @intCast(length);
    @memcpy(target.data[0..length], packet[0..length]);
    pipeline.packet_queue_tail = (pipeline.packet_queue_tail + 1) % queue_capacity;
    pipeline.packet_queue_count += 1;
    pipeline.packet_condition.signal();
}

pub export fn go_video_pipeline_render(pipeline_pointer: ?*Pipeline) void {
    const pipeline = pipeline_pointer orelse return;
    if (!pipeline.frame_ready.load(.acquire)) return;
    pipeline.frame_mutex.lock();
    if (pipeline.frame_ready.load(.acquire)) {
        c.av_frame_unref(pipeline.render_frame);
        c.av_frame_move_ref(pipeline.render_frame, pipeline.display_frame);
        pipeline.frame_ready.store(false, .release);
    }
    pipeline.frame_mutex.unlock();
    const frame = pipeline.render_frame orelse return;
    if (frame.data[0] == null or uploadFrame(pipeline, frame) < 0) {
        if (!pipeline.upload_error_reported) {
            std.debug.print("Frame upload failed: {s}\n", .{std.mem.span(c.SDL_GetError())});
            pipeline.upload_error_reported = true;
        }
        c.av_frame_unref(frame);
        return;
    }
    var output_width: c_int = 0;
    var output_height: c_int = 0;
    _ = c.SDL_GetRendererOutputSize(pipeline.renderer, &output_width, &output_height);
    var source = c.SDL_Rect{ .x = 0, .y = 0, .w = pipeline.texture_width, .h = pipeline.texture_height };
    var destination = c.SDL_Rect{ .x = 0, .y = 0, .w = output_width, .h = output_height };
    if (@as(i64, output_width) * source.h > @as(i64, output_height) * source.w) {
        destination.w = @divTrunc(output_height * source.w, source.h);
        destination.x = @divTrunc(output_width - destination.w, 2);
    } else {
        destination.h = @divTrunc(output_width * source.h, source.w);
        destination.y = @divTrunc(output_height - destination.h, 2);
    }
    _ = c.SDL_SetRenderDrawColor(pipeline.renderer, 0, 0, 0, 255);
    _ = c.SDL_RenderClear(pipeline.renderer);
    _ = c.SDL_RenderCopy(pipeline.renderer, pipeline.texture, &source, &destination);
    c.SDL_RenderPresent(pipeline.renderer);
    _ = pipeline.rendered_frames.fetchAdd(1, .monotonic);
    c.av_frame_unref(frame);
}

pub export fn go_video_pipeline_needs_keyframe(pipeline: ?*const Pipeline) c_int {
    const value = pipeline orelse return 0;
    return @intFromBool(!value.synced.load(.acquire) or value.keyframe_pending.load(.acquire));
}

pub export fn go_video_pipeline_has_media(pipeline: ?*const Pipeline) c_int {
    return @intFromBool(if (pipeline) |value| value.rtp_packets.load(.monotonic) > 0 else false);
}

pub export fn go_video_pipeline_failed(pipeline: ?*const Pipeline) c_int {
    return @intFromBool(if (pipeline) |value| value.failed.load(.acquire) else false);
}

pub export fn go_video_pipeline_note_keyframe_request(pipeline: ?*Pipeline) void {
    if (pipeline) |value| _ = value.keyframe_requests.fetchAdd(1, .monotonic);
}

pub export fn go_video_pipeline_stats(pipeline_pointer: ?*Pipeline) Stats {
    const pipeline = pipeline_pointer orelse return .{};
    var stats = Stats{
        .rtp_packets = pipeline.rtp_packets.load(.monotonic),
        .payload_packets = pipeline.payload_packets.load(.monotonic),
        .rejected_packets = pipeline.rejected_packets.load(.monotonic),
        .last_rejected_payload_type = pipeline.last_rejected_payload_type.load(.monotonic),
        .access_units = pipeline.access_units.load(.monotonic),
        .decoded_frames = pipeline.decoded_frames.load(.monotonic),
        .rendered_frames = pipeline.rendered_frames.load(.monotonic),
        .source_width = pipeline.source_width.load(.monotonic),
        .source_height = pipeline.source_height.load(.monotonic),
        .frame_nals = pipeline.frame_nals.load(.monotonic),
        .idr_nals = pipeline.idr_nals.load(.monotonic),
        .parameter_nals = pipeline.parameter_nals.load(.monotonic),
        .auxiliary_nals = pipeline.auxiliary_nals.load(.monotonic),
        .last_timestamp = pipeline.last_timestamp.load(.monotonic),
        .synced = @intFromBool(pipeline.synced.load(.acquire)),
        .discontinuities = pipeline.discontinuities.load(.monotonic),
        .missing_packets = pipeline.missing_packets.load(.monotonic),
        .late_packets = pipeline.late_packets.load(.monotonic),
        .decoder_send_errors = pipeline.decoder_send_errors.load(.monotonic),
        .decoder_receive_errors = pipeline.decoder_receive_errors.load(.monotonic),
        .last_decoder_error = pipeline.last_decoder_error.load(.monotonic),
        .decoder_backend = @intCast(pipeline.decoder_backend.load(.monotonic)),
        .decoder_init_failures = pipeline.decoder_init_failures.load(.monotonic),
        .decoder_runtime_fallbacks = pipeline.decoder_runtime_fallbacks.load(.monotonic),
        .decoder_backpressure_events = pipeline.decoder_backpressure_events.load(.monotonic),
        .decoder_corrupt_frames = pipeline.decoder_corrupt_frames.load(.monotonic),
        .decoder_info_changes = pipeline.decoder_info_changes.load(.monotonic),
        .keyframe_requests = pipeline.keyframe_requests.load(.monotonic),
        .dropped_packets = pipeline.dropped_packets.load(.monotonic),
    };
    pipeline.packet_mutex.lock();
    stats.pending_packets = @intCast(pipeline.packet_queue_count);
    pipeline.packet_mutex.unlock();
    return stats;
}

fn freeFrame(frame: *?*c.AVFrame) void {
    if (frame.* != null) c.av_frame_free(@ptrCast(frame));
}

pub export fn go_video_pipeline_destroy(pipeline_pointer: ?*Pipeline) c_int {
    const pipeline = pipeline_pointer orelse return 0;
    go_video_pipeline_stop(pipeline);
    const persist_result = persistBootstrap(pipeline);
    pipeline.frame_mutex.lock();
    pipeline.frame_ready.store(false, .release);
    if (pipeline.display_frame) |frame| c.av_frame_unref(frame);
    pipeline.frame_mutex.unlock();
    freeFrame(&pipeline.render_frame);
    freeFrame(&pipeline.display_frame);
    if (pipeline.scaler) |scaler| c.sws_freeContext(scaler);
    c.free(pipeline.rgb_buffer);
    destroyTexture(pipeline);
    c.go_video_decoder_selection_destroy(&pipeline.decoders);
    freeFrame(&pipeline.decoded_frame);
    c.go_h264_depacketizer_destroy(pipeline.depacketizer);
    std.heap.c_allocator.destroy(pipeline);
    return persist_result;
}
