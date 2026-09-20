const std = @import("std");

pub const Field = struct {
    name: []const u8,
    value: []const u8,
};

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

pub fn encode(input: []const u8, output: []u8) !usize {
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

pub fn build(fields: []const Field, output: []u8) ![:0]u8 {
    if (output.len == 0) return error.NoSpace;

    var cursor: usize = 0;
    for (fields, 0..) |field, index| {
        if (index != 0) {
            if (cursor + 1 >= output.len) return error.NoSpace;
            output[cursor] = '&';
            cursor += 1;
        }

        cursor += try encode(field.name, output[cursor..]);
        if (cursor + 1 >= output.len) return error.NoSpace;
        output[cursor] = '=';
        cursor += 1;
        cursor += try encode(field.value, output[cursor..]);
    }

    output[cursor] = 0;
    return output[0..cursor :0];
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

test "builds an encoded form body" {
    var output: [128]u8 = undefined;
    const body = try build(&.{
        .{ .name = "grant_type", .value = "refresh_token" },
        .{ .name = "scope", .value = "openid email" },
        .{ .name = "device/id", .value = "a&b" },
    }, &output);
    try std.testing.expectEqualStrings(
        "grant_type=refresh_token&scope=openid+email&device%2Fid=a%26b",
        body,
    );
}

test "build handles an empty form and rejects short destinations" {
    var empty: [1]u8 = undefined;
    try std.testing.expectEqualStrings("", try build(&.{}, &empty));

    var short: [3]u8 = undefined;
    try std.testing.expectError(
        error.NoSpace,
        build(&.{.{ .name = "a", .value = "b" }}, &short),
    );
}
