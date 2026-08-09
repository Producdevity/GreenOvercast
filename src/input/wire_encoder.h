#ifndef GREENOVERCAST_WIRE_ENCODER_H
#define GREENOVERCAST_WIRE_ENCODER_H

#include <stdint.h>

enum GoControllerButton {
    GO_CONTROLLER_A = 1u << 0,
    GO_CONTROLLER_B = 1u << 1,
    GO_CONTROLLER_X = 1u << 2,
    GO_CONTROLLER_Y = 1u << 3,
    GO_CONTROLLER_LEFT_SHOULDER = 1u << 4,
    GO_CONTROLLER_RIGHT_SHOULDER = 1u << 5,
    GO_CONTROLLER_BACK = 1u << 6,
    GO_CONTROLLER_START = 1u << 7,
    GO_CONTROLLER_DPAD_UP = 1u << 8,
    GO_CONTROLLER_DPAD_DOWN = 1u << 9,
    GO_CONTROLLER_DPAD_LEFT = 1u << 10,
    GO_CONTROLLER_DPAD_RIGHT = 1u << 11,
    GO_CONTROLLER_LEFT_STICK = 1u << 12,
    GO_CONTROLLER_RIGHT_STICK = 1u << 13,
};

uint16_t go_xcloud_button_mask(uint32_t source_buttons);
void go_xcloud_encode_gamepad(uint8_t* buffer, uint32_t sequence, double timestamp_ms,
                              uint16_t buttons, int16_t left_x, int16_t left_y, int16_t right_x,
                              int16_t right_y, uint16_t left_trigger, uint16_t right_trigger);

#endif
