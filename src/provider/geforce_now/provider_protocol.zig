const std = @import("std");
const endpoint_rules = @import("endpoint.zig");

pub const service_urls_endpoint = "https://pcs.geforcenow.com/v1/serviceUrls";

pub const Provider = struct {
    allocator: std.mem.Allocator,
    code: []u8,
    display_name: []u8,
    idp_id: []u8,
    streaming_url: []u8,

    pub fn deinit(self: *Provider) void {
        self.allocator.free(self.code);
        self.allocator.free(self.display_name);
        self.allocator.free(self.idp_id);
        self.allocator.free(self.streaming_url);
        self.* = undefined;
    }
};

pub fn parsePreferredProvider(allocator: std.mem.Allocator, data: []const u8) !Provider {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    const root = try object(parsed.value);
    const info = try object(root.get("gfnServiceInfo") orelse return error.MissingServiceInfo);
    const endpoints = try array(info.get("gfnServiceEndpoints") orelse return error.MissingEndpoints);
    if (endpoints.items.len == 0) return error.MissingEndpoints;

    const default_code = optionalString(info, "defaultProvider") catch null;
    var selected: ?std.json.ObjectMap = null;
    if (default_code) |preferred| {
        for (endpoints.items) |entry| {
            const endpoint = object(entry) catch continue;
            const code = optionalString(endpoint, "loginProviderCode") catch continue;
            if (code != null and std.ascii.eqlIgnoreCase(code.?, preferred)) {
                selected = endpoint;
                break;
            }
        }
    }
    const provider_entry = selected orelse try object(endpoints.items[0]);

    const code = try allocator.dupe(u8, try requiredString(provider_entry, "loginProviderCode"));
    errdefer allocator.free(code);
    const display_name = try allocator.dupe(u8, try requiredString(provider_entry, "loginProviderDisplayName"));
    errdefer allocator.free(display_name);
    const idp_id = try allocator.dupe(u8, try requiredString(provider_entry, "idpId"));
    errdefer allocator.free(idp_id);
    const raw_url = try requiredString(provider_entry, "streamingServiceUrl");
    const streaming_url = try endpoint_rules.normalizeCloudMatchBase(allocator, raw_url);
    errdefer allocator.free(streaming_url);

    return .{
        .allocator = allocator,
        .code = code,
        .display_name = display_name,
        .idp_id = idp_id,
        .streaming_url = streaming_url,
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

fn requiredString(value: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return (try optionalString(value, key)) orelse error.MissingField;
}

fn optionalString(value: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const field = value.get(key) orelse return null;
    return switch (field) {
        .string => |text| if (text.len > 0) text else null,
        .null => null,
        else => error.InvalidField,
    };
}

test "selects the advertised default provider" {
    var provider = try parsePreferredProvider(std.testing.allocator,
        \\{
        \\  "gfnServiceInfo": {
        \\    "defaultProvider": "BPC",
        \\    "gfnServiceEndpoints": [
        \\      {"loginProviderCode":"NVIDIA","loginProviderDisplayName":"NVIDIA","idpId":"one","streamingServiceUrl":"https://one.cloudmatchbeta.nvidiagrid.net/"},
        \\      {"loginProviderCode":"BPC","loginProviderDisplayName":"bro.game","idpId":"two","streamingServiceUrl":"https://two.cloudmatchbeta.nvidiagrid.net"}
        \\    ]
        \\  }
        \\}
    );
    defer provider.deinit();

    try std.testing.expectEqualStrings("BPC", provider.code);
    try std.testing.expectEqualStrings("bro.game", provider.display_name);
    try std.testing.expectEqualStrings("two", provider.idp_id);
    try std.testing.expectEqualStrings("https://two.cloudmatchbeta.nvidiagrid.net/", provider.streaming_url);
}

test "falls back to the first provider" {
    var provider = try parsePreferredProvider(std.testing.allocator,
        \\{"gfnServiceInfo":{"gfnServiceEndpoints":[{"loginProviderCode":"NVIDIA","loginProviderDisplayName":"NVIDIA","idpId":"idp","streamingServiceUrl":"https://prod.cloudmatchbeta.nvidiagrid.net/"}]}}
    );
    defer provider.deinit();
    try std.testing.expectEqualStrings("NVIDIA", provider.code);
}

test "rejects an untrusted streaming service endpoint" {
    try std.testing.expectError(
        error.UntrustedCloudMatchUrl,
        parsePreferredProvider(std.testing.allocator,
            \\{"gfnServiceInfo":{"gfnServiceEndpoints":[{"loginProviderCode":"NVIDIA","loginProviderDisplayName":"NVIDIA","idpId":"idp","streamingServiceUrl":"https://example.invalid/"}]}}
        ),
    );
}

test "rejects an empty provider list" {
    try std.testing.expectError(
        error.MissingEndpoints,
        parsePreferredProvider(std.testing.allocator,
            \\{"gfnServiceInfo":{"gfnServiceEndpoints":[]}}
        ),
    );
}
