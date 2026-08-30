const std = @import("std");

const c = @cImport({
    @cInclude("cedar_loader.h");
    @cInclude("video_decoder.h");
});

const Decoder = struct {
    base: c.GoVideoDecoder = .{ .ops = null },
    library: ?*c.GoCedarLibrary = null,
    pending_frame: c.GoCedarFrame = std.mem.zeroes(c.GoCedarFrame),
    max_width: c_int,
    max_height: c_int,
    frame_pending: bool = false,
    frame_outstanding: bool = false,
    last_width: c_int = 0,
    last_height: c_int = 0,
    last_y_stride: c_int = 0,
    last_uv_stride: c_int = 0,
    error_message: [256]u8 = [_]u8{0} ** 256,
};

fn fromBase(base: *c.GoVideoDecoder) *Decoder {
    return @fieldParentPtr("base", base);
}

fn fromConstBase(base: *const c.GoVideoDecoder) *const Decoder {
    return @fieldParentPtr("base", base);
}

fn copyZ(destination: []u8, message: []const u8) void {
    @memset(destination, 0);
    const length = @min(destination.len - 1, message.len);
    @memcpy(destination[0..length], message[0..length]);
}

fn writeError(destination: [*c]u8, capacity: usize, message: []const u8) void {
    if (destination == null or capacity == 0) return;
    const length = @min(capacity - 1, message.len);
    @memcpy(destination[0..length], message[0..length]);
    destination[length] = 0;
}

fn openCedar(decoder: *Decoder) c_int {
    decoder.library = c.go_cedar_library_open(decoder.max_width, decoder.max_height);
    if (c.go_cedar_library_ready(decoder.library) == 0) {
        copyZ(&decoder.error_message, std.mem.span(c.go_cedar_library_error(decoder.library)));
        c.go_cedar_library_close(decoder.library);
        decoder.library = null;
        return -1;
    }
    decoder.error_message[0] = 0;
    return 0;
}

fn cedarSubmit(
    base: ?*c.GoVideoDecoder,
    data: [*c]const u8,
    length: usize,
) callconv(.c) c.GoVideoDecoderResult {
    const decoder = fromBase(base orelse return c.GO_VIDEO_DECODER_RESULT_FATAL);
    if (decoder.frame_pending or decoder.frame_outstanding)
        return c.GO_VIDEO_DECODER_RESULT_AGAIN;
    const result = c.go_cedar_library_feed(decoder.library, data, length, &decoder.pending_frame);
    if (result < 0) {
        copyZ(&decoder.error_message, std.mem.span(c.go_cedar_library_error(decoder.library)));
        return c.GO_VIDEO_DECODER_RESULT_FATAL;
    }
    decoder.frame_pending = result > 0;
    return c.GO_VIDEO_DECODER_RESULT_OK;
}

fn cedarReceive(
    base: ?*c.GoVideoDecoder,
    output_pointer: ?*c.GoDecodedVideoFrame,
) callconv(.c) c.GoVideoDecoderResult {
    const decoder = fromBase(base orelse return c.GO_VIDEO_DECODER_RESULT_FATAL);
    const output = output_pointer orelse return c.GO_VIDEO_DECODER_RESULT_FATAL;
    if (!decoder.frame_pending) return c.GO_VIDEO_DECODER_RESULT_AGAIN;
    const frame = &decoder.pending_frame;
    output.format = c.GO_VIDEO_PIXEL_FORMAT_NV12;
    output.color_range = c.GO_VIDEO_COLOR_RANGE_LIMITED;
    output.width = frame.width;
    output.height = frame.height;
    output.coded_width = frame.width;
    output.coded_height = frame.height;
    output.planes[0] = frame.y;
    output.planes[1] = frame.uv;
    output.strides[0] = frame.y_stride;
    output.strides[1] = frame.uv_stride;
    output.info_changed = @intFromBool(
        decoder.last_width != output.width or decoder.last_height != output.height or
            decoder.last_y_stride != output.strides[0] or
            decoder.last_uv_stride != output.strides[1],
    );
    decoder.last_width = output.width;
    decoder.last_height = output.height;
    decoder.last_y_stride = output.strides[0];
    decoder.last_uv_stride = output.strides[1];
    output.backend_frame = decoder;
    decoder.frame_pending = false;
    decoder.frame_outstanding = true;
    return c.GO_VIDEO_DECODER_RESULT_OK;
}

fn cedarRelease(
    base: ?*c.GoVideoDecoder,
    frame_pointer: ?*c.GoDecodedVideoFrame,
) callconv(.c) void {
    const decoder = fromBase(base orelse return);
    const frame = frame_pointer orelse return;
    if (frame.backend_frame == @as(?*anyopaque, @ptrCast(decoder)))
        decoder.frame_outstanding = false;
}

fn cedarReset(base: ?*c.GoVideoDecoder) callconv(.c) c_int {
    const decoder = fromBase(base orelse return -1);
    if (decoder.frame_outstanding) {
        copyZ(&decoder.error_message, "Cedar reset refused with a frame outstanding");
        return -1;
    }
    c.go_cedar_library_close(decoder.library);
    decoder.library = null;
    decoder.frame_pending = false;
    decoder.last_width = 0;
    decoder.last_height = 0;
    decoder.last_y_stride = 0;
    decoder.last_uv_stride = 0;
    decoder.pending_frame = std.mem.zeroes(c.GoCedarFrame);
    return openCedar(decoder);
}

fn cedarLastError(base: ?*const c.GoVideoDecoder) callconv(.c) [*c]const u8 {
    const decoder = fromConstBase(base orelse return "Cedar H.264 decoder failure");
    return if (decoder.error_message[0] != 0)
        @ptrCast(&decoder.error_message)
    else
        "Cedar H.264 decoder failure";
}

fn cedarDestroy(base: ?*c.GoVideoDecoder) callconv(.c) void {
    const decoder = fromBase(base orelse return);
    c.go_cedar_library_close(decoder.library);
    std.heap.c_allocator.destroy(decoder);
}

const ops = c.GoVideoDecoderOps{
    .name = "cedar-h616",
    .backend = c.GO_VIDEO_DECODER_BACKEND_CEDAR,
    .submit_access_unit = cedarSubmit,
    .receive_frame = cedarReceive,
    .release_frame = cedarRelease,
    .reset = cedarReset,
    .last_error = cedarLastError,
    .destroy = cedarDestroy,
};

pub export fn go_video_decoder_cedar_create(
    max_width: c_int,
    max_height: c_int,
    error_buffer: [*c]u8,
    error_capacity: usize,
) ?*c.GoVideoDecoder {
    if (max_width <= 0 or max_height <= 0) {
        writeError(error_buffer, error_capacity, "invalid Cedar decoder dimensions");
        return null;
    }
    const decoder = std.heap.c_allocator.create(Decoder) catch return null;
    decoder.* = .{ .max_width = max_width, .max_height = max_height };
    c.go_video_decoder_initialize(&decoder.base, &ops);
    if (openCedar(decoder) != 0) {
        writeError(error_buffer, error_capacity, std.mem.sliceTo(&decoder.error_message, 0));
        cedarDestroy(&decoder.base);
        return null;
    }
    return &decoder.base;
}
