#include "video_decoder.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

typedef struct {
    GoVideoDecoder base;
    GoVideoDecoderBackend backend;
    int resets;
    int destroys;
} FakeDecoder;

static FakeDecoder software;
static FakeDecoder cedar;
static FakeDecoder mpp;
static int cedar_available = 1;
static int mpp_available = 1;

static GoVideoDecoderResult fake_submit(GoVideoDecoder* decoder, const uint8_t* data,
                                        size_t length) {
    (void)decoder;
    (void)data;
    (void)length;
    return GO_VIDEO_DECODER_RESULT_OK;
}

static GoVideoDecoderResult fake_receive(GoVideoDecoder* decoder, GoDecodedVideoFrame* frame) {
    (void)decoder;
    (void)frame;
    return GO_VIDEO_DECODER_RESULT_AGAIN;
}

static void fake_release(GoVideoDecoder* decoder, GoDecodedVideoFrame* frame) {
    (void)decoder;
    (void)frame;
}

static int fake_reset(GoVideoDecoder* decoder) {
    ((FakeDecoder*)decoder)->resets++;
    return 0;
}

static const char* fake_error(const GoVideoDecoder* decoder) {
    (void)decoder;
    return "fake decoder failure";
}

static void fake_destroy(GoVideoDecoder* decoder) {
    ((FakeDecoder*)decoder)->destroys++;
}

static const GoVideoDecoderOps software_ops = {
    .name = "fake-software",
    .backend = GO_VIDEO_DECODER_BACKEND_SOFTWARE,
    .submit_access_unit = fake_submit,
    .receive_frame = fake_receive,
    .release_frame = fake_release,
    .reset = fake_reset,
    .last_error = fake_error,
    .destroy = fake_destroy,
};

static const GoVideoDecoderOps cedar_ops = {
    .name = "fake-cedar",
    .backend = GO_VIDEO_DECODER_BACKEND_CEDAR,
    .submit_access_unit = fake_submit,
    .receive_frame = fake_receive,
    .release_frame = fake_release,
    .reset = fake_reset,
    .last_error = fake_error,
    .destroy = fake_destroy,
};

static const GoVideoDecoderOps mpp_ops = {
    .name = "fake-mpp",
    .backend = GO_VIDEO_DECODER_BACKEND_MPP,
    .submit_access_unit = fake_submit,
    .receive_frame = fake_receive,
    .release_frame = fake_release,
    .reset = fake_reset,
    .last_error = fake_error,
    .destroy = fake_destroy,
};

static GoVideoDecoder* initialize(FakeDecoder* decoder, const GoVideoDecoderOps* ops) {
    decoder->base.ops = ops;
    return &decoder->base;
}

GoVideoDecoder* go_video_decoder_ffmpeg_create(char* error, size_t error_capacity) {
    (void)error;
    (void)error_capacity;
    return initialize(&software, &software_ops);
}

GoVideoDecoder* go_video_decoder_cedar_create(int max_width, int max_height, char* error,
                                              size_t error_capacity) {
    (void)max_width;
    (void)max_height;
    if (!cedar_available) {
        if (error && error_capacity > 0)
            snprintf(error, error_capacity, "fake Cedar unavailable");
        return NULL;
    }
    return initialize(&cedar, &cedar_ops);
}

GoVideoDecoder* go_video_decoder_mpp_create(int max_width, int max_height, char* error,
                                            size_t error_capacity) {
    (void)max_width;
    (void)max_height;
    if (mpp_available)
        return initialize(&mpp, &mpp_ops);
    if (error && error_capacity > 0)
        snprintf(error, error_capacity, "fake MPP unavailable");
    return NULL;
}

int main(void) {
    GoVideoDecoderSelection selection;
    char error[128];
    GoVideoDecoderSelectionConfig config = {
        .max_width = 1280,
        .max_height = 720,
        .preference = GO_VIDEO_DECODER_PREFERENCE_MPP,
    };

    assert(go_video_decoder_selection_create(&config, &selection, error, sizeof(error)) == 0);
    assert(selection.active == &mpp.base);
    assert(selection.software == NULL);
    assert(selection.allow_runtime_fallback == 0);
    go_video_decoder_selection_destroy(&selection);
    assert(mpp.destroys == 1);

    mpp_available = 0;
    cedar_available = 0;
    config.preference = GO_VIDEO_DECODER_PREFERENCE_AUTO;
    assert(go_video_decoder_selection_create(&config, &selection, error, sizeof(error)) == 0);
    assert(selection.active == &software.base);
    assert(selection.software == &software.base);
    go_video_decoder_selection_destroy(&selection);
    assert(software.destroys == 1);

    selection = (GoVideoDecoderSelection){
        .active = initialize(&mpp, &mpp_ops),
        .software = initialize(&software, &software_ops),
        .allow_runtime_fallback = 1,
    };
    assert(go_video_decoder_selection_fallback(&selection, error, sizeof(error)) == 0);
    assert(selection.active == &software.base);
    assert(selection.allow_runtime_fallback == 0);
    assert(mpp.destroys == 2);
    assert(software.resets == 1);
    go_video_decoder_selection_destroy(&selection);
    assert(software.destroys == 2);

    config.preference = GO_VIDEO_DECODER_PREFERENCE_MPP;
    assert(go_video_decoder_selection_create(&config, &selection, error, sizeof(error)) == -1);
    assert(strstr(error, "fake MPP unavailable") != NULL);

    config.max_width = 0;
    assert(go_video_decoder_selection_create(&config, &selection, error, sizeof(error)) == -1);
    assert(strstr(error, "invalid video decoder configuration") != NULL);
    return 0;
}
