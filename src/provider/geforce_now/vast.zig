const std = @import("std");
const xml = @import("xml_document");

pub const Track = struct {
    event: []const u8,
    url: []const u8,
    offset_ms: ?u64 = null,
    offset_percent: ?u8 = null,
};
pub const Position = union(enum) { start, end, pixel: u16 };
pub const Media = struct { url: []const u8, width: u16, height: u16, bitrate: u32 };
pub const max_fallback_width = 1920;
pub const max_fallback_height = 1080;
pub const Icon = struct {
    program: []const u8,
    image: []const u8,
    fallback: ?[]const u8,
    click_through: ?[]const u8,
    views: []const []const u8,
    clicks: []const []const u8,
    offset_ms: u64,
    duration_ms: ?u64,
    width: u16,
    height: u16,
    x: Position,
    y: Position,
    fallback_width: u16 = 0,
    fallback_height: u16 = 0,
};
pub const Creative = struct {
    duration_ms: u64,
    media: []const Media,
    tracks: []const Track,
    icons: []const Icon,
};
pub const Ad = struct {
    sequence: ?u32,
    impressions: []const []const u8,
    errors: []const []const u8,
    tracks: []const Track = &.{},
    icons: []const Icon = &.{},
    verification_errors: []const []const u8 = &.{},
    body: union(enum) { inline_ad: Creative, wrapper: Wrapper },
};
pub const Wrapper = struct {
    url: []const u8,
    follow_wrappers: bool,
    allow_multiple: bool,
    fallback_on_no_ad: bool,
};
pub const Manifest = struct {
    document: xml.Document,
    ads: []const Ad,
    errors: []const []const u8,

    pub fn deinit(self: *Manifest) void {
        self.document.deinit();
    }
};

pub fn duration(input: []const u8) !u64 {
    var fields = std.mem.splitScalar(u8, input, ':');
    const hours = std.fmt.parseUnsigned(u64, fields.next() orelse return error.InvalidDuration, 10) catch return error.InvalidDuration;
    const minutes = std.fmt.parseUnsigned(u64, fields.next() orelse return error.InvalidDuration, 10) catch return error.InvalidDuration;
    var seconds = std.mem.splitScalar(u8, fields.next() orelse return error.InvalidDuration, '.');
    const whole = std.fmt.parseUnsigned(u64, seconds.next().?, 10) catch return error.InvalidDuration;
    if (minutes >= 60 or whole >= 60 or hours > 1 or fields.next() != null) return error.InvalidDuration;
    var fraction: u64 = 0;
    if (seconds.next()) |decimal| {
        if (decimal.len == 0 or decimal.len > 3 or seconds.next() != null) return error.InvalidDuration;
        fraction = std.fmt.parseUnsigned(u64, decimal, 10) catch return error.InvalidDuration;
        for (decimal.len..3) |_| fraction *= 10;
    }
    return (hours * 3600 + minutes * 60 + whole) * 1000 + fraction;
}

pub fn validateUrl(address: []const u8) !void {
    if (address.len == 0 or address.len > 8192) return error.InvalidAdUrl;
    for (address) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidAdUrl;
    const uri = std.Uri.parse(address) catch return error.InvalidAdUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https") or uri.host == null or
        uri.user != null or uri.password != null or uri.fragment != null or
        (uri.port != null and uri.port.? != 443)) return error.InvalidAdUrl;
}

fn url(node: *const xml.Node) ![]const u8 {
    const result = node.content();
    try validateUrl(result);
    return result;
}

fn urls(allocator: std.mem.Allocator, node: *const xml.Node, name: []const u8) ![]const []const u8 {
    var result = std.ArrayList([]const u8).init(allocator);
    for (node.children.items) |child| if (std.mem.eql(u8, child.name, name)) {
        if (result.items.len == 64) return error.VastLimitExceeded;
        try result.append(try url(child));
    };
    return result.toOwnedSlice();
}

fn unsignedAttribute(comptime T: type, node: *const xml.Node, name: []const u8) !T {
    return std.fmt.parseUnsigned(T, node.attributes.get(name) orelse return error.MissingAttribute, 10);
}

fn parseIcon(allocator: std.mem.Allocator, node: *const xml.Node) !Icon {
    const image = node.child("StaticResource") orelse return error.UnsupportedIcon;
    const kind = image.attributes.get("creativeType") orelse return error.UnsupportedIcon;
    if (!std.mem.eql(u8, kind, "image/png") and !std.mem.eql(u8, kind, "image/jpeg")) return error.UnsupportedIcon;
    const clicks = node.child("IconClicks");
    var fallback: ?[]const u8 = null;
    var fallback_width: u16 = 0;
    var fallback_height: u16 = 0;
    const program = node.attributes.get("program") orelse "";
    var fallback_images = if (clicks) |click| click.child("IconClickFallbackImages") else null;
    if (fallback_images == null) {
        var ancestor: ?*const xml.Node = node.parent;
        while (ancestor) |content| : (ancestor = content.parent) {
            if (!std.mem.eql(u8, content.name, "InLine") and !std.mem.eql(u8, content.name, "Wrapper")) continue;
            if (content.child("Extensions")) |extensions| for (extensions.children.items) |extension| {
                if (!std.mem.eql(u8, extension.attributes.get("type") orelse "", "IconClickFallbackImages")) continue;
                for (extension.children.items) |images| {
                    if (std.mem.eql(u8, images.name, "IconClickFallbackImages") and
                        std.mem.eql(u8, images.attributes.get("program") orelse "", program)) fallback_images = images;
                }
            };
            break;
        }
    }
    if (fallback_images) |images| for (images.children.items) |candidate| {
        if (!std.mem.eql(u8, candidate.name, "IconClickFallbackImage")) continue;
        const resource = candidate.child("StaticResource") orelse continue;
        const resource_type = resource.attributes.get("creativeType") orelse continue;
        if (!std.mem.eql(u8, resource_type, "image/png") and !std.mem.eql(u8, resource_type, "image/jpeg")) continue;
        const width = try unsignedAttribute(u16, candidate, "width");
        const height = try unsignedAttribute(u16, candidate, "height");
        if (width == 0 or height == 0 or width > max_fallback_width or height > max_fallback_height) continue;
        if (fallback != null and @as(u32, width) * height >= @as(u32, fallback_width) * fallback_height) continue;
        fallback = try url(resource);
        fallback_width = width;
        fallback_height = height;
    };
    return .{
        .program = program,
        .image = try url(image),
        .fallback = fallback,
        .click_through = if (clicks) |click| if (click.child("IconClickThrough")) |target| try url(target) else null else null,
        .views = try urls(allocator, node, "IconViewTracking"),
        .clicks = if (clicks) |click| try urls(allocator, click, "IconClickTracking") else &.{},
        .offset_ms = if (node.attributes.get("offset")) |offset| try duration(offset) else 0,
        .duration_ms = if (node.attributes.get("duration")) |length| try duration(length) else null,
        .width = try unsignedAttribute(u16, node, "width"),
        .height = try unsignedAttribute(u16, node, "height"),
        .x = try position(node.attributes.get("xPosition") orelse "right"),
        .y = try position(node.attributes.get("yPosition") orelse "top"),
        .fallback_width = fallback_width,
        .fallback_height = fallback_height,
    };
}

fn position(value: []const u8) !Position {
    if (std.mem.eql(u8, value, "left") or std.mem.eql(u8, value, "top")) return .start;
    if (std.mem.eql(u8, value, "right") or std.mem.eql(u8, value, "bottom")) return .end;
    const pixel = try std.fmt.parseUnsigned(u16, value, 10);
    if (pixel > 4096) return error.InvalidIconPosition;
    return .{ .pixel = pixel };
}

fn parseTracks(allocator: std.mem.Allocator, node: *const xml.Node, duration_ms: ?u64) ![]const Track {
    var tracks = std.ArrayList(Track).init(allocator);
    if (node.child("TrackingEvents")) |events| for (events.children.items) |event| {
        if (!std.mem.eql(u8, event.name, "Tracking")) continue;
        if (tracks.items.len == 128) return error.VastLimitExceeded;
        const name = event.attributes.get("event") orelse return error.MissingEvent;
        var track = Track{ .event = name, .url = try url(event) };
        if (std.mem.eql(u8, name, "progress")) {
            const offset = event.attributes.get("offset") orelse return error.MissingOffset;
            if (std.mem.endsWith(u8, offset, "%")) {
                const percent = try std.fmt.parseUnsigned(u8, offset[0 .. offset.len - 1], 10);
                if (percent > 100) return error.InvalidOffset;
                if (duration_ms) |length| track.offset_ms = length * percent / 100 else track.offset_percent = percent;
            } else track.offset_ms = try duration(offset);
        }
        try tracks.append(track);
    };
    return tracks.toOwnedSlice();
}

fn parseIcons(allocator: std.mem.Allocator, node: *const xml.Node) ![]Icon {
    var icons = std.ArrayList(Icon).init(allocator);
    if (node.child("Icons")) |group| for (group.children.items) |icon| {
        if (!std.mem.eql(u8, icon.name, "Icon")) continue;
        if (icons.items.len == 8) return error.VastLimitExceeded;
        const parsed = try parseIcon(allocator, icon);
        if (parsed.width == 0 or parsed.height == 0 or parsed.width > 640 or parsed.height > 480) return error.UnsupportedIcon;
        try icons.append(parsed);
    };
    return icons.toOwnedSlice();
}

fn parseCreative(allocator: std.mem.Allocator, node: *const xml.Node) !Creative {
    const length = node.child("Duration") orelse return error.MissingDuration;
    const duration_ms = try duration(length.content());
    if (duration_ms == 0 or duration_ms > 120000) return error.InvalidDuration;
    const media_files = node.child("MediaFiles") orelse return error.MissingMedia;
    var media = std.ArrayList(Media).init(allocator);
    for (media_files.children.items) |file| {
        if (!std.mem.eql(u8, file.name, "MediaFile")) continue;
        const kind = file.attributes.get("type") orelse continue;
        const delivery = file.attributes.get("delivery") orelse continue;
        if (!std.mem.eql(u8, kind, "video/mp4") or !std.mem.eql(u8, delivery, "progressive")) continue;
        const width = try unsignedAttribute(u16, file, "width");
        const height = try unsignedAttribute(u16, file, "height");
        if (width == 0 or height == 0 or width > 1280 or height > 768) continue;
        if (media.items.len == 32) return error.VastLimitExceeded;
        try media.append(.{ .url = try url(file), .width = width, .height = height, .bitrate = unsignedAttribute(u32, file, "bitrate") catch 0 });
    }
    if (media.items.len == 0) return error.UnsupportedMedia;
    if (node.child("InteractiveCreativeFile") != null) return error.UnsupportedInteractiveAd;
    return .{ .duration_ms = duration_ms, .media = try media.toOwnedSlice(), .tracks = try parseTracks(allocator, node, duration_ms), .icons = try parseIcons(allocator, node) };
}

fn booleanAttribute(node: *const xml.Node, name: []const u8, default: bool) !bool {
    const value = node.attributes.get(name) orelse return default;
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1")) return true;
    if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "0")) return false;
    return error.InvalidWrapperAttribute;
}

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Manifest {
    var document = try xml.parse(allocator, bytes);
    errdefer document.deinit();
    if (!std.mem.eql(u8, document.root.name, "VAST")) return error.InvalidVastRoot;
    const storage = document.arena.allocator();
    var ads = std.ArrayList(Ad).init(storage);
    for (document.root.children.items) |node| {
        if (!std.mem.eql(u8, node.name, "Ad")) continue;
        if (ads.items.len == 16) return error.VastLimitExceeded;
        const content = node.child("InLine") orelse node.child("Wrapper") orelse return error.InvalidAd;
        if (node.child("InLine") != null and node.child("Wrapper") != null) return error.InvalidAd;
        const impressions = try urls(storage, content, "Impression");
        const errors = try urls(storage, content, "Error");
        var verification = std.ArrayList([]const u8).init(storage);
        if (content.child("AdVerifications")) |group| for (group.children.items) |entry| {
            if (entry.child("TrackingEvents")) |events| for (events.children.items) |event| {
                if (std.mem.eql(u8, event.attributes.get("event") orelse "", "verificationNotExecuted")) {
                    if (verification.items.len == 64) return error.VastLimitExceeded;
                    try verification.append(try url(event));
                }
            };
        };
        const verification_errors = try verification.toOwnedSlice();
        const sequence: ?u32 = if (node.attributes.get("sequence")) |value| try std.fmt.parseUnsigned(u32, value, 10) else null;
        if (sequence == 0) return error.InvalidAdSequence;
        if (sequence) |number| for (ads.items) |prior| {
            if (prior.sequence == number) return error.DuplicateAdSequence;
        };
        if (std.mem.eql(u8, content.name, "Wrapper")) {
            const destination = content.child("VASTAdTagURI") orelse return error.MissingWrapperUrl;
            var tracks: []const Track = &.{};
            var icons: []const Icon = &.{};
            if (content.child("Creatives")) |creatives| for (creatives.children.items) |creative| {
                if (creative.child("Linear")) |linear| {
                    tracks = try parseTracks(storage, linear, null);
                    icons = try parseIcons(storage, linear);
                    break;
                }
            };
            try ads.append(.{ .sequence = sequence, .impressions = impressions, .errors = errors, .tracks = tracks, .icons = icons, .verification_errors = verification_errors, .body = .{ .wrapper = .{ .url = try url(destination), .follow_wrappers = try booleanAttribute(content, "followAdditionalWrappers", true), .allow_multiple = try booleanAttribute(content, "allowMultipleAds", false), .fallback_on_no_ad = try booleanAttribute(content, "fallbackOnNoAd", false) } } });
            continue;
        }
        const creatives = content.child("Creatives") orelse return error.MissingCreative;
        var selected: ?Creative = null;
        for (creatives.children.items) |creative| {
            if (!std.mem.eql(u8, creative.name, "Creative")) continue;
            const linear = creative.child("Linear") orelse continue;
            if (selected != null) return error.MultipleLinearCreatives;
            selected = try parseCreative(storage, linear);
        }
        try ads.append(.{ .sequence = sequence, .impressions = impressions, .errors = errors, .verification_errors = verification_errors, .body = .{ .inline_ad = selected orelse return error.MissingLinearCreative } });
    }
    const errors = try urls(storage, document.root, "Error");
    std.mem.sort(Ad, ads.items, {}, struct {
        fn less(_: void, lhs: Ad, rhs: Ad) bool {
            return (lhs.sequence orelse std.math.maxInt(u32)) < (rhs.sequence orelse std.math.maxInt(u32));
        }
    }.less);
    return .{ .document = document, .ads = try ads.toOwnedSlice(), .errors = errors };
}

test "empty inventory, wrappers and inline MP4 metadata are distinct" {
    var empty = try parse(std.testing.allocator, "<VAST version=\"4.0\"/>");
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.ads.len);
    var wrapper = try parse(std.testing.allocator, "<VAST><Ad><Wrapper><Impression>https://example.invalid/view</Impression><VASTAdTagURI>https://example.invalid/tag</VASTAdTagURI></Wrapper></Ad></VAST>");
    defer wrapper.deinit();
    try std.testing.expectEqualStrings("https://example.invalid/tag", wrapper.ads[0].body.wrapper.url);
    var inline_ad = try parse(std.testing.allocator, "<VAST><Ad><InLine><Creatives><Creative><Linear><Duration>00:00:05.250</Duration><MediaFiles>" ++
        "<MediaFile type=\"video/mp4\" delivery=\"progressive\" width=\"640\" height=\"360\">https://example.invalid/ad.mp4</MediaFile>" ++
        "</MediaFiles><TrackingEvents><Tracking event=\"progress\" offset=\"25%\">https://example.invalid/progress</Tracking></TrackingEvents>" ++
        "</Linear></Creative></Creatives></InLine></Ad></VAST>");
    defer inline_ad.deinit();
    try std.testing.expectEqual(@as(u64, 5250), inline_ad.ads[0].body.inline_ad.duration_ms);
    try std.testing.expectEqual(@as(u64, 1312), inline_ad.ads[0].body.inline_ad.tracks[0].offset_ms.?);
}

test "malformed ads and dangerous URLs never become no-fill" {
    try std.testing.expectError(error.InvalidAd, parse(std.testing.allocator, "<VAST><Ad/></VAST>"));
    try std.testing.expectError(error.InvalidVastRoot, parse(std.testing.allocator, "<Error/>"));
    for ([_][]const u8{ "file:///tmp/video", "http://example.invalid/ad", "https://user:pass@example.invalid/ad", "https://example.invalid:444/ad" }) |value|
        try std.testing.expectError(error.InvalidAdUrl, validateUrl(value));
    try std.testing.expectEqual(@as(u64, 1250), try duration("00:00:01.25"));
    for ([_][]const u8{ "00:61:00", "00:00:61", "00:00:01.", "00:00:01.1234", "-1:00:00", "00:00:01:02" }) |value|
        try std.testing.expectError(error.InvalidDuration, duration(value));
}

test "VAST 3 AdChoices selects the smallest supported fallback for its program" {
    var manifest = try parse(std.testing.allocator, "<VAST version=\"3.0\"><Ad><InLine><Creatives><Creative><Linear><Duration>00:00:05</Duration>" ++
        "<MediaFiles><MediaFile delivery=\"progressive\" type=\"video/mp4\" width=\"640\" height=\"360\">https://example.invalid/video</MediaFile></MediaFiles>" ++
        "<Icons><Icon program=\"GoogleWhyThisAd\" width=\"30\" height=\"30\"><StaticResource creativeType=\"image/png\">" ++
        "https://example.invalid/icon</StaticResource></Icon></Icons></Linear></Creative></Creatives>" ++
        "<Extensions><Extension type=\"IconClickFallbackImages\"><IconClickFallbackImages program=\"Other\">" ++
        "<IconClickFallbackImage width=\"400\" height=\"150\"><StaticResource creativeType=\"image/png\">https://example.invalid/wrong</StaticResource>" ++
        "</IconClickFallbackImage></IconClickFallbackImages><IconClickFallbackImages program=\"GoogleWhyThisAd\">" ++
        "<IconClickFallbackImage width=\"800\" height=\"300\"><StaticResource creativeType=\"image/png\">https://example.invalid/large</StaticResource></IconClickFallbackImage>" ++
        "<IconClickFallbackImage width=\"400\" height=\"150\"><StaticResource creativeType=\"image/png\">https://example.invalid/fallback</StaticResource></IconClickFallbackImage>" ++
        "</IconClickFallbackImages></Extension></Extensions></InLine></Ad></VAST>");
    defer manifest.deinit();
    const icon = manifest.ads[0].body.inline_ad.icons[0];
    try std.testing.expectEqualStrings("https://example.invalid/fallback", icon.fallback.?);
    try std.testing.expectEqual(@as(u16, 400), icon.fallback_width);
}

test "full HD AdChoices artwork is accepted within explicit decode bounds" {
    for ([_][2]u16{ .{ 1920, 1080 }, .{ 1921, 1080 }, .{ 1920, 1081 }, .{ 0, 150 } }, 0..) |size, index| {
        const bytes = try std.fmt.allocPrint(std.testing.allocator, "<VAST><Ad><InLine><Creatives><Creative><Linear><Duration>00:00:05</Duration>" ++
            "<MediaFiles><MediaFile delivery=\"progressive\" type=\"video/mp4\" width=\"640\" height=\"360\">https://example.invalid/video</MediaFile></MediaFiles>" ++
            "<Icons><Icon width=\"18\" height=\"18\"><StaticResource creativeType=\"image/png\">https://example.invalid/icon</StaticResource>" ++
            "<IconClicks><IconClickFallbackImages><IconClickFallbackImage width=\"{d}\" height=\"{d}\">" ++
            "<StaticResource creativeType=\"image/png\">https://example.invalid/panel</StaticResource>" ++
            "</IconClickFallbackImage></IconClickFallbackImages></IconClicks></Icon></Icons></Linear></Creative></Creatives></InLine></Ad></VAST>", .{ size[0], size[1] });
        defer std.testing.allocator.free(bytes);
        var manifest = try parse(std.testing.allocator, bytes);
        defer manifest.deinit();
        try std.testing.expectEqual(index == 0, manifest.ads[0].body.inline_ad.icons[0].fallback != null);
    }
}

test "wrapper flags and invalid sequence values are checked" {
    var manifest = try parse(std.testing.allocator, "<VAST><Ad sequence=\"2\"><Wrapper followAdditionalWrappers=\"0\" allowMultipleAds=\"true\" fallbackOnNoAd=\"1\">" ++
        "<VASTAdTagURI>https://example.invalid/tag</VASTAdTagURI></Wrapper></Ad></VAST>");
    defer manifest.deinit();
    const wrapper = manifest.ads[0].body.wrapper;
    try std.testing.expect(!wrapper.follow_wrappers and wrapper.allow_multiple and wrapper.fallback_on_no_ad);
    try std.testing.expectError(error.InvalidAdSequence, parse(std.testing.allocator, "<VAST><Ad sequence=\"0\"><Wrapper><VASTAdTagURI>https://example.invalid/tag</VASTAdTagURI></Wrapper></Ad></VAST>"));
}
