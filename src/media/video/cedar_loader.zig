const std = @import("std");

const c = @cImport({
    @cInclude("cedar_decoder.h");
    @cInclude("dlfcn.h");
});

const CreateDecoder = *const fn (c_int, c_int) callconv(.c) ?*c.GoCedarDecoder;
const FeedDecoder = *const fn (*c.GoCedarDecoder, [*]const u8, usize, *c.GoCedarFrame) callconv(.c) c_int;
const DecoderError = *const fn (*const c.GoCedarDecoder) callconv(.c) [*:0]const u8;
const DestroyDecoder = *const fn (*c.GoCedarDecoder) callconv(.c) void;

const Library = struct {
    handle: ?*anyopaque = null,
    decoder: ?*c.GoCedarDecoder = null,
    feed: ?FeedDecoder = null,
    decoder_error: ?DecoderError = null,
    destroy: ?DestroyDecoder = null,
    error_message: [256]u8 = [_]u8{0} ** 256,
};

fn copyZ(destination: []u8, message: []const u8) void {
    @memset(destination, 0);
    const length = @min(destination.len - 1, message.len);
    @memcpy(destination[0..length], message[0..length]);
}

fn setError(library: *Library, message: ?[*:0]const u8) void {
    copyZ(&library.error_message, if (message) |value| std.mem.span(value) else "unknown error");
}

fn loadSymbol(library: *Library, comptime T: type, name: [*:0]const u8) ?T {
    _ = c.dlerror();
    const symbol = c.dlsym(library.handle, name);
    const load_error = c.dlerror();
    if (load_error != null or symbol == null) {
        setError(
            library,
            if (load_error != null) @ptrCast(load_error) else "incomplete Cedar decoder ABI",
        );
        return null;
    }
    return @ptrCast(@alignCast(symbol));
}

fn ready(library: ?*const Library) bool {
    const value = library orelse return false;
    return value.decoder != null and value.feed != null and value.destroy != null;
}

pub export fn go_cedar_library_open(width: c_int, height: c_int) ?*Library {
    const library = std.heap.c_allocator.create(Library) catch return null;
    library.* = .{};
    const path = std.posix.getenv("GREENOVERCAST_CEDAR_LIBRARY") orelse
        "libgreenovercast-cedar.so";
    library.handle = c.dlopen(path.ptr, c.RTLD_NOW | c.RTLD_LOCAL);
    if (library.handle == null) {
        const load_error = c.dlerror();
        setError(library, if (load_error != null) @ptrCast(load_error) else null);
        return library;
    }

    const create = loadSymbol(library, CreateDecoder, "go_cedar_v1_create");
    library.feed = loadSymbol(library, FeedDecoder, "go_cedar_v1_feed");
    library.decoder_error = loadSymbol(library, DecoderError, "go_cedar_v1_last_error");
    library.destroy = loadSymbol(library, DestroyDecoder, "go_cedar_v1_destroy");
    if (create == null or library.feed == null or library.decoder_error == null or
        library.destroy == null)
    {
        _ = c.dlclose(library.handle);
        library.handle = null;
        return library;
    }
    library.decoder = create.?(width, height);
    if (library.decoder == null) copyZ(&library.error_message, "Cedar decoder initialization failed");
    return library;
}

pub export fn go_cedar_library_ready(library: ?*const Library) c_int {
    return @intFromBool(ready(library));
}

pub export fn go_cedar_library_feed(
    library_pointer: ?*Library,
    annex_b: ?[*]const u8,
    length: usize,
    frame: ?*c.GoCedarFrame,
) c_int {
    const library = library_pointer orelse return -1;
    const data = annex_b orelse return -1;
    const output = frame orelse return -1;
    if (!ready(library)) return -1;
    const result = library.feed.?(library.decoder.?, data, length, output);
    if (result < 0) setError(library, library.decoder_error.?(@ptrCast(library.decoder.?)));
    return result;
}

pub export fn go_cedar_library_error(library: ?*const Library) [*:0]const u8 {
    if (library) |value| {
        if (value.error_message[0] != 0) return @ptrCast(&value.error_message);
    }
    return "Cedar decoder unavailable";
}

pub export fn go_cedar_library_close(library_pointer: ?*Library) void {
    const library = library_pointer orelse return;
    if (library.decoder) |decoder| {
        if (library.destroy) |destroy| destroy(decoder);
    }
    if (library.handle != null) _ = c.dlclose(library.handle);
    std.heap.c_allocator.destroy(library);
}
