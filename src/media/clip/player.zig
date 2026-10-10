const std = @import("std");
const media = @import("decoder.zig");
const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

const BufferedFrame = struct { frame: *media.c.AVFrame, pts: i64, duration: i64 };
const queue_capacity = 16;
const bytes_per_second = 48000 * 2 * @sizeOf(i16);

pub const Progress = struct {
    played_ms: u64,
    rendered_frames: u64,
    dropped_frames: u64,
    finished: bool,
};

pub const Player = struct {
    bytes: []const u8,
    device: c.SDL_AudioDeviceID,
    renderer: *c.SDL_Renderer,
    texture: ?*c.SDL_Texture = null,
    texture_width: c_int = 0,
    texture_height: c_int = 0,
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    total_samples: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    has_audio: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ended: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    queue: [queue_capacity]BufferedFrame = undefined,
    head: usize = 0,
    count: usize = 0,
    failure: ?anyerror = null,
    started_at: ?u64 = null,
    visible_end_ms: u64 = 0,
    rendered_frames: u64 = 0,
    dropped_frames: u64 = 0,
    paused_at: ?u64 = null,
    paused_ms: u64 = 0,
    previous_yuv_mode: c.SDL_YUV_CONVERSION_MODE = c.SDL_YUV_CONVERSION_AUTOMATIC,
    last_audio_position: u64 = 0,
    last_audio_progress_at: u64 = 0,
    last_position: u64 = 0,

    pub fn start(self: *Player) !void {
        if (self.thread != null) return error.AlreadyPlaying;
        self.previous_yuv_mode = c.SDL_GetYUVConversionMode();
        c.SDL_PauseAudioDevice(self.device, 1);
        c.SDL_ClearQueuedAudio(self.device);
        self.thread = try std.Thread.spawn(.{}, worker, .{self});
    }

    fn worker(self: *Player) void {
        self.decode() catch |err| {
            self.mutex.lock();
            self.failure = err;
            self.mutex.unlock();
        };
        self.ended.store(true, .release);
    }

    fn decode(self: *Player) !void {
        const decoder = try media.Decoder.open(self.bytes);
        defer decoder.destroy();
        self.has_audio.store(decoder.contexts[1] != null, .release);
        var pcm: [65536]i16 = undefined;
        while (!self.stop.load(.acquire)) {
            const event = try decoder.next() orelse {
                while (true) {
                    const samples = try decoder.finishAudio(&pcm);
                    if (samples.len == 0) return;
                    try self.queueAudio(samples);
                }
            };
            if (event.video) {
                const cloned = media.c.av_frame_clone(event.frame);
                if (cloned == null) return error.OutOfMemory;
                self.mutex.lock();
                while (self.count == queue_capacity and !self.stop.load(.acquire))
                    self.condition.wait(&self.mutex);
                if (self.stop.load(.acquire)) {
                    self.mutex.unlock();
                    var frame = cloned;
                    media.c.av_frame_free(&frame);
                    return;
                }
                const duration = media.c.av_rescale_q(event.frame.duration, decoder.format.*.streams[@intCast(decoder.streams[0])].*.time_base, .{ .num = 1, .den = 1000 });
                const rate = decoder.format.*.streams[@intCast(decoder.streams[0])].*.avg_frame_rate;
                const frame_duration = if (duration > 0) duration else if (rate.num > 0 and rate.den > 0)
                    media.c.av_rescale(1000, rate.den, rate.num)
                else
                    0;
                if (frame_duration <= 0 or frame_duration > 1000) {
                    self.mutex.unlock();
                    var frame = cloned;
                    media.c.av_frame_free(&frame);
                    return error.MissingFrameDuration;
                }
                self.queue[(self.head + self.count) % queue_capacity] = .{
                    .frame = cloned,
                    .pts = @max(0, event.timestamp_ms),
                    .duration = frame_duration,
                };
                self.count += 1;
                self.mutex.unlock();
            } else {
                const samples = try decoder.audio(event.frame, &pcm);
                try self.queueAudio(samples);
            }
        }
    }

    fn queueAudio(self: *Player, samples: []const i16) !void {
        while (c.SDL_GetQueuedAudioSize(self.device) >= bytes_per_second / 2) {
            if (self.stop.load(.acquire)) return error.Cancelled;
            std.Thread.sleep(2 * std.time.ns_per_ms);
        }
        if (self.stop.load(.acquire)) return error.Cancelled;
        if (c.SDL_QueueAudio(self.device, samples.ptr, @intCast(samples.len * @sizeOf(i16))) != 0)
            return error.AudioQueueFailed;
        _ = self.total_samples.fetchAdd(samples.len / 2, .release);
    }

    pub fn pause(self: *Player, paused: bool) void {
        if (self.started_at == null) return;
        const now = c.SDL_GetTicks64();
        if (paused and self.paused_at == null) {
            self.paused_at = now;
            c.SDL_PauseAudioDevice(self.device, 1);
        } else if (!paused and self.paused_at != null) {
            self.paused_ms += now - self.paused_at.?;
            self.paused_at = null;
            if (self.started_at != null) c.SDL_PauseAudioDevice(self.device, 0);
        }
    }

    fn playhead(self: *Player, now: u64) u64 {
        const start_time = self.started_at orelse return 0;
        if (!self.has_audio.load(.acquire)) return (self.paused_at orelse now) - start_time - self.paused_ms;
        const queued_samples = c.SDL_GetQueuedAudioSize(self.device) / (2 * @sizeOf(i16));
        const samples = self.total_samples.load(.acquire);
        const audio_position = (samples -| queued_samples) * 1000 / 48000;
        const effective_now = (self.paused_at orelse now) - self.paused_ms;
        if (audio_position > self.last_audio_position or self.last_audio_progress_at == 0) {
            self.last_audio_position = audio_position;
            self.last_audio_progress_at = effective_now;
        }
        const position = audio_position + if (queued_samples == 0) effective_now - self.last_audio_progress_at else 0;
        self.last_position = @max(self.last_position, position);
        return self.last_position;
    }

    fn render(self: *Player, frame: *const media.c.AVFrame) !void {
        if (frame.width <= 0 or frame.height <= 0 or frame.width > 1280 or frame.height > 768)
            return error.InvalidFrame;
        if (frame.format != media.c.AV_PIX_FMT_YUV420P and frame.format != media.c.AV_PIX_FMT_YUVJ420P)
            return error.UnsupportedPixelFormat;
        if (self.texture == null or self.texture_width != frame.width or self.texture_height != frame.height) {
            if (self.texture) |texture| c.SDL_DestroyTexture(texture);
            self.texture = c.SDL_CreateTexture(self.renderer, c.SDL_PIXELFORMAT_IYUV, c.SDL_TEXTUREACCESS_STREAMING, frame.width, frame.height);
            if (self.texture == null) return error.TextureUnavailable;
            self.texture_width = frame.width;
            self.texture_height = frame.height;
        }
        c.SDL_SetYUVConversionMode(if (frame.color_range == media.c.AVCOL_RANGE_JPEG)
            c.SDL_YUV_CONVERSION_JPEG
        else if (frame.colorspace == media.c.AVCOL_SPC_BT709)
            c.SDL_YUV_CONVERSION_BT709
        else
            c.SDL_YUV_CONVERSION_BT601);
        if (c.SDL_UpdateYUVTexture(self.texture, null, frame.data[0], frame.linesize[0], frame.data[1], frame.linesize[1], frame.data[2], frame.linesize[2]) != 0)
            return error.TextureUpdateFailed;
    }

    pub fn draw(self: *Player) !void {
        if (self.texture == null) return;
        var width: c_int = undefined;
        var height: c_int = undefined;
        const size = try canvasSize(self.renderer);
        width = size.width;
        height = size.height;
        const scale = @min(@as(f64, @floatFromInt(width)) / @as(f64, @floatFromInt(self.texture_width)), @as(f64, @floatFromInt(height)) / @as(f64, @floatFromInt(self.texture_height)));
        const scaled_width: c_int = @intFromFloat(@as(f64, @floatFromInt(self.texture_width)) * scale);
        const scaled_height: c_int = @intFromFloat(@as(f64, @floatFromInt(self.texture_height)) * scale);
        const destination = c.SDL_Rect{ .x = @divTrunc(width - scaled_width, 2), .y = @divTrunc(height - scaled_height, 2), .w = scaled_width, .h = scaled_height };
        _ = c.SDL_SetRenderDrawColor(self.renderer, 0, 0, 0, 255);
        _ = c.SDL_RenderClear(self.renderer);
        if (c.SDL_RenderCopy(self.renderer, self.texture, null, &destination) != 0) return error.RenderFailed;
    }

    pub fn tick(self: *Player) !Progress {
        const now = c.SDL_GetTicks64();
        self.mutex.lock();
        const failure = self.failure;
        const available = self.count;
        self.mutex.unlock();
        if (failure) |err| return err;
        if (self.paused_at == null and self.started_at == null and available > 0 and
            (!self.has_audio.load(.acquire) or c.SDL_GetQueuedAudioSize(self.device) >= bytes_per_second / 5 or self.ended.load(.acquire)))
        {
            self.started_at = now;
            c.SDL_PauseAudioDevice(self.device, 0);
        }
        if (self.started_at == null) return .{ .played_ms = 0, .rendered_frames = 0, .dropped_frames = 0, .finished = false };
        const position = self.playhead(now);
        while (self.paused_at == null) {
            self.mutex.lock();
            if (self.count == 0 or self.queue[self.head].pts > position) {
                self.mutex.unlock();
                break;
            }
            const next = self.queue[self.head];
            self.head = (self.head + 1) % queue_capacity;
            self.count -= 1;
            const empty = self.count == 0;
            self.condition.signal();
            self.mutex.unlock();
            var owned: [*c]media.c.AVFrame = next.frame;
            defer media.c.av_frame_free(&owned);
            if (position > @as(u64, @intCast(next.pts)) + 80 and !empty) {
                self.dropped_frames += 1;
                continue;
            }
            try self.render(next.frame);
            self.rendered_frames += 1;
            self.visible_end_ms = @intCast(next.pts + next.duration);
        }
        self.mutex.lock();
        const drained = self.count == 0;
        self.mutex.unlock();
        const complete = self.ended.load(.acquire) and drained and
            c.SDL_GetQueuedAudioSize(self.device) == 0 and position + 2 >= self.visible_end_ms and self.rendered_frames > 0;
        return .{ .played_ms = @min(position, self.visible_end_ms), .rendered_frames = self.rendered_frames, .dropped_frames = self.dropped_frames, .finished = complete };
    }

    pub fn deinit(self: *Player) void {
        self.stop.store(true, .release);
        self.mutex.lock();
        self.condition.broadcast();
        self.mutex.unlock();
        if (self.thread) |thread| thread.join();
        self.thread = null;
        while (self.count > 0) {
            var frame: [*c]media.c.AVFrame = self.queue[self.head].frame;
            media.c.av_frame_free(&frame);
            self.head = (self.head + 1) % queue_capacity;
            self.count -= 1;
        }
        c.SDL_ClearQueuedAudio(self.device);
        c.SDL_SetYUVConversionMode(self.previous_yuv_mode);
        c.SDL_PauseAudioDevice(self.device, 0);
        if (self.texture) |texture| c.SDL_DestroyTexture(texture);
        self.texture = null;
    }
};

pub fn canvasSize(renderer: *c.SDL_Renderer) !struct { width: c_int, height: c_int } {
    var width: c_int = 0;
    var height: c_int = 0;
    c.SDL_RenderGetLogicalSize(renderer, &width, &height);
    if ((width == 0 or height == 0) and c.SDL_GetRendererOutputSize(renderer, &width, &height) != 0)
        return error.RendererUnavailable;
    if (width <= 0 or height <= 0) return error.RendererUnavailable;
    return .{ .width = width, .height = height };
}
