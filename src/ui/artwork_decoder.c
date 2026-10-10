#include "artwork_decoder.h"

#include <libavcodec/avcodec.h>
#include <libavutil/frame.h>
#include <libavutil/imgutils.h>
#include <libavutil/pixfmt.h>
#include <libswscale/swscale.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

static void normalize_jpeg_pixel_format(AVFrame* frame) {
    switch ((enum AVPixelFormat)frame->format) {
    case AV_PIX_FMT_YUVJ420P:
        frame->format = AV_PIX_FMT_YUV420P;
        break;
    case AV_PIX_FMT_YUVJ422P:
        frame->format = AV_PIX_FMT_YUV422P;
        break;
    case AV_PIX_FMT_YUVJ444P:
        frame->format = AV_PIX_FMT_YUV444P;
        break;
    case AV_PIX_FMT_YUVJ440P:
        frame->format = AV_PIX_FMT_YUV440P;
        break;
    case AV_PIX_FMT_YUVJ411P:
        frame->format = AV_PIX_FMT_YUV411P;
        break;
    default:
        return;
    }
    frame->color_range = AVCOL_RANGE_JPEG;
}

void go_artwork_image_destroy(GoArtworkImage* image) {
    if (!image)
        return;
    free(image->pixels);
    memset(image, 0, sizeof(*image));
}

static int decode_image(const uint8_t* data, size_t length, int max_width, int max_height,
                        enum AVCodecID codec_id, enum AVPixelFormat pixel_format,
                        int bytes_per_pixel, GoArtworkImage* output) {
    if (!data || length == 0 || length > INT_MAX || max_width <= 0 || max_height <= 0 || !output)
        return -1;
    memset(output, 0, sizeof(*output));

    const AVCodec* codec = avcodec_find_decoder(codec_id);
    if (!codec)
        return -1;
    AVCodecContext* context = codec ? avcodec_alloc_context3(codec) : NULL;
    AVPacket* packet = av_packet_alloc();
    AVFrame* frame = av_frame_alloc();
    AVFrame* rgb = av_frame_alloc();
    struct SwsContext* scaler = NULL;
    int result = -1;
    if (!context || !packet || !frame || !rgb)
        goto cleanup;
    context->thread_count = 1;
    context->max_pixels = (int64_t)max_width * max_height;
    if (avcodec_open2(context, codec, NULL) < 0)
        goto cleanup;
    if (av_new_packet(packet, (int)length) < 0)
        goto cleanup;
    memcpy(packet->data, data, length);
    if (avcodec_send_packet(context, packet) < 0 || avcodec_receive_frame(context, frame) < 0)
        goto cleanup;
    normalize_jpeg_pixel_format(frame);
    if (frame->width <= 0 || frame->height <= 0 || frame->width > max_width ||
        frame->height > max_height || frame->width > INT_MAX / bytes_per_pixel)
        goto cleanup;
    size_t stride = (size_t)frame->width * bytes_per_pixel;
    if ((size_t)frame->height > SIZE_MAX / stride || stride > INT_MAX)
        goto cleanup;
    output->pixels = malloc(stride * (size_t)frame->height);
    if (!output->pixels)
        goto cleanup;
    rgb->format = pixel_format;
    rgb->width = frame->width;
    rgb->height = frame->height;
    rgb->color_range = AVCOL_RANGE_JPEG;
    if (av_image_fill_arrays(rgb->data, rgb->linesize, output->pixels, pixel_format, frame->width,
                             frame->height, 1) < 0)
        goto cleanup;
    scaler = sws_alloc_context();
    if (!scaler)
        goto cleanup;
    scaler->flags = SWS_BILINEAR;
    if (sws_scale_frame(scaler, rgb, frame) < 0)
        goto cleanup;
    output->width = frame->width;
    output->height = frame->height;
    output->stride = (int)stride;
    result = 0;

cleanup:
    if (result != 0)
        go_artwork_image_destroy(output);
    sws_free_context(&scaler);
    av_frame_free(&rgb);
    av_frame_free(&frame);
    av_packet_free(&packet);
    avcodec_free_context(&context);
    return result;
}

int go_artwork_decode_jpeg(const uint8_t* data, size_t length, int max_width, int max_height,
                           GoArtworkImage* output) {
    return decode_image(data, length, max_width, max_height, AV_CODEC_ID_MJPEG, AV_PIX_FMT_RGB24, 3,
                        output);
}

int go_artwork_decode_rgba(const uint8_t* data, size_t length, int max_width, int max_height,
                           GoArtworkImage* output) {
    static const uint8_t png_signature[] = {137, 80, 78, 71, 13, 10, 26, 10};
    if (!data || length < 8)
        return -1;
    enum AVCodecID codec = memcmp(data, png_signature, sizeof(png_signature)) == 0
                               ? AV_CODEC_ID_PNG
                               : AV_CODEC_ID_MJPEG;
    return decode_image(data, length, max_width, max_height, codec, AV_PIX_FMT_RGBA, 4, output);
}
