const std = @import("std");

// PortMaster resizes muOS port artwork with "320x240>": fit inside the box,
// keep the aspect ratio, never enlarge.
pub const box_width = 320;
pub const box_height = 240;

pub const Image = struct {
    pixels: []u8,
    width: usize,
    height: usize,

    pub fn deinit(self: Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

pub fn fittedSize(width: usize, height: usize, max_width: usize, max_height: usize) [2]usize {
    if (width <= max_width and height <= max_height) return .{ width, height };
    if (width * max_height >= height * max_width)
        return .{ max_width, @max(1, height * max_width / width) };
    return .{ @max(1, width * max_height / height), max_height };
}

/// Box-filters a tightly or loosely packed RGB24 image into a new packed RGB24 image
/// that fits inside max_width x max_height.
pub fn fitWithin(
    allocator: std.mem.Allocator,
    pixels: []const u8,
    width: usize,
    height: usize,
    stride: usize,
    max_width: usize,
    max_height: usize,
) !Image {
    if (width == 0 or height == 0 or stride < width * 3 or
        pixels.len < stride * (height - 1) + width * 3) return error.InvalidImage;
    const size = fittedSize(width, height, max_width, max_height);
    const output = try allocator.alloc(u8, size[0] * size[1] * 3);
    for (0..size[1]) |y| {
        const y0 = y * height / size[1];
        const y1 = @max(y0 + 1, (y + 1) * height / size[1]);
        for (0..size[0]) |x| {
            const x0 = x * width / size[0];
            const x1 = @max(x0 + 1, (x + 1) * width / size[0]);
            var sum = [3]usize{ 0, 0, 0 };
            for (y0..y1) |source_y| {
                const row = pixels[source_y * stride ..];
                for (x0..x1) |source_x| {
                    for (0..3) |channel| sum[channel] += row[source_x * 3 + channel];
                }
            }
            const count = (y1 - y0) * (x1 - x0);
            const target = (y * size[0] + x) * 3;
            for (0..3) |channel| output[target + channel] = @intCast(sum[channel] / count);
        }
    }
    return .{ .pixels = output, .width = size[0], .height = size[1] };
}

pub fn encodePng(allocator: std.mem.Allocator, image: Image) ![]u8 {
    if (image.width == 0 or image.height == 0 or
        image.width > std.math.maxInt(u31) or image.height > std.math.maxInt(u31) or
        image.pixels.len != image.width * image.height * 3) return error.InvalidImage;

    const row_bytes = image.width * 3;
    const raw = try allocator.alloc(u8, (row_bytes + 1) * image.height);
    defer allocator.free(raw);
    for (0..image.height) |y| {
        const target = raw[y * (row_bytes + 1) ..];
        target[0] = 0;
        @memcpy(target[1 .. row_bytes + 1], image.pixels[y * row_bytes ..][0..row_bytes]);
    }

    var compressed = std.ArrayList(u8).init(allocator);
    defer compressed.deinit();
    var source = std.io.fixedBufferStream(raw);
    try std.compress.zlib.compress(source.reader(), compressed.writer(), .{});

    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();
    try output.appendSlice("\x89PNG\r\n\x1a\n");
    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], @intCast(image.width), .big);
    std.mem.writeInt(u32, header[4..8], @intCast(image.height), .big);
    header[8] = 8; // bit depth
    header[9] = 2; // truecolour RGB
    header[10] = 0;
    header[11] = 0;
    header[12] = 0;
    try writeChunk(&output, "IHDR", &header);
    try writeChunk(&output, "IDAT", compressed.items);
    try writeChunk(&output, "IEND", "");
    return output.toOwnedSlice();
}

fn writeChunk(output: *std.ArrayList(u8), kind: *const [4]u8, data: []const u8) !void {
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(data.len), .big);
    try output.appendSlice(&length);
    try output.appendSlice(kind);
    try output.appendSlice(data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var checksum: [4]u8 = undefined;
    std.mem.writeInt(u32, &checksum, crc.final(), .big);
    try output.appendSlice(&checksum);
}

test "fits portrait and landscape art inside the port artwork box without enlarging" {
    try std.testing.expectEqual([2]usize{ 160, 240 }, fittedSize(256, 384, box_width, box_height));
    try std.testing.expectEqual([2]usize{ 320, 180 }, fittedSize(1280, 720, box_width, box_height));
    try std.testing.expectEqual([2]usize{ 100, 80 }, fittedSize(100, 80, box_width, box_height));
}

test "box filter averages each source block" {
    const pixels = [_]u8{
        0,   0,   0,   255, 255, 255,
        255, 255, 255, 0,   0,   0,
    };
    const image = try fitWithin(std.testing.allocator, &pixels, 2, 2, 6, 1, 1);
    defer image.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), image.width);
    try std.testing.expectEqualSlices(u8, &.{ 127, 127, 127 }, image.pixels);
}

test "png carries the image header and decompressible rows" {
    var pixels = [_]u8{ 10, 20, 30, 40, 50, 60 };
    const png = try encodePng(std.testing.allocator, .{ .pixels = &pixels, .width = 2, .height = 1 });
    defer std.testing.allocator.free(png);

    try std.testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", png[0..8]);
    try std.testing.expectEqualSlices(u8, "IHDR", png[12..16]);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, png[16..20], .big));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, png[20..24], .big));
    try std.testing.expectEqualSlices(u8, "\x00\x00\x00\x00IEND\xae\x42\x60\x82", png[png.len - 12 ..]);

    const idat_length = std.mem.readInt(u32, png[33..37], .big);
    try std.testing.expectEqualSlices(u8, "IDAT", png[37..41]);
    var compressed = std.io.fixedBufferStream(png[41 .. 41 + idat_length]);
    var raw = std.ArrayList(u8).init(std.testing.allocator);
    defer raw.deinit();
    try std.compress.zlib.decompress(compressed.reader(), raw.writer());
    try std.testing.expectEqualSlices(u8, &.{ 0, 10, 20, 30, 40, 50, 60 }, raw.items);
}
