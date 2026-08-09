const std = @import("std");

const embedded_json_depth = 3;

fn looksLikeJson(text: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, text, " \t\r\n");
    return trimmed.len > 0 and (trimmed[0] == '{' or trimmed[0] == '[');
}

fn copyMatchingString(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    key: []const u8,
    output: []u8,
    depth: usize,
) !?usize {
    switch (value) {
        .object => |object| {
            if (object.get(key)) |candidate| {
                switch (candidate) {
                    .string => |text| {
                        if (text.len >= output.len) return error.NoSpaceLeft;
                        @memcpy(output[0..text.len], text);
                        output[text.len] = 0;
                        return text.len;
                    },
                    else => {},
                }
            }
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (try copyMatchingString(allocator, entry.value_ptr.*, key, output, depth)) |length|
                    return length;
            }
        },
        .array => |array| {
            for (array.items) |item| {
                if (try copyMatchingString(allocator, item, key, output, depth)) |length|
                    return length;
            }
        },
        .string => |text| {
            if (depth >= embedded_json_depth or !looksLikeJson(text)) return null;
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return null;
            defer parsed.deinit();
            return copyMatchingString(allocator, parsed.value, key, output, depth + 1);
        },
        else => {},
    }
    return null;
}

fn findUnsigned(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    key: []const u8,
    depth: usize,
) !?u32 {
    switch (value) {
        .object => |object| {
            if (object.get(key)) |candidate| {
                switch (candidate) {
                    .integer => |number| {
                        if (number >= 0 and number <= std.math.maxInt(u32)) return @intCast(number);
                    },
                    else => {},
                }
            }
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (try findUnsigned(allocator, entry.value_ptr.*, key, depth)) |number|
                    return number;
            }
        },
        .array => |array| {
            for (array.items) |item| {
                if (try findUnsigned(allocator, item, key, depth)) |number| return number;
            }
        },
        .string => |text| {
            if (depth >= embedded_json_depth or !looksLikeJson(text)) return null;
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return null;
            defer parsed.deinit();
            return findUnsigned(allocator, parsed.value, key, depth + 1);
        },
        else => {},
    }
    return null;
}

fn parseString(data: []const u8, key: []const u8, output: []u8) !usize {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, data, .{});
    defer parsed.deinit();
    return try copyMatchingString(std.heap.page_allocator, parsed.value, key, output, 0) orelse
        error.MissingField;
}

fn parseUnsigned(data: []const u8, key: []const u8) !u32 {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, data, .{});
    defer parsed.deinit();
    return try findUnsigned(std.heap.page_allocator, parsed.value, key, 0) orelse
        error.MissingField;
}

export fn go_json_copy_string(
    data: [*]const u8,
    length: usize,
    key: [*:0]const u8,
    output: [*]u8,
    capacity: usize,
) c_int {
    const copied = parseString(data[0..length], std.mem.span(key), output[0..capacity]) catch
        return -1;
    return @intCast(copied);
}

export fn go_json_unsigned(
    data: [*]const u8,
    length: usize,
    key: [*:0]const u8,
    output: *c_uint,
) c_int {
    output.* = parseUnsigned(data[0..length], std.mem.span(key)) catch return -1;
    return 0;
}

test "copies decoded strings from direct and embedded JSON" {
    var output: [128]u8 = undefined;
    const direct =
        \\{"refresh_token":"line\nquote\"value"}
    ;
    const direct_length = try parseString(direct, "refresh_token", &output);
    try std.testing.expectEqualStrings("line\nquote\"value", output[0..direct_length]);

    const embedded =
        \\{"exchangeResponse":"{\"sdp\":\"v=0\\r\\na=mid:video\"}"}
    ;
    const embedded_length = try parseString(embedded, "sdp", &output);
    try std.testing.expectEqualStrings("v=0\r\na=mid:video", output[0..embedded_length]);
}

test "string extraction rejects missing malformed and oversized values" {
    var output: [4]u8 = undefined;
    try std.testing.expectError(error.MissingField, parseString("{}", "token", &output));
    try std.testing.expectError(error.UnexpectedEndOfInput, parseString("{", "token", &output));
    try std.testing.expectError(error.NoSpaceLeft, parseString("{\"token\":\"four\"}", "token", &output));
}

test "reads bounded unsigned integer fields" {
    try std.testing.expectEqual(@as(u32, 900), try parseUnsigned("{\"expires_in\":900}", "expires_in"));
    try std.testing.expectError(error.MissingField, parseUnsigned("{\"expires_in\":-1}", "expires_in"));
    try std.testing.expectError(error.MissingField, parseUnsigned("{\"expires_in\":\"900\"}", "expires_in"));
}
