const std = @import("std");
const catalog = @import("catalog_parser");
const auth_client = @import("auth_client.zig");
const cloudmatch = @import("cloudmatch_protocol.zig");
const protocol = @import("catalog_protocol.zig");

const c = @cImport({
    @cInclude("handheld_ui.h");
    @cInclude("http_client.h");
});

const maximum_pages = 64;
const maximum_bearer_length = 64 * 1024;

pub const PickResult = union(enum) {
    title: struct {
        id: []const u8,
        name: []const u8,
    },
    cancelled,
    change_provider,
    sign_out,
};

pub const Service = struct {
    allocator: std.mem.Allocator,
    auth: *auth_client.Client,
    ui: *c.GoHandheldUi,
    titles: ?[]catalog.Title = null,

    pub fn create(
        allocator: std.mem.Allocator,
        auth: *auth_client.Client,
        ui_pointer: *anyopaque,
    ) !*Service {
        const service = try allocator.create(Service);
        service.* = .{
            .allocator = allocator,
            .auth = auth,
            .ui = @ptrCast(ui_pointer),
        };
        return service;
    }

    pub fn destroy(self: *Service) void {
        if (self.titles) |titles| self.allocator.free(titles);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn load(self: *Service) !void {
        if (self.titles != null) return error.AlreadyLoaded;
        const bearer = self.auth.bearer() orelse return error.MissingCredentials;
        const streaming_url = self.auth.streamingUrl() orelse return error.MissingProvider;
        const vpc_id = self.fetchVpcId(bearer, streaming_url) catch |err| {
            std.debug.print("GeForce NOW server discovery failed: {s}\n", .{@errorName(err)});
            return err;
        };
        defer self.allocator.free(vpc_id);

        var loaded = std.ArrayList(catalog.Title).init(self.allocator);
        errdefer loaded.deinit();
        var cursor: ?[]u8 = null;
        defer if (cursor) |value| self.allocator.free(value);
        var page_index: usize = 0;
        while (page_index < maximum_pages) : (page_index += 1) {
            const body = try protocol.buildRequest(
                self.allocator,
                vpc_id,
                cursor orelse "",
            );
            defer self.allocator.free(body);
            const response = try self.catalogRequest(bearer, body);
            defer c.go_http_response_destroy(response);
            var page = try protocol.parsePage(
                self.allocator,
                response.*.data[0..response.*.len],
            );
            defer page.deinit();
            try loaded.appendSlice(page.titles);

            var progress_buffer: [96]u8 = undefined;
            const progress = try std.fmt.bufPrintZ(
                &progress_buffer,
                "{d} OF {d} GAMES",
                .{ loaded.items.len, page.total_count orelse loaded.items.len },
            );
            c.go_handheld_ui_draw_loading(
                self.ui,
                "LOADING GEFORCE NOW",
                progress.ptr,
                c.GO_HANDHELD_UI_ACTION_BACK,
            );
            if (c.go_handheld_ui_cancel_requested(self.ui) != 0) return error.Cancelled;

            if (cursor) |value| self.allocator.free(value);
            cursor = null;
            cursor = if (page.next_cursor) |value| try self.allocator.dupe(u8, value) else null;
            if (cursor == null) break;
        }
        if (cursor != null) return error.CatalogPageLimit;
        if (loaded.items.len == 0) return error.EmptyCatalog;

        std.mem.sort(catalog.Title, loaded.items, {}, titleIdLessThan);
        removeDuplicateLaunchIds(&loaded);
        std.mem.sort(catalog.Title, loaded.items, {}, titleLessThan);
        self.titles = try loaded.toOwnedSlice();
    }

    pub fn titleCount(self: *const Service) usize {
        return if (self.titles) |titles| titles.len else 0;
    }

    pub fn pick(self: *Service, requested: []const u8) !PickResult {
        const titles = self.titles orelse return error.NotLoaded;
        if (titles.len == 0 or titles.len > std.math.maxInt(c_int)) return error.InvalidCatalog;
        var requested_buffer: [128]u8 = [_]u8{0} ** 128;
        if (requested.len >= requested_buffer.len) return error.InvalidRequestedTitle;
        @memcpy(requested_buffer[0..requested.len], requested);
        const selected = c.go_handheld_ui_pick_title(
            self.ui,
            @ptrCast(titles.ptr),
            @intCast(titles.len),
            @ptrCast(&requested_buffer),
        );
        if (selected == c.GO_HANDHELD_UI_PICK_CHANGE_PROVIDER) return .change_provider;
        if (selected == c.GO_HANDHELD_UI_PICK_SIGN_OUT) return .sign_out;
        if (selected == c.GO_HANDHELD_UI_PICK_CANCELLED) return .cancelled;
        if (selected < 0 or selected >= titles.len) return error.InvalidSelection;
        const title = &titles[@intCast(selected)];
        std.debug.print("Selected title: {s} ({s})\n", .{
            displayName(title),
            catalog.cString(&title.title_id),
        });
        return .{ .title = .{
            .id = catalog.cString(&title.title_id),
            .name = displayName(title),
        } };
    }

    fn fetchVpcId(self: *Service, bearer: []const u8, streaming_url: []const u8) ![]u8 {
        var url_buffer: [512]u8 = undefined;
        const url = try std.fmt.bufPrintZ(
            &url_buffer,
            "{s}v2/serverInfo",
            .{streaming_url},
        );
        const authorization = try authorizationHeader(self.allocator, bearer);
        defer secureFree(self.allocator, authorization);
        var client_id_header: [512]u8 = undefined;
        var headers = [_][*c]const u8{
            authorization.ptr,
            try header(&client_id_header, "nv-client-id", null, self.auth.protocolClientId()),
            "Accept: application/json",
            "nv-client-type: NATIVE",
            "nv-client-streamer: NVIDIA-CLASSIC",
            "nv-client-version: 2.0.86.124",
            "nv-device-os: WINDOWS",
            "nv-device-type: DESKTOP",
            "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/128.0.0.0 Safari/537.36",
        };
        const response = c.go_http_request_bounded_cancelable(
            "GET",
            url.ptr,
            null,
            @ptrCast(&headers),
            headers.len,
            1024 * 1024,
            cancelRequest,
            self.ui,
        );
        defer c.go_http_response_destroy(response);
        if (!successful(response)) {
            if (c.go_handheld_ui_cancelled(self.ui) != 0) return error.Cancelled;
            return error.ServerInfoRequestFailed;
        }
        return cloudmatch.parseVpcId(self.allocator, response.*.data[0..response.*.len]);
    }

    fn catalogRequest(self: *Service, bearer: []const u8, body: []const u8) ![*c]c.GoHttpResponse {
        const terminated = try self.allocator.dupeZ(u8, body);
        defer self.allocator.free(terminated);
        const authorization = try authorizationHeader(self.allocator, bearer);
        defer secureFree(self.allocator, authorization);
        var client_id_header: [512]u8 = undefined;
        var headers = [_][*c]const u8{
            authorization.ptr,
            try header(&client_id_header, "nv-client-id", null, self.auth.protocolClientId()),
            "Accept: application/json, text/plain, */*",
            "Content-Type: application/json",
            "Origin: https://play.geforcenow.com",
            "Referer: https://play.geforcenow.com/",
            "nv-browser-type: CHROME",
            "nv-client-type: NATIVE",
            "nv-client-streamer: NVIDIA-CLASSIC",
            "nv-client-version: 2.0.86.124",
            "nv-device-make: UNKNOWN",
            "nv-device-model: UNKNOWN",
            "nv-device-os: WINDOWS",
            "nv-device-type: DESKTOP",
            "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/128.0.0.0 Safari/537.36",
        };
        const response = c.go_http_request_bounded_cancelable(
            "POST",
            protocol.endpoint,
            terminated.ptr,
            @ptrCast(&headers),
            headers.len,
            8 * 1024 * 1024,
            cancelRequest,
            self.ui,
        );
        if (!successful(response)) {
            defer c.go_http_response_destroy(response);
            if (c.go_handheld_ui_cancelled(self.ui) != 0) return error.Cancelled;
            if (response != null) {
                std.debug.print("GeForce NOW catalog request returned HTTP {d}\n", .{response.*.status});
                if (response.*.data != null) {
                    var summary_buffer: [256]u8 = undefined;
                    if (protocol.writeErrorSummary(
                        self.allocator,
                        response.*.data[0..response.*.len],
                        &summary_buffer,
                    )) |summary| std.debug.print("GeForce NOW catalog error: {s}\n", .{summary});
                }
            }
            return error.CatalogRequestFailed;
        }
        return response;
    }
};

fn cancelRequest(context: ?*anyopaque) callconv(.c) c_int {
    return c.go_handheld_ui_cancel_requested(@ptrCast(@alignCast(context)));
}

fn authorizationHeader(allocator: std.mem.Allocator, bearer: []const u8) ![:0]u8 {
    if (bearer.len == 0 or bearer.len > maximum_bearer_length)
        return error.InvalidBearerToken;
    return std.fmt.allocPrintZ(allocator, "Authorization: GFNJWT {s}", .{bearer});
}

fn secureFree(allocator: std.mem.Allocator, value: [:0]u8) void {
    std.crypto.secureZero(u8, value);
    allocator.free(value);
}

fn header(
    output: []u8,
    name: []const u8,
    scheme: ?[]const u8,
    value: []const u8,
) ![*c]const u8 {
    const result = if (scheme) |prefix|
        try std.fmt.bufPrintZ(output, "{s}: {s} {s}", .{ name, prefix, value })
    else
        try std.fmt.bufPrintZ(output, "{s}: {s}", .{ name, value });
    return result.ptr;
}

fn successful(response: [*c]c.GoHttpResponse) bool {
    return c.go_http_response_succeeded(response) != 0 and response.*.data != null;
}

fn displayName(title: *const catalog.Title) []const u8 {
    const name = catalog.cString(&title.name);
    return if (name.len > 0) name else catalog.cString(&title.title_id);
}

fn titleLessThan(_: void, left: catalog.Title, right: catalog.Title) bool {
    return std.ascii.lessThanIgnoreCase(displayName(&left), displayName(&right));
}

fn titleIdLessThan(_: void, left: catalog.Title, right: catalog.Title) bool {
    return std.mem.lessThan(
        u8,
        catalog.cString(&left.title_id),
        catalog.cString(&right.title_id),
    );
}

fn removeDuplicateLaunchIds(titles: *std.ArrayList(catalog.Title)) void {
    var write_index: usize = 0;
    for (titles.items) |title| {
        const duplicate = write_index > 0 and std.mem.eql(
            u8,
            catalog.cString(&titles.items[write_index - 1].title_id),
            catalog.cString(&title.title_id),
        );
        if (!duplicate) {
            titles.items[write_index] = title;
            write_index += 1;
        }
    }
    titles.shrinkRetainingCapacity(write_index);
}

test "deduplicates launch ids after sorting" {
    var titles = std.ArrayList(catalog.Title).init(std.testing.allocator);
    defer titles.deinit();
    for ([_][]const u8{ "two", "one", "one" }) |id| {
        var title = std.mem.zeroes(catalog.Title);
        _ = catalog.writeCString(&title.title_id, id);
        _ = catalog.writeCString(&title.name, id);
        try titles.append(title);
    }
    std.mem.sort(catalog.Title, titles.items, {}, titleIdLessThan);
    removeDuplicateLaunchIds(&titles);
    try std.testing.expectEqual(@as(usize, 2), titles.items.len);
}

test "authorization header accepts realistic token lengths" {
    const bearer = try std.testing.allocator.alloc(u8, 2048);
    defer std.testing.allocator.free(bearer);
    @memset(bearer, 'a');
    const value = try authorizationHeader(std.testing.allocator, bearer);
    defer secureFree(std.testing.allocator, value);
    try std.testing.expectEqual(@as(usize, 2070), value.len);
    try std.testing.expect(std.mem.endsWith(u8, value, bearer));
}

test "catalog requests preserve cancellation during HTTP transfers" {
    const http = @import("gfn_http_fake");
    var auth = http.authClient(auth_client.Client);
    var service = Service{
        .allocator = std.testing.allocator,
        .auth = &auth,
        .ui = @ptrCast(auth.ui),
    };
    http.reset();
    try std.testing.expectError(error.Cancelled, service.fetchVpcId("test", "https://example.invalid/"));
    try std.testing.expectEqual(@as(usize, 1), http.requests);
    try std.testing.expectEqual(@as(usize, 1), http.polls);

    http.reset();
    try std.testing.expectError(error.Cancelled, service.catalogRequest("test", "{}"));
    try std.testing.expectEqual(@as(usize, 1), http.requests);
    try std.testing.expectEqual(@as(usize, 1), http.polls);
}
