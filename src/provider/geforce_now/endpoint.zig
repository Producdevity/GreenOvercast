const std = @import("std");

pub fn normalizeCloudMatchBase(
    allocator: std.mem.Allocator,
    url: []const u8,
) ![]u8 {
    const parsed = std.Uri.parse(url) catch return error.UntrustedCloudMatchUrl;
    if (!std.ascii.eqlIgnoreCase(parsed.scheme, "https") or
        parsed.user != null or parsed.password != null or
        (parsed.port != null and parsed.port.? != 443) or
        parsed.query != null or parsed.fragment != null)
        return error.UntrustedCloudMatchUrl;

    const host = componentBytes(parsed.host orelse return error.UntrustedCloudMatchUrl) orelse
        return error.UntrustedCloudMatchUrl;
    const path = componentBytes(parsed.path) orelse return error.UntrustedCloudMatchUrl;
    if ((path.len != 0 and !std.mem.eql(u8, path, "/")) or !trustedHost(host))
        return error.UntrustedCloudMatchUrl;

    return if (std.mem.endsWith(u8, url, "/"))
        allocator.dupe(u8, url)
    else
        std.fmt.allocPrint(allocator, "{s}/", .{url});
}

fn trustedHost(host: []const u8) bool {
    const root = "nvidiagrid.net";
    return std.ascii.eqlIgnoreCase(host, root) or
        (host.len > root.len and host[host.len - root.len - 1] == '.' and
            std.ascii.endsWithIgnoreCase(host, root));
}

fn componentBytes(component: std.Uri.Component) ?[]const u8 {
    return switch (component) {
        .raw => |value| value,
        .percent_encoded => |value| if (std.mem.indexOfScalar(u8, value, '%') == null) value else null,
    };
}

test "normalizes trusted CloudMatch endpoints" {
    const normalized = try normalizeCloudMatchBase(
        std.testing.allocator,
        "https://np-ams-06.cloudmatchbeta.nvidiagrid.net",
    );
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings(
        "https://np-ams-06.cloudmatchbeta.nvidiagrid.net/",
        normalized,
    );
}

test "rejects endpoints that could receive an account token" {
    for ([_][]const u8{
        "http://prod.cloudmatchbeta.nvidiagrid.net",
        "https://example.invalid",
        "https://user@prod.cloudmatchbeta.nvidiagrid.net",
        "https://prod.cloudmatchbeta.nvidiagrid.net/path",
        "https://prod.cloudmatchbeta.nvidiagrid.net/?query=1",
    }) |url| {
        try std.testing.expectError(
            error.UntrustedCloudMatchUrl,
            normalizeCloudMatchBase(std.testing.allocator, url),
        );
    }
}
