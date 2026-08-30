const std = @import("std");

fn escapedLength(input: []const u8) ?usize {
    var length: usize = 0;
    for (input) |byte| {
        const addition: usize = switch (byte) {
            '"', '\\', '\n', '\r', '\t', 0x08, 0x0c => 2,
            0...0x07, 0x0b, 0x0e...0x1f => 6,
            else => 1,
        };
        length = std.math.add(usize, length, addition) catch return null;
    }
    return length;
}

pub fn escape(input: []const u8, output: []u8) !usize {
    const required = escapedLength(input) orelse return error.Overflow;
    if (output.len < required + 1) return error.NoSpace;
    var cursor: usize = 0;
    for (input) |byte| {
        const replacement: ?[]const u8 = switch (byte) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0x08 => "\\b",
            0x0c => "\\f",
            else => null,
        };
        if (replacement) |text| {
            @memcpy(output[cursor..][0..text.len], text);
            cursor += text.len;
        } else if (byte < 0x20) {
            const hex = "0123456789abcdef";
            output[cursor..][0..4].* = "\\u00".*;
            output[cursor + 4] = hex[byte >> 4];
            output[cursor + 5] = hex[byte & 0x0f];
            cursor += 6;
        } else {
            output[cursor] = byte;
            cursor += 1;
        }
    }
    output[cursor] = 0;
    return cursor;
}

test "escapes JSON string content and terminates it" {
    var output: [128]u8 = undefined;
    const input = "line 1\r\n\"line 2\"\\\t\x01";
    const length = try escape(input, &output);
    try std.testing.expectEqualStrings("line 1\\r\\n\\\"line 2\\\"\\\\\\t\\u0001", output[0..length]);
    try std.testing.expectEqual(@as(u8, 0), output[length]);
}

test "rejects an undersized destination without partial success" {
    var output: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpace, escape("\r\n", &output));
}
