#include "video_decoder.h"

#include <errno.h>
#include <fcntl.h>
#include <libavcodec/avcodec.h>
#include <libavutil/error.h>
#include <libavutil/hwcontext.h>
#include <linux/videodev2.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

typedef struct {
    GoVideoDecoder base;
    const AVCodec* codec;
    AVCodecContext* context;
    AVBufferRef* device;
    AVPacket* packet;
    AVFrame* hardware_frame;
    AVFrame* mapped_frame;
    enum AVHWDeviceType device_type;
    int max_width;
    int max_height;
    int last_width;
    int last_height;
    int last_format;
    int last_strides[3];
    char error[256];
} GoV4l2RequestVideoDecoder;

static void copy_error(char* destination, size_t capacity, const char* message) {
    if (destination && capacity > 0)
        snprintf(destination, capacity, "%s", message);
}

static void set_ffmpeg_error(GoV4l2RequestVideoDecoder* decoder, const char* operation,
                             int result) {
    char detail[128];
    if (av_strerror(result, detail, sizeof(detail)) < 0)
        snprintf(detail, sizeof(detail), "error %d", result);
    snprintf(decoder->error, sizeof(decoder->error), "%s: %s", operation, detail);
}

static int has_usable_media_device(void) {
    char path[32];
    for (int index = 0; index < 64; ++index) {
        snprintf(path, sizeof(path), "/dev/media%d", index);
        int descriptor = open(path, O_RDWR | O_CLOEXEC);
        if (descriptor >= 0) {
            close(descriptor);
            return 1;
        }
    }
    return 0;
}

static int video_device_supports_h264_request(int descriptor) {
    struct v4l2_capability capability;
    memset(&capability, 0, sizeof(capability));
    if (ioctl(descriptor, VIDIOC_QUERYCAP, &capability) < 0)
        return 0;

    uint32_t capabilities = (capability.capabilities & V4L2_CAP_DEVICE_CAPS) != 0
                                ? capability.device_caps
                                : capability.capabilities;
    if ((capabilities & V4L2_CAP_STREAMING) == 0)
        return 0;

    struct v4l2_fmtdesc format;
    memset(&format, 0, sizeof(format));
    if ((capabilities & V4L2_CAP_VIDEO_M2M_MPLANE) != 0)
        format.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
    else if ((capabilities & V4L2_CAP_VIDEO_M2M) != 0)
        format.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
    else
        return 0;
    while (ioctl(descriptor, VIDIOC_ENUM_FMT, &format) == 0) {
        if (format.pixelformat == V4L2_PIX_FMT_H264_SLICE)
            return 1;
        ++format.index;
    }
    return 0;
}

static int has_usable_h264_request_decoder(void) {
    char path[32];
    for (int index = 0; index < 64; ++index) {
        snprintf(path, sizeof(path), "/dev/video%d", index);
        int descriptor = open(path, O_RDWR | O_CLOEXEC);
        if (descriptor < 0)
            continue;
        int supported = video_device_supports_h264_request(descriptor);
        close(descriptor);
        if (supported)
            return 1;
    }
    return 0;
}

static int has_usable_v4l2_request_devices(void) {
    return has_usable_media_device() && has_usable_h264_request_decoder();
}

static int codec_supports_device(const AVCodec* codec, enum AVHWDeviceType type) {
    for (int index = 0;; ++index) {
        const AVCodecHWConfig* config = avcodec_get_hw_config(codec, index);
        if (!config)
            return 0;
        if (config->device_type == type && config->pix_fmt == AV_PIX_FMT_DRM_PRIME &&
            (config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) != 0)
            return 1;
    }
}

static enum AVPixelFormat select_hardware_format(AVCodecContext* context,
                                                 const enum AVPixelFormat* formats) {
    GoV4l2RequestVideoDecoder* decoder = context->opaque;
    for (const enum AVPixelFormat* format = formats; *format != AV_PIX_FMT_NONE; ++format) {
        if (*format == AV_PIX_FMT_DRM_PRIME)
            return *format;
    }
    snprintf(decoder->error, sizeof(decoder->error),
             "V4L2 request decoder did not offer DRM PRIME output");
    return AV_PIX_FMT_NONE;
}

static GoVideoDecoderResult v4l2_request_submit(GoVideoDecoder* base, const uint8_t* data,
                                                size_t length) {
    GoV4l2RequestVideoDecoder* decoder = (GoV4l2RequestVideoDecoder*)base;
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
    set_ffmpeg_error(decoder, "V4L2 request packet submission failed", result);
    return GO_VIDEO_DECODER_RESULT_FATAL;
}

static GoVideoDecoderResult v4l2_request_receive(GoVideoDecoder* base,
                                                 GoDecodedVideoFrame* output) {
    GoV4l2RequestVideoDecoder* decoder = (GoV4l2RequestVideoDecoder*)base;
    int result = avcodec_receive_frame(decoder->context, decoder->hardware_frame);
    if (result == AVERROR(EAGAIN) || result == AVERROR_EOF)
        return GO_VIDEO_DECODER_RESULT_AGAIN;
    if (result < 0) {
        set_ffmpeg_error(decoder, "V4L2 request frame receive failed", result);
        return GO_VIDEO_DECODER_RESULT_FATAL;
    }
    if (decoder->hardware_frame->format != AV_PIX_FMT_DRM_PRIME) {
        snprintf(decoder->error, sizeof(decoder->error),
                 "V4L2 request decoder returned pixel format %d",
                 decoder->hardware_frame->format);
        av_frame_unref(decoder->hardware_frame);
        return GO_VIDEO_DECODER_RESULT_FATAL;
    }

    result = av_hwframe_transfer_data(decoder->mapped_frame, decoder->hardware_frame, 0);
    if (result < 0) {
        set_ffmpeg_error(decoder, "V4L2 request frame mapping failed", result);
        av_frame_unref(decoder->hardware_frame);
        return GO_VIDEO_DECODER_RESULT_FATAL;
    }
    if (decoder->mapped_frame->format != AV_PIX_FMT_NV12) {
        snprintf(decoder->error, sizeof(decoder->error),
                 "V4L2 request decoder returned unsupported mapped format %d",
                 decoder->mapped_frame->format);
        av_frame_unref(decoder->mapped_frame);
        av_frame_unref(decoder->hardware_frame);
        return GO_VIDEO_DECODER_RESULT_FATAL;
    }
    if (decoder->mapped_frame->width <= 0 || decoder->mapped_frame->height <= 0 ||
        decoder->mapped_frame->width > decoder->max_width ||
        decoder->mapped_frame->height > decoder->max_height) {
        snprintf(decoder->error, sizeof(decoder->error),
                 "V4L2 request decoder returned invalid dimensions %dx%d",
                 decoder->mapped_frame->width, decoder->mapped_frame->height);
        av_frame_unref(decoder->mapped_frame);
        av_frame_unref(decoder->hardware_frame);
        return GO_VIDEO_DECODER_RESULT_FATAL;
    }

    output->format = GO_VIDEO_PIXEL_FORMAT_NV12;
    output->color_range = decoder->mapped_frame->color_range == AVCOL_RANGE_JPEG
                              ? GO_VIDEO_COLOR_RANGE_FULL
                              : GO_VIDEO_COLOR_RANGE_LIMITED;
    output->width = decoder->mapped_frame->width;
    output->height = decoder->mapped_frame->height;
    output->coded_width = decoder->context->coded_width;
    output->coded_height = decoder->context->coded_height;
    for (int plane = 0; plane < 3; ++plane) {
        output->planes[plane] = decoder->mapped_frame->data[plane];
        output->strides[plane] = decoder->mapped_frame->linesize[plane];
    }
    output->info_changed =
        decoder->last_width != output->width || decoder->last_height != output->height ||
        decoder->last_format != decoder->mapped_frame->format ||
        memcmp(decoder->last_strides, output->strides, sizeof(decoder->last_strides)) != 0;
    decoder->last_width = output->width;
    decoder->last_height = output->height;
    decoder->last_format = decoder->mapped_frame->format;
    memcpy(decoder->last_strides, output->strides, sizeof(decoder->last_strides));
    output->corrupt = (decoder->hardware_frame->flags & AV_FRAME_FLAG_CORRUPT) != 0;
    output->backend_frame = decoder->mapped_frame;
    return GO_VIDEO_DECODER_RESULT_OK;
}

static void v4l2_request_release(GoVideoDecoder* base, GoDecodedVideoFrame* frame) {
    GoV4l2RequestVideoDecoder* decoder = (GoV4l2RequestVideoDecoder*)base;
    if (frame->backend_frame == decoder->mapped_frame) {
        av_frame_unref(decoder->mapped_frame);
        av_frame_unref(decoder->hardware_frame);
    }
}

static int v4l2_request_reset(GoVideoDecoder* base) {
    GoV4l2RequestVideoDecoder* decoder = (GoV4l2RequestVideoDecoder*)base;
    av_frame_unref(decoder->mapped_frame);
    av_frame_unref(decoder->hardware_frame);
    avcodec_flush_buffers(decoder->context);
    decoder->last_width = 0;
    decoder->last_height = 0;
    decoder->last_format = 0;
    memset(decoder->last_strides, 0, sizeof(decoder->last_strides));
    return 0;
}

static const char* v4l2_request_last_error(const GoVideoDecoder* base) {
    const GoV4l2RequestVideoDecoder* decoder = (const GoV4l2RequestVideoDecoder*)base;
    return decoder->error[0] ? decoder->error : "V4L2 request H.264 decoder failure";
}

static void v4l2_request_destroy(GoVideoDecoder* base) {
    GoV4l2RequestVideoDecoder* decoder = (GoV4l2RequestVideoDecoder*)base;
    av_frame_free(&decoder->mapped_frame);
    av_frame_free(&decoder->hardware_frame);
    av_packet_free(&decoder->packet);
    avcodec_free_context(&decoder->context);
    av_buffer_unref(&decoder->device);
    free(decoder);
}

static const GoVideoDecoderOps v4l2_request_ops = {
    .name = "v4l2-request",
    .backend = GO_VIDEO_DECODER_BACKEND_V4L2_REQUEST,
    .submit_access_unit = v4l2_request_submit,
    .receive_frame = v4l2_request_receive,
    .release_frame = v4l2_request_release,
    .reset = v4l2_request_reset,
    .last_error = v4l2_request_last_error,
    .destroy = v4l2_request_destroy,
};

GoVideoDecoder* go_video_decoder_v4l2_request_create(int max_width, int max_height, char* error,
                                                     size_t error_capacity) {
    if (max_width <= 0 || max_height <= 0) {
        copy_error(error, error_capacity, "invalid V4L2 request decoder dimensions");
        return NULL;
    }
    if (!has_usable_v4l2_request_devices()) {
        copy_error(error, error_capacity, "no writable H.264 V4L2 Request decoder");
        return NULL;
    }

    GoV4l2RequestVideoDecoder* decoder = calloc(1, sizeof(*decoder));
    if (!decoder) {
        copy_error(error, error_capacity, "V4L2 request decoder allocation failed");
        return NULL;
    }
    go_video_decoder_initialize(&decoder->base, &v4l2_request_ops);
    decoder->max_width = max_width;
    decoder->max_height = max_height;
    decoder->device_type = av_hwdevice_find_type_by_name("v4l2request");
    decoder->codec = avcodec_find_decoder(AV_CODEC_ID_H264);

    if (decoder->device_type == AV_HWDEVICE_TYPE_NONE)
        snprintf(decoder->error, sizeof(decoder->error),
                 "FFmpeg was built without V4L2 request support");
    else if (!decoder->codec || !codec_supports_device(decoder->codec, decoder->device_type))
        snprintf(decoder->error, sizeof(decoder->error),
                 "FFmpeg H.264 V4L2 request decoder is unavailable");
    else {
        int result = av_hwdevice_ctx_create(&decoder->device, decoder->device_type, NULL, NULL, 0);
        if (result < 0)
            set_ffmpeg_error(decoder, "V4L2 request device initialization failed", result);
    }

    if (decoder->device && decoder->codec) {
        decoder->context = avcodec_alloc_context3(decoder->codec);
        if (decoder->context) {
            decoder->context->opaque = decoder;
            decoder->context->get_format = select_hardware_format;
            decoder->context->hw_device_ctx = av_buffer_ref(decoder->device);
            decoder->context->thread_count = 1;
            decoder->context->flags |= AV_CODEC_FLAG_LOW_DELAY;
            int result = avcodec_open2(decoder->context, decoder->codec, NULL);
            if (result < 0)
                set_ffmpeg_error(decoder, "V4L2 request H.264 initialization failed", result);
            else {
                decoder->packet = av_packet_alloc();
                decoder->hardware_frame = av_frame_alloc();
                decoder->mapped_frame = av_frame_alloc();
            }
        }
    }

    if (!decoder->context || !decoder->context->hw_device_ctx || !decoder->packet ||
        !decoder->hardware_frame || !decoder->mapped_frame) {
        if (!decoder->error[0])
            snprintf(decoder->error, sizeof(decoder->error),
                     "V4L2 request H.264 decoder initialization failed");
        copy_error(error, error_capacity, decoder->error);
        v4l2_request_destroy(&decoder->base);
        return NULL;
    }
    return &decoder->base;
}
