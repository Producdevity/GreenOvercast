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
    /* A console picked on the CONSOLES tab is reported as
     * GO_HANDHELD_UI_PICK_CONSOLE_BASE - index (so -100, -101, ...). */
    GO_HANDHELD_UI_PICK_CONSOLE_BASE = -100,
};

#define GO_UI_MAX_CONSOLES 8

typedef struct {
    char name[128];
    char power_state[32];
} GoUiConsoleRow;

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
/* Provides the xHome consoles for the CONSOLES tab (copied; count is capped at
 * GO_UI_MAX_CONSOLES). count <= 0 hides the tab. */
void go_handheld_ui_set_consoles(GoHandheldUi* ui, const GoUiConsoleRow* rows, int count);
/* How many consoles go_handheld_ui_set_consoles last provided. */
int go_handheld_ui_console_count(const GoHandheldUi* ui);
int go_handheld_ui_cancelled(const GoHandheldUi* ui);
/* Nonzero when Settings asks for the software video decoder. */
int go_handheld_ui_software_decoder(const GoHandheldUi* ui);
/* Nonzero when Settings asks for frame smoothing. */
int go_handheld_ui_smooth_video(const GoHandheldUi* ui);
unsigned int go_handheld_ui_stream_width(const GoHandheldUi* ui);
unsigned int go_handheld_ui_stream_height(const GoHandheldUi* ui);

#ifdef __cplusplus
}
#endif

#endif
