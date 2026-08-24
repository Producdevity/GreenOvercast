const std = @import("std");

const c = @cImport({
    @cInclude("video_frame_copy.h");
});

fn validPlane(plane: ?[*]const u8, stride: c_int, row_bytes: c_int, rows: c_int) bool {
    if (plane == null or stride < row_bytes or row_bytes <= 0 or rows <= 0) return false;
    const byte_stride: usize = @intCast(stride);
    const visible_bytes: usize = @intCast(row_bytes);
    const row_count: usize = @intCast(rows);
    return row_count - 1 <= (std.math.maxInt(usize) - visible_bytes) / byte_stride;
}

fn validate(frame: *const c.GoDecodedVideoFrame, max_width: c_int, max_height: c_int) bool {
    if (max_width <= 0 or max_height <= 0 or frame.width <= 0 or frame.height <= 0 or
        frame.width > max_width or frame.height > max_height or
        !validPlane(frame.planes[0], frame.strides[0], frame.width, frame.height))
    {
        return false;
    }

    const chroma_height = @divTrunc(frame.height + 1, 2);
    if (frame.format == c.GO_VIDEO_PIXEL_FORMAT_NV12) {
        const chroma_width = frame.width + @mod(frame.width, 2);
        return validPlane(frame.planes[1], frame.strides[1], chroma_width, chroma_height);
    }
    if (frame.format == c.GO_VIDEO_PIXEL_FORMAT_YUV420P) {
        const chroma_width = @divTrunc(frame.width + 1, 2);
        return validPlane(frame.planes[1], frame.strides[1], chroma_width, chroma_height) and
            validPlane(frame.planes[2], frame.strides[2], chroma_width, chroma_height);
    }
    return false;
}

pub export fn go_video_frame_validate(
    frame: ?*const c.GoDecodedVideoFrame,
    max_width: c_int,
    max_height: c_int,
) c_int {
    const source = frame orelse return -1;
    return if (validate(source, max_width, max_height)) 0 else -1;
}

fn copyPlane(
    destination: [*]u8,
    destination_stride: usize,
    source: [*]const u8,
    source_stride: usize,
    row_bytes: usize,
    rows: usize,
) void {
    for (0..rows) |row| {
        const destination_offset = row * destination_stride;
        const source_offset = row * source_stride;
        @memcpy(
            destination[destination_offset .. destination_offset + row_bytes],
            source[source_offset .. source_offset + row_bytes],
        );
    }
}

pub export fn go_video_frame_copy(
    source: ?*const c.GoDecodedVideoFrame,
    max_width: c_int,
    max_height: c_int,
    destination_planes: ?[*]?[*]u8,
    destination_strides: ?[*]const c_int,
) c_int {
    const frame = source orelse return -1;
    const planes = destination_planes orelse return -1;
    const strides = destination_strides orelse return -1;
    if (!validate(frame, max_width, max_height) or
        !validPlane(planes[0], strides[0], frame.width, frame.height))
    {
        return -1;
    }

    const chroma_height: c_int = @divTrunc(frame.height + 1, 2);
    const chroma_width: c_int = if (frame.format == c.GO_VIDEO_PIXEL_FORMAT_NV12)
        frame.width + @mod(frame.width, 2)
    else
        @divTrunc(frame.width + 1, 2);
    if (!validPlane(planes[1], strides[1], chroma_width, chroma_height) or
        (frame.format == c.GO_VIDEO_PIXEL_FORMAT_YUV420P and
            !validPlane(planes[2], strides[2], chroma_width, chroma_height)))
    {
        return -1;
    }

    copyPlane(
        planes[0].?,
        @intCast(strides[0]),
        frame.planes[0].?,
        @intCast(frame.strides[0]),
        @intCast(frame.width),
        @intCast(frame.height),
    );
    const plane_count: usize = if (frame.format == c.GO_VIDEO_PIXEL_FORMAT_NV12) 2 else 3;
    for (1..plane_count) |plane| {
        copyPlane(
            planes[plane].?,
            @intCast(strides[plane]),
            frame.planes[plane].?,
            @intCast(frame.strides[plane]),
            @intCast(chroma_width),
            @intCast(chroma_height),
        );
    }
    return 0;
}
