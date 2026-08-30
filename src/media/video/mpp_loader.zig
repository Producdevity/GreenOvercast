const std = @import("std");

const c = @cImport({
    @cInclude("dlfcn.h");
    @cInclude("mpp_decoder.h");
});

const AbiVersion = *const fn () callconv(.c) u32;
const CreateDecoder = *const fn (c_int, c_int) callconv(.c) ?*c.GoMppDecoder;
const SubmitDecoder = *const fn (*c.GoMppDecoder, [*]const u8, usize) callconv(.c) c_int;
const ReceiveDecoder = *const fn (*c.GoMppDecoder, *c.GoMppFrame) callconv(.c) c_int;
const ReleaseFrame = *const fn (*c.GoMppDecoder, *c.GoMppFrame) callconv(.c) void;
const ResetDecoder = *const fn (*c.GoMppDecoder) callconv(.c) c_int;
const DecoderError = *const fn (?*c.GoMppDecoder) callconv(.c) [*:0]const u8;
const DestroyDecoder = *const fn (*c.GoMppDecoder) callconv(.c) void;

const Library = struct {
    handle: ?*anyopaque = null,
    decoder: ?*c.GoMppDecoder = null,
    submit: ?SubmitDecoder = null,
    receive: ?ReceiveDecoder = null,
    release_frame: ?ReleaseFrame = null,
    reset: ?ResetDecoder = null,
    decoder_error: ?DecoderError = null,
    destroy: ?DestroyDecoder = null,
    path: [512]u8 = [_]u8{0} ** 512,
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
            if (load_error != null) @ptrCast(load_error) else "MPP plugin symbol is missing",
        );
        return null;
    }
    return @ptrCast(@alignCast(symbol));
}

fn ready(library: ?*const Library) bool {
    const value = library orelse return false;
    return value.decoder != null and value.submit != null and value.receive != null and
        value.release_frame != null and value.reset != null and value.decoder_error != null and
        value.destroy != null;
}

pub export fn go_mpp_library_open(max_width: c_int, max_height: c_int) ?*Library {
    const library = std.heap.c_allocator.create(Library) catch return null;
    library.* = .{};

    const path = std.posix.getenv("GREENOVERCAST_MPP_LIBRARY") orelse "libgreenovercast-mpp.so";
    if (path.len >= library.path.len) {
        copyZ(&library.error_message, "MPP plugin path is too long");
        return library;
    }
    copyZ(&library.path, path);

    var flags: c_int = c.RTLD_NOW | c.RTLD_LOCAL;
    // Older MPP builds can run process-lifetime cleanup after decoder teardown.
    if (@hasDecl(c, "RTLD_NODELETE")) flags |= c.RTLD_NODELETE;
    library.handle = c.dlopen(@ptrCast(&library.path), flags);
    if (library.handle == null) {
        const load_error = c.dlerror();
        setError(library, if (load_error != null) @ptrCast(load_error) else null);
        return library;
    }

    const abi_version = loadSymbol(library, AbiVersion, "go_mpp_decoder_abi_version") orelse {
        _ = c.dlclose(library.handle);
        library.handle = null;
        return library;
    };
    const version = abi_version();
    if (version != c.GO_MPP_DECODER_ABI_VERSION) {
        _ = std.fmt.bufPrintZ(
            &library.error_message,
            "MPP plugin ABI {d} is incompatible with required ABI {d}",
            .{ version, c.GO_MPP_DECODER_ABI_VERSION },
        ) catch copyZ(&library.error_message, "MPP plugin ABI is incompatible");
        _ = c.dlclose(library.handle);
        library.handle = null;
        return library;
    }

    const create = loadSymbol(library, CreateDecoder, "go_mpp_decoder_create");
    library.submit = loadSymbol(library, SubmitDecoder, "go_mpp_decoder_submit");
    library.receive = loadSymbol(library, ReceiveDecoder, "go_mpp_decoder_receive");
    library.release_frame = loadSymbol(library, ReleaseFrame, "go_mpp_decoder_release_frame");
    library.reset = loadSymbol(library, ResetDecoder, "go_mpp_decoder_reset");
    library.decoder_error = loadSymbol(library, DecoderError, "go_mpp_decoder_last_error");
    library.destroy = loadSymbol(library, DestroyDecoder, "go_mpp_decoder_destroy");
    if (create == null or library.submit == null or library.receive == null or
        library.release_frame == null or library.reset == null or library.decoder_error == null or
        library.destroy == null)
    {
        _ = c.dlclose(library.handle);
        library.handle = null;
        return library;
    }

    library.decoder = create.?(max_width, max_height);
    if (library.decoder == null) setError(library, library.decoder_error.?(null));
    return library;
}

pub export fn go_mpp_library_ready(library: ?*const Library) c_int {
    return @intFromBool(ready(library));
}

pub export fn go_mpp_library_submit(
    library_pointer: ?*Library,
    data: ?[*]const u8,
    length: usize,
) c_int {
    const library = library_pointer orelse return -1;
    const bytes = data orelse return -1;
    if (!ready(library)) return -1;
    const result = library.submit.?(library.decoder.?, bytes, length);
    if (result < 0) setError(library, library.decoder_error.?(library.decoder));
    return result;
}

pub export fn go_mpp_library_receive(library_pointer: ?*Library, frame: ?*c.GoMppFrame) c_int {
    const library = library_pointer orelse return -1;
    const output = frame orelse return -1;
    if (!ready(library)) return -1;
    const result = library.receive.?(library.decoder.?, output);
    if (result < 0) setError(library, library.decoder_error.?(library.decoder));
    return result;
}

pub export fn go_mpp_library_release_frame(
    library_pointer: ?*Library,
    frame: ?*c.GoMppFrame,
) void {
    const library = library_pointer orelse return;
    const output = frame orelse return;
    if (ready(library)) library.release_frame.?(library.decoder.?, output);
}

pub export fn go_mpp_library_reset(library_pointer: ?*Library) c_int {
    const library = library_pointer orelse return -1;
    if (!ready(library)) return -1;
    const result = library.reset.?(library.decoder.?);
    if (result < 0) setError(library, library.decoder_error.?(library.decoder));
    return result;
}

pub export fn go_mpp_library_error(library: ?*const Library) [*:0]const u8 {
    if (library) |value| {
        if (value.error_message[0] != 0) return @ptrCast(&value.error_message);
    }
    return "MPP decoder unavailable";
}

pub export fn go_mpp_library_path(library: ?*const Library) [*:0]const u8 {
    if (library) |value| {
        if (value.path[0] != 0) return @ptrCast(&value.path);
    }
    return "libgreenovercast-mpp.so";
}

pub export fn go_mpp_library_close(library_pointer: ?*Library) void {
    const library = library_pointer orelse return;
    if (library.decoder) |decoder| {
        if (library.destroy) |destroy| destroy(decoder);
    }
    if (library.handle != null) _ = c.dlclose(library.handle);
    std.heap.c_allocator.destroy(library);
}
