const std = @import("std");
pub const c = @cImport({
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavformat/avformat.h");
    @cInclude("libavutil/error.h");
    @cInclude("libswresample/swresample.h");
});

const sample_rate = 48000;

const Input = struct {
    bytes: []const u8,
    position: usize = 0,

    fn read(pointer: ?*anyopaque, output: [*c]u8, capacity: c_int) callconv(.c) c_int {
        const self: *Input = @ptrCast(@alignCast(pointer.?));
        if (capacity <= 0) return c.AVERROR(c.EINVAL);
        if (self.position == self.bytes.len) return c.AVERROR_EOF;
        const count = @min(@as(usize, @intCast(capacity)), self.bytes.len - self.position);
        @memcpy(output[0..count], self.bytes[self.position..][0..count]);
        self.position += count;
        return @intCast(count);
    }

    fn seek(pointer: ?*anyopaque, offset: i64, origin: c_int) callconv(.c) i64 {
        const self: *Input = @ptrCast(@alignCast(pointer.?));
        if (origin == c.AVSEEK_SIZE) return @intCast(self.bytes.len);
        const base: i64 = switch (origin & ~@as(c_int, c.AVSEEK_FORCE)) {
            c.SEEK_SET => 0,
            c.SEEK_CUR => @intCast(self.position),
            c.SEEK_END => @intCast(self.bytes.len),
            else => return -1,
        };
        const next = std.math.add(i64, base, offset) catch return -1;
        if (next < 0 or next > self.bytes.len) return -1;
        self.position = @intCast(next);
        return next;
    }
};

pub const Frame = struct {
    video: bool,
    timestamp_ms: i64,
    frame: *c.AVFrame,
};

pub const Decoder = struct {
    input: Input,
    io: [*c]c.AVIOContext = null,
    format: [*c]c.AVFormatContext = null,
    contexts: [2][*c]c.AVCodecContext = .{ null, null },
    streams: [2]c_int = .{ -1, -1 },
    packet: [*c]c.AVPacket = null,
    frame: [*c]c.AVFrame = null,
    receiving: ?usize = null,
    input_ended: bool = false,
    flush_index: usize = 0,
    resampler: ?*c.SwrContext = null,
    start_ms: i64 = 0,

    pub fn open(bytes: []const u8) !*Decoder {
        if (bytes.len == 0 or bytes.len > 96 * 1024 * 1024) return error.InvalidMediaSize;
        const self = try std.heap.c_allocator.create(Decoder);
        self.* = .{ .input = .{ .bytes = bytes } };
        errdefer self.destroy();
        const buffer: [*c]u8 = @ptrCast(c.av_malloc(32768));
        if (buffer == null) return error.OutOfMemory;
        self.io = c.avio_alloc_context(buffer, 32768, 0, &self.input, Input.read, null, Input.seek);
        if (self.io == null) {
            c.av_free(buffer);
            return error.OutOfMemory;
        }
        self.format = c.avformat_alloc_context();
        if (self.format == null) return error.OutOfMemory;
        self.format.*.pb = self.io;
        self.format.*.flags |= c.AVFMT_FLAG_CUSTOM_IO;
        self.format.*.probesize = 1024 * 1024;
        self.format.*.max_analyze_duration = 3 * c.AV_TIME_BASE;
        const input_format = c.av_find_input_format("mov");
        if (input_format == null) return error.Mp4Unavailable;
        if (c.avformat_open_input(&self.format, null, input_format, null) < 0 or
            c.avformat_find_stream_info(self.format, null) < 0) return error.InvalidMp4;
        if (self.format.*.duration > 120 * c.AV_TIME_BASE) return error.AdMediaTooLong;
        if (self.format.*.start_time != c.AV_NOPTS_VALUE)
            self.start_ms = @divTrunc(self.format.*.start_time, 1000);
        if (self.format.*.nb_streams > 8) return error.TooManyStreams;
        for ([_]c.AVMediaType{ c.AVMEDIA_TYPE_VIDEO, c.AVMEDIA_TYPE_AUDIO }, 0..) |kind, index| {
            const stream_index = c.av_find_best_stream(self.format, kind, -1, -1, null, 0);
            if (stream_index < 0) {
                if (index == 0) return error.MissingVideo;
                continue;
            }
            const parameters = self.format.*.streams[@intCast(stream_index)].*.codecpar;
            if (parameters.*.codec_id != (if (index == 0) c.AV_CODEC_ID_H264 else c.AV_CODEC_ID_AAC))
                return error.UnsupportedCodec;
            if (index == 0 and (parameters.*.width <= 0 or parameters.*.height <= 0 or
                parameters.*.width > 1280 or parameters.*.height > 768)) return error.UnsupportedDimensions;
            if (index == 1 and (parameters.*.sample_rate <= 0 or parameters.*.sample_rate > 96000 or
                parameters.*.ch_layout.nb_channels <= 0 or parameters.*.ch_layout.nb_channels > 8))
                return error.UnsupportedAudio;
            const codec = c.avcodec_find_decoder(parameters.*.codec_id);
            if (codec == null) return error.CodecUnavailable;
            const context = c.avcodec_alloc_context3(codec);
            if (context == null) return error.OutOfMemory;
            self.contexts[index] = context;
            self.streams[index] = stream_index;
            context.*.thread_count = 3;
            context.*.max_pixels = 1280 * 768;
            if (c.avcodec_parameters_to_context(context, parameters) < 0 or
                c.avcodec_open2(context, codec, null) < 0) return error.DecoderUnavailable;
        }
        self.packet = c.av_packet_alloc();
        self.frame = c.av_frame_alloc();
        if (self.packet == null or self.frame == null) return error.OutOfMemory;
        return self;
    }

    pub fn next(self: *Decoder) !?Frame {
        for (0..4096) |_| {
            if (self.receiving) |index| {
                c.av_frame_unref(self.frame);
                const result = c.avcodec_receive_frame(self.contexts[index], self.frame);
                if (result == 0) {
                    const time_base = self.format.*.streams[@intCast(self.streams[index])].*.time_base;
                    const pts = self.frame.*.best_effort_timestamp;
                    if (pts == c.AV_NOPTS_VALUE) return error.MissingTimestamp;
                    const timestamp_ms = std.math.sub(i64, c.av_rescale_q(pts, time_base, .{ .num = 1, .den = 1000 }), self.start_ms) catch return error.InvalidMediaTimestamp;
                    if (timestamp_ms < -1000 or timestamp_ms > 120000) return error.InvalidMediaTimestamp;
                    return .{ .video = index == 0, .frame = self.frame, .timestamp_ms = timestamp_ms };
                }
                if (result != c.AVERROR(c.EAGAIN) and result != c.AVERROR_EOF) return error.DecodeFailed;
                self.receiving = null;
            }
            if (self.input_ended) {
                if (self.flush_index == 2) return null;
                const index = self.flush_index;
                self.flush_index += 1;
                if (self.contexts[index] == null) continue;
                if (c.avcodec_send_packet(self.contexts[index], null) < 0) return error.DecodeFailed;
                self.receiving = index;
                continue;
            }
            const result = c.av_read_frame(self.format, self.packet);
            if (result == c.AVERROR_EOF) {
                self.input_ended = true;
                continue;
            }
            if (result < 0) return error.DemuxFailed;
            defer c.av_packet_unref(self.packet);
            for (self.streams, 0..) |stream, index| {
                if (self.packet.*.stream_index != stream) continue;
                if (c.avcodec_send_packet(self.contexts[index], self.packet) < 0) return error.DecodeFailed;
                self.receiving = index;
                break;
            }
        }
        return error.NonProgressingMedia;
    }

    pub fn audio(self: *Decoder, frame: *const c.AVFrame, output: []i16) ![]i16 {
        if (frame.sample_rate <= 0 or frame.sample_rate > 96000 or frame.ch_layout.nb_channels <= 0 or
            frame.ch_layout.nb_channels > 8 or frame.nb_samples < 0) return error.UnsupportedAudio;
        if (self.resampler == null) {
            var stereo: c.AVChannelLayout = undefined;
            c.av_channel_layout_default(&stereo, 2);
            defer c.av_channel_layout_uninit(&stereo);
            if (c.swr_alloc_set_opts2(&self.resampler, &stereo, c.AV_SAMPLE_FMT_S16, sample_rate, &frame.ch_layout, @intCast(frame.format), frame.sample_rate, 0, null) < 0 or
                c.swr_init(self.resampler) < 0) return error.ResamplerUnavailable;
        }
        const required = c.swr_get_out_samples(self.resampler, frame.nb_samples);
        if (required < 0 or required > output.len / 2) return error.AudioLimitExceeded;
        var destination = [_][*c]u8{@ptrCast(output.ptr)};
        const count = c.swr_convert(self.resampler, &destination, @intCast(output.len / 2), @ptrCast(frame.extended_data), frame.nb_samples);
        if (count < 0) return error.ResampleFailed;
        return output[0 .. @as(usize, @intCast(count)) * 2];
    }

    pub fn finishAudio(self: *Decoder, output: []i16) ![]i16 {
        if (self.resampler == null) return output[0..0];
        var destination = [_][*c]u8{@ptrCast(output.ptr)};
        const count = c.swr_convert(self.resampler, &destination, @intCast(output.len / 2), null, 0);
        if (count < 0) return error.ResampleFailed;
        return output[0 .. @as(usize, @intCast(count)) * 2];
    }

    pub fn destroy(self: *Decoder) void {
        c.swr_free(&self.resampler);
        c.av_frame_free(&self.frame);
        c.av_packet_free(&self.packet);
        for (&self.contexts) |*context| c.avcodec_free_context(context);
        c.avformat_close_input(&self.format);
        if (self.io != null) c.av_freep(@ptrCast(&self.io.*.buffer));
        c.avio_context_free(&self.io);
        std.heap.c_allocator.destroy(self);
    }
};
