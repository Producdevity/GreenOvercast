#ifndef GREENOVERCAST_CEDAR_DECODER_H
#define GREENOVERCAST_CEDAR_DECODER_H

#include <stddef.h>
#include <stdint.h>

#if defined(__GNUC__)
#define GO_CEDAR_API __attribute__((visibility("default")))
#else
#define GO_CEDAR_API
#endif

typedef struct GoCedarDecoder GoCedarDecoder;

typedef struct {
    const uint8_t* y;
    const uint8_t* uv;
    int width;
    int height;
    int y_stride;
    int uv_stride;
} GoCedarFrame;

GO_CEDAR_API GoCedarDecoder* go_cedar_v1_create(int width, int height);
GO_CEDAR_API int go_cedar_v1_feed(GoCedarDecoder* decoder, const uint8_t* annex_b, size_t length,
                                  GoCedarFrame* frame);
GO_CEDAR_API int go_cedar_v1_flush(GoCedarDecoder* decoder, GoCedarFrame* frame);
GO_CEDAR_API const char* go_cedar_v1_last_error(const GoCedarDecoder* decoder);
GO_CEDAR_API void go_cedar_v1_destroy(GoCedarDecoder* decoder);

#endif
