const std = @import("std");
const catalog = @import("catalog_parser");

pub const endpoint = "https://games.geforce.com/graphql";
pub const page_size: u32 = 200;

const LibraryFilters = struct {
    variants: struct {
        gfn: struct {
            library: struct {
                status: struct {
                    notEquals: []const u8,
                },
            },
        },
    },
};

const library_filters = LibraryFilters{
    .variants = .{
        .gfn = .{
            .library = .{
                .status = .{ .notEquals = "NOT_OWNED" },
            },
        },
    },
};

const query =
    \\query GetCatalogApps($vpcId:String!,$locale:String!,$sortString:String!,$fetchCount:Int!,$cursor:String!,$filters:AppFilterFields!){
    \\  apps(vpcId:$vpcId,language:$locale,orderBy:$sortString,first:$fetchCount,after:$cursor,filters:$filters){
    \\    items{id title variants{id appStore gfn{status library{status selected}}} images{GAME_BOX_ART KEY_IMAGE KEY_ART}}
    \\    pageInfo{hasNextPage endCursor totalCount}
    \\  }
    \\}
;

pub const Page = struct {
    allocator: std.mem.Allocator,
    titles: []catalog.Title,
    next_cursor: ?[]u8,
    total_count: ?usize,

    pub fn deinit(self: *Page) void {
        self.allocator.free(self.titles);
        if (self.next_cursor) |cursor| self.allocator.free(cursor);
        self.* = undefined;
    }
};

pub fn buildRequest(
    allocator: std.mem.Allocator,
    vpc_id: []const u8,
    cursor: []const u8,
) ![]u8 {
    if (vpc_id.len == 0) return error.InvalidVpcId;
    return std.json.stringifyAlloc(allocator, .{
        .query = query,
        .variables = .{
            .vpcId = vpc_id,
            .locale = "en_US",
            .sortString = "variants.gfn.library.lastPlayedDate:DESC,computedValues.libraryAddedDate:DESC,sortName:ASC",
            .fetchCount = page_size,
            .cursor = cursor,
            .filters = library_filters,
        },
    }, .{});
}

pub fn parsePage(allocator: std.mem.Allocator, data: []const u8) !Page {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    const root = try object(parsed.value);
    if (root.get("errors")) |errors| {
        const values = try array(errors);
        if (values.items.len > 0) return error.GraphQlRejected;
    }
    const response_data = try object(root.get("data") orelse return error.MissingData);
    const apps = try object(response_data.get("apps") orelse return error.MissingApps);
    const items = try array(apps.get("items") orelse return error.MissingItems);

    var titles = std.ArrayList(catalog.Title).init(allocator);
    errdefer titles.deinit();
    for (items.items) |value| {
        const item = object(value) catch continue;
        const name = optionalString(item, "title") catch continue orelse continue;
        var title = std.mem.zeroes(catalog.Title);
        const launch_id = launchId(item) catch continue orelse continue;
        if (!writeIdentifier(&title.title_id, launch_id)) continue;
        if (item.get("id")) |stable_id| {
            if (!writeIdentifier(&title.product_id, stable_id))
                _ = catalog.writeCString(&title.product_id, catalog.cString(&title.title_id));
        } else {
            _ = catalog.writeCString(&title.product_id, catalog.cString(&title.title_id));
        }
        _ = catalog.writeDisplayCString(&title.name, name);
        if (artworkUrl(item)) |url| _ = writeArtwork(&title.artwork_url, url);
        try titles.append(title);
    }

    var next_cursor: ?[]u8 = null;
    var total_count: ?usize = null;
    if (apps.get("pageInfo")) |page_info_value| {
        const page_info = try object(page_info_value);
        total_count = optionalUnsigned(page_info, "totalCount");
        if (optionalBool(page_info, "hasNextPage") orelse false) {
            if (try optionalString(page_info, "endCursor")) |cursor| {
                if (cursor.len > 0) next_cursor = try allocator.dupe(u8, cursor);
            }
        }
    }
    errdefer if (next_cursor) |cursor| allocator.free(cursor);

    return .{
        .allocator = allocator,
        .titles = try titles.toOwnedSlice(),
        .next_cursor = next_cursor,
        .total_count = total_count,
    };
}

pub fn writeErrorSummary(
    allocator: std.mem.Allocator,
    data: []const u8,
    output: []u8,
) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return null;
    defer parsed.deinit();
    const root = object(parsed.value) catch return null;
    const errors = array(root.get("errors") orelse return null) catch return null;
    if (errors.items.len == 0) return null;
    const first = object(errors.items[0]) catch return null;
    const message = (optionalString(first, "message") catch return null) orelse return null;
    const length = @min(message.len, output.len);
    for (message[0..length], 0..) |byte, index| {
        output[index] = if (byte >= 0x20 and byte != 0x7f) byte else ' ';
    }
    return output[0..length];
}

fn launchId(item: std.json.ObjectMap) !?std.json.Value {
    if (item.get("variants")) |variants_value| {
        const variants = try array(variants_value);
        for (variants.items) |variant_value| {
            const variant = object(variant_value) catch continue;
            const value = variant.get("id") orelse continue;
            if (numericIdentifier(value) and selectedOwnedLibraryVariant(variant)) return value;
        }
        for (variants.items) |variant_value| {
            const variant = object(variant_value) catch continue;
            const value = variant.get("id") orelse continue;
            if (numericIdentifier(value) and ownedLibraryVariant(variant)) return value;
        }
    }
    return null;
}

fn selectedOwnedLibraryVariant(variant: std.json.ObjectMap) bool {
    const gfn = object(variant.get("gfn") orelse return false) catch return false;
    const library = object(gfn.get("library") orelse return false) catch return false;
    return (optionalBool(library, "selected") orelse false) and ownedLibraryStatus(library);
}

fn ownedLibraryVariant(variant: std.json.ObjectMap) bool {
    const gfn = object(variant.get("gfn") orelse return false) catch return false;
    const library = object(gfn.get("library") orelse return false) catch return false;
    return ownedLibraryStatus(library);
}

fn ownedLibraryStatus(library: std.json.ObjectMap) bool {
    const status = (optionalString(library, "status") catch return false) orelse return false;
    return std.mem.eql(u8, status, "MANUAL") or
        std.mem.eql(u8, status, "PLATFORM_SYNC") or
        std.mem.eql(u8, status, "IN_LIBRARY");
}

fn artworkUrl(item: std.json.ObjectMap) ?[]const u8 {
    const images = object(item.get("images") orelse return null) catch return null;
    for ([_][]const u8{ "GAME_BOX_ART", "KEY_IMAGE", "KEY_ART" }) |key| {
        const value = images.get(key) orelse continue;
        switch (value) {
            .string => |text| if (text.len > 0) return text,
            .array => |values| if (values.items.len > 0) switch (values.items[0]) {
                .string => |text| if (text.len > 0) return text,
                else => {},
            },
            else => {},
        }
    }
    return null;
}

fn writeArtwork(output: []u8, url: []const u8) bool {
    if (!std.mem.startsWith(u8, url, "https://")) return false;
    const suffix = if (std.mem.indexOf(u8, url, "img.nvidiagrid.net") != null)
        ";f=jpeg;w=256"
    else
        "";
    if (url.len + suffix.len >= output.len) return false;
    @memset(output, 0);
    @memcpy(output[0..url.len], url);
    @memcpy(output[url.len..][0..suffix.len], suffix);
    return true;
}

fn numericIdentifier(value: std.json.Value) bool {
    return switch (value) {
        .integer => |number| number >= 0,
        .string => |text| numeric: {
            if (text.len == 0) break :numeric false;
            for (text) |byte| if (!std.ascii.isDigit(byte)) break :numeric false;
            break :numeric true;
        },
        else => false,
    };
}

fn writeIdentifier(output: []u8, value: std.json.Value) bool {
    return switch (value) {
        .string => |text| catalog.writeCString(output, text),
        .integer => |number| if (number >= 0) blk: {
            var buffer: [32]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "{d}", .{number}) catch break :blk false;
            break :blk catalog.writeCString(output, text);
        } else false,
        else => false,
    };
}

fn object(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |result| result,
        else => error.ExpectedObject,
    };
}

fn array(value: std.json.Value) !std.json.Array {
    return switch (value) {
        .array => |result| result,
        else => error.ExpectedArray,
    };
}

fn optionalString(value: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const field = value.get(key) orelse return null;
    return switch (field) {
        .string => |text| if (text.len > 0) text else null,
        .null => null,
        else => error.InvalidField,
    };
}

fn optionalUnsigned(value: std.json.ObjectMap, key: []const u8) ?usize {
    const field = value.get(key) orelse return null;
    return switch (field) {
        .integer => |number| if (number >= 0 and number <= std.math.maxInt(usize)) @intCast(number) else null,
        else => null,
    };
}

fn optionalBool(value: std.json.ObjectMap, key: []const u8) ?bool {
    const field = value.get(key) orelse return null;
    return switch (field) {
        .bool => |enabled| enabled,
        else => null,
    };
}

test "builds a paged catalog request" {
    const request = try buildRequest(std.testing.allocator, "GFN-PC", "cursor/value");
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"vpcId\":\"GFN-PC\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"cursor\":\"cursor/value\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"notEquals\":\"NOT_OWNED\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "GAME_BOX_ART") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "library{status selected}") != null);
}

test "parses launch variants artwork and pagination" {
    var page = try parsePage(std.testing.allocator,
        \\{"data":{"apps":{"items":[
        \\  {"id":"game-one","title":"Fixture Racer","variants":[{"id":"variant-name"},{"id":"202","gfn":{"library":{"status":"MANUAL"}}}],"images":{"GAME_BOX_ART":"https://img.nvidiagrid.net/box"}},
        \\  {"id":303,"title":"Second Game","variants":[{"id":303,"gfn":{"library":{"status":"IN_LIBRARY"}}}],"images":{"KEY_IMAGE":["https://example.invalid/key.jpg"]}}
        \\],"pageInfo":{"hasNextPage":true,"endCursor":"next","totalCount":402}}}}
    );
    defer page.deinit();

    try std.testing.expectEqual(@as(usize, 2), page.titles.len);
    try std.testing.expectEqualStrings("202", catalog.cString(&page.titles[0].title_id));
    try std.testing.expectEqualStrings("game-one", catalog.cString(&page.titles[0].product_id));
    try std.testing.expectEqualStrings("Fixture Racer", catalog.cString(&page.titles[0].name));
    try std.testing.expectEqualStrings(
        "https://img.nvidiagrid.net/box;f=jpeg;w=256",
        catalog.cString(&page.titles[0].artwork_url),
    );
    try std.testing.expectEqualStrings("303", catalog.cString(&page.titles[1].title_id));
    try std.testing.expectEqualStrings("next", page.next_cursor.?);
    try std.testing.expectEqual(@as(?usize, 402), page.total_count);
}

test "prefers the account-selected numeric launch variant" {
    var page = try parsePage(std.testing.allocator,
        \\{"data":{"apps":{"items":[
        \\  {"id":"game-one","title":"Fixture Racer","variants":[
        \\    {"id":"202","appStore":"STEAM","gfn":{"library":{"status":"NOT_OWNED","selected":false}}},
        \\    {"id":"303","appStore":"EPIC","gfn":{"library":{"status":"MANUAL","selected":true}}}
        \\  ]}
        \\],"pageInfo":{"hasNextPage":false}}}}
    );
    defer page.deinit();
    try std.testing.expectEqualStrings("303", catalog.cString(&page.titles[0].title_id));
}

test "does not launch an unowned selected store variant" {
    var page = try parsePage(std.testing.allocator,
        \\{"data":{"apps":{"items":[
        \\  {"id":"game-one","title":"Fixture Racer","variants":[
        \\    {"id":"202","appStore":"STEAM","gfn":{"library":{"status":"NOT_OWNED","selected":true}}},
        \\    {"id":"303","appStore":"XBOX","gfn":{"library":{"status":"PLATFORM_SYNC","selected":false}}}
        \\  ]}
        \\],"pageInfo":{"hasNextPage":false}}}}
    );
    defer page.deinit();
    try std.testing.expectEqualStrings("303", catalog.cString(&page.titles[0].title_id));
}

test "rejects GraphQL errors" {
    try std.testing.expectError(
        error.GraphQlRejected,
        parsePage(std.testing.allocator, "{\"errors\":[{\"message\":\"bad\"}]}"),
    );
}

test "does not infer library ownership from a numeric id or missing status" {
    var page = try parsePage(std.testing.allocator,
        \\{"data":{"apps":{"items":[
        \\  {"id":101,"title":"Unowned","variants":[{"id":101,"gfn":{"library":{"status":"NOT_OWNED","selected":true}}}]},
        \\  {"id":202,"title":"Unknown","variants":[{"id":202,"gfn":{"library":{"selected":true}}}]},
        \\  {"id":303,"title":"No variants","variants":[]},
        \\  {"id":404,"title":"Invalid launch id","variants":[{"id":"not-numeric","gfn":{"library":{"status":"MANUAL"}}}]}
        \\],"pageInfo":{"hasNextPage":false}}}}
    );
    defer page.deinit();
    try std.testing.expectEqual(@as(usize, 0), page.titles.len);
}

test "writes a bounded single-line GraphQL error" {
    var output: [18]u8 = undefined;
    const summary = writeErrorSummary(
        std.testing.allocator,
        "{\"errors\":[{\"message\":\"Invalid query\\nwith details\"}]}",
        &output,
    ).?;
    try std.testing.expectEqualStrings("Invalid query with", summary);
}
