const std = @import("std");

const c = @cImport({
    @cInclude("video_decoder.h");
});

const none_name: [*:0]const u8 = "none";
const unavailable_error: [*:0]const u8 = "video decoder unavailable";

pub export fn go_video_decoder_initialize(
    decoder: ?*c.GoVideoDecoder,
    ops: ?*const c.GoVideoDecoderOps,
) void {
    if (decoder) |value| value.ops = ops;
}

pub export fn go_video_decoder_preference_parse(
    value: ?[*:0]const u8,
    preference: ?*c.GoVideoDecoderPreference,
) c_int {
    const output = preference orelse return -1;
    const name = if (value) |text| std.mem.span(text) else "";
    output.* = if (name.len == 0 or std.mem.eql(u8, name, "auto"))
        c.GO_VIDEO_DECODER_PREFERENCE_AUTO
    else if (std.mem.eql(u8, name, "mpp"))
        c.GO_VIDEO_DECODER_PREFERENCE_MPP
    else if (std.mem.eql(u8, name, "cedar"))
        c.GO_VIDEO_DECODER_PREFERENCE_CEDAR
    else if (std.mem.eql(u8, name, "software"))
        c.GO_VIDEO_DECODER_PREFERENCE_SOFTWARE
    else
        return -1;
    return 0;
}

pub export fn go_video_decoder_platform(
    compatible: ?[*]const u8,
    length: usize,
    is_arm: c_int,
) c.GoVideoPlatform {
    if (is_arm == 0) return c.GO_VIDEO_PLATFORM_NON_ARM;
    const bytes = if (compatible) |data| data[0..length] else return c.GO_VIDEO_PLATFORM_OTHER_ARM;

    var offset: usize = 0;
    while (offset < bytes.len) {
        const remainder = bytes[offset..];
        const token_length = std.mem.indexOfScalar(u8, remainder, 0) orelse remainder.len;
        const token = remainder[0..token_length];
        if (std.mem.startsWith(u8, token, "rockchip,")) return c.GO_VIDEO_PLATFORM_ROCKCHIP;
        if (std.mem.startsWith(u8, token, "allwinner,")) return c.GO_VIDEO_PLATFORM_ALLWINNER;
        offset += token_length;
        if (offset < bytes.len) offset += 1;
    }
    return c.GO_VIDEO_PLATFORM_OTHER_ARM;
}

pub export fn go_video_decoder_candidate_order(
    preference: c.GoVideoDecoderPreference,
    platform: c.GoVideoPlatform,
    output: ?[*]c.GoVideoDecoderBackend,
    capacity: usize,
) usize {
    var candidates: [3]c.GoVideoDecoderBackend = undefined;
    var count: usize = 0;

    if (preference == c.GO_VIDEO_DECODER_PREFERENCE_MPP) {
        candidates[count] = c.GO_VIDEO_DECODER_BACKEND_MPP;
        count += 1;
    } else if (preference == c.GO_VIDEO_DECODER_PREFERENCE_CEDAR) {
        candidates[count] = c.GO_VIDEO_DECODER_BACKEND_CEDAR;
        count += 1;
    } else if (preference == c.GO_VIDEO_DECODER_PREFERENCE_SOFTWARE) {
        candidates[count] = c.GO_VIDEO_DECODER_BACKEND_SOFTWARE;
        count += 1;
    } else if (platform == c.GO_VIDEO_PLATFORM_ROCKCHIP) {
        candidates[count] = c.GO_VIDEO_DECODER_BACKEND_MPP;
        count += 1;
        candidates[count] = c.GO_VIDEO_DECODER_BACKEND_SOFTWARE;
        count += 1;
    } else if (platform == c.GO_VIDEO_PLATFORM_ALLWINNER) {
        candidates[count] = c.GO_VIDEO_DECODER_BACKEND_CEDAR;
        count += 1;
        candidates[count] = c.GO_VIDEO_DECODER_BACKEND_SOFTWARE;
        count += 1;
    } else if (platform == c.GO_VIDEO_PLATFORM_NON_ARM) {
        candidates[count] = c.GO_VIDEO_DECODER_BACKEND_SOFTWARE;
        count += 1;
    } else {
        candidates[count] = c.GO_VIDEO_DECODER_BACKEND_MPP;
        count += 1;
        candidates[count] = c.GO_VIDEO_DECODER_BACKEND_CEDAR;
        count += 1;
        candidates[count] = c.GO_VIDEO_DECODER_BACKEND_SOFTWARE;
        count += 1;
    }

    if (output) |destination| {
        const written = @min(count, capacity);
        @memcpy(destination[0..written], candidates[0..written]);
    }
    return count;
}

pub export fn go_video_decoder_name(decoder: ?*const c.GoVideoDecoder) [*:0]const u8 {
    const value = decoder orelse return none_name;
    const ops = value.ops orelse return none_name;
    return ops.*.name orelse none_name;
}

pub export fn go_video_decoder_backend(decoder: ?*const c.GoVideoDecoder) c.GoVideoDecoderBackend {
    const value = decoder orelse return c.GO_VIDEO_DECODER_BACKEND_NONE;
    const ops = value.ops orelse return c.GO_VIDEO_DECODER_BACKEND_NONE;
    return ops.*.backend;
}

pub export fn go_video_decoder_submit_access_unit(
    decoder: ?*c.GoVideoDecoder,
    data: ?[*]const u8,
    length: usize,
) c.GoVideoDecoderResult {
    const value = decoder orelse return c.GO_VIDEO_DECODER_RESULT_FATAL;
    const ops = value.ops orelse return c.GO_VIDEO_DECODER_RESULT_FATAL;
    const submit = ops.*.submit_access_unit orelse return c.GO_VIDEO_DECODER_RESULT_FATAL;
    const bytes = data orelse return c.GO_VIDEO_DECODER_RESULT_FATAL;
    if (length == 0) return c.GO_VIDEO_DECODER_RESULT_FATAL;
    return submit(value, bytes, length);
}

pub export fn go_video_decoder_receive_frame(
    decoder: ?*c.GoVideoDecoder,
    frame: ?*c.GoDecodedVideoFrame,
) c.GoVideoDecoderResult {
    const value = decoder orelse return c.GO_VIDEO_DECODER_RESULT_FATAL;
    const ops = value.ops orelse return c.GO_VIDEO_DECODER_RESULT_FATAL;
    const receive = ops.*.receive_frame orelse return c.GO_VIDEO_DECODER_RESULT_FATAL;
    const output = frame orelse return c.GO_VIDEO_DECODER_RESULT_FATAL;
    output.* = std.mem.zeroes(c.GoDecodedVideoFrame);
    return receive(value, output);
}

pub export fn go_video_decoder_release_frame(
    decoder: ?*c.GoVideoDecoder,
    frame: ?*c.GoDecodedVideoFrame,
) void {
    const value = decoder orelse return;
    const ops = value.ops orelse return;
    const release = ops.*.release_frame orelse return;
    const output = frame orelse return;
    release(value, output);
    output.* = std.mem.zeroes(c.GoDecodedVideoFrame);
}

pub export fn go_video_decoder_reset(decoder: ?*c.GoVideoDecoder) c_int {
    const value = decoder orelse return -1;
    const ops = value.ops orelse return -1;
    const reset = ops.*.reset orelse return -1;
    return reset(value);
}

pub export fn go_video_decoder_last_error(
    decoder: ?*const c.GoVideoDecoder,
) [*:0]const u8 {
    const value = decoder orelse return unavailable_error;
    const ops = value.ops orelse return unavailable_error;
    const last_error = ops.*.last_error orelse return unavailable_error;
    return last_error(value) orelse unavailable_error;
}

pub export fn go_video_decoder_destroy(decoder: ?*c.GoVideoDecoder) void {
    const value = decoder orelse return;
    const ops = value.ops orelse return;
    const destroy = ops.*.destroy orelse return;
    destroy(value);
}
