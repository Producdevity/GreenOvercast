#include "video_frame_copy.h"

#include <assert.h>
#include <stdlib.h>
#include <string.h>

static void test_nv12(int width, int height, int source_padding, int destination_padding) {
    int chroma_height = (height + 1) / 2;
    int chroma_width = width + width % 2;
    int source_stride = width + source_padding;
    int destination_stride = width + destination_padding;
    size_t source_size = (size_t)source_stride * (size_t)(height + chroma_height);
    size_t destination_size = (size_t)destination_stride * (size_t)(height + chroma_height);
    uint8_t* source = malloc(source_size);
    uint8_t* destination = malloc(destination_size);
    assert(source && destination);
    memset(source, 0xa5, source_size);
    memset(destination, 0, destination_size);

    GoDecodedVideoFrame frame = {
        .format = GO_VIDEO_PIXEL_FORMAT_NV12,
        .width = width,
        .height = height,
        .planes = {source, source + (size_t)source_stride * (size_t)height, NULL},
        .strides = {source_stride, source_stride, 0},
    };
    uint8_t* planes[3] = {
        destination,
        destination + (size_t)destination_stride * (size_t)height,
        NULL,
    };
    int strides[3] = {destination_stride, destination_stride, 0};
    assert(go_video_frame_copy(&frame, width, height, planes, strides) == 0);
    for (int row = 0; row < height; ++row)
        assert(memcmp(planes[0] + (size_t)row * (size_t)destination_stride,
                      frame.planes[0] + (size_t)row * (size_t)source_stride, (size_t)width) == 0);
    for (int row = 0; row < chroma_height; ++row)
        assert(memcmp(planes[1] + (size_t)row * (size_t)destination_stride,
                      frame.planes[1] + (size_t)row * (size_t)source_stride,
                      (size_t)chroma_width) == 0);
    free(destination);
    free(source);
}

static void test_yuv420p(void) {
    uint8_t y[8 * 5];
    uint8_t u[4 * 3];
    uint8_t v[4 * 3];
    uint8_t output_y[10 * 5];
    uint8_t output_u[6 * 3];
    uint8_t output_v[6 * 3];
    memset(y, 1, sizeof(y));
    memset(u, 2, sizeof(u));
    memset(v, 3, sizeof(v));
    GoDecodedVideoFrame frame = {
        .format = GO_VIDEO_PIXEL_FORMAT_YUV420P,
        .width = 8,
        .height = 5,
        .planes = {y, u, v},
        .strides = {8, 4, 4},
    };
    uint8_t* planes[3] = {output_y, output_u, output_v};
    int strides[3] = {10, 6, 6};
    assert(go_video_frame_copy(&frame, 8, 5, planes, strides) == 0);
    assert(output_y[0] == 1 && output_y[40] == 1);
    assert(output_u[0] == 2 && output_u[12] == 2);
    assert(output_v[0] == 3 && output_v[12] == 3);
}

int main(void) {
    test_nv12(640, 360, 32, 16);
    test_nv12(1280, 720, 64, 32);
    test_nv12(1920, 1080, 128, 64);
    test_nv12(8, 5, 4, 2);
    test_nv12(7, 5, 3, 2);
    test_yuv420p();

    uint8_t plane[16] = {0};
    GoDecodedVideoFrame invalid = {
        .format = GO_VIDEO_PIXEL_FORMAT_NV12,
        .width = 8,
        .height = 4,
        .planes = {plane, plane, NULL},
        .strides = {7, 8, 0},
    };
    assert(go_video_frame_validate(&invalid, 8, 4) == -1);
    invalid.strides[0] = 8;
    assert(go_video_frame_validate(&invalid, 7, 4) == -1);
    invalid.format = (GoVideoPixelFormat)99;
    assert(go_video_frame_validate(&invalid, 8, 4) == -1);
    return 0;
}
