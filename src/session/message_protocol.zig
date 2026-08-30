const std = @import("std");

const disconnect_target = "/streaming/sessionLifetimeManagement/serverInitiatedDisconnect";

pub fn buildDisconnectAck(message: []const u8, output: []u8) !?usize {
    const json = std.mem.trimRight(u8, message, "\x00");
    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, json, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return null,
    };
    const target = switch (object.get("target") orelse return null) {
        .string => |value| value,
        else => return null,
    };
    if (!std.mem.eql(u8, target, disconnect_target)) return null;
    const id = switch (object.get("id") orelse return error.MissingTransactionId) {
        .string => |value| value,
        else => return error.MissingTransactionId,
    };
    if (id.len == 0) return error.MissingTransactionId;

    var stream = std.io.fixedBufferStream(output);
    const writer = stream.writer();
    try writer.writeAll("{\"type\":\"TransactionComplete\",\"content\":\"\\\"\\\"\",\"id\":");
    try std.json.encodeJsonString(id, .{}, writer);
    try writer.writeAll(",\"cv\":\"\"}");
    if (stream.pos >= output.len) return error.NoSpaceLeft;
    output[stream.pos] = 0;
    return stream.pos;
}

test "builds the disconnect transaction acknowledgement" {
    const message =
        "{\"type\":\"TransactionStart\",\"target\":\"/streaming/sessionLifetimeManagement/" ++
        "serverInitiatedDisconnect\",\"id\":\"quit-\\\"1\",\"content\":\"\"}\x00";
    var output: [512]u8 = undefined;
    const length = (try buildDisconnectAck(message, &output)).?;
    try std.testing.expectEqualStrings(
        "{\"type\":\"TransactionComplete\",\"content\":\"\\\"\\\"\",\"id\":\"quit-\\\"1\",\"cv\":\"\"}",
        output[0..length],
    );
    try std.testing.expectEqual(@as(u8, 0), output[length]);
}

test "ignores unrelated messages and rejects missing ids" {
    var output: [256]u8 = undefined;
    try std.testing.expect((try buildDisconnectAck("{\"target\":\"other\"}", &output)) == null);
    try std.testing.expectError(
        error.MissingTransactionId,
        buildDisconnectAck(
            "{\"target\":\"/streaming/sessionLifetimeManagement/serverInitiatedDisconnect\"}",
            &output,
        ),
    );
}
