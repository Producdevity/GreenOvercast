#include "video_decoder.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cedar_loader.h"

typedef struct {
    GoVideoDecoder base;
    GoCedarLibrary* library;
    GoCedarFrame pending_frame;
    int max_width;
    int max_height;
    int frame_pending;
    int frame_outstanding;
    int last_width;
    int last_height;
    int last_y_stride;
    int last_uv_stride;
    char error[256];
} GoCedarVideoDecoder;

static int open_cedar(GoCedarVideoDecoder* decoder) {
    decoder->library = go_cedar_library_open(decoder->max_width, decoder->max_height);
    if (!go_cedar_library_ready(decoder->library)) {
        snprintf(decoder->error, sizeof(decoder->error), "%s",
                 go_cedar_library_error(decoder->library));
        go_cedar_library_close(decoder->library);
        decoder->library = NULL;
        return -1;
    }
    return 0;
}

static GoVideoDecoderResult cedar_submit(GoVideoDecoder* base, const uint8_t* data, size_t length) {
    GoCedarVideoDecoder* decoder = (GoCedarVideoDecoder*)base;
    if (decoder->frame_pending || decoder->frame_outstanding)
        return GO_VIDEO_DECODER_RESULT_AGAIN;
    int result = go_cedar_library_feed(decoder->library, data, length, &decoder->pending_frame);
    if (result < 0) {
        snprintf(decoder->error, sizeof(decoder->error), "%s",
                 go_cedar_library_error(decoder->library));
        return GO_VIDEO_DECODER_RESULT_FATAL;
    }
    decoder->frame_pending = result > 0;
    return GO_VIDEO_DECODER_RESULT_OK;
}

static GoVideoDecoderResult cedar_receive(GoVideoDecoder* base, GoDecodedVideoFrame* output) {
    GoCedarVideoDecoder* decoder = (GoCedarVideoDecoder*)base;
    if (!decoder->frame_pending)
        return GO_VIDEO_DECODER_RESULT_AGAIN;
    GoCedarFrame* frame = &decoder->pending_frame;
    output->format = GO_VIDEO_PIXEL_FORMAT_NV12;
    output->color_range = GO_VIDEO_COLOR_RANGE_LIMITED;
    output->width = frame->width;
    output->height = frame->height;
    output->coded_width = frame->y_stride;
    output->coded_height = frame->height;
    output->planes[0] = frame->y;
    output->planes[1] = frame->uv;
    output->strides[0] = frame->y_stride;
    output->strides[1] = frame->uv_stride;
    output->info_changed = decoder->last_width != output->width ||
                           decoder->last_height != output->height ||
                           decoder->last_y_stride != output->strides[0] ||
                           decoder->last_uv_stride != output->strides[1];
    decoder->last_width = output->width;
    decoder->last_height = output->height;
    decoder->last_y_stride = output->strides[0];
    decoder->last_uv_stride = output->strides[1];
    output->backend_frame = decoder;
    decoder->frame_pending = 0;
    decoder->frame_outstanding = 1;
    return GO_VIDEO_DECODER_RESULT_OK;
}

static void cedar_release(GoVideoDecoder* base, GoDecodedVideoFrame* frame) {
    GoCedarVideoDecoder* decoder = (GoCedarVideoDecoder*)base;
    if (frame->backend_frame == decoder)
        decoder->frame_outstanding = 0;
}

static int cedar_reset(GoVideoDecoder* base) {
    GoCedarVideoDecoder* decoder = (GoCedarVideoDecoder*)base;
    go_cedar_library_close(decoder->library);
    decoder->library = NULL;
    decoder->frame_pending = 0;
    decoder->frame_outstanding = 0;
    decoder->last_width = 0;
    decoder->last_height = 0;
    decoder->last_y_stride = 0;
    decoder->last_uv_stride = 0;
    memset(&decoder->pending_frame, 0, sizeof(decoder->pending_frame));
    return open_cedar(decoder);
}

static const char* cedar_last_error(const GoVideoDecoder* base) {
    const GoCedarVideoDecoder* decoder = (const GoCedarVideoDecoder*)base;
    return decoder->error[0] ? decoder->error : "Cedar H.264 decoder failure";
}

static void cedar_destroy(GoVideoDecoder* base) {
    GoCedarVideoDecoder* decoder = (GoCedarVideoDecoder*)base;
    go_cedar_library_close(decoder->library);
    free(decoder);
}

static const GoVideoDecoderOps cedar_ops = {
    .name = "cedar-h616",
    .backend = GO_VIDEO_DECODER_BACKEND_CEDAR,
    .submit_access_unit = cedar_submit,
    .receive_frame = cedar_receive,
    .release_frame = cedar_release,
    .reset = cedar_reset,
    .last_error = cedar_last_error,
    .destroy = cedar_destroy,
};

GoVideoDecoder* go_video_decoder_cedar_create(int max_width, int max_height, char* error,
                                              size_t error_capacity) {
    if (max_width <= 0 || max_height <= 0) {
        if (error && error_capacity > 0)
            snprintf(error, error_capacity, "invalid Cedar decoder dimensions");
        return NULL;
    }
    GoCedarVideoDecoder* decoder = calloc(1, sizeof(*decoder));
    if (!decoder)
        return NULL;
    go_video_decoder_initialize(&decoder->base, &cedar_ops);
    decoder->max_width = max_width;
    decoder->max_height = max_height;
    if (open_cedar(decoder) != 0) {
        if (error && error_capacity > 0)
            snprintf(error, error_capacity, "%s", decoder->error);
        cedar_destroy(&decoder->base);
        return NULL;
    }
    return &decoder->base;
}
