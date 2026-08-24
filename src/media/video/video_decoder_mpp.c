#include "video_decoder.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mpp_loader.h"

typedef struct {
    GoVideoDecoder base;
    GoMppLibrary* library;
    GoMppFrame active_frame;
    int frame_outstanding;
    int last_width;
    int last_height;
    int last_y_stride;
    int last_uv_stride;
    char error[256];
} GoMppVideoDecoder;

static void copy_mpp_error(GoMppVideoDecoder* decoder) {
    snprintf(decoder->error, sizeof(decoder->error), "%s", go_mpp_library_error(decoder->library));
}

static GoVideoDecoderResult mpp_submit(GoVideoDecoder* base, const uint8_t* data, size_t length) {
    GoMppVideoDecoder* decoder = (GoMppVideoDecoder*)base;
    int result = go_mpp_library_submit(decoder->library, data, length);
    if (result > 0)
        return GO_VIDEO_DECODER_RESULT_OK;
    if (result == 0)
        return GO_VIDEO_DECODER_RESULT_AGAIN;
    copy_mpp_error(decoder);
    return GO_VIDEO_DECODER_RESULT_FATAL;
}

static GoVideoDecoderResult mpp_receive(GoVideoDecoder* base, GoDecodedVideoFrame* output) {
    GoMppVideoDecoder* decoder = (GoMppVideoDecoder*)base;
    if (decoder->frame_outstanding) {
        snprintf(decoder->error, sizeof(decoder->error), "MPP frame was not released");
        return GO_VIDEO_DECODER_RESULT_FATAL;
    }
    int result = go_mpp_library_receive(decoder->library, &decoder->active_frame);
    if (result == 0)
        return GO_VIDEO_DECODER_RESULT_AGAIN;
    if (result < 0) {
        copy_mpp_error(decoder);
        return GO_VIDEO_DECODER_RESULT_FATAL;
    }
    output->format = GO_VIDEO_PIXEL_FORMAT_NV12;
    output->color_range = GO_VIDEO_COLOR_RANGE_LIMITED;
    output->width = decoder->active_frame.width;
    output->height = decoder->active_frame.height;
    output->coded_width = decoder->active_frame.width;
    output->coded_height = decoder->active_frame.height;
    output->planes[0] = decoder->active_frame.y;
    output->planes[1] = decoder->active_frame.uv;
    output->strides[0] = decoder->active_frame.y_stride;
    output->strides[1] = decoder->active_frame.uv_stride;
    output->info_changed = decoder->last_width != output->width ||
                           decoder->last_height != output->height ||
                           decoder->last_y_stride != output->strides[0] ||
                           decoder->last_uv_stride != output->strides[1];
    decoder->last_width = output->width;
    decoder->last_height = output->height;
    decoder->last_y_stride = output->strides[0];
    decoder->last_uv_stride = output->strides[1];
    output->backend_frame = &decoder->active_frame;
    decoder->frame_outstanding = 1;
    return GO_VIDEO_DECODER_RESULT_OK;
}

static void mpp_release(GoVideoDecoder* base, GoDecodedVideoFrame* frame) {
    GoMppVideoDecoder* decoder = (GoMppVideoDecoder*)base;
    if (decoder->frame_outstanding && frame->backend_frame == &decoder->active_frame) {
        go_mpp_library_release_frame(decoder->library, &decoder->active_frame);
        memset(&decoder->active_frame, 0, sizeof(decoder->active_frame));
        decoder->frame_outstanding = 0;
    }
}

static int mpp_reset(GoVideoDecoder* base) {
    GoMppVideoDecoder* decoder = (GoMppVideoDecoder*)base;
    if (decoder->frame_outstanding) {
        snprintf(decoder->error, sizeof(decoder->error),
                 "MPP reset refused with a frame outstanding");
        return -1;
    }
    int result = go_mpp_library_reset(decoder->library);
    if (result < 0)
        copy_mpp_error(decoder);
    else {
        decoder->last_width = 0;
        decoder->last_height = 0;
        decoder->last_y_stride = 0;
        decoder->last_uv_stride = 0;
        decoder->error[0] = '\0';
    }
    return result;
}

static const char* mpp_last_error(const GoVideoDecoder* base) {
    const GoMppVideoDecoder* decoder = (const GoMppVideoDecoder*)base;
    return decoder->error[0] ? decoder->error : "MPP H.264 decoder failure";
}

static void mpp_destroy(GoVideoDecoder* base) {
    GoMppVideoDecoder* decoder = (GoMppVideoDecoder*)base;
    if (decoder->frame_outstanding)
        go_mpp_library_release_frame(decoder->library, &decoder->active_frame);
    go_mpp_library_close(decoder->library);
    free(decoder);
}

static const GoVideoDecoderOps mpp_ops = {
    .name = "rockchip-mpp",
    .backend = GO_VIDEO_DECODER_BACKEND_MPP,
    .submit_access_unit = mpp_submit,
    .receive_frame = mpp_receive,
    .release_frame = mpp_release,
    .reset = mpp_reset,
    .last_error = mpp_last_error,
    .destroy = mpp_destroy,
};

GoVideoDecoder* go_video_decoder_mpp_create(int max_width, int max_height, char* error,
                                            size_t error_capacity) {
    GoMppVideoDecoder* decoder = calloc(1, sizeof(*decoder));
    if (!decoder)
        return NULL;
    go_video_decoder_initialize(&decoder->base, &mpp_ops);
    decoder->library = go_mpp_library_open(max_width, max_height);
    if (!go_mpp_library_ready(decoder->library)) {
        copy_mpp_error(decoder);
        if (error && error_capacity > 0)
            snprintf(error, error_capacity, "%s", decoder->error);
        mpp_destroy(&decoder->base);
        return NULL;
    }
    fprintf(stderr, "MPP plugin: %s\n", go_mpp_library_path(decoder->library));
    return &decoder->base;
}
