#include "video_decoder.h"

#include <errno.h>
#include <libavcodec/avcodec.h>
#include <libavutil/error.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    GoVideoDecoder base;
    const AVCodec* codec;
    AVCodecContext* context;
    AVPacket* packet;
    AVFrame* frame;
    int last_width;
    int last_height;
    int last_format;
    int last_strides[3];
    char error[256];
} GoFfmpegVideoDecoder;

static void set_ffmpeg_error(GoFfmpegVideoDecoder* decoder, const char* operation, int result) {
    char detail[128];
    if (av_strerror(result, detail, sizeof(detail)) < 0)
        snprintf(detail, sizeof(detail), "error %d", result);
    snprintf(decoder->error, sizeof(decoder->error), "%s: %s", operation, detail);
}

static GoVideoDecoderResult ffmpeg_submit(GoVideoDecoder* base, const uint8_t* data,
                                          size_t length) {
    GoFfmpegVideoDecoder* decoder = (GoFfmpegVideoDecoder*)base;
    if (length > INT_MAX) {
        snprintf(decoder->error, sizeof(decoder->error), "H.264 access unit is too large");
        return GO_VIDEO_DECODER_RESULT_FATAL;
    }
    decoder->packet->data = (uint8_t*)data;
    decoder->packet->size = (int)length;
    int result = avcodec_send_packet(decoder->context, decoder->packet);
    decoder->packet->data = NULL;
    decoder->packet->size = 0;
    if (result == 0)
        return GO_VIDEO_DECODER_RESULT_OK;
    if (result == AVERROR(EAGAIN))
        return GO_VIDEO_DECODER_RESULT_AGAIN;
    set_ffmpeg_error(decoder, "FFmpeg packet submission failed", result);
    return GO_VIDEO_DECODER_RESULT_FATAL;
}

static GoVideoDecoderResult ffmpeg_receive(GoVideoDecoder* base, GoDecodedVideoFrame* output) {
    GoFfmpegVideoDecoder* decoder = (GoFfmpegVideoDecoder*)base;
    int result = avcodec_receive_frame(decoder->context, decoder->frame);
    if (result == AVERROR(EAGAIN) || result == AVERROR_EOF)
        return GO_VIDEO_DECODER_RESULT_AGAIN;
    if (result < 0) {
        set_ffmpeg_error(decoder, "FFmpeg frame receive failed", result);
        return GO_VIDEO_DECODER_RESULT_FATAL;
    }

    if (decoder->frame->format == AV_PIX_FMT_NV12)
        output->format = GO_VIDEO_PIXEL_FORMAT_NV12;
    else if (decoder->frame->format == AV_PIX_FMT_YUV420P)
        output->format = GO_VIDEO_PIXEL_FORMAT_YUV420P;
    else {
        snprintf(decoder->error, sizeof(decoder->error), "unsupported FFmpeg pixel format %d",
                 decoder->frame->format);
        av_frame_unref(decoder->frame);
        return GO_VIDEO_DECODER_RESULT_FATAL;
    }

    output->color_range = decoder->frame->color_range == AVCOL_RANGE_JPEG
                              ? GO_VIDEO_COLOR_RANGE_FULL
                              : GO_VIDEO_COLOR_RANGE_LIMITED;
    output->width = decoder->frame->width;
    output->height = decoder->frame->height;
    output->coded_width = decoder->context->coded_width;
    output->coded_height = decoder->context->coded_height;
    for (int plane = 0; plane < 3; ++plane) {
        output->planes[plane] = decoder->frame->data[plane];
        output->strides[plane] = decoder->frame->linesize[plane];
    }
    output->info_changed =
        decoder->last_width != output->width || decoder->last_height != output->height ||
        decoder->last_format != decoder->frame->format ||
        memcmp(decoder->last_strides, output->strides, sizeof(decoder->last_strides)) != 0;
    decoder->last_width = output->width;
    decoder->last_height = output->height;
    decoder->last_format = decoder->frame->format;
    memcpy(decoder->last_strides, output->strides, sizeof(decoder->last_strides));
    output->corrupt = (decoder->frame->flags & AV_FRAME_FLAG_CORRUPT) != 0;
    output->backend_frame = decoder->frame;
    return GO_VIDEO_DECODER_RESULT_OK;
}

static void ffmpeg_release(GoVideoDecoder* base, GoDecodedVideoFrame* frame) {
    GoFfmpegVideoDecoder* decoder = (GoFfmpegVideoDecoder*)base;
    if (frame->backend_frame == decoder->frame)
        av_frame_unref(decoder->frame);
}

static int ffmpeg_reset(GoVideoDecoder* base) {
    GoFfmpegVideoDecoder* decoder = (GoFfmpegVideoDecoder*)base;
    avcodec_flush_buffers(decoder->context);
    av_frame_unref(decoder->frame);
    decoder->last_width = 0;
    decoder->last_height = 0;
    decoder->last_format = 0;
    memset(decoder->last_strides, 0, sizeof(decoder->last_strides));
    return 0;
}

static const char* ffmpeg_last_error(const GoVideoDecoder* base) {
    const GoFfmpegVideoDecoder* decoder = (const GoFfmpegVideoDecoder*)base;
    return decoder->error[0] ? decoder->error : "FFmpeg H.264 decoder failure";
}

static void ffmpeg_destroy(GoVideoDecoder* base) {
    GoFfmpegVideoDecoder* decoder = (GoFfmpegVideoDecoder*)base;
    av_frame_free(&decoder->frame);
    av_packet_free(&decoder->packet);
    avcodec_free_context(&decoder->context);
    free(decoder);
}

static const GoVideoDecoderOps ffmpeg_ops = {
    .name = "ffmpeg-software",
    .backend = GO_VIDEO_DECODER_BACKEND_SOFTWARE,
    .submit_access_unit = ffmpeg_submit,
    .receive_frame = ffmpeg_receive,
    .release_frame = ffmpeg_release,
    .reset = ffmpeg_reset,
    .last_error = ffmpeg_last_error,
    .destroy = ffmpeg_destroy,
};

GoVideoDecoder* go_video_decoder_ffmpeg_create(char* error, size_t error_capacity) {
    GoFfmpegVideoDecoder* decoder = calloc(1, sizeof(*decoder));
    if (!decoder)
        return NULL;
    go_video_decoder_initialize(&decoder->base, &ffmpeg_ops);

    decoder->codec = avcodec_find_decoder(AV_CODEC_ID_H264);
    if (decoder->codec)
        decoder->context = avcodec_alloc_context3(decoder->codec);
    if (decoder->context) {
        decoder->context->thread_count = 3;
        decoder->context->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;
        decoder->context->skip_frame = AVDISCARD_NONREF;
        if (avcodec_open2(decoder->context, decoder->codec, NULL) < 0) {
            snprintf(decoder->error, sizeof(decoder->error), "FFmpeg H.264 initialization failed");
        } else {
            decoder->packet = av_packet_alloc();
            decoder->frame = av_frame_alloc();
        }
    }
    if (!decoder->codec || !decoder->context || !decoder->packet || !decoder->frame) {
        if (!decoder->error[0])
            snprintf(decoder->error, sizeof(decoder->error), "FFmpeg H.264 decoder unavailable");
        if (error && error_capacity > 0)
            snprintf(error, error_capacity, "%s", decoder->error);
        ffmpeg_destroy(&decoder->base);
        return NULL;
    }
    return &decoder->base;
}
