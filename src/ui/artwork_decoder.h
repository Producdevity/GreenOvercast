#ifndef GREENOVERCAST_ARTWORK_DECODER_H
#define GREENOVERCAST_ARTWORK_DECODER_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint8_t* pixels;
    int width;
    int height;
    int stride;
} GoArtworkImage;

int go_artwork_decode_jpeg(const uint8_t* data, size_t length, int max_width, int max_height,
                           GoArtworkImage* output);
void go_artwork_image_destroy(GoArtworkImage* image);

#endif
