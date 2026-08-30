const std = @import("std");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("controller.h");
    @cInclude("handheld_ui.h");
});

const StopRequested = ?*const fn (?*anyopaque) callconv(.c) c_int;

const Platform = struct {
    sdl_initialized: bool = false,
    window: ?*c.SDL_Window = null,
    renderer: ?*c.SDL_Renderer = null,
    audio_device: c.SDL_AudioDeviceID = 0,
    controller: ?*c.GoControllerInput = null,
    ui: ?*c.GoHandheldUi = null,
};

fn debugEnabled() bool {
    return std.posix.getenv("GREENOVERCAST_DEBUG") != null;
}

fn sdlError(comptime operation: []const u8) void {
    std.debug.print("{s}: {s}\n", .{ operation, std.mem.span(c.SDL_GetError()) });
}

pub export fn go_sdl_platform_create(
    stop_requested: StopRequested,
    stop_context: ?*anyopaque,
) ?*Platform {
    const platform = std.heap.c_allocator.create(Platform) catch return null;
    platform.* = .{};
    errdefer go_sdl_platform_destroy(platform);

    if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_AUDIO | c.SDL_INIT_JOYSTICK | c.SDL_INIT_GAMECONTROLLER) != 0) {
        sdlError("SDL_Init");
        return null;
    }
    platform.sdl_initialized = true;
    _ = c.SDL_SetHint(c.SDL_HINT_RENDER_SCALE_QUALITY, "linear");
    platform.window = c.SDL_CreateWindow(
        "GreenOvercast",
        0,
        0,
        640,
        480,
        c.SDL_WINDOW_FULLSCREEN,
    );
    if (platform.window == null) {
        sdlError("SDL_CreateWindow");
        return null;
    }

    platform.renderer = c.SDL_CreateRenderer(platform.window, -1, c.SDL_RENDERER_ACCELERATED);
    if (platform.renderer == null) {
        std.debug.print("Accelerated renderer failed, trying software\n", .{});
        platform.renderer = c.SDL_CreateRenderer(platform.window, -1, 0);
    }
    if (platform.renderer == null) {
        sdlError("SDL_CreateRenderer");
        return null;
    }

    var renderer_info: c.SDL_RendererInfo = undefined;
    if (debugEnabled() and c.SDL_GetRendererInfo(platform.renderer, &renderer_info) == 0) {
        const name = if (renderer_info.name != null) std.mem.span(renderer_info.name) else "unknown";
        std.debug.print("SDL2 renderer ready: {s}{s}\n", .{
            name,
            if (renderer_info.flags & c.SDL_RENDERER_ACCELERATED != 0) " (accelerated)" else "",
        });
    }
    _ = c.SDL_ShowCursor(0);
    _ = c.SDL_SetRenderDrawColor(platform.renderer, 13, 35, 27, 255);
    _ = c.SDL_RenderClear(platform.renderer);
    c.SDL_RenderPresent(platform.renderer);

    platform.controller = c.go_controller_input_create();
    if (platform.controller == null) return null;
    platform.ui = c.go_handheld_ui_create(
        platform.renderer,
        platform.controller,
        stop_requested,
        stop_context,
    );
    if (platform.ui == null) return null;
    _ = c.SDL_GameControllerEventState(c.SDL_ENABLE);
    _ = c.SDL_JoystickEventState(c.SDL_ENABLE);

    var wanted: c.SDL_AudioSpec = std.mem.zeroes(c.SDL_AudioSpec);
    wanted.freq = 48000;
    wanted.format = c.AUDIO_S16SYS;
    wanted.channels = 2;
    wanted.samples = 960;
    var obtained: c.SDL_AudioSpec = undefined;
    platform.audio_device = c.SDL_OpenAudioDevice(null, 0, &wanted, &obtained, 0);
    if (platform.audio_device == 0) {
        sdlError("SDL_OpenAudioDevice");
        return null;
    }
    if (obtained.freq != wanted.freq or obtained.format != wanted.format or
        obtained.channels != wanted.channels)
    {
        std.debug.print("Unsupported audio format: {d} Hz, format 0x{x}, {d} channels\n", .{
            obtained.freq,
            obtained.format,
            obtained.channels,
        });
        return null;
    }
    if (debugEnabled()) std.debug.print("Audio: {d} Hz stereo s16\n", .{obtained.freq});
    return platform;
}

pub export fn go_sdl_platform_renderer(platform: ?*const Platform) ?*c.SDL_Renderer {
    return if (platform) |value| value.renderer else null;
}

pub export fn go_sdl_platform_audio_device(platform: ?*const Platform) c.SDL_AudioDeviceID {
    return if (platform) |value| value.audio_device else 0;
}

pub export fn go_sdl_platform_controller(platform: ?*const Platform) ?*c.GoControllerInput {
    return if (platform) |value| value.controller else null;
}

pub export fn go_sdl_platform_ui(platform: ?*const Platform) ?*c.GoHandheldUi {
    return if (platform) |value| value.ui else null;
}

pub export fn go_sdl_platform_destroy(platform: ?*Platform) void {
    const value = platform orelse return;
    c.go_handheld_ui_destroy(value.ui);
    c.go_controller_input_destroy(value.controller);
    if (value.audio_device != 0) c.SDL_CloseAudioDevice(value.audio_device);
    if (value.renderer) |renderer| c.SDL_DestroyRenderer(renderer);
    if (value.window) |window| c.SDL_DestroyWindow(window);
    if (value.sdl_initialized) c.SDL_Quit();
    std.heap.c_allocator.destroy(value);
}
