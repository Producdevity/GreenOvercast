#ifndef GREENOVERCAST_VIDEO_DECODER_H
#define GREENOVERCAST_VIDEO_DECODER_H

#include <stddef.h>
#include <stdint.h>

typedef enum {
    GO_VIDEO_DECODER_RESULT_FATAL = -1,
    GO_VIDEO_DECODER_RESULT_AGAIN = 0,
    GO_VIDEO_DECODER_RESULT_OK = 1,
} GoVideoDecoderResult;

typedef enum {
    GO_VIDEO_DECODER_BACKEND_NONE,
    GO_VIDEO_DECODER_BACKEND_SOFTWARE,
    GO_VIDEO_DECODER_BACKEND_CEDAR,
    GO_VIDEO_DECODER_BACKEND_MPP,
    GO_VIDEO_DECODER_BACKEND_V4L2_REQUEST,
} GoVideoDecoderBackend;

typedef enum {
    GO_VIDEO_DECODER_PREFERENCE_AUTO,
    GO_VIDEO_DECODER_PREFERENCE_MPP,
    GO_VIDEO_DECODER_PREFERENCE_CEDAR,
    GO_VIDEO_DECODER_PREFERENCE_SOFTWARE,
    GO_VIDEO_DECODER_PREFERENCE_V4L2_REQUEST,
} GoVideoDecoderPreference;

typedef enum {
    GO_VIDEO_PLATFORM_ROCKCHIP,
    GO_VIDEO_PLATFORM_ALLWINNER,
    GO_VIDEO_PLATFORM_OTHER_ARM,
    GO_VIDEO_PLATFORM_NON_ARM,
} GoVideoPlatform;

typedef enum {
    GO_VIDEO_PIXEL_FORMAT_NV12,
    GO_VIDEO_PIXEL_FORMAT_YUV420P,
} GoVideoPixelFormat;

typedef enum {
    GO_VIDEO_COLOR_RANGE_UNSPECIFIED,
    GO_VIDEO_COLOR_RANGE_LIMITED,
    GO_VIDEO_COLOR_RANGE_FULL,
} GoVideoColorRange;

typedef struct {
    GoVideoPixelFormat format;
    GoVideoColorRange color_range;
    int width;
    int height;
    int coded_width;
    int coded_height;
    const uint8_t* planes[3];
    int strides[3];
    int corrupt;
    int info_changed;
    void* backend_frame;
} GoDecodedVideoFrame;

typedef struct GoVideoDecoder GoVideoDecoder;

typedef struct {
    const char* name;
    GoVideoDecoderBackend backend;
    GoVideoDecoderResult (*submit_access_unit)(GoVideoDecoder* decoder, const uint8_t* data,
                                               size_t length);
    GoVideoDecoderResult (*receive_frame)(GoVideoDecoder* decoder, GoDecodedVideoFrame* frame);
    void (*release_frame)(GoVideoDecoder* decoder, GoDecodedVideoFrame* frame);
    int (*reset)(GoVideoDecoder* decoder);
    const char* (*last_error)(const GoVideoDecoder* decoder);
    void (*destroy)(GoVideoDecoder* decoder);
} GoVideoDecoderOps;

struct GoVideoDecoder {
    const GoVideoDecoderOps* ops;
};

typedef struct {
    int max_width;
    int max_height;
    GoVideoDecoderPreference preference;
} GoVideoDecoderSelectionConfig;

typedef struct {
    GoVideoDecoder* active;
    GoVideoDecoder* software;
    int allow_runtime_fallback;
    uint64_t init_failures;
} GoVideoDecoderSelection;

void go_video_decoder_initialize(GoVideoDecoder* decoder, const GoVideoDecoderOps* ops);
int go_video_decoder_preference_parse(const char* value, GoVideoDecoderPreference* preference);
GoVideoPlatform go_video_decoder_platform(const uint8_t* compatible, size_t length, int is_arm);
size_t go_video_decoder_candidate_order(GoVideoDecoderPreference preference,
                                        GoVideoPlatform platform, GoVideoDecoderBackend* output,
                                        size_t capacity);
const char* go_video_decoder_name(const GoVideoDecoder* decoder);
GoVideoDecoderBackend go_video_decoder_backend(const GoVideoDecoder* decoder);
GoVideoDecoderResult go_video_decoder_submit_access_unit(GoVideoDecoder* decoder,
                                                         const uint8_t* data, size_t length);
GoVideoDecoderResult go_video_decoder_receive_frame(GoVideoDecoder* decoder,
                                                    GoDecodedVideoFrame* frame);
/* A successful receive owns one backend frame until this function is called. */
void go_video_decoder_release_frame(GoVideoDecoder* decoder, GoDecodedVideoFrame* frame);
int go_video_decoder_reset(GoVideoDecoder* decoder);
const char* go_video_decoder_last_error(const GoVideoDecoder* decoder);
void go_video_decoder_destroy(GoVideoDecoder* decoder);

int go_video_decoder_selection_create(const GoVideoDecoderSelectionConfig* config,
                                      GoVideoDecoderSelection* selection, char* error,
                                      size_t error_capacity);
int go_video_decoder_selection_fallback(GoVideoDecoderSelection* selection, char* error,
                                        size_t error_capacity);
void go_video_decoder_selection_destroy(GoVideoDecoderSelection* selection);

GoVideoDecoder* go_video_decoder_ffmpeg_create(char* error, size_t error_capacity);
GoVideoDecoder* go_video_decoder_cedar_create(int max_width, int max_height, char* error,
                                              size_t error_capacity);
GoVideoDecoder* go_video_decoder_mpp_create(int max_width, int max_height, char* error,
                                            size_t error_capacity);
GoVideoDecoder* go_video_decoder_v4l2_request_create(int max_width, int max_height, char* error,
                                                     size_t error_capacity);

#endif
