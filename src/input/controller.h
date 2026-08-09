#ifndef GREENOVERCAST_CONTROLLER_H
#define GREENOVERCAST_CONTROLLER_H

#include <SDL2/SDL.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GoControllerInput GoControllerInput;

GoControllerInput* go_controller_input_create(void);
void go_controller_input_destroy(GoControllerInput* input);
void go_controller_input_handle_event(GoControllerInput* input, const SDL_Event* event);
size_t go_controller_input_encode_metadata(GoControllerInput* input, uint8_t* output,
                                           size_t capacity);
size_t go_controller_input_encode(GoControllerInput* input, uint8_t* output, size_t capacity);
int go_controller_input_exit_held(GoControllerInput* input, uint32_t minimum_milliseconds);

#ifdef __cplusplus
}
#endif

#endif
