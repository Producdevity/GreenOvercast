const std = @import("std");

pub const Header = struct {
    marker: bool,
    payload_type: u7,
    sequence: u16,
    timestamp: u32,
    ssrc: u32,
};

pub const Parsed = struct {
    header: Header,
    payload: []const u8,
};

pub const ParseError = error{
    TooShort,
    BadVersion,
    BadPadding,
};

pub fn parse(data: []const u8) ParseError!Parsed {
    if (data.len < 12) return error.TooShort;

    const first = data[0];
    if (first >> 6 != 2) return error.BadVersion;

    const csrc_count: usize = first & 0x0f;
    var offset: usize = 12 + csrc_count * 4;
    if (offset > data.len) return error.TooShort;

    if (first & 0x10 != 0) {
        if (data.len - offset < 4) return error.TooShort;
        const extension_words = std.mem.readInt(u16, data[offset + 2 ..][0..2], .big);
        const extension_bytes = @as(usize, extension_words) * 4;
        if (extension_bytes > data.len - offset - 4) return error.TooShort;
        offset += 4 + extension_bytes;
    }

    var payload = data[offset..];
    if (first & 0x20 != 0) {
        if (payload.len == 0) return error.BadPadding;
        const padding_length = payload[payload.len - 1];
        if (padding_length == 0 or padding_length > payload.len) return error.BadPadding;
        payload = payload[0 .. payload.len - padding_length];
    }

    const second = data[1];
    return .{
        .header = .{
            .marker = second & 0x80 != 0,
            .payload_type = @intCast(second & 0x7f),
            .sequence = std.mem.readInt(u16, data[2..4], .big),
            .timestamp = std.mem.readInt(u32, data[4..8], .big),
            .ssrc = std.mem.readInt(u32, data[8..12], .big),
        },
        .payload = payload,
    };
}

test "parse minimal header" {
    const data = [_]u8{
        0x80, 0xe6, 0x00, 0x01,
        0x00, 0x00, 0x0e, 0x10,
        0x12, 0x34, 0x56, 0x78,
        0xaa, 0xbb,
    };
    const parsed = try parse(&data);

    try std.testing.expect(parsed.header.marker);
    try std.testing.expectEqual(@as(u7, 102), parsed.header.payload_type);
    try std.testing.expectEqual(@as(u16, 1), parsed.header.sequence);
    try std.testing.expectEqual(@as(u32, 3600), parsed.header.timestamp);
    try std.testing.expectEqual(@as(u32, 0x12345678), parsed.header.ssrc);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb }, parsed.payload);
}

test "parse CSRC extension and padding" {
    const data = [_]u8{
        0xb1, 0x66, 0x00, 0x02,
        0x00, 0x00, 0x0e, 0x10,
        0x12, 0x34, 0x56, 0x78,
        0xde, 0xad, 0xbe, 0xef,
        0xab, 0xcd, 0x00, 0x01,
        0x01, 0x02, 0x03, 0x04,
        0x41, 0x42, 0x00, 0x02,
    };
    const parsed = try parse(&data);

    try std.testing.expectEqualSlices(u8, &.{ 0x41, 0x42 }, parsed.payload);
}

test "reject truncated header fields" {
    try std.testing.expectError(error.TooShort, parse(&.{ 0x80, 0x66 }));

    var csrc = [_]u8{0} ** 12;
    csrc[0] = 0x81;
    try std.testing.expectError(error.TooShort, parse(&csrc));

    var extension = [_]u8{0} ** 15;
    extension[0] = 0x90;
    try std.testing.expectError(error.TooShort, parse(&extension));
}

test "reject bad version and padding" {
    var bad_version = [_]u8{0} ** 12;
    bad_version[0] = 0x40;
    try std.testing.expectError(error.BadVersion, parse(&bad_version));

    var no_padding_bytes = [_]u8{0} ** 12;
    no_padding_bytes[0] = 0xa0;
    try std.testing.expectError(error.BadPadding, parse(&no_padding_bytes));

    var zero_padding = [_]u8{0} ** 13;
    zero_padding[0] = 0xa0;
    try std.testing.expectError(error.BadPadding, parse(&zero_padding));
}
