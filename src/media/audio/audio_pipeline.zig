const std = @import("std");
const rtp = @import("rtp_packet");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("opus/opus.h");
});

const payload_type = 111;
const queue_capacity = 32;
const target_pending_packets = 2;
const packet_capacity = 2048;
const max_samples = 5760 * 2;
const target_max_bytes = 48000 * 2 * 2 * 40 / 1000;
const hard_reset_bytes = 48000 * 2 * 2 * 120 / 1000;

const AudioPacket = struct {
    length: u16 = 0,
    data: [packet_capacity]u8 = undefined,
};

const Pipeline = struct {
    device: c.SDL_AudioDeviceID,
    decoder: *c.OpusDecoder,
    queue: [queue_capacity]AudioPacket = undefined,
    queue_head: usize = 0,
    queue_tail: usize = 0,
    queue_count: usize = 0,
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    accepting_packets: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    rtp_packets: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    decoded_packets: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    dropped_packets: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    late_packets: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
    queue_resets: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0),
};

pub const Stats = extern struct {
    rtp_packets: c_int = 0,
    decoded_packets: c_int = 0,
    dropped_packets: c_int = 0,
    late_packets: c_int = 0,
    pending_packets: c_int = 0,
    queue_resets: c_int = 0,
    queued_milliseconds: c_uint = 0,
};

fn worker(pipeline: *Pipeline) void {
    while (!pipeline.stop.load(.acquire)) {
        pipeline.mutex.lock();
        while (pipeline.queue_count == 0 and !pipeline.stop.load(.acquire))
            pipeline.condition.wait(&pipeline.mutex);
        if (pipeline.stop.load(.acquire)) {
            pipeline.mutex.unlock();
            break;
        }
        while (pipeline.queue_count > target_pending_packets) {
            pipeline.queue_head = (pipeline.queue_head + 1) % queue_capacity;
            pipeline.queue_count -= 1;
            _ = pipeline.late_packets.fetchAdd(1, .monotonic);
        }
        const packet = pipeline.queue[pipeline.queue_head];
        pipeline.queue_head = (pipeline.queue_head + 1) % queue_capacity;
        pipeline.queue_count -= 1;
        pipeline.mutex.unlock();

        var pcm: [max_samples]c_short = undefined;
        const samples_per_channel = c.opus_decode(
            pipeline.decoder,
            &packet.data,
            packet.length,
            &pcm,
            max_samples / 2,
            0,
        );
        if (samples_per_channel <= 0) {
            _ = pipeline.dropped_packets.fetchAdd(1, .monotonic);
            continue;
        }
        const samples = samples_per_channel * 2;
        const output_bytes: c.Uint32 = @intCast(@as(usize, @intCast(samples)) * @sizeOf(c_short));
        while (!pipeline.stop.load(.acquire)) {
            const queued = c.SDL_GetQueuedAudioSize(pipeline.device);
            if (queued > hard_reset_bytes) {
                c.SDL_ClearQueuedAudio(pipeline.device);
                _ = pipeline.queue_resets.fetchAdd(1, .monotonic);
                break;
            }
            const pending_bytes = @as(u64, queued) + @as(u64, output_bytes);
            if (queued == 0 or pending_bytes <= target_max_bytes) break;
            c.SDL_Delay(2);
        }
        if (pipeline.stop.load(.acquire)) break;
        if (c.SDL_QueueAudio(pipeline.device, &pcm, output_bytes) == 0)
            _ = pipeline.decoded_packets.fetchAdd(1, .monotonic)
        else
            _ = pipeline.dropped_packets.fetchAdd(1, .monotonic);
    }
}

pub export fn go_audio_pipeline_create(device: c.SDL_AudioDeviceID) ?*Pipeline {
    if (device == 0) return null;
    var opus_error: c_int = 0;
    const decoder = c.opus_decoder_create(48000, 2, &opus_error) orelse return null;
    if (opus_error != c.OPUS_OK) {
        c.opus_decoder_destroy(decoder);
        return null;
    }
    errdefer c.opus_decoder_destroy(decoder);
    const pipeline = std.heap.c_allocator.create(Pipeline) catch return null;
    pipeline.* = .{ .device = device, .decoder = decoder };
    return pipeline;
}

pub export fn go_audio_pipeline_start(pipeline_pointer: ?*Pipeline) c_int {
    const pipeline = pipeline_pointer orelse return -1;
    if (pipeline.thread != null) return -1;
    c.SDL_ClearQueuedAudio(pipeline.device);
    pipeline.stop.store(false, .release);
    pipeline.accepting_packets.store(true, .release);
    pipeline.thread = std.Thread.spawn(.{}, worker, .{pipeline}) catch {
        pipeline.accepting_packets.store(false, .release);
        return -1;
    };
    c.SDL_PauseAudioDevice(pipeline.device, 0);
    return 0;
}

pub export fn go_audio_pipeline_stop(pipeline_pointer: ?*Pipeline) void {
    const pipeline = pipeline_pointer orelse return;
    pipeline.accepting_packets.store(false, .release);
    if (pipeline.thread) |thread| {
        pipeline.stop.store(true, .release);
        pipeline.mutex.lock();
        pipeline.condition.broadcast();
        pipeline.mutex.unlock();
        thread.join();
        pipeline.thread = null;
    }
    c.SDL_PauseAudioDevice(pipeline.device, 1);
    c.SDL_ClearQueuedAudio(pipeline.device);
    pipeline.mutex.lock();
    pipeline.queue_head = 0;
    pipeline.queue_tail = 0;
    pipeline.queue_count = 0;
    pipeline.mutex.unlock();
}

pub export fn go_audio_pipeline_push_rtp(
    pipeline_pointer: ?*Pipeline,
    packet_pointer: ?[*]const u8,
    length: usize,
) void {
    const pipeline = pipeline_pointer orelse return;
    const packet = packet_pointer orelse return;
    if (!pipeline.accepting_packets.load(.acquire)) return;
    const parsed = rtp.parse(packet[0..length]) catch return;
    if (parsed.header.payload_type != payload_type or parsed.payload.len == 0) return;
    _ = pipeline.rtp_packets.fetchAdd(1, .monotonic);
    if (parsed.payload.len > packet_capacity) {
        _ = pipeline.dropped_packets.fetchAdd(1, .monotonic);
        return;
    }

    pipeline.mutex.lock();
    defer pipeline.mutex.unlock();
    if (!pipeline.accepting_packets.load(.acquire)) return;
    if (pipeline.queue_count == queue_capacity) {
        _ = pipeline.dropped_packets.fetchAdd(1, .monotonic);
        return;
    }
    const target = &pipeline.queue[pipeline.queue_tail];
    target.length = @intCast(parsed.payload.len);
    @memcpy(target.data[0..parsed.payload.len], parsed.payload);
    pipeline.queue_tail = (pipeline.queue_tail + 1) % queue_capacity;
    pipeline.queue_count += 1;
    pipeline.condition.signal();
}

pub export fn go_audio_pipeline_stats(pipeline_pointer: ?*Pipeline) Stats {
    const pipeline = pipeline_pointer orelse return .{};
    var stats = Stats{
        .rtp_packets = pipeline.rtp_packets.load(.monotonic),
        .decoded_packets = pipeline.decoded_packets.load(.monotonic),
        .dropped_packets = pipeline.dropped_packets.load(.monotonic),
        .late_packets = pipeline.late_packets.load(.monotonic),
        .queue_resets = pipeline.queue_resets.load(.monotonic),
    };
    pipeline.mutex.lock();
    stats.pending_packets = @intCast(pipeline.queue_count);
    pipeline.mutex.unlock();
    stats.queued_milliseconds = c.SDL_GetQueuedAudioSize(pipeline.device) * 1000 /
        (48000 * 2 * @sizeOf(c_short));
    return stats;
}

pub export fn go_audio_pipeline_destroy(pipeline_pointer: ?*Pipeline) void {
    const pipeline = pipeline_pointer orelse return;
    go_audio_pipeline_stop(pipeline);
    c.opus_decoder_destroy(pipeline.decoder);
    std.heap.c_allocator.destroy(pipeline);
}
