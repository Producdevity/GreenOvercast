const std = @import("std");
const parser = @import("catalog_parser.zig");

const c = @cImport({
    @cInclude("cloud_session.h");
    @cInclude("handheld_ui.h");
});

const max_titles = 1024;
const metadata_batch = 24;

pub const LoadResult = enum {
    loaded,
    cancelled,
};

pub const PickResult = union(enum) {
    title_id: []const u8,
    cancelled,
    sign_out,
};

pub const Service = struct {
    allocator: std.mem.Allocator,
    titles: ?[]parser.Title = null,
    count: usize = 0,
    base_url: [256]u8 = [_]u8{0} ** 256,
    base_url_length: usize = 0,
    cache_path: [512]u8 = [_]u8{0} ** 512,
    cache_path_length: usize = 0,
    cloud: *anyopaque,
    ui: *anyopaque,

    pub fn create(
        allocator: std.mem.Allocator,
        base_url: []const u8,
        cache_path: ?[]const u8,
        cloud: *anyopaque,
        ui: *anyopaque,
    ) !*Service {
        if (base_url.len == 0 or base_url.len >= 256) return error.InvalidBaseUrl;
        if (cache_path) |path| {
            if (path.len >= 512) return error.InvalidCachePath;
        }

        const service = try allocator.create(Service);
        service.* = .{
            .allocator = allocator,
            .cloud = cloud,
            .ui = ui,
        };
        @memcpy(service.base_url[0..base_url.len], base_url);
        service.base_url_length = base_url.len;
        if (cache_path) |path| {
            @memcpy(service.cache_path[0..path.len], path);
            service.cache_path_length = path.len;
        }
        return service;
    }

    pub fn load(self: *Service) !LoadResult {
        if (self.titles != null) return error.AlreadyLoaded;
        const titles = try self.allocator.alloc(parser.Title, max_titles);
        @memset(titles, std.mem.zeroes(parser.Title));
        self.titles = titles;

        var url_buffer: [512]u8 = undefined;
        const url = try std.fmt.bufPrintZ(&url_buffer, "{s}/v2/titles", .{self.baseUrl()});
        var headers = [_][*c]const u8{"x-xbl-contract-version: 2"};
        const response = c.go_cloud_session_request(
            self.cloudHandle(),
            "GET",
            url.ptr,
            null,
            @ptrCast(&headers),
            headers.len,
        );
        defer c.go_http_response_destroy(response);
        if (response == null or response.*.status != 200 or response.*.data == null)
            return error.CatalogRequestFailed;

        self.count = try parser.parseTitles(response.*.data[0..response.*.len], titles);
        if (self.count == 0) return error.EmptyCatalog;

        self.applyCache();
        try self.fetchMissingMetadata();
        if (c.go_handheld_ui_cancelled(self.uiHandle()) != 0) return .cancelled;

        for (titles[0..self.count]) |*title| {
            if (parser.cString(&title.product_id).len > 0 and parser.cString(&title.name).len == 0)
                _ = parser.writeCString(&title.name, parser.cString(&title.title_id));
        }
        std.mem.sort(parser.Title, titles[0..self.count], {}, titleLessThan);
        self.removeDuplicates();
        self.persistCache() catch {
            std.debug.print("Catalog cache could not be updated\n", .{});
        };
        return .loaded;
    }

    pub fn titleCount(self: *const Service) usize {
        return self.count;
    }

    pub fn pick(self: *Service, requested: []const u8) !PickResult {
        const titles = self.titles orelse return error.NotLoaded;
        if (self.count == 0) return error.EmptyCatalog;

        var requested_buffer: [128]u8 = [_]u8{0} ** 128;
        if (requested.len >= requested_buffer.len) return error.InvalidRequestedTitle;
        @memcpy(requested_buffer[0..requested.len], requested);
        const selected = c.go_handheld_ui_pick_title(
            self.uiHandle(),
            @ptrCast(titles.ptr),
            @intCast(self.count),
            @ptrCast(&requested_buffer),
        );
        if (selected == c.GO_HANDHELD_UI_PICK_SIGN_OUT) return .sign_out;
        if (selected == c.GO_HANDHELD_UI_PICK_CANCELLED) return .cancelled;
        if (selected < 0) return error.InvalidSelection;
        if (selected >= self.count) return error.InvalidSelection;
        const title = &titles[@intCast(selected)];
        const title_id = parser.cString(&title.title_id);
        std.debug.print("Selected title: {s} ({s})\n", .{ titleName(title), title_id });
        return .{ .title_id = title_id };
    }

    pub fn destroy(self: *Service) void {
        if (self.titles) |titles| self.allocator.free(titles);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    fn baseUrl(self: *const Service) []const u8 {
        return self.base_url[0..self.base_url_length];
    }

    fn cachePath(self: *const Service) []const u8 {
        return self.cache_path[0..self.cache_path_length];
    }

    fn applyCache(self: *Service) void {
        const path = self.cachePath();
        if (path.len == 0) return;
        const titles = self.titles orelse return;
        const file = std.fs.cwd().openFile(path, .{}) catch return;
        defer file.close();
        const data = file.readToEndAlloc(self.allocator, 1024 * 1024) catch return;
        defer self.allocator.free(data);

        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trimRight(u8, raw_line, "\r");
            const separator = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            const product_id = line[0..separator];
            const remainder = line[separator + 1 ..];
            const artwork_separator = std.mem.indexOfScalar(u8, remainder, '\t');
            const name = if (artwork_separator) |index| remainder[0..index] else remainder;
            const artwork = if (artwork_separator) |index| remainder[index + 1 ..] else "";
            if (product_id.len == 0 or name.len == 0) continue;
            for (titles[0..self.count]) |*title| {
                if (std.mem.eql(u8, parser.cString(&title.product_id), product_id)) {
                    _ = parser.writeCString(&title.name, name);
                    if (artwork.len > 0) _ = parser.writeCString(&title.artwork_url, artwork);
                    break;
                }
            }
        }
    }

    fn persistCache(self: *const Service) !void {
        const path = self.cachePath();
        if (path.len == 0) return;
        const titles = self.titles orelse return;
        var temporary_buffer: [517]u8 = undefined;
        const temporary_path = try std.fmt.bufPrint(&temporary_buffer, "{s}.tmp", .{path});
        const cwd = std.fs.cwd();
        errdefer cwd.deleteFile(temporary_path) catch {};

        var file = try cwd.createFile(temporary_path, .{ .truncate = true, .mode = 0o600 });
        var closed = false;
        defer if (!closed) file.close();
        var writer = file.writer();
        for (titles[0..self.count]) |*title| {
            const product_id = parser.cString(&title.product_id);
            const name = parser.cString(&title.name);
            const artwork = parser.cString(&title.artwork_url);
            if (product_id.len > 0 and name.len > 0)
                try writer.print("{s}\t{s}\t{s}\n", .{ product_id, name, artwork });
        }
        try file.sync();
        file.close();
        closed = true;
        try cwd.rename(temporary_path, path);
    }

    fn fetchMissingMetadata(self: *Service) !void {
        const titles = self.titles orelse return;
        var next: usize = 0;
        var resolved: usize = 0;
        while (next < self.count) {
            var indexes: [metadata_batch]usize = undefined;
            var batch_count: usize = 0;
            while (next < self.count and batch_count < metadata_batch) : (next += 1) {
                if (parser.cString(&titles[next].product_id).len > 0 and
                    (parser.cString(&titles[next].name).len == 0 or
                        parser.cString(&titles[next].artwork_url).len == 0))
                {
                    indexes[batch_count] = next;
                    batch_count += 1;
                }
            }
            if (batch_count == 0) continue;

            var url: [4096]u8 = undefined;
            var used: usize = 0;
            try append(&url, &used, "https://displaycatalog.mp.microsoft.com/v7.0/products?bigIds=", .{});
            for (indexes[0..batch_count], 0..) |title_index, index| {
                try append(&url, &used, "{s}{s}", .{
                    if (index == 0) "" else ",",
                    parser.cString(&titles[title_index].product_id),
                });
            }
            try append(&url, &used, "&market=US&languages=en-us&fieldsTemplate=Details", .{});
            url[used] = 0;

            var headers = [_][*c]const u8{"Accept: application/json"};
            const response = c.go_http_request(
                "GET",
                @ptrCast(&url),
                null,
                @ptrCast(&headers),
                headers.len,
            );
            if (response != null) {
                if (response.*.status == 200 and response.*.data != null) {
                    _ = parser.parseMetadata(
                        response.*.data[0..response.*.len],
                        titles[0..self.count],
                    ) catch {
                        std.debug.print("Catalog metadata response was invalid\n", .{});
                    };
                }
                c.go_http_response_destroy(response);
            }

            resolved += batch_count;
            var progress_buffer: [64]u8 = undefined;
            const progress = try std.fmt.bufPrintZ(
                &progress_buffer,
                "{d} OF {d} GAMES",
                .{ resolved, self.count },
            );
            c.go_handheld_ui_draw_loading(
                self.uiHandle(),
                "LOADING LIBRARY",
                progress.ptr,
                c.GO_HANDHELD_UI_ACTION_BACK,
            );
            if (c.go_handheld_ui_cancel_requested(self.uiHandle()) != 0) return;
        }
    }

    fn removeDuplicates(self: *Service) void {
        const titles = self.titles orelse return;
        var unique_count: usize = 0;
        for (titles[0..self.count]) |title| {
            var duplicate = false;
            for (titles[0..unique_count]) |previous| {
                if (std.mem.eql(
                    u8,
                    parser.cString(&previous.title_id),
                    parser.cString(&title.title_id),
                )) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) {
                titles[unique_count] = title;
                unique_count += 1;
            }
        }
        self.count = unique_count;
    }

    fn cloudHandle(self: *const Service) *c.GoCloudSession {
        return @ptrCast(@alignCast(self.cloud));
    }

    fn uiHandle(self: *const Service) *c.GoHandheldUi {
        return @ptrCast(@alignCast(self.ui));
    }
};

fn append(buffer: []u8, used: *usize, comptime format: []const u8, args: anytype) !void {
    if (used.* >= buffer.len - 1) return error.NoSpaceLeft;
    const written = try std.fmt.bufPrint(buffer[used.* .. buffer.len - 1], format, args);
    used.* += written.len;
}

fn titleName(title: *const parser.Title) []const u8 {
    const name = parser.cString(&title.name);
    return if (name.len > 0) name else parser.cString(&title.title_id);
}

fn titleLessThan(_: void, left: parser.Title, right: parser.Title) bool {
    const by_name = std.ascii.orderIgnoreCase(titleName(&left), titleName(&right));
    if (by_name != .eq) return by_name == .lt;
    return std.mem.order(u8, parser.cString(&left.title_id), parser.cString(&right.title_id)) == .lt;
}

comptime {
    if (@sizeOf(parser.Title) != @sizeOf(c.GoCatalogTitle))
        @compileError("catalog title ABI mismatch");
}
