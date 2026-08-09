const std = @import("std");

pub const title_id_capacity = 128;
pub const product_id_capacity = 64;
pub const name_capacity = 192;

pub const Title = extern struct {
    title_id: [title_id_capacity]u8,
    product_id: [product_id_capacity]u8,
    name: [name_capacity]u8,
};

fn objectString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn arraysIntersect(left: std.json.Value, right: std.json.Value) bool {
    const left_items = switch (left) {
        .array => |array| array.items,
        else => return false,
    };
    const right_items = switch (right) {
        .array => |array| array.items,
        else => return false,
    };
    for (left_items) |left_value| {
        const left_text = switch (left_value) {
            .string => |text| text,
            else => continue,
        };
        for (right_items) |right_value| {
            const right_text = switch (right_value) {
                .string => |text| text,
                else => continue,
            };
            if (std.mem.eql(u8, left_text, right_text)) return true;
        }
    }
    return false;
}

fn findValue(value: std.json.Value, key: []const u8) ?std.json.Value {
    switch (value) {
        .object => |object| {
            if (object.get(key)) |candidate| return candidate;
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (findValue(entry.value_ptr.*, key)) |candidate| return candidate;
            }
        },
        .array => |array| {
            for (array.items) |item| {
                if (findValue(item, key)) |candidate| return candidate;
            }
        },
        else => {},
    }
    return null;
}

fn isPlayable(value: std.json.Value) bool {
    if (findValue(value, "hasEntitlement")) |entitlement| {
        switch (entitlement) {
            .bool => |enabled| if (enabled) return true,
            else => {},
        }
    }
    const programs = findValue(value, "programs") orelse return false;
    const subscriptions = findValue(value, "userSubscriptions") orelse return false;
    return arraysIntersect(programs, subscriptions);
}

fn collectTitles(value: std.json.Value, titles: []Title, count: *usize) void {
    switch (value) {
        .object => |object| {
            if (count.* < titles.len) {
                if (objectString(object, "titleId")) |title_id| {
                    if (!isPlayable(value)) return;
                    var title = std.mem.zeroes(Title);
                    if (writeCString(&title.title_id, title_id)) {
                        if (findValue(value, "productId")) |product_value| switch (product_value) {
                            .string => |product_id| _ = writeCString(&title.product_id, product_id),
                            else => {},
                        };
                        titles[count.*] = title;
                        count.* += 1;
                    }
                    return;
                }
            }
            var iterator = object.iterator();
            while (iterator.next()) |entry|
                collectTitles(entry.value_ptr.*, titles, count);
        },
        .array => |array| {
            for (array.items) |item| collectTitles(item, titles, count);
        },
        else => {},
    }
}

pub fn writeCString(destination: []u8, text: []const u8) bool {
    if (text.len == 0 or text.len >= destination.len) return false;
    @memset(destination, 0);
    @memcpy(destination[0..text.len], text);
    return true;
}

fn writeDisplayCString(destination: []u8, text: []const u8) bool {
    @memset(destination, 0);
    var source_index: usize = 0;
    var destination_index: usize = 0;
    while (source_index < text.len and destination_index + 1 < destination.len) {
        const byte = text[source_index];
        source_index += 1;
        if (byte < 32) {
            destination[destination_index] = ' ';
        } else if (byte < 128) {
            destination[destination_index] = byte;
        } else {
            while (source_index < text.len and (text[source_index] & 0xc0) == 0x80)
                source_index += 1;
            destination[destination_index] = '?';
        }
        destination_index += 1;
    }
    return destination_index > 0;
}

fn findString(value: std.json.Value, key: []const u8) ?[]const u8 {
    switch (value) {
        .object => |object| {
            if (objectString(object, key)) |text| return text;
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (findString(entry.value_ptr.*, key)) |text| return text;
            }
        },
        .array => |array| {
            for (array.items) |item| {
                if (findString(item, key)) |text| return text;
            }
        },
        else => {},
    }
    return null;
}

pub fn cString(bytes: []const u8) []const u8 {
    return bytes[0 .. std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len];
}

fn applyMetadata(value: std.json.Value, titles: []Title, applied: *usize) void {
    switch (value) {
        .object => |object| {
            if (objectString(object, "ProductId")) |product_id| {
                if (findString(value, "ProductTitle")) |name| {
                    for (titles) |*title| {
                        if (std.mem.eql(u8, cString(&title.product_id), product_id) and
                            writeDisplayCString(&title.name, name))
                        {
                            applied.* += 1;
                            break;
                        }
                    }
                }
            }
            var iterator = object.iterator();
            while (iterator.next()) |entry|
                applyMetadata(entry.value_ptr.*, titles, applied);
        },
        .array => |array| {
            for (array.items) |item| applyMetadata(item, titles, applied);
        },
        else => {},
    }
}

pub fn parseTitles(data: []const u8, titles: []Title) !usize {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, data, .{});
    defer parsed.deinit();
    var count: usize = 0;
    collectTitles(parsed.value, titles, &count);
    return count;
}

pub fn parseMetadata(data: []const u8, titles: []Title) !usize {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, data, .{});
    defer parsed.deinit();
    var applied: usize = 0;
    applyMetadata(parsed.value, titles, &applied);
    return applied;
}

export fn go_catalog_parse_titles(data: [*]const u8, length: usize, titles: [*]Title, capacity: usize) c_int {
    const count = parseTitles(data[0..length], titles[0..capacity]) catch |err| {
        std.debug.print("Catalog JSON parse failed: {s}\n", .{@errorName(err)});
        return -1;
    };
    return @intCast(count);
}

export fn go_catalog_apply_metadata(data: [*]const u8, length: usize, titles: [*]Title, count: usize) c_int {
    const applied = parseMetadata(data[0..length], titles[0..count]) catch |err| {
        std.debug.print("Catalog metadata JSON parse failed: {s}\n", .{@errorName(err)});
        return -1;
    };
    return @intCast(applied);
}

test "catalog parsing accepts entitlement and subscription membership" {
    const fixture =
        \\{
        \\  "results": [
        \\    {"titleId":"DIRECT","details":{"productId":"P1","hasEntitlement":true}},
        \\    {"titleId":"PROGRAM","productId":"P2","catalog":{"programs":["XGPU","OTHER"]},"account":{"userSubscriptions":["XGPU"]}},
        \\    {"titleId":"LOCKED","productId":"P3","programs":["OTHER"],"userSubscriptions":["XGPU"]}
        \\  ]
        \\}
    ;
    var titles = std.mem.zeroes([4]Title);
    const count = try parseTitles(fixture, &titles);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("DIRECT", cString(&titles[0].title_id));
    try std.testing.expectEqualStrings("P1", cString(&titles[0].product_id));
    try std.testing.expectEqualStrings("PROGRAM", cString(&titles[1].title_id));
}

test "catalog parsing is bounded and rejects malformed JSON" {
    var titles = std.mem.zeroes([1]Title);
    const fixture =
        \\[{"titleId":"ONE","hasEntitlement":true},{"titleId":"TWO","hasEntitlement":true}]
    ;
    try std.testing.expectEqual(@as(usize, 1), try parseTitles(fixture, &titles));
    try std.testing.expectError(error.UnexpectedEndOfInput, parseTitles("{", &titles));
}

test "metadata parsing follows nested localized properties" {
    var titles = std.mem.zeroes([2]Title);
    try std.testing.expect(writeCString(&titles[0].product_id, "P1"));
    try std.testing.expect(writeCString(&titles[1].product_id, "P2"));
    const fixture =
        \\{"Products":[
        \\  {"ProductId":"P1","LocalizedProperties":[{"ProductTitle":"Hollow Knight"}]},
        \\  {"ProductId":"P2","LocalizedProperties":[{"ProductTitle":"Café\nRacer"}]}
        \\]}
    ;
    try std.testing.expectEqual(@as(usize, 2), try parseMetadata(fixture, &titles));
    try std.testing.expectEqualStrings("Hollow Knight", cString(&titles[0].name));
    try std.testing.expectEqualStrings("Caf? Racer", cString(&titles[1].name));
}
