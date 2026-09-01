#ifndef GREENOVERCAST_HANDHELD_UI_H
#define GREENOVERCAST_HANDHELD_UI_H

#include <SDL2/SDL.h>

#include "catalog_parser.h"
#include "controller.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GoHandheldUi GoHandheldUi;
typedef int (*GoUiStopRequested)(void* context);

enum {
    GO_HANDHELD_UI_PICK_CANCELLED = -1,
    GO_HANDHELD_UI_PICK_SIGN_OUT = -2,
};

typedef enum {
    GO_HANDHELD_UI_ACTION_NONE = 0,
    GO_HANDHELD_UI_ACTION_BACK,
    GO_HANDHELD_UI_ACTION_CANCEL,
    GO_HANDHELD_UI_ACTION_RETRY_BACK,
} GoHandheldUiAction;

GoHandheldUi* go_handheld_ui_create(SDL_Renderer* renderer, GoControllerInput* controller,
                                    GoUiStopRequested stop_requested, void* stop_context);
void go_handheld_ui_destroy(GoHandheldUi* ui);

void go_handheld_ui_draw_loading(GoHandheldUi* ui, const char* heading, const char* detail,
                                 GoHandheldUiAction action);
void go_handheld_ui_draw_device_code(GoHandheldUi* ui, const char* user_code, const char* status,
                                     unsigned int seconds_remaining);
int go_handheld_ui_wait(GoHandheldUi* ui, Uint32 milliseconds);
int go_handheld_ui_cancel_requested(GoHandheldUi* ui);
int go_handheld_ui_sign_in_action(GoHandheldUi* ui);
int go_handheld_ui_wait_for_retry(GoHandheldUi* ui, const char* heading, const char* detail);
int go_handheld_ui_pick_title(GoHandheldUi* ui, const GoCatalogTitle* titles, int count,
                              const char* requested);
int go_handheld_ui_cancelled(const GoHandheldUi* ui);
unsigned int go_handheld_ui_stream_width(const GoHandheldUi* ui);
unsigned int go_handheld_ui_stream_height(const GoHandheldUi* ui);

#ifdef __cplusplus
}
#endif

#endif
