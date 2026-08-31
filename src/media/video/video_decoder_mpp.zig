const std = @import("std");

const c = @cImport({
    @cInclude("mpp_loader.h");
    @cInclude("video_decoder.h");
});

const Decoder = struct {
    base: c.GoVideoDecoder = .{ .ops = null },
    library: *c.GoMppLibrary,
    active_frame: c.GoMppFrame = std.mem.zeroes(c.GoMppFrame),
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

fn copyLibraryError(decoder: *Decoder) void {
    copyZ(&decoder.error_message, std.mem.span(c.go_mpp_library_error(decoder.library)));
}

fn writeError(destination: [*c]u8, capacity: usize, message: []const u8) void {
    if (destination == null or capacity == 0) return;
    const length = @min(capacity - 1, message.len);
    @memcpy(destination[0..length], message[0..length]);
    destination[length] = 0;
}

fn mppSubmit(
    base: ?*c.GoVideoDecoder,
    data: [*c]const u8,
    length: usize,
) callconv(.c) c.GoVideoDecoderResult {
    const decoder = fromBase(base orelse return c.GO_VIDEO_DECODER_RESULT_FATAL);
    const result = c.go_mpp_library_submit(decoder.library, data, length);
    if (result > 0) return c.GO_VIDEO_DECODER_RESULT_OK;
    if (result == 0) return c.GO_VIDEO_DECODER_RESULT_AGAIN;
    copyLibraryError(decoder);
    return c.GO_VIDEO_DECODER_RESULT_FATAL;
}

fn mppReceive(
    base: ?*c.GoVideoDecoder,
    output_pointer: ?*c.GoDecodedVideoFrame,
) callconv(.c) c.GoVideoDecoderResult {
    const decoder = fromBase(base orelse return c.GO_VIDEO_DECODER_RESULT_FATAL);
    const output = output_pointer orelse return c.GO_VIDEO_DECODER_RESULT_FATAL;
    if (decoder.frame_outstanding) {
        copyZ(&decoder.error_message, "MPP frame was not released");
        return c.GO_VIDEO_DECODER_RESULT_FATAL;
    }
    const result = c.go_mpp_library_receive(decoder.library, &decoder.active_frame);
    if (result == 0) return c.GO_VIDEO_DECODER_RESULT_AGAIN;
    if (result < 0) {
        copyLibraryError(decoder);
        return c.GO_VIDEO_DECODER_RESULT_FATAL;
    }

    output.format = c.GO_VIDEO_PIXEL_FORMAT_NV12;
    output.color_range = c.GO_VIDEO_COLOR_RANGE_LIMITED;
    output.width = decoder.active_frame.width;
    output.height = decoder.active_frame.height;
    output.coded_width = output.width;
    output.coded_height = output.height;
    output.planes[0] = decoder.active_frame.y;
    output.planes[1] = decoder.active_frame.uv;
    output.strides[0] = decoder.active_frame.y_stride;
    output.strides[1] = decoder.active_frame.uv_stride;
    output.info_changed = @intFromBool(
        decoder.last_width != output.width or decoder.last_height != output.height or
            decoder.last_y_stride != output.strides[0] or
            decoder.last_uv_stride != output.strides[1],
    );
    decoder.last_width = output.width;
    decoder.last_height = output.height;
    decoder.last_y_stride = output.strides[0];
    decoder.last_uv_stride = output.strides[1];
    output.backend_frame = &decoder.active_frame;
    decoder.frame_outstanding = true;
    return c.GO_VIDEO_DECODER_RESULT_OK;
}

fn mppRelease(
    base: ?*c.GoVideoDecoder,
    frame_pointer: ?*c.GoDecodedVideoFrame,
) callconv(.c) void {
    const decoder = fromBase(base orelse return);
    const frame = frame_pointer orelse return;
    if (decoder.frame_outstanding and
        frame.backend_frame == @as(?*anyopaque, @ptrCast(&decoder.active_frame)))
    {
        c.go_mpp_library_release_frame(decoder.library, &decoder.active_frame);
        decoder.active_frame = std.mem.zeroes(c.GoMppFrame);
        decoder.frame_outstanding = false;
    }
}

fn mppReset(base: ?*c.GoVideoDecoder) callconv(.c) c_int {
    const decoder = fromBase(base orelse return -1);
    if (decoder.frame_outstanding) {
        copyZ(&decoder.error_message, "MPP reset refused with a frame outstanding");
        return -1;
    }
    const result = c.go_mpp_library_reset(decoder.library);
    if (result < 0) {
        copyLibraryError(decoder);
    } else {
        decoder.last_width = 0;
        decoder.last_height = 0;
        decoder.last_y_stride = 0;
        decoder.last_uv_stride = 0;
        decoder.error_message[0] = 0;
    }
    return result;
}

fn mppLastError(base: ?*const c.GoVideoDecoder) callconv(.c) [*c]const u8 {
    const decoder = fromConstBase(base orelse return "MPP H.264 decoder failure");
    return if (decoder.error_message[0] != 0)
        @ptrCast(&decoder.error_message)
    else
        "MPP H.264 decoder failure";
}

fn mppDestroy(base: ?*c.GoVideoDecoder) callconv(.c) void {
    const decoder = fromBase(base orelse return);
    if (decoder.frame_outstanding)
        c.go_mpp_library_release_frame(decoder.library, &decoder.active_frame);
    c.go_mpp_library_close(decoder.library);
    std.heap.c_allocator.destroy(decoder);
}

const ops = c.GoVideoDecoderOps{
    .name = "rockchip-mpp",
    .backend = c.GO_VIDEO_DECODER_BACKEND_MPP,
    .submit_access_unit = mppSubmit,
    .receive_frame = mppReceive,
    .release_frame = mppRelease,
    .reset = mppReset,
    .last_error = mppLastError,
    .destroy = mppDestroy,
};

pub export fn go_video_decoder_mpp_create(
    max_width: c_int,
    max_height: c_int,
    error_buffer: [*c]u8,
    error_capacity: usize,
) ?*c.GoVideoDecoder {
    const decoder = std.heap.c_allocator.create(Decoder) catch return null;
    const library = c.go_mpp_library_open(max_width, max_height) orelse {
        std.heap.c_allocator.destroy(decoder);
        return null;
    };
    decoder.* = .{ .library = library };
    c.go_video_decoder_initialize(&decoder.base, &ops);
    if (c.go_mpp_library_ready(library) == 0) {
        copyLibraryError(decoder);
        writeError(error_buffer, error_capacity, std.mem.sliceTo(&decoder.error_message, 0));
        mppDestroy(&decoder.base);
        return null;
    }
    std.debug.print("MPP plugin: {s}\n", .{std.mem.span(c.go_mpp_library_path(library))});
    return &decoder.base;
}
