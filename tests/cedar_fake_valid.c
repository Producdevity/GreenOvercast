#include "cedar_decoder.h"

#include <stdlib.h>
#include <string.h>

struct GoCedarDecoder {
    uint8_t frame[48];
    char error[64];
};

GoCedarDecoder* go_cedar_v1_create(int width, int height) {
    if (width == 13 || width <= 0 || height <= 0)
        return NULL;
    GoCedarDecoder* decoder = calloc(1, sizeof(*decoder));
    if (decoder)
        memset(decoder->frame, 0x80, sizeof(decoder->frame));
    return decoder;
}

int go_cedar_v1_feed(GoCedarDecoder* decoder, const uint8_t* data, size_t length,
                     GoCedarFrame* frame) {
    if (!decoder || !data || length == 0 || !frame)
        return -1;
    memset(frame, 0, sizeof(*frame));
    if (data[0] == 0xfe)
        return 0;
    if (data[0] == 0xff) {
        strcpy(decoder->error, "fake Cedar runtime failure");
        return -1;
    }
    frame->y = decoder->frame;
    frame->uv = decoder->frame + 32;
    frame->width = 4;
    frame->height = 4;
    frame->y_stride = 8;
    frame->uv_stride = 8;
    return 1;
}

int go_cedar_v1_flush(GoCedarDecoder* decoder, GoCedarFrame* frame) {
    if (!decoder || !frame)
        return -1;
    memset(frame, 0, sizeof(*frame));
    return 0;
}

const char* go_cedar_v1_last_error(const GoCedarDecoder* decoder) {
    return decoder && decoder->error[0] ? decoder->error : "fake Cedar failure";
}

void go_cedar_v1_destroy(GoCedarDecoder* decoder) {
    free(decoder);
}
