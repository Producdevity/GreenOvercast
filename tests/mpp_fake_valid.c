#include "mpp_decoder.h"

#include <stdlib.h>
#include <string.h>

struct GoMppDecoder {
    int frame_ready;
    const char* error;
};

uint32_t go_mpp_decoder_abi_version(void) {
    return GO_MPP_DECODER_ABI_VERSION;
}

GoMppDecoder* go_mpp_decoder_create(int max_width, int max_height) {
    if (max_width == 13 || max_width <= 0 || max_height <= 0)
        return NULL;
    return calloc(1, sizeof(GoMppDecoder));
}

int go_mpp_decoder_submit(GoMppDecoder* decoder, const uint8_t* data, size_t length) {
    if (!decoder || !data || length == 0)
        return -1;
    if (data[0] == 0xfe)
        return 0;
    if (data[0] == 0xff) {
        decoder->error = "fake runtime failure";
        return -1;
    }
    decoder->frame_ready = 1;
    return 1;
}

int go_mpp_decoder_receive(GoMppDecoder* decoder, GoMppFrame* frame) {
    static uint8_t y[16];
    static uint8_t uv[8];
    if (!decoder || !frame)
        return -1;
    if (!decoder->frame_ready)
        return 0;
    memset(frame, 0, sizeof(*frame));
    frame->y = y;
    frame->uv = uv;
    frame->width = 4;
    frame->height = 4;
    frame->y_stride = 4;
    frame->uv_stride = 4;
    frame->owner = decoder;
    decoder->frame_ready = 0;
    return 1;
}

void go_mpp_decoder_release_frame(GoMppDecoder* decoder, GoMppFrame* frame) {
    if (decoder && frame && frame->owner == decoder)
        memset(frame, 0, sizeof(*frame));
}

int go_mpp_decoder_reset(GoMppDecoder* decoder) {
    if (!decoder)
        return -1;
    decoder->frame_ready = 0;
    return 0;
}

const char* go_mpp_decoder_last_error(GoMppDecoder* decoder) {
    return decoder && decoder->error ? decoder->error : "fake initialization failed";
}

void go_mpp_decoder_destroy(GoMppDecoder* decoder) {
    free(decoder);
}
