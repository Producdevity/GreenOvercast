const std = @import("std");

const normalized_capacity = 256;

fn normalize(input: []const u8, output: []u8) ?[]const u8 {
    var length: usize = 0;
    for (input) |byte| {
        if (!std.ascii.isAlphanumeric(byte)) continue;
        if (length == output.len) return null;
        output[length] = std.ascii.toUpper(byte);
        length += 1;
    }
    return output[0..length];
}

pub fn matches(title: []const u8, query: []const u8) bool {
    var normalized_title_storage: [normalized_capacity]u8 = undefined;
    var normalized_query_storage: [normalized_capacity]u8 = undefined;
    const normalized_title = normalize(title, &normalized_title_storage) orelse return false;
    const normalized_query = normalize(query, &normalized_query_storage) orelse return false;
    return normalized_query.len == 0 or
        std.mem.indexOf(u8, normalized_title, normalized_query) != null;
}

test "search is case insensitive and ignores title separators" {
    try std.testing.expect(matches("Hollow Knight: Voidheart Edition", "hollowk"));
    try std.testing.expect(matches("Forza Horizon 5", "HORIZON5"));
    try std.testing.expect(matches("33 Immortals", "33"));
}

test "search rejects non-matching text" {
    try std.testing.expect(!matches("Hollow Knight", "silksong"));
    try std.testing.expect(!matches("Forza Horizon 5", "horizon4"));
}

test "an empty search includes every title" {
    try std.testing.expect(matches("Any Game", ""));
}

test "normalization is bounded" {
    var output: [3]u8 = undefined;
    try std.testing.expectEqualStrings("ABC", normalize("A-b c", &output).?);
    try std.testing.expect(normalize("ABCD", &output) == null);
}
