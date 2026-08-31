const std = @import("std");
const settings = @import("persistent_settings.zig");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("artwork_decoder.h");
    @cInclude("http_client.h");
});

const response_limit = 8 * 1024 * 1024;
const retry_delay_ns = 5 * std.time.ns_per_s;
const product_capacity = settings.product_id_capacity;
const url_capacity = 768;

pub const Loader = struct {
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    thread: ?std.Thread = null,
    stop_requested: bool = false,
    request_pending: bool = false,
    generation: u64 = 0,
    request_product: [product_capacity]u8 = [_]u8{0} ** product_capacity,
    request_url: [url_capacity]u8 = [_]u8{0} ** url_capacity,
    result_generation: u64 = 0,
    result_product: [product_capacity]u8 = [_]u8{0} ** product_capacity,
    result_image: c.GoArtworkImage = std.mem.zeroes(c.GoArtworkImage),
    texture: ?*c.SDL_Texture = null,
    texture_product: [product_capacity]u8 = [_]u8{0} ** product_capacity,
    cache_dir: [512]u8 = [_]u8{0} ** 512,
    cache_dir_length: usize = 0,

    pub fn start(self: *Loader, cache_dir: ?[]const u8) !void {
        if (self.thread != null) return error.AlreadyStarted;
        if (cache_dir) |path| {
            if (path.len == 0 or path.len >= self.cache_dir.len) return error.InvalidCachePath;
            @memcpy(self.cache_dir[0..path.len], path);
            self.cache_dir_length = path.len;
        }
        self.thread = try std.Thread.spawn(.{}, worker, .{self});
    }

    pub fn request(self: *Loader, product_id: []const u8, url: []const u8) void {
        if (!settings.validProductId(product_id) or url.len == 0 or url.len >= self.request_url.len) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (std.mem.eql(u8, cString(&self.request_product), product_id) and
            std.mem.eql(u8, cString(&self.request_url), url)) return;
        self.generation +%= 1;
        @memset(&self.request_product, 0);
        @memset(&self.request_url, 0);
        @memcpy(self.request_product[0..product_id.len], product_id);
        @memcpy(self.request_url[0..url.len], url);
        self.request_pending = true;
        self.condition.signal();
    }

    pub fn clear(self: *Loader) void {
        self.mutex.lock();
        self.generation +%= 1;
        self.request_pending = false;
        @memset(&self.request_product, 0);
        @memset(&self.request_url, 0);
        self.condition.signal();
        if (self.result_image.pixels != null) c.go_artwork_image_destroy(&self.result_image);
        @memset(&self.result_product, 0);
        self.mutex.unlock();
        if (self.texture) |texture| c.SDL_DestroyTexture(texture);
        self.texture = null;
        @memset(&self.texture_product, 0);
    }

    pub fn textureFor(
        self: *Loader,
        renderer_pointer: *anyopaque,
        product_id: []const u8,
    ) ?*anyopaque {
        const renderer: *c.SDL_Renderer = @ptrCast(@alignCast(renderer_pointer));
        var image = std.mem.zeroes(c.GoArtworkImage);
        var image_product = [_]u8{0} ** product_capacity;
        self.mutex.lock();
        if (self.result_image.pixels != null and self.result_generation == self.generation) {
            image = self.result_image;
            self.result_image = std.mem.zeroes(c.GoArtworkImage);
            image_product = self.result_product;
            @memset(&self.result_product, 0);
        }
        self.mutex.unlock();

        if (image.pixels != null) {
            if (self.texture) |texture| c.SDL_DestroyTexture(texture);
            self.texture = c.SDL_CreateTexture(
                renderer,
                c.SDL_PIXELFORMAT_RGB24,
                c.SDL_TEXTUREACCESS_STATIC,
                image.width,
                image.height,
            );
            if (self.texture) |texture| {
                if (c.SDL_UpdateTexture(texture, null, image.pixels, image.stride) != 0) {
                    c.SDL_DestroyTexture(texture);
                    self.texture = null;
                }
            }
            @memset(&self.texture_product, 0);
            if (self.texture != null) self.texture_product = image_product;
            c.go_artwork_image_destroy(&image);
        }
        if (!std.mem.eql(u8, cString(&self.texture_product), product_id)) return null;
        return if (self.texture) |texture| @ptrCast(texture) else null;
    }

    pub fn stop(self: *Loader) void {
        const thread = self.thread orelse {
            self.clear();
            return;
        };
        self.mutex.lock();
        self.stop_requested = true;
        self.condition.broadcast();
        self.mutex.unlock();
        thread.join();
        self.thread = null;
        self.clear();
    }
};

fn worker(loader: *Loader) void {
    while (true) {
        var product = [_]u8{0} ** product_capacity;
        var url = [_]u8{0} ** url_capacity;
        var generation: u64 = 0;
        loader.mutex.lock();
        while (!loader.stop_requested and !loader.request_pending)
            loader.condition.wait(&loader.mutex);
        if (loader.stop_requested) {
            loader.mutex.unlock();
            return;
        }
        product = loader.request_product;
        url = loader.request_url;
        generation = loader.generation;
        loader.request_pending = false;
        loader.mutex.unlock();

        var image = loadImage(loader, generation, cString(&product), @ptrCast(&url));
        if (image.pixels == null) {
            retryCurrentRequest(loader, generation);
            continue;
        }
        loader.mutex.lock();
        if (!loader.stop_requested and generation == loader.generation) {
            if (loader.result_image.pixels != null)
                c.go_artwork_image_destroy(&loader.result_image);
            loader.result_image = image;
            loader.result_generation = generation;
            loader.result_product = product;
            image = std.mem.zeroes(c.GoArtworkImage);
        }
        loader.mutex.unlock();
        if (image.pixels != null) c.go_artwork_image_destroy(&image);
    }
}

fn retryCurrentRequest(loader: *Loader, generation: u64) void {
    var timer = std.time.Timer.start() catch return;
    loader.mutex.lock();
    defer loader.mutex.unlock();
    while (!loader.stop_requested and generation == loader.generation) {
        const elapsed = timer.read();
        if (elapsed >= retry_delay_ns) {
            loader.request_pending = true;
            return;
        }
        loader.condition.timedWait(&loader.mutex, retry_delay_ns - elapsed) catch |err| switch (err) {
            error.Timeout => {},
        };
    }
}

const CancelContext = struct {
    loader: *Loader,
    generation: u64,
};

fn loadImage(
    loader: *Loader,
    generation: u64,
    product_id: []const u8,
    url: [*c]const u8,
) c.GoArtworkImage {
    var image = std.mem.zeroes(c.GoArtworkImage);
    var cache_path_buffer: [640]u8 = undefined;
    const cache_path = cachePath(loader, product_id, &cache_path_buffer);
    if (cache_path) |path| {
        if (std.fs.cwd().openFile(path, .{})) |file| {
            defer file.close();
            if (file.readToEndAlloc(std.heap.c_allocator, response_limit)) |data| {
                defer std.heap.c_allocator.free(data);
                if (c.go_artwork_decode_jpeg(data.ptr, data.len, 1024, 1024, &image) == 0)
                    return image;
            } else |_| {}
            std.fs.cwd().deleteFile(path) catch {};
        } else |_| {}
    }

    var headers = [_][*c]const u8{"Accept: image/jpeg"};
    var cancel_context = CancelContext{ .loader = loader, .generation = generation };
    const response = c.go_http_request_bounded_cancelable(
        "GET",
        url,
        null,
        @ptrCast(&headers),
        headers.len,
        response_limit,
        requestCancelled,
        &cancel_context,
    );
    defer c.go_http_response_destroy(response);
    if (c.go_http_response_succeeded(response) == 0 or response.*.data == null or
        c.go_artwork_decode_jpeg(
            @ptrCast(response.*.data),
            response.*.len,
            1024,
            1024,
            &image,
        ) != 0) return std.mem.zeroes(c.GoArtworkImage);
    if (cache_path) |path| writeCache(path, response.*.data[0..response.*.len]);
    return image;
}

fn requestCancelled(context: ?*anyopaque) callconv(.c) c_int {
    const cancel: *CancelContext = @ptrCast(@alignCast(context orelse return 1));
    cancel.loader.mutex.lock();
    defer cancel.loader.mutex.unlock();
    return @intFromBool(cancel.loader.stop_requested or
        cancel.loader.generation != cancel.generation);
}

fn cachePath(loader: *const Loader, product_id: []const u8, output: []u8) ?[]const u8 {
    if (loader.cache_dir_length == 0) return null;
    return std.fmt.bufPrint(
        output,
        "{s}/{s}.jpg",
        .{ loader.cache_dir[0..loader.cache_dir_length], product_id },
    ) catch null;
}

fn writeCache(path: []const u8, data: []const u8) void {
    var temporary_buffer: [645]u8 = undefined;
    const temporary = std.fmt.bufPrint(&temporary_buffer, "{s}.tmp", .{path}) catch return;
    const cwd = std.fs.cwd();
    var file = cwd.createFile(temporary, .{ .truncate = true, .mode = 0o600 }) catch return;
    var closed = false;
    defer if (!closed) file.close();
    file.writeAll(data) catch {
        cwd.deleteFile(temporary) catch {};
        return;
    };
    file.sync() catch {
        cwd.deleteFile(temporary) catch {};
        return;
    };
    file.close();
    closed = true;
    cwd.rename(temporary, path) catch cwd.deleteFile(temporary) catch {};
}

fn cString(buffer: []const u8) []const u8 {
    return buffer[0 .. std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len];
}
