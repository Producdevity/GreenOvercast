#include "video_pipeline.h"

#include <errno.h>
#include <libavcodec/avcodec.h>
#include <libswscale/swscale.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "../../util/log.h"
#include "cedar_loader.h"
#include "h264_depacketizer.h"

#define H264_BOOTSTRAP_MAX_SIZE 4104
#define VIDEO_PACKET_MAX_SIZE 4096
#define VIDEO_PACKET_QUEUE_CAPACITY 128

typedef struct {
    uint16_t length;
    uint8_t data[VIDEO_PACKET_MAX_SIZE];
} VideoPacket;

struct GoVideoPipeline {
    SDL_Renderer* renderer;
    GoH264Depacketizer* depacketizer;
    uint8_t bootstrap[H264_BOOTSTRAP_MAX_SIZE];
    size_t bootstrap_length;
    int parameter_sets_dirty;
    char bootstrap_path[512];

    VideoPacket packet_queue[VIDEO_PACKET_QUEUE_CAPACITY];
    int packet_queue_head;
    int packet_queue_tail;
    int packet_queue_count;
    pthread_mutex_t packet_lock;
    pthread_cond_t packet_condition;
    int packet_sync_initialized;
    pthread_t thread;
    int thread_started;
    atomic_int stop;
    atomic_int accepting_packets;

    const AVCodec* codec;
    AVCodecContext* decoder;
    AVPacket* decoder_packet;
    AVFrame* decoder_frame;
    AVFrame* cedar_frame;
    GoCedarLibrary* cedar;

    SDL_Texture* texture;
    struct SwsContext* scaler;
    uint8_t* rgb_buffer;
    int rgb_linesize;
    int texture_width;
    int texture_height;
    unsigned int crop_aspect_width;
    unsigned int crop_aspect_height;
    Uint32 texture_format;
    int direct_nv12_available;
    int upload_error_reported;

    pthread_mutex_t frame_lock;
    int frame_lock_initialized;
    AVFrame* display_frame;
    AVFrame* render_frame;
    atomic_int frame_ready;

    atomic_int synced;
    atomic_int keyframe_pending;
    atomic_int rtp_packets;
    atomic_int payload_packets;
    atomic_int rejected_packets;
    atomic_int last_rejected_payload_type;
    atomic_int access_units;
    atomic_int decoded_frames;
    atomic_int rendered_frames;
    atomic_int frame_nals;
    atomic_int idr_nals;
    atomic_int parameter_nals;
    atomic_int auxiliary_nals;
    atomic_uint last_timestamp;
    atomic_int discontinuities;
    atomic_int missing_packets;
    atomic_int late_packets;
    atomic_int decoder_send_errors;
    atomic_int decoder_receive_errors;
    atomic_int last_decoder_error;
    atomic_int keyframe_requests;
    atomic_int dropped_packets;
};

static int load_bootstrap(GoVideoPipeline* pipeline) {
    if (!pipeline->bootstrap_path[0])
        return 0;
    struct stat status;
    if (stat(pipeline->bootstrap_path, &status) != 0)
        return errno == ENOENT ? 0 : -1;
    if (status.st_size <= 0 || status.st_size > H264_BOOTSTRAP_MAX_SIZE)
        return -1;
    FILE* file = fopen(pipeline->bootstrap_path, "rb");
    if (!file)
        return -1;
    uint8_t data[H264_BOOTSTRAP_MAX_SIZE];
    size_t length = fread(data, 1, (size_t)status.st_size, file);
    int failed = ferror(file) || length != (size_t)status.st_size;
    fclose(file);
    if (failed || go_h264_depacketizer_set_bootstrap(pipeline->depacketizer, data, length) != 0)
        return -1;
    go_dbg("H.264 bootstrap loaded (%zu bytes)\n", length);
    return 0;
}

static int persist_bootstrap(GoVideoPipeline* pipeline) {
    if (!pipeline->parameter_sets_dirty || !pipeline->bootstrap_path[0] ||
        pipeline->bootstrap_length == 0)
        return 0;
    char temporary_path[sizeof(pipeline->bootstrap_path) + 5];
    if (snprintf(temporary_path, sizeof(temporary_path), "%s.tmp", pipeline->bootstrap_path) >=
        (int)sizeof(temporary_path))
        return -1;
    FILE* file = fopen(temporary_path, "wb");
    if (!file)
        return -1;
    int failed = fchmod(fileno(file), 0600) != 0 ||
                 fwrite(pipeline->bootstrap, 1, pipeline->bootstrap_length, file) !=
                     pipeline->bootstrap_length ||
                 fflush(file) != 0 || fsync(fileno(file)) != 0;
    if (fclose(file) != 0)
        failed = 1;
    if (failed || rename(temporary_path, pipeline->bootstrap_path) != 0) {
        unlink(temporary_path);
        return -1;
    }
    pipeline->parameter_sets_dirty = 0;
    go_dbg("H.264 bootstrap updated\n");
    return 0;
}

static void publish_frame(GoVideoPipeline* pipeline, AVFrame* frame, const char* decoder_name) {
    atomic_fetch_add(&pipeline->decoded_frames, 1);
    atomic_store(&pipeline->keyframe_pending, 0);
    if (!atomic_exchange(&pipeline->synced, 1)) {
        go_dbg("Video output active: %dx%d format=%d decoder=%s\n", frame->width, frame->height,
               frame->format, decoder_name);
    }
    pthread_mutex_lock(&pipeline->frame_lock);
    av_frame_unref(pipeline->display_frame);
    if (av_frame_ref(pipeline->display_frame, frame) == 0)
        atomic_store(&pipeline->frame_ready, 1);
    pthread_mutex_unlock(&pipeline->frame_lock);
}

static int publish_cedar_frame(GoVideoPipeline* pipeline, const GoCedarFrame* frame) {
    if (!pipeline->cedar_frame || frame->width <= 0 || frame->height <= 0)
        return -1;
    AVFrame* target = pipeline->cedar_frame;
    if (target->format != AV_PIX_FMT_NV12 || target->width != frame->width ||
        target->height != frame->height) {
        av_frame_unref(target);
        target->format = AV_PIX_FMT_NV12;
        target->width = frame->width;
        target->height = frame->height;
        if (av_frame_get_buffer(target, 32) < 0)
            return -1;
    }
    if (av_frame_make_writable(target) < 0)
        return -1;
    for (int y = 0; y < frame->height; y++)
        memcpy(target->data[0] + (size_t)y * (size_t)target->linesize[0],
               frame->y + (size_t)y * (size_t)frame->y_stride, (size_t)frame->width);
    for (int y = 0; y < frame->height / 2; y++)
        memcpy(target->data[1] + (size_t)y * (size_t)target->linesize[1],
               frame->uv + (size_t)y * (size_t)frame->uv_stride, (size_t)frame->width);
    target->color_range = AVCOL_RANGE_MPEG;
    target->colorspace = AVCOL_SPC_BT709;
    publish_frame(pipeline, target, "cedar-h616");
    return 0;
}

static void feed_software_decoder(GoVideoPipeline* pipeline, const uint8_t* data, int length) {
    pipeline->decoder_packet->data = (uint8_t*)data;
    pipeline->decoder_packet->size = length;
    if (avcodec_send_packet(pipeline->decoder, pipeline->decoder_packet) < 0)
        atomic_fetch_add(&pipeline->decoder_send_errors, 1);
    int result;
    while ((result = avcodec_receive_frame(pipeline->decoder, pipeline->decoder_frame)) == 0) {
        publish_frame(pipeline, pipeline->decoder_frame, "ffmpeg-software");
        av_frame_unref(pipeline->decoder_frame);
    }
    if (result != AVERROR(EAGAIN) && result != AVERROR_EOF) {
        atomic_fetch_add(&pipeline->decoder_receive_errors, 1);
        atomic_store(&pipeline->last_decoder_error, result);
    }
}

static void decode_access_unit(void* context, const uint8_t* data, size_t length,
                               const GoH264AccessUnit* info) {
    (void)info;
    GoVideoPipeline* pipeline = context;
    if (length > INT32_MAX || !pipeline->decoder)
        return;
    if (pipeline->cedar) {
        GoCedarFrame frame;
        int result = go_cedar_library_feed(pipeline->cedar, data, length, &frame);
        if (result > 0 && publish_cedar_frame(pipeline, &frame) == 0)
            return;
        if (result == 0)
            return;
        fprintf(stderr, "Cedar decoder disabled: %s\n", go_cedar_library_error(pipeline->cedar));
        go_cedar_library_close(pipeline->cedar);
        pipeline->cedar = NULL;
        atomic_store(&pipeline->keyframe_pending, 1);
        atomic_store(&pipeline->synced, 0);
    }
    feed_software_decoder(pipeline, data, (int)length);
}

static void process_packet(GoVideoPipeline* pipeline, const uint8_t* packet, size_t length) {
    if (length < 12 || !pipeline->depacketizer)
        return;
    atomic_fetch_add(&pipeline->rtp_packets, 1);
    GoH264FeedResult result = go_h264_depacketizer_feed(pipeline->depacketizer, packet, length,
                                                        decode_access_unit, pipeline);
    if (!result.accepted) {
        atomic_fetch_add(&pipeline->rejected_packets, 1);
        atomic_store(&pipeline->last_rejected_payload_type, packet[1] & 0x7F);
        return;
    }
    atomic_fetch_add(&pipeline->payload_packets, 1);
    atomic_store(&pipeline->last_timestamp, result.timestamp);
    atomic_fetch_add(&pipeline->missing_packets, result.missing_packets);
    atomic_fetch_add(&pipeline->late_packets, result.late_packets);
    atomic_fetch_add(&pipeline->discontinuities, result.discontinuities);
    atomic_fetch_add(&pipeline->access_units, result.access_units);
    atomic_fetch_add(&pipeline->frame_nals, result.frame_nals);
    atomic_fetch_add(&pipeline->idr_nals, result.idr_nals);
    atomic_fetch_add(&pipeline->parameter_nals, result.parameter_nals);
    atomic_fetch_add(&pipeline->auxiliary_nals, result.auxiliary_nals);
    if (result.requires_keyframe)
        atomic_store(&pipeline->keyframe_pending, 1);

    size_t bootstrap_length = 0;
    int bootstrap_result =
        go_h264_depacketizer_take_bootstrap(pipeline->depacketizer, pipeline->bootstrap,
                                            sizeof(pipeline->bootstrap), &bootstrap_length);
    if (bootstrap_result > 0) {
        pipeline->bootstrap_length = bootstrap_length;
        pipeline->parameter_sets_dirty = 1;
    } else if (bootstrap_result < 0) {
        fprintf(stderr, "H.264 parameter sets exceed the bootstrap limit\n");
    }
}

static void* video_worker(void* context) {
    GoVideoPipeline* pipeline = context;
    for (;;) {
        VideoPacket packet;
        pthread_mutex_lock(&pipeline->packet_lock);
        while (pipeline->packet_queue_count == 0 && !atomic_load(&pipeline->stop))
            pthread_cond_wait(&pipeline->packet_condition, &pipeline->packet_lock);
        if (atomic_load(&pipeline->stop)) {
            pthread_mutex_unlock(&pipeline->packet_lock);
            break;
        }
        packet = pipeline->packet_queue[pipeline->packet_queue_head];
        pipeline->packet_queue_head =
            (pipeline->packet_queue_head + 1) % VIDEO_PACKET_QUEUE_CAPACITY;
        pipeline->packet_queue_count--;
        pthread_mutex_unlock(&pipeline->packet_lock);
        process_packet(pipeline, packet.data, packet.length);
    }
    return NULL;
}

static void destroy_texture(GoVideoPipeline* pipeline) {
    if (pipeline->texture)
        SDL_DestroyTexture(pipeline->texture);
    pipeline->texture = NULL;
    pipeline->texture_format = SDL_PIXELFORMAT_UNKNOWN;
}

static int configure_renderer(GoVideoPipeline* pipeline, const AVFrame* frame) {
    int width = frame->width;
    int height = frame->height;
    int source_format = frame->format;
    int source_full_range = frame->color_range == AVCOL_RANGE_JPEG;
    if (width <= 0 || height <= 0 || width > 8192 || height > 8192)
        return -1;
    int direct_nv12 = source_format == AV_PIX_FMT_NV12 && pipeline->direct_nv12_available;
    Uint32 requested_format = direct_nv12 ? SDL_PIXELFORMAT_NV12 : SDL_PIXELFORMAT_RGB24;
    if (pipeline->texture &&
        (width != pipeline->texture_width || height != pipeline->texture_height ||
         requested_format != pipeline->texture_format))
        destroy_texture(pipeline);
    if (!pipeline->texture) {
        if (direct_nv12) {
            SDL_SetYUVConversionMode(SDL_YUV_CONVERSION_BT709);
            pipeline->texture = SDL_CreateTexture(pipeline->renderer, SDL_PIXELFORMAT_NV12,
                                                  SDL_TEXTUREACCESS_STREAMING, width, height);
            if (!pipeline->texture) {
                fprintf(stderr, "Direct NV12 texture unavailable: %s\n", SDL_GetError());
                pipeline->direct_nv12_available = 0;
                requested_format = SDL_PIXELFORMAT_RGB24;
            }
        }
        if (!pipeline->texture)
            pipeline->texture = SDL_CreateTexture(pipeline->renderer, SDL_PIXELFORMAT_RGB24,
                                                  SDL_TEXTUREACCESS_STREAMING, width, height);
        if (!pipeline->texture) {
            fprintf(stderr, "SDL_CreateTexture: %s\n", SDL_GetError());
            return -1;
        }
        pipeline->texture_width = width;
        pipeline->texture_height = height;
        pipeline->texture_format = requested_format;
        go_dbg("Created %s texture %dx%d\n",
               requested_format == SDL_PIXELFORMAT_NV12 ? "NV12" : "RGB24", width, height);
    }
    if (pipeline->texture_format == SDL_PIXELFORMAT_NV12)
        return 0;

    struct SwsContext* scaler =
        sws_getCachedContext(pipeline->scaler, width, height, (enum AVPixelFormat)source_format,
                             width, height, AV_PIX_FMT_RGB24, SWS_BILINEAR, NULL, NULL, NULL);
    if (!scaler) {
        fprintf(stderr, "Failed to create YUV-to-RGB converter\n");
        return -1;
    }
    pipeline->scaler = scaler;
    const int* coefficients = sws_getCoefficients(SWS_CS_ITU709);
    sws_setColorspaceDetails(pipeline->scaler, coefficients, source_full_range, coefficients, 1, 0,
                             1 << 16, 1 << 16);
    size_t required = (size_t)width * (size_t)height * 3;
    uint8_t* buffer = realloc(pipeline->rgb_buffer, required);
    if (!buffer) {
        fprintf(stderr, "Failed to allocate %zu-byte RGB frame\n", required);
        return -1;
    }
    pipeline->rgb_buffer = buffer;
    pipeline->rgb_linesize = width * 3;
    return 0;
}

static int upload_frame(GoVideoPipeline* pipeline, const AVFrame* frame) {
    if (configure_renderer(pipeline, frame) < 0)
        return -1;
    if (pipeline->texture_format == SDL_PIXELFORMAT_NV12) {
        if (SDL_UpdateNVTexture(pipeline->texture, NULL, frame->data[0], frame->linesize[0],
                                frame->data[1], frame->linesize[1]) == 0)
            return 0;
        fprintf(stderr, "Direct NV12 upload disabled: %s\n", SDL_GetError());
        pipeline->direct_nv12_available = 0;
        destroy_texture(pipeline);
        if (configure_renderer(pipeline, frame) < 0)
            return -1;
    }
    const uint8_t* source[4] = {frame->data[0], frame->data[1], frame->data[2], frame->data[3]};
    uint8_t* destination[4] = {pipeline->rgb_buffer, NULL, NULL, NULL};
    int destination_linesize[4] = {pipeline->rgb_linesize, 0, 0, 0};
    sws_scale(pipeline->scaler, source, frame->linesize, 0, frame->height, destination,
              destination_linesize);
    return SDL_UpdateTexture(pipeline->texture, NULL, pipeline->rgb_buffer, pipeline->rgb_linesize);
}

GoVideoPipeline* go_video_pipeline_create(SDL_Renderer* renderer, const char* bootstrap_path) {
    if (!renderer)
        return NULL;
    GoVideoPipeline* pipeline = calloc(1, sizeof(*pipeline));
    if (!pipeline)
        return NULL;
    pipeline->renderer = renderer;
    pipeline->direct_nv12_available = 1;
    pipeline->texture_format = SDL_PIXELFORMAT_UNKNOWN;
    atomic_store(&pipeline->keyframe_pending, 1);
    atomic_store(&pipeline->last_rejected_payload_type, -1);
    if (bootstrap_path && snprintf(pipeline->bootstrap_path, sizeof(pipeline->bootstrap_path), "%s",
                                   bootstrap_path) >= (int)sizeof(pipeline->bootstrap_path)) {
        free(pipeline);
        return NULL;
    }
    if (pthread_mutex_init(&pipeline->packet_lock, NULL) != 0) {
        free(pipeline);
        return NULL;
    }
    if (pthread_cond_init(&pipeline->packet_condition, NULL) != 0) {
        pthread_mutex_destroy(&pipeline->packet_lock);
        free(pipeline);
        return NULL;
    }
    pipeline->packet_sync_initialized = 1;
    if (pthread_mutex_init(&pipeline->frame_lock, NULL) != 0) {
        go_video_pipeline_destroy(pipeline);
        return NULL;
    }
    pipeline->frame_lock_initialized = 1;
    pipeline->depacketizer = go_h264_depacketizer_create(GO_VIDEO_PAYLOAD_TYPE);
    pipeline->codec = avcodec_find_decoder(AV_CODEC_ID_H264);
    if (!pipeline->depacketizer || !pipeline->codec) {
        go_video_pipeline_destroy(pipeline);
        return NULL;
    }
    pipeline->decoder = avcodec_alloc_context3(pipeline->codec);
    if (!pipeline->decoder) {
        go_video_pipeline_destroy(pipeline);
        return NULL;
    }
    pipeline->decoder->thread_count = 3;
    pipeline->decoder->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;
    pipeline->decoder->skip_frame = AVDISCARD_NONREF;
    if (load_bootstrap(pipeline) != 0 ||
        avcodec_open2(pipeline->decoder, pipeline->codec, NULL) < 0) {
        go_video_pipeline_destroy(pipeline);
        return NULL;
    }
    pipeline->decoder_packet = av_packet_alloc();
    pipeline->decoder_frame = av_frame_alloc();
    pipeline->cedar_frame = av_frame_alloc();
    pipeline->display_frame = av_frame_alloc();
    pipeline->render_frame = av_frame_alloc();
    if (!pipeline->decoder_packet || !pipeline->decoder_frame || !pipeline->cedar_frame ||
        !pipeline->display_frame || !pipeline->render_frame) {
        go_video_pipeline_destroy(pipeline);
        return NULL;
    }
    pipeline->cedar = go_cedar_library_open(1280, 720);
    if (go_cedar_library_ready(pipeline->cedar)) {
        go_dbg("H.264 decoder: Cedar hardware acceleration\n");
    } else {
        go_dbg("H.264 decoder: software fallback (%s)\n", go_cedar_library_error(pipeline->cedar));
        go_cedar_library_close(pipeline->cedar);
        pipeline->cedar = NULL;
    }
    return pipeline;
}

int go_video_pipeline_start(GoVideoPipeline* pipeline) {
    if (!pipeline || pipeline->thread_started)
        return -1;
    atomic_store(&pipeline->stop, 0);
    atomic_store(&pipeline->accepting_packets, 1);
    if (pthread_create(&pipeline->thread, NULL, video_worker, pipeline) != 0) {
        atomic_store(&pipeline->accepting_packets, 0);
        return -1;
    }
    pipeline->thread_started = 1;
    return 0;
}

void go_video_pipeline_stop(GoVideoPipeline* pipeline) {
    if (!pipeline)
        return;
    atomic_store(&pipeline->accepting_packets, 0);
    if (!pipeline->thread_started)
        return;
    atomic_store(&pipeline->stop, 1);
    pthread_mutex_lock(&pipeline->packet_lock);
    pthread_cond_broadcast(&pipeline->packet_condition);
    pthread_mutex_unlock(&pipeline->packet_lock);
    pthread_join(pipeline->thread, NULL);
    pipeline->thread_started = 0;
    pthread_mutex_lock(&pipeline->packet_lock);
    pipeline->packet_queue_head = 0;
    pipeline->packet_queue_tail = 0;
    pipeline->packet_queue_count = 0;
    pthread_mutex_unlock(&pipeline->packet_lock);
}

void go_video_pipeline_set_crop_aspect(GoVideoPipeline* pipeline, unsigned int width,
                                       unsigned int height) {
    if (!pipeline)
        return;
    pipeline->crop_aspect_width = width;
    pipeline->crop_aspect_height = height;
}

void go_video_pipeline_push_rtp(GoVideoPipeline* pipeline, const uint8_t* packet, size_t length) {
    if (!pipeline || !packet || length < 12 || !atomic_load(&pipeline->accepting_packets))
        return;
    if (length > VIDEO_PACKET_MAX_SIZE) {
        atomic_fetch_add(&pipeline->dropped_packets, 1);
        atomic_store(&pipeline->keyframe_pending, 1);
        return;
    }
    pthread_mutex_lock(&pipeline->packet_lock);
    if (pipeline->packet_queue_count == VIDEO_PACKET_QUEUE_CAPACITY) {
        pipeline->packet_queue_head =
            (pipeline->packet_queue_head + 1) % VIDEO_PACKET_QUEUE_CAPACITY;
        pipeline->packet_queue_count--;
        atomic_fetch_add(&pipeline->dropped_packets, 1);
        atomic_store(&pipeline->keyframe_pending, 1);
    }
    VideoPacket* target = &pipeline->packet_queue[pipeline->packet_queue_tail];
    target->length = (uint16_t)length;
    memcpy(target->data, packet, length);
    pipeline->packet_queue_tail = (pipeline->packet_queue_tail + 1) % VIDEO_PACKET_QUEUE_CAPACITY;
    pipeline->packet_queue_count++;
    pthread_cond_signal(&pipeline->packet_condition);
    pthread_mutex_unlock(&pipeline->packet_lock);
}

void go_video_pipeline_render(GoVideoPipeline* pipeline) {
    if (!pipeline || !atomic_load(&pipeline->frame_ready))
        return;
    pthread_mutex_lock(&pipeline->frame_lock);
    if (atomic_load(&pipeline->frame_ready)) {
        av_frame_unref(pipeline->render_frame);
        av_frame_move_ref(pipeline->render_frame, pipeline->display_frame);
        atomic_store(&pipeline->frame_ready, 0);
    }
    pthread_mutex_unlock(&pipeline->frame_lock);
    if (!pipeline->render_frame->data[0] || upload_frame(pipeline, pipeline->render_frame) < 0) {
        if (!pipeline->upload_error_reported) {
            fprintf(stderr, "Frame upload failed: %s\n", SDL_GetError());
            pipeline->upload_error_reported = 1;
        }
        av_frame_unref(pipeline->render_frame);
        return;
    }
    int output_width = 0;
    int output_height = 0;
    SDL_GetRendererOutputSize(pipeline->renderer, &output_width, &output_height);
    SDL_Rect source = {0, 0, pipeline->texture_width, pipeline->texture_height};
    if (pipeline->crop_aspect_width > 0 && pipeline->crop_aspect_height > 0 &&
        (int64_t)source.w * pipeline->crop_aspect_height >
            (int64_t)source.h * pipeline->crop_aspect_width) {
        source.w =
            (int)((int64_t)source.h * pipeline->crop_aspect_width / pipeline->crop_aspect_height) &
            ~1;
        source.x = (pipeline->texture_width - source.w) / 2;
    }
    SDL_Rect destination = {0, 0, output_width, output_height};
    if ((int64_t)output_width * source.h > (int64_t)output_height * source.w) {
        destination.w = output_height * source.w / source.h;
        destination.x = (output_width - destination.w) / 2;
    } else {
        destination.h = output_width * source.h / source.w;
        destination.y = (output_height - destination.h) / 2;
    }
    SDL_SetRenderDrawColor(pipeline->renderer, 0, 0, 0, 255);
    SDL_RenderClear(pipeline->renderer);
    SDL_RenderCopy(pipeline->renderer, pipeline->texture, &source, &destination);
    SDL_RenderPresent(pipeline->renderer);
    atomic_fetch_add(&pipeline->rendered_frames, 1);
    av_frame_unref(pipeline->render_frame);
}

int go_video_pipeline_needs_keyframe(const GoVideoPipeline* pipeline) {
    return pipeline &&
           (!atomic_load(&pipeline->synced) || atomic_load(&pipeline->keyframe_pending));
}

int go_video_pipeline_has_media(const GoVideoPipeline* pipeline) {
    return pipeline && atomic_load(&pipeline->rtp_packets) > 0;
}

void go_video_pipeline_note_keyframe_request(GoVideoPipeline* pipeline) {
    if (pipeline)
        atomic_fetch_add(&pipeline->keyframe_requests, 1);
}

GoVideoStats go_video_pipeline_stats(GoVideoPipeline* pipeline) {
    GoVideoStats stats = {0};
    if (!pipeline)
        return stats;
    stats.rtp_packets = atomic_load(&pipeline->rtp_packets);
    stats.payload_packets = atomic_load(&pipeline->payload_packets);
    stats.rejected_packets = atomic_load(&pipeline->rejected_packets);
    stats.last_rejected_payload_type = atomic_load(&pipeline->last_rejected_payload_type);
    stats.access_units = atomic_load(&pipeline->access_units);
    stats.decoded_frames = atomic_load(&pipeline->decoded_frames);
    stats.rendered_frames = atomic_load(&pipeline->rendered_frames);
    stats.frame_nals = atomic_load(&pipeline->frame_nals);
    stats.idr_nals = atomic_load(&pipeline->idr_nals);
    stats.parameter_nals = atomic_load(&pipeline->parameter_nals);
    stats.auxiliary_nals = atomic_load(&pipeline->auxiliary_nals);
    stats.last_timestamp = atomic_load(&pipeline->last_timestamp);
    stats.synced = atomic_load(&pipeline->synced);
    stats.discontinuities = atomic_load(&pipeline->discontinuities);
    stats.missing_packets = atomic_load(&pipeline->missing_packets);
    stats.late_packets = atomic_load(&pipeline->late_packets);
    stats.decoder_send_errors = atomic_load(&pipeline->decoder_send_errors);
    stats.decoder_receive_errors = atomic_load(&pipeline->decoder_receive_errors);
    stats.last_decoder_error = atomic_load(&pipeline->last_decoder_error);
    stats.keyframe_requests = atomic_load(&pipeline->keyframe_requests);
    stats.dropped_packets = atomic_load(&pipeline->dropped_packets);
    pthread_mutex_lock(&pipeline->packet_lock);
    stats.pending_packets = pipeline->packet_queue_count;
    pthread_mutex_unlock(&pipeline->packet_lock);
    return stats;
}

int go_video_pipeline_destroy(GoVideoPipeline* pipeline) {
    if (!pipeline)
        return 0;
    go_video_pipeline_stop(pipeline);
    int persist_result = persist_bootstrap(pipeline);
    if (pipeline->frame_lock_initialized) {
        pthread_mutex_lock(&pipeline->frame_lock);
        atomic_store(&pipeline->frame_ready, 0);
        if (pipeline->display_frame)
            av_frame_unref(pipeline->display_frame);
        pthread_mutex_unlock(&pipeline->frame_lock);
    }
    if (pipeline->render_frame)
        av_frame_free(&pipeline->render_frame);
    if (pipeline->display_frame)
        av_frame_free(&pipeline->display_frame);
    if (pipeline->scaler)
        sws_freeContext(pipeline->scaler);
    free(pipeline->rgb_buffer);
    destroy_texture(pipeline);
    if (pipeline->cedar)
        go_cedar_library_close(pipeline->cedar);
    if (pipeline->cedar_frame)
        av_frame_free(&pipeline->cedar_frame);
    if (pipeline->decoder_frame)
        av_frame_free(&pipeline->decoder_frame);
    if (pipeline->decoder_packet)
        av_packet_free(&pipeline->decoder_packet);
    if (pipeline->decoder)
        avcodec_free_context(&pipeline->decoder);
    if (pipeline->depacketizer)
        go_h264_depacketizer_destroy(pipeline->depacketizer);
    if (pipeline->frame_lock_initialized)
        pthread_mutex_destroy(&pipeline->frame_lock);
    if (pipeline->packet_sync_initialized) {
        pthread_cond_destroy(&pipeline->packet_condition);
        pthread_mutex_destroy(&pipeline->packet_lock);
    }
    free(pipeline);
    return persist_result;
}
