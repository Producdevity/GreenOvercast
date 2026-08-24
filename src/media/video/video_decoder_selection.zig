const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("video_decoder.h");
});

fn writeError(destination: ?[*]u8, capacity: usize, message: []const u8) void {
    const output = destination orelse return;
    if (capacity == 0) return;
    const length = @min(message.len, capacity - 1);
    @memcpy(output[0..length], message[0..length]);
    output[length] = 0;
}

fn readCompatible(output: []u8) usize {
    const paths = [_][]const u8{
        "/proc/device-tree/compatible",
        "/sys/firmware/devicetree/base/compatible",
    };
    for (paths) |path| {
        const file = std.fs.openFileAbsolute(path, .{}) catch continue;
        defer file.close();
        const length = file.readAll(output) catch continue;
        if (length > 0) return length;
    }
    return 0;
}

fn isArm() c_int {
    return switch (builtin.cpu.arch) {
        .arm, .armeb, .aarch64, .aarch64_be, .thumb, .thumbeb => 1,
        else => 0,
    };
}

fn backendName(backend: c.GoVideoDecoderBackend) []const u8 {
    return if (backend == c.GO_VIDEO_DECODER_BACKEND_MPP)
        "mpp"
    else if (backend == c.GO_VIDEO_DECODER_BACKEND_CEDAR)
        "cedar"
    else if (backend == c.GO_VIDEO_DECODER_BACKEND_SOFTWARE)
        "software"
    else
        "none";
}

fn createBackend(
    config: *const c.GoVideoDecoderSelectionConfig,
    backend: c.GoVideoDecoderBackend,
    error_buffer: *[256]u8,
) ?*c.GoVideoDecoder {
    @memset(error_buffer, 0);
    if (backend == c.GO_VIDEO_DECODER_BACKEND_MPP) {
        return c.go_video_decoder_mpp_create(
            config.max_width,
            config.max_height,
            error_buffer,
            error_buffer.len,
        );
    }
    if (backend == c.GO_VIDEO_DECODER_BACKEND_CEDAR) {
        return c.go_video_decoder_cedar_create(
            config.max_width,
            config.max_height,
            error_buffer,
            error_buffer.len,
        );
    }
    if (backend == c.GO_VIDEO_DECODER_BACKEND_SOFTWARE) {
        return c.go_video_decoder_ffmpeg_create(error_buffer, error_buffer.len);
    }
    return null;
}

fn bufferString(buffer: *const [256]u8) []const u8 {
    return std.mem.sliceTo(buffer, 0);
}

pub export fn go_video_decoder_selection_create(
    config: ?*const c.GoVideoDecoderSelectionConfig,
    selection: ?*c.GoVideoDecoderSelection,
    error_output: ?[*]u8,
    error_capacity: usize,
) c_int {
    const settings = config orelse return -1;
    const output = selection orelse return -1;
    output.* = std.mem.zeroes(c.GoVideoDecoderSelection);
    if (settings.max_width <= 0 or settings.max_height <= 0 or
        settings.max_width > 8192 or settings.max_height > 8192 or
        settings.preference < c.GO_VIDEO_DECODER_PREFERENCE_AUTO or
        settings.preference > c.GO_VIDEO_DECODER_PREFERENCE_SOFTWARE)
    {
        writeError(error_output, error_capacity, "invalid video decoder configuration");
        return -1;
    }

    var compatible: [4096]u8 = undefined;
    const compatible_length = readCompatible(&compatible);
    const platform = c.go_video_decoder_platform(&compatible, compatible_length, isArm());
    var candidates: [3]c.GoVideoDecoderBackend = undefined;
    const candidate_count = c.go_video_decoder_candidate_order(
        settings.preference,
        platform,
        &candidates,
        candidates.len,
    );
    const automatic = settings.preference == c.GO_VIDEO_DECODER_PREFERENCE_AUTO;
    var backend_error = [_]u8{0} ** 256;

    if (automatic) {
        output.software = createBackend(settings, c.GO_VIDEO_DECODER_BACKEND_SOFTWARE, &backend_error);
        if (output.software == null) {
            const detail = bufferString(&backend_error);
            std.debug.print("Software video decoder unavailable: {s}\n", .{detail});
            writeError(error_output, error_capacity, detail);
            return -1;
        }
    }

    for (candidates[0..candidate_count]) |backend| {
        std.debug.print("Trying video decoder: {s}\n", .{backendName(backend)});
        const candidate = if (backend == c.GO_VIDEO_DECODER_BACKEND_SOFTWARE and
            output.software != null)
            output.software
        else
            createBackend(settings, backend, &backend_error);
        if (candidate) |decoder| {
            output.active = decoder;
            if (backend == c.GO_VIDEO_DECODER_BACKEND_SOFTWARE) output.software = decoder;
            break;
        }
        output.init_failures += 1;
        std.debug.print("{s} video decoder unavailable: {s}\n", .{
            backendName(backend),
            bufferString(&backend_error),
        });
    }

    if (output.active == null) {
        writeError(error_output, error_capacity, bufferString(&backend_error));
        go_video_decoder_selection_destroy(output);
        return -1;
    }
    output.allow_runtime_fallback = @intFromBool(automatic and output.active != output.software);
    std.debug.print("Selected video decoder: {s}\n", .{
        std.mem.span(c.go_video_decoder_name(output.active)),
    });
    return 0;
}

pub export fn go_video_decoder_selection_fallback(
    selection: ?*c.GoVideoDecoderSelection,
    error_output: ?[*]u8,
    error_capacity: usize,
) c_int {
    const output = selection orelse return -1;
    if (output.allow_runtime_fallback == 0 or output.software == null or
        output.active == output.software)
    {
        return -1;
    }

    c.go_video_decoder_destroy(output.active);
    output.active = output.software;
    output.allow_runtime_fallback = 0;
    if (c.go_video_decoder_reset(output.active) != 0) {
        writeError(
            error_output,
            error_capacity,
            std.mem.span(c.go_video_decoder_last_error(output.active)),
        );
        return -1;
    }
    return 0;
}

pub export fn go_video_decoder_selection_destroy(selection: ?*c.GoVideoDecoderSelection) void {
    const output = selection orelse return;
    if (output.active != null and output.active != output.software)
        c.go_video_decoder_destroy(output.active);
    if (output.software != null) c.go_video_decoder_destroy(output.software);
    output.* = std.mem.zeroes(c.GoVideoDecoderSelection);
}
