const std = @import("std");

fn isUnreserved(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or
        byte == '~';
}

fn encodedLength(input: []const u8) ?usize {
    var length: usize = 0;
    for (input) |byte| {
        const addition: usize = if (isUnreserved(byte) or byte == ' ') 1 else 3;
        length = std.math.add(usize, length, addition) catch return null;
    }
    return length;
}

fn encode(input: []const u8, output: []u8) !usize {
    const required = encodedLength(input) orelse return error.Overflow;
    if (output.len < required + 1) return error.NoSpace;

    const hex = "0123456789ABCDEF";
    var cursor: usize = 0;
    for (input) |byte| {
        if (isUnreserved(byte)) {
            output[cursor] = byte;
            cursor += 1;
        } else if (byte == ' ') {
            output[cursor] = '+';
            cursor += 1;
        } else {
            output[cursor] = '%';
            output[cursor + 1] = hex[byte >> 4];
            output[cursor + 2] = hex[byte & 0x0f];
            cursor += 3;
        }
    }
    output[cursor] = 0;
    return cursor;
}

export fn go_form_urlencode(input: ?[*]const u8, input_length: usize, output: ?[*]u8, output_capacity: usize) callconv(.c) c_int {
    const input_pointer = input orelse return -1;
    const output_pointer = output orelse return -1;
    const length = encode(input_pointer[0..input_length], output_pointer[0..output_capacity]) catch
        return -1;
    return std.math.cast(c_int, length) orelse -1;
}

test "encodes application form values and terminates them" {
    var output: [256]u8 = undefined;
    const input = "xboxlive.signin openid service::http://Passport.NET/?a=b&c=d";
    const length = try encode(input, &output);
    try std.testing.expectEqualStrings(
        "xboxlive.signin+openid+service%3A%3Ahttp%3A%2F%2FPassport.NET%2F%3Fa%3Db%26c%3Dd",
        output[0..length],
    );
    try std.testing.expectEqual(@as(u8, 0), output[length]);
}

test "preserves unreserved bytes and rejects undersized output" {
    var output: [8]u8 = undefined;
    const length = try encode("a-._~Z", &output);
    try std.testing.expectEqualStrings("a-._~Z", output[0..length]);
    try std.testing.expectError(error.NoSpace, encode("a/b", output[0..5]));
}
