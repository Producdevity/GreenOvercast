const std = @import("std");

pub const string_length = 36;

pub fn generate(output: *[string_length + 1]u8) void {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    write(output, bytes);
}

pub fn valid(value: []const u8) bool {
    if (value.len != string_length) return false;
    for (value, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (byte != '-') return false;
        } else if (!std.ascii.isHex(byte)) return false;
    }
    return value[14] == '4' and (value[19] == '8' or value[19] == '9' or
        std.ascii.toLower(value[19]) == 'a' or std.ascii.toLower(value[19]) == 'b');
}

fn write(output: *[string_length + 1]u8, bytes: [16]u8) void {
    _ = std.fmt.bufPrintZ(
        output,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-" ++
            "{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15],
        },
    ) catch unreachable;
}

test "generates a valid version four UUID" {
    var output: [string_length + 1]u8 = undefined;
    generate(&output);
    try std.testing.expect(valid(std.mem.sliceTo(&output, 0)));
}

test "rejects malformed UUIDs" {
    try std.testing.expect(!valid("12345678-1234-4abc-8def"));
    try std.testing.expect(!valid("12345678-1234-1abc-8def-123456789abc"));
}
