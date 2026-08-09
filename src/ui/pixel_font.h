#ifndef GREENOVERCAST_PIXEL_FONT_H
#define GREENOVERCAST_PIXEL_FONT_H

#include <SDL2/SDL.h>

int go_ui_text_width(const char* text, int scale);
void go_ui_text(SDL_Renderer* renderer, int x, int y, int scale, const char* text, SDL_Color color);
void go_ui_text_ellipsized(SDL_Renderer* renderer, int x, int y, int scale, const char* text,
                           int max_width, SDL_Color color);

#endif
