#ifndef GREENOVERCAST_SDL_PLATFORM_H
#define GREENOVERCAST_SDL_PLATFORM_H

#include <SDL2/SDL.h>

#include "controller.h"
#include "handheld_ui.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GoSdlPlatform GoSdlPlatform;

GoSdlPlatform* go_sdl_platform_create(GoUiStopRequested stop_requested, void* stop_context);
SDL_Renderer* go_sdl_platform_renderer(const GoSdlPlatform* platform);
SDL_AudioDeviceID go_sdl_platform_audio_device(const GoSdlPlatform* platform);
GoControllerInput* go_sdl_platform_controller(const GoSdlPlatform* platform);
GoHandheldUi* go_sdl_platform_ui(const GoSdlPlatform* platform);
void go_sdl_platform_destroy(GoSdlPlatform* platform);

#ifdef __cplusplus
}
#endif

#endif
