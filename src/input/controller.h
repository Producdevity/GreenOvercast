#ifndef GREENOVERCAST_CONTROLLER_H
#define GREENOVERCAST_CONTROLLER_H

#include <SDL2/SDL.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GoControllerInput GoControllerInput;

typedef enum {
    GO_FACE_BUTTON_LAYOUT_XBOX = 0,
    GO_FACE_BUTTON_LAYOUT_NINTENDO = 1,
} GoFaceButtonLayout;

GoControllerInput* go_controller_input_create(void);
void go_controller_input_destroy(GoControllerInput* input);
void go_controller_input_handle_event(GoControllerInput* input, const SDL_Event* event);
int go_controller_input_event_is_active(const GoControllerInput* input,
                                        const SDL_Event* event);
void go_controller_input_set_face_layout(GoControllerInput* input, GoFaceButtonLayout layout);
SDL_GameControllerButton go_controller_input_map_button(const GoControllerInput* input,
                                                        Uint8 physical_button);
int go_controller_input_button_pressed(const GoControllerInput* input,
                                       SDL_GameControllerButton semantic_button);
Sint16 go_controller_input_axis(const GoControllerInput* input, SDL_GameControllerAxis axis);
size_t go_controller_input_encode_metadata(GoControllerInput* input, uint8_t* output,
                                           size_t capacity);
size_t go_controller_input_encode(GoControllerInput* input, uint8_t* output, size_t capacity);
int go_controller_input_exit_held(GoControllerInput* input, uint32_t minimum_milliseconds);

#ifdef __cplusplus
}
#endif

#endif
