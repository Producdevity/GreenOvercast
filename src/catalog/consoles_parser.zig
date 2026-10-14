const std = @import("std");

// Field shapes verified against GET /v6/servers/home responses as consumed
// by xbox-xcloud-player (unknownskl) - see ConsolesResponse/Console there.
pub const device_name_capacity = 128;
pub const server_id_capacity = 64;
pub const power_state_capacity = 32;
pub const console_type_capacity = 32;
pub const play_path_capacity = 192;

pub const Console = extern struct {
    device_name: [device_name_capacity]u8,
    server_id: [server_id_capacity]u8,
    power_state: [power_state_capacity]u8,
    console_type: [console_type_capacity]u8,
    play_path: [play_path_capacity]u8,
    out_of_home_warning: bool,
    wireless_warning: bool,
};

pub fn cString(bytes: []const u8) []const u8 {
    return bytes[0 .. std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len];
}

fn writeCString(destination: []u8, text: []const u8) bool {
    if (text.len == 0 or text.len >= destination.len) return false;
    @memset(destination, 0);
    @memcpy(destination[0..text.len], text);
    return true;
}

fn objectString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn objectBool(object: std.json.ObjectMap, key: []const u8) bool {
    const value = object.get(key) orelse return false;
    return switch (value) {
        .bool => |flag| flag,
        else => false,
    };
}

fn parseConsole(object: std.json.ObjectMap) ?Console {
    const server_id = objectString(object, "serverId") orelse return null;
    if (server_id.len == 0) return null;
    var console = std.mem.zeroes(Console);
    if (!writeCString(&console.server_id, server_id)) return null;
    if (objectString(object, "deviceName")) |value| _ = writeCString(&console.device_name, value);
    if (objectString(object, "powerState")) |value| _ = writeCString(&console.power_state, value);
    if (objectString(object, "consoleType")) |value| _ = writeCString(&console.console_type, value);
    if (objectString(object, "playPath")) |value| _ = writeCString(&console.play_path, value);
    console.out_of_home_warning = objectBool(object, "outOfHomeWarning");
    console.wireless_warning = objectBool(object, "wirelessWarning");
    return console;
}

pub fn parseConsoles(data: []const u8, consoles: []Console) !usize {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, data, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.MissingField,
    };
    const results = switch (root.get("results") orelse return error.MissingField) {
        .array => |array| array.items,
        else => return error.MissingField,
    };
    var count: usize = 0;
    for (results) |item| {
        if (count >= consoles.len) break;
        const object = switch (item) {
            .object => |value| value,
            else => continue,
        };
        if (parseConsole(object)) |console| {
            consoles[count] = console;
            count += 1;
        }
    }
    return count;
}

export fn go_consoles_parse(data: [*]const u8, length: usize, consoles: [*]Console, capacity: usize) c_int {
    const count = parseConsoles(data[0..length], consoles[0..capacity]) catch |err| {
        std.debug.print("Consoles JSON parse failed: {s}\n", .{@errorName(err)});
        return -1;
    };
    return @intCast(count);
}

test "parses consoles and skips entries without a serverId" {
    const fixture =
        \\{"totalItems":2,"results":[
        \\  {"deviceName":"Living Room","serverId":"abc-123","powerState":"On",
        \\   "consoleType":"XboxSeriesX","playPath":"/v5/sessions/home/play",
        \\   "outOfHomeWarning":false,"wirelessWarning":true,"isDevKit":false},
        \\  {"deviceName":"No id","powerState":"Off"}
        \\],"continuationToken":null}
    ;
    var consoles = std.mem.zeroes([4]Console);
    const count = try parseConsoles(fixture, &consoles);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("Living Room", cString(&consoles[0].device_name));
    try std.testing.expectEqualStrings("abc-123", cString(&consoles[0].server_id));
    try std.testing.expectEqualStrings("On", cString(&consoles[0].power_state));
    try std.testing.expectEqualStrings("XboxSeriesX", cString(&consoles[0].console_type));
    try std.testing.expect(!consoles[0].out_of_home_warning);
    try std.testing.expect(consoles[0].wireless_warning);
}

test "console parsing is bounded and rejects malformed JSON" {
    var consoles = std.mem.zeroes([1]Console);
    const fixture =
        \\{"results":[{"serverId":"one"},{"serverId":"two"}]}
    ;
    try std.testing.expectEqual(@as(usize, 1), try parseConsoles(fixture, &consoles));
    try std.testing.expectError(error.UnexpectedEndOfInput, parseConsoles("{", &consoles));
    try std.testing.expectError(error.MissingField, parseConsoles("{}", &consoles));
}
