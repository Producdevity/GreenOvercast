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

pub fn parseString(data: []const u8, key: []const u8, output: []u8) !usize {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, data, .{});
    defer parsed.deinit();
    return try copyMatchingString(std.heap.page_allocator, parsed.value, key, output, 0) orelse
        error.MissingField;
}

pub fn parseUnsigned(data: []const u8, key: []const u8) !u32 {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, data, .{});
    defer parsed.deinit();
    return try findUnsigned(std.heap.page_allocator, parsed.value, key, 0) orelse
        error.MissingField;
}

// GSSV login/user responses (both xgpuweb/cloud and xhome offerings) carry
// several candidate regions under offeringSettings.regions[]; unlike the
// cloud offering, xHome does not use a fixed well-known host, so the caller
// must read the region marked isDefault and use its baseUri for every
// subsequent call on that session (state/connect/sdp/ice/keepalive/delete).
pub fn parseDefaultRegionBaseUri(data: []const u8, output: []u8) !usize {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, data, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.MissingField,
    };
    const offering_settings = switch (root.get("offeringSettings") orelse return error.MissingField) {
        .object => |object| object,
        else => return error.MissingField,
    };
    const regions = switch (offering_settings.get("regions") orelse return error.MissingField) {
        .array => |array| array.items,
        else => return error.MissingField,
    };
    for (regions) |region| {
        const object = switch (region) {
            .object => |value| value,
            else => continue,
        };
        const is_default = switch (object.get("isDefault") orelse continue) {
            .bool => |value| value,
            else => false,
        };
        if (!is_default) continue;
        const base_uri = switch (object.get("baseUri") orelse continue) {
            .string => |text| text,
            else => continue,
        };
        if (base_uri.len >= output.len) return error.NoSpaceLeft;
        @memcpy(output[0..base_uri.len], base_uri);
        output[base_uri.len] = 0;
        return base_uri.len;
    }
    return error.MissingField;
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

test "picks the default region's baseUri among several candidates" {
    var output: [128]u8 = undefined;
    const fixture =
        \\{"gsToken":"abc","offeringSettings":{"regions":[
        \\  {"name":"WestEurope","baseUri":"https://weu.core.gssv-play-prodxhome.xboxlive.com","isDefault":false},
        \\  {"name":"UKSouth","baseUri":"https://uks.core.gssv-play-prodxhome.xboxlive.com","isDefault":true}
        \\]}}
    ;
    const length = try parseDefaultRegionBaseUri(fixture, &output);
    try std.testing.expectEqualStrings("https://uks.core.gssv-play-prodxhome.xboxlive.com", output[0..length]);
}

test "default region lookup rejects a response with no default region" {
    var output: [128]u8 = undefined;
    const fixture =
        \\{"offeringSettings":{"regions":[{"name":"WestEurope","baseUri":"https://weu.example","isDefault":false}]}}
    ;
    try std.testing.expectError(error.MissingField, parseDefaultRegionBaseUri(fixture, &output));
    try std.testing.expectError(error.MissingField, parseDefaultRegionBaseUri("{}", &output));
}
