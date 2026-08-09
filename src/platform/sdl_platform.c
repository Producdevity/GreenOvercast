#include "sdl_platform.h"

#include <stdio.h>
#include <stdlib.h>

#include "../util/log.h"

struct GoSdlPlatform {
    int sdl_initialized;
    SDL_Window* window;
    SDL_Renderer* renderer;
    SDL_AudioDeviceID audio_device;
    GoControllerInput* controller;
    GoHandheldUi* ui;
};

GoSdlPlatform* go_sdl_platform_create(GoUiStopRequested stop_requested, void* stop_context) {
    GoSdlPlatform* platform = calloc(1, sizeof(*platform));
    if (!platform)
        return NULL;
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO | SDL_INIT_JOYSTICK | SDL_INIT_GAMECONTROLLER) !=
        0) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        go_sdl_platform_destroy(platform);
        return NULL;
    }
    platform->sdl_initialized = 1;
    SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "linear");
    platform->window =
        SDL_CreateWindow("GreenOvercast", 0, 0, 640, 480, SDL_WINDOW_FULLSCREEN);
    if (!platform->window) {
        fprintf(stderr, "SDL_CreateWindow: %s\n", SDL_GetError());
        go_sdl_platform_destroy(platform);
        return NULL;
    }
    platform->renderer = SDL_CreateRenderer(platform->window, -1, SDL_RENDERER_ACCELERATED);
    if (!platform->renderer) {
        fprintf(stderr, "Accelerated renderer failed, trying software\n");
        platform->renderer = SDL_CreateRenderer(platform->window, -1, 0);
    }
    if (!platform->renderer) {
        fprintf(stderr, "SDL_CreateRenderer: %s\n", SDL_GetError());
        go_sdl_platform_destroy(platform);
        return NULL;
    }
    SDL_RendererInfo renderer_info;
    if (SDL_GetRendererInfo(platform->renderer, &renderer_info) == 0) {
        go_dbg("SDL2 renderer ready: %s%s\n",
               renderer_info.name ? renderer_info.name : "unknown",
               renderer_info.flags & SDL_RENDERER_ACCELERATED ? " (accelerated)" : "");
    }
    SDL_ShowCursor(0);
    SDL_SetRenderDrawColor(platform->renderer, 13, 35, 27, 255);
    SDL_RenderClear(platform->renderer);
    SDL_RenderPresent(platform->renderer);

    platform->controller = go_controller_input_create();
    if (!platform->controller) {
        go_sdl_platform_destroy(platform);
        return NULL;
    }
    platform->ui = go_handheld_ui_create(platform->renderer, platform->controller,
                                         stop_requested, stop_context);
    if (!platform->ui) {
        go_sdl_platform_destroy(platform);
        return NULL;
    }
    SDL_GameControllerEventState(SDL_ENABLE);
    SDL_JoystickEventState(SDL_ENABLE);

    SDL_AudioSpec wanted;
    SDL_zero(wanted);
    wanted.freq = 48000;
    wanted.format = AUDIO_S16SYS;
    wanted.channels = 2;
    wanted.samples = 960;
    SDL_AudioSpec obtained;
    platform->audio_device = SDL_OpenAudioDevice(NULL, 0, &wanted, &obtained, 0);
    if (!platform->audio_device) {
        fprintf(stderr, "SDL_OpenAudioDevice: %s\n", SDL_GetError());
        go_sdl_platform_destroy(platform);
        return NULL;
    }
    if (obtained.freq != wanted.freq || obtained.format != wanted.format ||
        obtained.channels != wanted.channels) {
        fprintf(stderr, "Unsupported audio format: %d Hz, format 0x%x, %d channels\n",
                obtained.freq, obtained.format, obtained.channels);
        go_sdl_platform_destroy(platform);
        return NULL;
    }
    go_dbg("Audio: %d Hz stereo s16\n", obtained.freq);
    return platform;
}

SDL_Renderer* go_sdl_platform_renderer(const GoSdlPlatform* platform) {
    return platform ? platform->renderer : NULL;
}

SDL_AudioDeviceID go_sdl_platform_audio_device(const GoSdlPlatform* platform) {
    return platform ? platform->audio_device : 0;
}

GoControllerInput* go_sdl_platform_controller(const GoSdlPlatform* platform) {
    return platform ? platform->controller : NULL;
}

GoHandheldUi* go_sdl_platform_ui(const GoSdlPlatform* platform) {
    return platform ? platform->ui : NULL;
}

void go_sdl_platform_destroy(GoSdlPlatform* platform) {
    if (!platform)
        return;
    go_handheld_ui_destroy(platform->ui);
    go_controller_input_destroy(platform->controller);
    if (platform->audio_device)
        SDL_CloseAudioDevice(platform->audio_device);
    if (platform->renderer)
        SDL_DestroyRenderer(platform->renderer);
    if (platform->window)
        SDL_DestroyWindow(platform->window);
    if (platform->sdl_initialized)
        SDL_Quit();
    free(platform);
}
