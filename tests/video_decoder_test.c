#include "video_decoder.h"

#include <assert.h>
#include <string.h>

typedef struct {
    GoVideoDecoder base;
    GoVideoDecoderResult submit_result;
    int frames_remaining;
    int submitted;
    int received;
    int released;
    int reset;
    int destroyed;
} FakeDecoder;

static GoVideoDecoderResult fake_submit(GoVideoDecoder* base, const uint8_t* data, size_t length) {
    FakeDecoder* decoder = (FakeDecoder*)base;
    assert(data != NULL);
    assert(length > 0);
    decoder->submitted++;
    return decoder->submit_result;
}

static GoVideoDecoderResult fake_receive(GoVideoDecoder* base, GoDecodedVideoFrame* frame) {
    FakeDecoder* decoder = (FakeDecoder*)base;
    if (decoder->frames_remaining == 0)
        return GO_VIDEO_DECODER_RESULT_AGAIN;
    decoder->frames_remaining--;
    decoder->received++;
    frame->format = GO_VIDEO_PIXEL_FORMAT_NV12;
    frame->width = 1280;
    frame->height = 720;
    frame->backend_frame = decoder;
    return GO_VIDEO_DECODER_RESULT_OK;
}

static void fake_release(GoVideoDecoder* base, GoDecodedVideoFrame* frame) {
    FakeDecoder* decoder = (FakeDecoder*)base;
    assert(frame->backend_frame == decoder);
    decoder->released++;
}

static int fake_reset(GoVideoDecoder* base) {
    FakeDecoder* decoder = (FakeDecoder*)base;
    decoder->reset++;
    return 0;
}

static const char* fake_last_error(const GoVideoDecoder* base) {
    (void)base;
    return "fake failure";
}

static void fake_destroy(GoVideoDecoder* base) {
    FakeDecoder* decoder = (FakeDecoder*)base;
    decoder->destroyed++;
}

static const GoVideoDecoderOps fake_ops = {
    .name = "fake",
    .backend = GO_VIDEO_DECODER_BACKEND_MPP,
    .submit_access_unit = fake_submit,
    .receive_frame = fake_receive,
    .release_frame = fake_release,
    .reset = fake_reset,
    .last_error = fake_last_error,
    .destroy = fake_destroy,
};

int main(void) {
    GoVideoDecoderPreference preference;
    assert(go_video_decoder_preference_parse(NULL, &preference) == 0);
    assert(preference == GO_VIDEO_DECODER_PREFERENCE_AUTO);
    assert(go_video_decoder_preference_parse("mpp", &preference) == 0);
    assert(preference == GO_VIDEO_DECODER_PREFERENCE_MPP);
    assert(go_video_decoder_preference_parse("invalid", &preference) == -1);

    const uint8_t rockchip[] = "rockchip,rk3566\0rockchip,rk3568";
    const uint8_t allwinner[] = "allwinner,sun50i-h700\0allwinner,sunxi-unknown";
    assert(go_video_decoder_platform(rockchip, sizeof(rockchip), 1) == GO_VIDEO_PLATFORM_ROCKCHIP);
    assert(go_video_decoder_platform(allwinner, sizeof(allwinner), 1) ==
           GO_VIDEO_PLATFORM_ALLWINNER);
    assert(go_video_decoder_platform(NULL, 0, 1) == GO_VIDEO_PLATFORM_OTHER_ARM);
    assert(go_video_decoder_platform(rockchip, sizeof(rockchip), 0) == GO_VIDEO_PLATFORM_NON_ARM);

    GoVideoDecoderBackend candidates[3];
    assert(go_video_decoder_candidate_order(GO_VIDEO_DECODER_PREFERENCE_AUTO,
                                            GO_VIDEO_PLATFORM_ROCKCHIP, candidates, 3) == 2);
    assert(candidates[0] == GO_VIDEO_DECODER_BACKEND_MPP);
    assert(candidates[1] == GO_VIDEO_DECODER_BACKEND_SOFTWARE);
    assert(go_video_decoder_candidate_order(GO_VIDEO_DECODER_PREFERENCE_AUTO,
                                            GO_VIDEO_PLATFORM_ALLWINNER, candidates, 3) == 2);
    assert(candidates[0] == GO_VIDEO_DECODER_BACKEND_CEDAR);
    assert(candidates[1] == GO_VIDEO_DECODER_BACKEND_SOFTWARE);
    assert(go_video_decoder_candidate_order(GO_VIDEO_DECODER_PREFERENCE_AUTO,
                                            GO_VIDEO_PLATFORM_OTHER_ARM, candidates, 3) == 3);
    assert(candidates[0] == GO_VIDEO_DECODER_BACKEND_MPP);
    assert(candidates[1] == GO_VIDEO_DECODER_BACKEND_CEDAR);
    assert(candidates[2] == GO_VIDEO_DECODER_BACKEND_SOFTWARE);
    assert(go_video_decoder_candidate_order(GO_VIDEO_DECODER_PREFERENCE_AUTO,
                                            GO_VIDEO_PLATFORM_NON_ARM, candidates, 3) == 1);
    assert(candidates[0] == GO_VIDEO_DECODER_BACKEND_SOFTWARE);
    assert(go_video_decoder_candidate_order(GO_VIDEO_DECODER_PREFERENCE_MPP,
                                            GO_VIDEO_PLATFORM_NON_ARM, candidates, 3) == 1);
    assert(candidates[0] == GO_VIDEO_DECODER_BACKEND_MPP);
    assert(go_video_decoder_candidate_order(GO_VIDEO_DECODER_PREFERENCE_CEDAR,
                                            GO_VIDEO_PLATFORM_ROCKCHIP, candidates, 3) == 1);
    assert(candidates[0] == GO_VIDEO_DECODER_BACKEND_CEDAR);
    assert(go_video_decoder_candidate_order(GO_VIDEO_DECODER_PREFERENCE_SOFTWARE,
                                            GO_VIDEO_PLATFORM_ROCKCHIP, candidates, 3) == 1);
    assert(candidates[0] == GO_VIDEO_DECODER_BACKEND_SOFTWARE);

    FakeDecoder decoder = {
        .submit_result = GO_VIDEO_DECODER_RESULT_OK,
        .frames_remaining = 2,
    };
    go_video_decoder_initialize(&decoder.base, &fake_ops);

    assert(strcmp(go_video_decoder_name(&decoder.base), "fake") == 0);
    assert(go_video_decoder_backend(&decoder.base) == GO_VIDEO_DECODER_BACKEND_MPP);
    const uint8_t access_unit[] = {0, 0, 0, 1, 0x65};
    assert(go_video_decoder_submit_access_unit(&decoder.base, access_unit, sizeof(access_unit)) ==
           GO_VIDEO_DECODER_RESULT_OK);

    GoDecodedVideoFrame frame;
    assert(go_video_decoder_receive_frame(&decoder.base, &frame) == GO_VIDEO_DECODER_RESULT_OK);
    assert(frame.backend_frame == &decoder);
    go_video_decoder_release_frame(&decoder.base, &frame);
    assert(frame.backend_frame == NULL);
    assert(go_video_decoder_receive_frame(&decoder.base, &frame) == GO_VIDEO_DECODER_RESULT_OK);
    go_video_decoder_release_frame(&decoder.base, &frame);
    assert(go_video_decoder_receive_frame(&decoder.base, &frame) == GO_VIDEO_DECODER_RESULT_AGAIN);
    assert(decoder.submitted == 1);
    assert(decoder.received == 2);
    assert(decoder.released == 2);

    decoder.submit_result = GO_VIDEO_DECODER_RESULT_AGAIN;
    assert(go_video_decoder_submit_access_unit(&decoder.base, access_unit, sizeof(access_unit)) ==
           GO_VIDEO_DECODER_RESULT_AGAIN);
    decoder.submit_result = GO_VIDEO_DECODER_RESULT_FATAL;
    assert(go_video_decoder_submit_access_unit(&decoder.base, access_unit, sizeof(access_unit)) ==
           GO_VIDEO_DECODER_RESULT_FATAL);
    assert(strcmp(go_video_decoder_last_error(&decoder.base), "fake failure") == 0);
    assert(go_video_decoder_reset(&decoder.base) == 0);
    go_video_decoder_destroy(&decoder.base);
    assert(decoder.reset == 1);
    assert(decoder.destroyed == 1);
    return 0;
}
