#include "mpp_decoder.h"

#include <stdlib.h>

struct GoMppDecoder {
    int unused;
};

uint32_t go_mpp_decoder_abi_version(void) {
    return GO_MPP_DECODER_ABI_VERSION;
}

GoMppDecoder* go_mpp_decoder_create(int max_width, int max_height) {
    return max_width > 0 && max_height > 0 ? calloc(1, sizeof(GoMppDecoder)) : NULL;
}

int go_mpp_decoder_submit(GoMppDecoder* decoder, const uint8_t* data, size_t length) {
    return decoder && data && length > 0;
}

int go_mpp_decoder_receive(GoMppDecoder* decoder, GoMppFrame* frame) {
    return decoder && frame ? 0 : -1;
}

void go_mpp_decoder_release_frame(GoMppDecoder* decoder, GoMppFrame* frame) {
    (void)decoder;
    (void)frame;
}

const char* go_mpp_decoder_last_error(GoMppDecoder* decoder) {
    (void)decoder;
    return "fake error";
}

void go_mpp_decoder_destroy(GoMppDecoder* decoder) {
    free(decoder);
}
