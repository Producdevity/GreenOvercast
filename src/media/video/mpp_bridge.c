#include "mpp_decoder.h"

#include <limits.h>
#include <mpp_buffer.h>
#include <mpp_err.h>
#include <mpp_frame.h>
#include <mpp_packet.h>
#include <mpp_task.h>
#include <rk_mpi.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define GO_MPP_FRAME_LIMIT 24

static _Thread_local char creation_error[256];

struct GoMppDecoder {
    MppCtx context;
    MppApi* api;
    MppBufferGroup frame_group;
    int initialized;
    int max_width;
    int max_height;
    int width;
    int height;
    int horizontal_stride;
    int vertical_stride;
    size_t buffer_size;
    char error[256];
};

static void set_error(GoMppDecoder* decoder, const char* message) {
    snprintf(decoder->error, sizeof(decoder->error), "%s", message);
}

static void set_mpp_error(GoMppDecoder* decoder, const char* operation, MPP_RET result) {
    snprintf(decoder->error, sizeof(decoder->error), "%s (MPP error %d)", operation, result);
}

static int valid_output(GoMppDecoder* decoder, MppFrame frame) {
    RK_U32 width = mpp_frame_get_width(frame);
    RK_U32 height = mpp_frame_get_height(frame);
    RK_U32 horizontal_stride = mpp_frame_get_hor_stride(frame);
    RK_U32 vertical_stride = mpp_frame_get_ver_stride(frame);
    MppFrameFormat format = mpp_frame_get_fmt(frame);
    if (width == 0 || height == 0 || width > (RK_U32)decoder->max_width ||
        height > (RK_U32)decoder->max_height || horizontal_stride < width ||
        vertical_stride < height || width > INT_MAX || height > INT_MAX ||
        horizontal_stride > INT_MAX || vertical_stride > INT_MAX) {
        set_error(decoder, "MPP returned invalid output dimensions");
        return 0;
    }
    if (MPP_FRAME_FMT_IS_FBC(format) || MPP_FRAME_FMT_IS_TILE(format) ||
        (format & MPP_FRAME_FMT_MASK) != MPP_FMT_YUV420SP) {
        set_error(decoder, "MPP returned an unsupported output format");
        return 0;
    }
    if ((size_t)horizontal_stride > SIZE_MAX / (size_t)vertical_stride) {
        set_error(decoder, "MPP output stride calculation overflowed");
        return 0;
    }
    size_t y_size = (size_t)horizontal_stride * (size_t)vertical_stride;
    size_t uv_rows = ((size_t)height + 1u) / 2u;
    if (uv_rows > (SIZE_MAX - y_size) / (size_t)horizontal_stride) {
        set_error(decoder, "MPP output buffer calculation overflowed");
        return 0;
    }
    size_t required = y_size + uv_rows * (size_t)horizontal_stride;
    size_t buffer_size = mpp_frame_get_buf_size(frame);
    if (buffer_size < required) {
        set_error(decoder, "MPP output buffer is smaller than its visible frame");
        return 0;
    }
    return 1;
}

static int handle_info_change(GoMppDecoder* decoder, MppFrame frame) {
    if (!valid_output(decoder, frame))
        return -1;
    size_t buffer_size = mpp_frame_get_buf_size(frame);
    if (!decoder->frame_group) {
        MPP_RET result = mpp_buffer_group_get_internal(&decoder->frame_group, MPP_BUFFER_TYPE_DRM);
        if (result != MPP_OK) {
            set_mpp_error(decoder, "MPP frame-buffer group creation failed", result);
            return -1;
        }
    } else {
        MPP_RET result = mpp_buffer_group_clear(decoder->frame_group);
        if (result != MPP_OK) {
            set_mpp_error(decoder, "MPP frame-buffer group reset failed", result);
            return -1;
        }
    }
    MPP_RET result =
        mpp_buffer_group_limit_config(decoder->frame_group, buffer_size, GO_MPP_FRAME_LIMIT);
    if (result != MPP_OK) {
        set_mpp_error(decoder, "MPP frame-buffer limit failed", result);
        return -1;
    }
    result =
        decoder->api->control(decoder->context, MPP_DEC_SET_EXT_BUF_GROUP, decoder->frame_group);
    if (result != MPP_OK) {
        set_mpp_error(decoder, "MPP frame-buffer group attachment failed", result);
        return -1;
    }
    result = decoder->api->control(decoder->context, MPP_DEC_SET_INFO_CHANGE_READY, NULL);
    if (result != MPP_OK) {
        set_mpp_error(decoder, "MPP info-change acknowledgement failed", result);
        return -1;
    }

    decoder->width = (int)mpp_frame_get_width(frame);
    decoder->height = (int)mpp_frame_get_height(frame);
    decoder->horizontal_stride = (int)mpp_frame_get_hor_stride(frame);
    decoder->vertical_stride = (int)mpp_frame_get_ver_stride(frame);
    decoder->buffer_size = buffer_size;
    fprintf(stderr, "MPP output: NV12 %dx%d, stride %dx%d, pool limit %d\n", decoder->width,
            decoder->height, decoder->horizontal_stride, decoder->vertical_stride,
            GO_MPP_FRAME_LIMIT);
    return 0;
}

uint32_t go_mpp_decoder_abi_version(void) {
    return GO_MPP_DECODER_ABI_VERSION;
}

GoMppDecoder* go_mpp_decoder_create(int max_width, int max_height) {
    creation_error[0] = 0;
    if (max_width <= 0 || max_height <= 0 || max_width > 8192 || max_height > 8192) {
        snprintf(creation_error, sizeof(creation_error), "invalid MPP decoder dimensions");
        return NULL;
    }
    GoMppDecoder* decoder = calloc(1, sizeof(*decoder));
    if (!decoder) {
        snprintf(creation_error, sizeof(creation_error), "MPP decoder allocation failed");
        return NULL;
    }
    decoder->max_width = max_width;
    decoder->max_height = max_height;

    MPP_RET result = mpp_check_support_format(MPP_CTX_DEC, MPP_VIDEO_CodingAVC);
    if (result != MPP_OK) {
        set_mpp_error(decoder, "MPP does not support H.264 decoding", result);
        goto fail;
    }
    result = mpp_create(&decoder->context, &decoder->api);
    if (result != MPP_OK || !decoder->context || !decoder->api) {
        set_mpp_error(decoder, "MPP context creation failed", result);
        goto fail;
    }
    MppPollType timeout = MPP_POLL_NON_BLOCK;
    result = decoder->api->control(decoder->context, MPP_SET_INPUT_TIMEOUT, &timeout);
    if (result != MPP_OK) {
        set_mpp_error(decoder, "MPP input timeout configuration failed", result);
        goto fail;
    }
    result = decoder->api->control(decoder->context, MPP_SET_OUTPUT_TIMEOUT, &timeout);
    if (result != MPP_OK) {
        set_mpp_error(decoder, "MPP output timeout configuration failed", result);
        goto fail;
    }
    result = mpp_init(decoder->context, MPP_CTX_DEC, MPP_VIDEO_CodingAVC);
    if (result != MPP_OK) {
        set_mpp_error(decoder, "MPP H.264 initialization failed", result);
        goto fail;
    }
    decoder->initialized = 1;
    MppFrameFormat format = MPP_FMT_YUV420SP;
    result = decoder->api->control(decoder->context, MPP_DEC_SET_OUTPUT_FORMAT, &format);
    if (result != MPP_OK) {
        set_mpp_error(decoder, "MPP NV12 output configuration failed", result);
        goto fail;
    }
    return decoder;

fail:
    snprintf(creation_error, sizeof(creation_error), "%s",
             decoder->error[0] ? decoder->error : "MPP H.264 initialization failed");
    if (decoder->context) {
        if (decoder->initialized && decoder->api)
            decoder->api->reset(decoder->context);
        mpp_destroy(decoder->context);
    }
    if (decoder->frame_group)
        mpp_buffer_group_put(decoder->frame_group);
    free(decoder);
    return NULL;
}

int go_mpp_decoder_submit(GoMppDecoder* decoder, const uint8_t* data, size_t length) {
    if (!decoder || !decoder->context || !decoder->api || !data || length == 0)
        return -1;
    MppPacket packet = NULL;
    MPP_RET result = mpp_packet_init(&packet, (void*)data, length);
    if (result != MPP_OK || !packet) {
        set_mpp_error(decoder, "MPP packet creation failed", result);
        return -1;
    }
    result = decoder->api->decode_put_packet(decoder->context, packet);
    mpp_packet_deinit(&packet);
    if (result == MPP_OK)
        return 1;
    if (result == MPP_NOK || result == MPP_ERR_TIMEOUT || result == MPP_ERR_BUFFER_FULL)
        return 0;
    set_mpp_error(decoder, "MPP packet submission failed", result);
    return -1;
}

int go_mpp_decoder_receive(GoMppDecoder* decoder, GoMppFrame* output) {
    if (!decoder || !decoder->context || !decoder->api || !output)
        return -1;
    memset(output, 0, sizeof(*output));
    for (int attempt = 0; attempt < 8; ++attempt) {
        MppFrame frame = NULL;
        MPP_RET result = decoder->api->decode_get_frame(decoder->context, &frame);
        if (result == MPP_ERR_TIMEOUT)
            return 0;
        if (result != MPP_OK) {
            set_mpp_error(decoder, "MPP frame receive failed", result);
            return -1;
        }
        if (!frame)
            return 0;
        if (mpp_frame_get_info_change(frame)) {
            int change_result = handle_info_change(decoder, frame);
            mpp_frame_deinit(&frame);
            if (change_result != 0)
                return -1;
            continue;
        }
        if (mpp_frame_get_errinfo(frame) || mpp_frame_get_discard(frame)) {
            mpp_frame_deinit(&frame);
            continue;
        }
        if (!valid_output(decoder, frame)) {
            mpp_frame_deinit(&frame);
            return -1;
        }
        MppBuffer buffer = mpp_frame_get_buffer(frame);
        uint8_t* base = buffer ? mpp_buffer_get_ptr(buffer) : NULL;
        size_t buffer_size = buffer ? mpp_buffer_get_size(buffer) : 0;
        size_t uv_offset =
            (size_t)mpp_frame_get_hor_stride(frame) * (size_t)mpp_frame_get_ver_stride(frame);
        size_t uv_size = ((size_t)mpp_frame_get_height(frame) + 1u) / 2u *
                         (size_t)mpp_frame_get_hor_stride(frame);
        if (!base || uv_size > SIZE_MAX - uv_offset || buffer_size < uv_offset + uv_size) {
            set_error(decoder, "MPP output buffer is not CPU-readable");
            mpp_frame_deinit(&frame);
            return -1;
        }
        output->y = base;
        output->uv = base + uv_offset;
        output->width = (int)mpp_frame_get_width(frame);
        output->height = (int)mpp_frame_get_height(frame);
        output->y_stride = (int)mpp_frame_get_hor_stride(frame);
        output->uv_stride = output->y_stride;
        output->owner = frame;
        return 1;
    }
    return 0;
}

void go_mpp_decoder_release_frame(GoMppDecoder* decoder, GoMppFrame* frame) {
    (void)decoder;
    if (!frame || !frame->owner)
        return;
    MppFrame owner = (MppFrame)frame->owner;
    mpp_frame_deinit(&owner);
    memset(frame, 0, sizeof(*frame));
}

int go_mpp_decoder_reset(GoMppDecoder* decoder) {
    if (!decoder || !decoder->context || !decoder->api)
        return -1;
    MPP_RET result = decoder->api->reset(decoder->context);
    if (result != MPP_OK) {
        set_mpp_error(decoder, "MPP decoder reset failed", result);
        return -1;
    }
    return 0;
}

const char* go_mpp_decoder_last_error(GoMppDecoder* decoder) {
    if (decoder && decoder->error[0])
        return decoder->error;
    return creation_error[0] ? creation_error : "MPP decoder failure";
}

void go_mpp_decoder_destroy(GoMppDecoder* decoder) {
    if (!decoder)
        return;
    if (decoder->context) {
        if (decoder->api)
            decoder->api->reset(decoder->context);
        mpp_destroy(decoder->context);
    }
    if (decoder->frame_group)
        mpp_buffer_group_put(decoder->frame_group);
    free(decoder);
}
