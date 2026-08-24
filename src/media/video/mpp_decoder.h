#ifndef GREENOVERCAST_MPP_DECODER_H
#define GREENOVERCAST_MPP_DECODER_H

#include <stddef.h>
#include <stdint.h>

#if defined(__GNUC__)
#define GO_MPP_API __attribute__((visibility("default")))
#else
#define GO_MPP_API
#endif

#define GO_MPP_DECODER_ABI_VERSION 1u

typedef struct GoMppDecoder GoMppDecoder;

typedef struct {
    const uint8_t* y;
    const uint8_t* uv;
    int width;
    int height;
    int y_stride;
    int uv_stride;
    void* owner;
} GoMppFrame;

GO_MPP_API uint32_t go_mpp_decoder_abi_version(void);
GO_MPP_API GoMppDecoder* go_mpp_decoder_create(int max_width, int max_height);
GO_MPP_API int go_mpp_decoder_submit(GoMppDecoder* decoder, const uint8_t* data, size_t length);
GO_MPP_API int go_mpp_decoder_receive(GoMppDecoder* decoder, GoMppFrame* frame);
GO_MPP_API void go_mpp_decoder_release_frame(GoMppDecoder* decoder, GoMppFrame* frame);
GO_MPP_API int go_mpp_decoder_reset(GoMppDecoder* decoder);
GO_MPP_API const char* go_mpp_decoder_last_error(GoMppDecoder* decoder);
GO_MPP_API void go_mpp_decoder_destroy(GoMppDecoder* decoder);

#endif
