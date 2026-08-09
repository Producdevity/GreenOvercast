#include "cedar_decoder.h"

#include "adapter.h"
#include "vdecoder.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void CedarPluginVDInit(void);

struct GoCedarDecoder {
    VideoDecoder* decoder;
    uint8_t* linear;
    size_t linear_capacity;
    int width;
    int height;
    char error[160];
};

static void set_error(GoCedarDecoder* decoder, const char* message) {
    snprintf(decoder->error, sizeof(decoder->error), "%s", message);
}

static size_t find_start_code(const uint8_t* data, size_t length, size_t offset) {
    for (size_t i = offset; i + 3 < length; ++i) {
        if (data[i] == 0 && data[i + 1] == 0 &&
            (data[i + 2] == 1 || (data[i + 2] == 0 && data[i + 3] == 1)))
            return i;
    }
    return length;
}

static int submit_nal(GoCedarDecoder* decoder, const uint8_t* data, size_t length) {
    if (length == 0 || length > INT32_MAX)
        return -1;
    char* first = NULL;
    char* ring = NULL;
    int first_size = 0;
    int ring_size = 0;
    if (RequestVideoStreamBuffer(decoder->decoder, (int)length, &first, &first_size, &ring,
                                 &ring_size, 0) != 0 ||
        first_size + ring_size < (int)length)
        return -1;

    size_t first_copy = (size_t)first_size < length ? (size_t)first_size : length;
    memcpy(first, data, first_copy);
    if (first_copy < length)
        memcpy(ring, data + first_copy, length - first_copy);

    VideoStreamDataInfo info;
    memset(&info, 0, sizeof(info));
    info.pData = first;
    info.nLength = (int)length;
    info.nPts = -1;
    info.nPcr = -1;
    info.bIsFirstPart = 1;
    info.bIsLastPart = 1;
    return SubmitVideoStreamData(decoder->decoder, &info, 0);
}

static void detile_32x32(const uint8_t* source, uint8_t* destination, int source_stride,
                         int visible_width, int visible_height) {
    int tiles_per_row = (source_stride + 31) / 32;
    for (int y = 0; y < visible_height; ++y) {
        int tile_row = y / 32;
        int row_in_tile = y % 32;
        for (int x = 0; x < visible_width; x += 32) {
            int copy = visible_width - x < 32 ? visible_width - x : 32;
            int tile_column = x / 32;
            size_t source_offset =
                ((size_t)tile_row * (size_t)tiles_per_row + (size_t)tile_column) * 1024u +
                (size_t)row_in_tile * 32u;
            memcpy(destination + (size_t)y * (size_t)visible_width + (size_t)x,
                   source + source_offset, (size_t)copy);
        }
    }
}

static int copy_newest_picture(GoCedarDecoder* decoder, GoCedarFrame* frame) {
    int produced = 0;
    VideoPicture* picture;
    while ((picture = RequestPicture(decoder->decoder, 0)) != NULL) {
        int width = picture->nRightOffset - picture->nLeftOffset;
        int height = picture->nBottomOffset - picture->nTopOffset;
        if (width <= 0 || height <= 0 || width > 4096 || height > 4096 ||
            picture->nLineStride < width) {
            ReturnPicture(decoder->decoder, picture);
            set_error(decoder, "invalid Cedar output dimensions");
            return -1;
        }

        size_t luma_size = (size_t)width * (size_t)height;
        size_t required = luma_size + luma_size / 2u;
        if (required > decoder->linear_capacity) {
            uint8_t* next = realloc(decoder->linear, required);
            if (!next) {
                ReturnPicture(decoder->decoder, picture);
                set_error(decoder, "Cedar output allocation failed");
                return -1;
            }
            decoder->linear = next;
            decoder->linear_capacity = required;
        }

        int buffer_height = (picture->nHeight + 63) & ~63;
        AdapterMemFlushCache(picture->pData0, picture->nLineStride * buffer_height);
        AdapterMemFlushCache(picture->pData1, picture->nLineStride * buffer_height / 2);
        detile_32x32((const uint8_t*)picture->pData0, decoder->linear, picture->nLineStride, width,
                     height);
        detile_32x32((const uint8_t*)picture->pData1, decoder->linear + luma_size,
                     picture->nLineStride, width, height / 2);
        decoder->width = width;
        decoder->height = height;
        produced = 1;
        ReturnPicture(decoder->decoder, picture);
    }

    if (produced) {
        frame->y = decoder->linear;
        frame->uv = decoder->linear + (size_t)decoder->width * (size_t)decoder->height;
        frame->width = decoder->width;
        frame->height = decoder->height;
        frame->y_stride = decoder->width;
        frame->uv_stride = decoder->width;
    }
    return produced;
}

GoCedarDecoder* go_cedar_v1_create(int width, int height) {
    if (width <= 0 || height <= 0 || width > 4096 || height > 4096)
        return NULL;
    GoCedarDecoder* decoder = calloc(1, sizeof(*decoder));
    if (!decoder)
        return NULL;

    CedarPluginVDInit();
    decoder->decoder = CreateVideoDecoder();
    if (!decoder->decoder)
        goto fail;

    VideoStreamInfo info;
    memset(&info, 0, sizeof(info));
    info.eCodecFormat = VIDEO_CODEC_FORMAT_H264;
    info.nWidth = width;
    info.nHeight = height;
    info.nFrameRate = 30;
    VConfig config;
    memset(&config, 0, sizeof(config));
    config.eOutputPixelFormat = PIXEL_FORMAT_YUV_MB32_420;
    config.nVbvBufferSize = 6 * 1024 * 1024;
    if (InitializeVideoDecoder(decoder->decoder, &info, &config) != 0)
        goto fail;
    return decoder;

fail:
    if (decoder->decoder)
        DestroyVideoDecoder(decoder->decoder);
    free(decoder);
    return NULL;
}

int go_cedar_v1_feed(GoCedarDecoder* decoder, const uint8_t* annex_b, size_t length,
                     GoCedarFrame* frame) {
    if (!decoder || !decoder->decoder || !annex_b || !frame || length == 0)
        return -1;
    memset(frame, 0, sizeof(*frame));

    size_t start = find_start_code(annex_b, length, 0);
    if (start == length) {
        set_error(decoder, "H.264 access unit is not Annex B");
        return -1;
    }
    while (start < length) {
        size_t prefix = annex_b[start + 2] == 1 ? 3u : 4u;
        size_t end = find_start_code(annex_b, length, start + prefix);
        if (submit_nal(decoder, annex_b + start, end - start) != 0) {
            set_error(decoder, "Cedar stream buffer rejected a NAL unit");
            return -1;
        }
        start = end;
    }

    for (int attempt = 0; attempt < 64; ++attempt) {
        int result = DecodeVideoStream(decoder->decoder, 0, 0, 0, 0);
        int copied = copy_newest_picture(decoder, frame);
        if (copied < 0)
            return -1;
        if (copied > 0)
            return 1;
        if (result == VDECODE_RESULT_NO_BITSTREAM || result == VDECODE_RESULT_CONTINUE ||
            result == VDECODE_RESULT_OK)
            return 0;
        if (result < 0) {
            set_error(decoder, "Cedar H.264 decode failed");
            return -1;
        }
    }
    set_error(decoder, "Cedar decode iteration limit reached");
    return -1;
}

int go_cedar_v1_flush(GoCedarDecoder* decoder, GoCedarFrame* frame) {
    if (!decoder || !decoder->decoder || !frame)
        return -1;
    memset(frame, 0, sizeof(*frame));
    for (int attempt = 0; attempt < 64; ++attempt) {
        int result = DecodeVideoStream(decoder->decoder, 1, 0, 0, 0);
        int copied = copy_newest_picture(decoder, frame);
        if (copied != 0)
            return copied;
        if (result == VDECODE_RESULT_NO_BITSTREAM)
            return 0;
        if (result < 0) {
            set_error(decoder, "Cedar H.264 flush failed");
            return -1;
        }
    }
    set_error(decoder, "Cedar flush iteration limit reached");
    return -1;
}

const char* go_cedar_v1_last_error(const GoCedarDecoder* decoder) {
    return decoder && decoder->error[0] ? decoder->error : "Cedar decoder failure";
}

void go_cedar_v1_destroy(GoCedarDecoder* decoder) {
    if (!decoder)
        return;
    if (decoder->decoder)
        DestroyVideoDecoder(decoder->decoder);
    free(decoder->linear);
    free(decoder);
}
