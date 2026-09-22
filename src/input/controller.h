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
    GO_FACE_BUTTON_MODE_SYSTEM = 0,
    GO_FACE_BUTTON_MODE_SWAPPED = 1,
} GoFaceButtonMode;

enum {
    GO_CONTROLLER_BUTTON_A = 1u << 0,
    GO_CONTROLLER_BUTTON_B = 1u << 1,
    GO_CONTROLLER_BUTTON_X = 1u << 2,
    GO_CONTROLLER_BUTTON_Y = 1u << 3,
    GO_CONTROLLER_BUTTON_LEFT_SHOULDER = 1u << 4,
    GO_CONTROLLER_BUTTON_RIGHT_SHOULDER = 1u << 5,
    GO_CONTROLLER_BUTTON_BACK = 1u << 6,
    GO_CONTROLLER_BUTTON_START = 1u << 7,
    GO_CONTROLLER_BUTTON_DPAD_UP = 1u << 8,
    GO_CONTROLLER_BUTTON_DPAD_DOWN = 1u << 9,
    GO_CONTROLLER_BUTTON_DPAD_LEFT = 1u << 10,
    GO_CONTROLLER_BUTTON_DPAD_RIGHT = 1u << 11,
    GO_CONTROLLER_BUTTON_LEFT_STICK = 1u << 12,
    GO_CONTROLLER_BUTTON_RIGHT_STICK = 1u << 13,
    GO_CONTROLLER_BUTTON_GUIDE = 1u << 14,
};

typedef struct {
    uint32_t buttons;
    int16_t left_x;
    int16_t left_y;
    int16_t right_x;
    int16_t right_y;
    uint16_t left_trigger;
    uint16_t right_trigger;
} GoControllerState;

GoControllerInput* go_controller_input_create(void);
void go_controller_input_destroy(GoControllerInput* input);
void go_controller_input_handle_event(GoControllerInput* input, const SDL_Event* event);
int go_controller_input_event_is_active(const GoControllerInput* input, const SDL_Event* event);
void go_controller_input_set_face_button_mode(GoControllerInput* input, GoFaceButtonMode mode);
SDL_GameControllerButton go_controller_input_map_button(const GoControllerInput* input,
                                                        Uint8 physical_button);
int go_controller_input_button_pressed(const GoControllerInput* input,
                                       SDL_GameControllerButton semantic_button);
Sint16 go_controller_input_axis(const GoControllerInput* input, SDL_GameControllerAxis axis);
int go_controller_input_sample(GoControllerInput* input, GoControllerState* state);
size_t go_controller_input_encode_metadata(GoControllerInput* input, uint8_t* output,
                                           size_t capacity);
size_t go_controller_input_encode(GoControllerInput* input, uint8_t* output, size_t capacity);
int go_controller_input_exit_held(GoControllerInput* input, uint32_t minimum_milliseconds);

#ifdef __cplusplus
}
#endif

#endif
