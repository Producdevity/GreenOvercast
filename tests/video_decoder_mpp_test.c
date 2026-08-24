#define _POSIX_C_SOURCE 200809L

#include "video_decoder.h"

#include <assert.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char** argv) {
    assert(argc == 2);
    assert(setenv("GREENOVERCAST_MPP_LIBRARY", argv[1], 1) == 0);

    char error[256] = {0};
    GoVideoDecoder* decoder = go_video_decoder_mpp_create(1280, 720, error, sizeof(error));
    assert(decoder != NULL);
    assert(go_video_decoder_backend(decoder) == GO_VIDEO_DECODER_BACKEND_MPP);

    const uint8_t backpressure[] = {0xfe};
    assert(go_video_decoder_submit_access_unit(decoder, backpressure, sizeof(backpressure)) ==
           GO_VIDEO_DECODER_RESULT_AGAIN);

    const uint8_t access_unit[] = {0, 0, 0, 1, 0x65};
    assert(go_video_decoder_submit_access_unit(decoder, access_unit, sizeof(access_unit)) ==
           GO_VIDEO_DECODER_RESULT_OK);
    GoDecodedVideoFrame frame;
    assert(go_video_decoder_receive_frame(decoder, &frame) == GO_VIDEO_DECODER_RESULT_OK);
    assert(frame.format == GO_VIDEO_PIXEL_FORMAT_NV12);
    assert(frame.width == 4 && frame.height == 4);
    assert(frame.strides[0] == 4 && frame.strides[1] == 4);
    assert(frame.info_changed == 1);
    assert(frame.backend_frame != NULL);
    assert(go_video_decoder_reset(decoder) == -1);
    assert(strstr(go_video_decoder_last_error(decoder), "frame outstanding") != NULL);
    go_video_decoder_release_frame(decoder, &frame);
    assert(frame.backend_frame == NULL);

    assert(go_video_decoder_submit_access_unit(decoder, access_unit, sizeof(access_unit)) ==
           GO_VIDEO_DECODER_RESULT_OK);
    assert(go_video_decoder_receive_frame(decoder, &frame) == GO_VIDEO_DECODER_RESULT_OK);
    assert(frame.info_changed == 0);
    go_video_decoder_release_frame(decoder, &frame);

    assert(go_video_decoder_reset(decoder) == 0);
    assert(go_video_decoder_submit_access_unit(decoder, access_unit, sizeof(access_unit)) ==
           GO_VIDEO_DECODER_RESULT_OK);
    assert(go_video_decoder_receive_frame(decoder, &frame) == GO_VIDEO_DECODER_RESULT_OK);
    assert(frame.info_changed == 1);
    go_video_decoder_release_frame(decoder, &frame);

    const uint8_t failure[] = {0xff};
    assert(go_video_decoder_submit_access_unit(decoder, failure, sizeof(failure)) ==
           GO_VIDEO_DECODER_RESULT_FATAL);
    assert(strstr(go_video_decoder_last_error(decoder), "fake runtime failure") != NULL);

    go_video_decoder_destroy(decoder);

    memset(error, 0, sizeof(error));
    decoder = go_video_decoder_mpp_create(13, 720, error, sizeof(error));
    assert(decoder == NULL);
    assert(strstr(error, "initialization failed") != NULL);
    unsetenv("GREENOVERCAST_MPP_LIBRARY");
    return 0;
}
