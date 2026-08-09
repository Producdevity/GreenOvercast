#include "audio_pipeline.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include "opus_adapter.h"
#include "packet.h"

#define AUDIO_PAYLOAD_TYPE 111
#define AUDIO_QUEUE_CAPACITY 32
#define AUDIO_TARGET_PENDING_PACKETS 2
#define AUDIO_PACKET_MAX 2048
#define AUDIO_MAX_SAMPLES (5760 * 2)
#define AUDIO_TARGET_MAX_BYTES (48000 * 2 * 2 * 40 / 1000)
#define AUDIO_HARD_RESET_BYTES (48000 * 2 * 2 * 120 / 1000)

typedef struct {
    uint16_t length;
    uint8_t data[AUDIO_PACKET_MAX];
} AudioPacket;

struct GoAudioPipeline {
    SDL_AudioDeviceID device;
    GoOpus* decoder;
    AudioPacket queue[AUDIO_QUEUE_CAPACITY];
    int queue_head;
    int queue_tail;
    int queue_count;
    pthread_mutex_t lock;
    pthread_cond_t condition;
    pthread_t thread;
    int thread_started;
    atomic_int stop;
    atomic_int accepting_packets;
    atomic_int rtp_packets;
    atomic_int decoded_packets;
    atomic_int dropped_packets;
    atomic_int late_packets;
    atomic_int queue_resets;
};

static void* audio_worker(void* context) {
    GoAudioPipeline* pipeline = context;
    while (!atomic_load(&pipeline->stop)) {
        AudioPacket packet;
        pthread_mutex_lock(&pipeline->lock);
        while (pipeline->queue_count == 0 && !atomic_load(&pipeline->stop))
            pthread_cond_wait(&pipeline->condition, &pipeline->lock);
        if (atomic_load(&pipeline->stop)) {
            pthread_mutex_unlock(&pipeline->lock);
            break;
        }
        while (pipeline->queue_count > AUDIO_TARGET_PENDING_PACKETS) {
            pipeline->queue_head = (pipeline->queue_head + 1) % AUDIO_QUEUE_CAPACITY;
            pipeline->queue_count--;
            atomic_fetch_add(&pipeline->late_packets, 1);
        }
        packet = pipeline->queue[pipeline->queue_head];
        pipeline->queue_head = (pipeline->queue_head + 1) % AUDIO_QUEUE_CAPACITY;
        pipeline->queue_count--;
        pthread_mutex_unlock(&pipeline->lock);

        short pcm[AUDIO_MAX_SAMPLES];
        int samples =
            go_opus_decode(pipeline->decoder, packet.data, packet.length, pcm, AUDIO_MAX_SAMPLES);
        if (samples <= 0) {
            atomic_fetch_add(&pipeline->dropped_packets, 1);
            continue;
        }
        Uint32 output_bytes = (Uint32)samples * sizeof(short);
        Uint32 queued;
        while ((queued = SDL_GetQueuedAudioSize(pipeline->device)) + output_bytes >
                   AUDIO_TARGET_MAX_BYTES &&
               !atomic_load(&pipeline->stop)) {
            if (queued > AUDIO_HARD_RESET_BYTES) {
                SDL_ClearQueuedAudio(pipeline->device);
                atomic_fetch_add(&pipeline->queue_resets, 1);
                break;
            }
            SDL_Delay(2);
        }
        if (atomic_load(&pipeline->stop))
            break;
        if (SDL_QueueAudio(pipeline->device, pcm, output_bytes) == 0)
            atomic_fetch_add(&pipeline->decoded_packets, 1);
        else
            atomic_fetch_add(&pipeline->dropped_packets, 1);
    }
    return NULL;
}

GoAudioPipeline* go_audio_pipeline_create(SDL_AudioDeviceID device) {
    if (!device)
        return NULL;
    GoAudioPipeline* pipeline = calloc(1, sizeof(*pipeline));
    if (!pipeline)
        return NULL;
    pipeline->device = device;
    pipeline->decoder = go_opus_create(48000, 2);
    if (!pipeline->decoder) {
        free(pipeline);
        return NULL;
    }
    if (pthread_mutex_init(&pipeline->lock, NULL) != 0) {
        go_opus_destroy(pipeline->decoder);
        free(pipeline);
        return NULL;
    }
    if (pthread_cond_init(&pipeline->condition, NULL) != 0) {
        pthread_mutex_destroy(&pipeline->lock);
        go_opus_destroy(pipeline->decoder);
        free(pipeline);
        return NULL;
    }
    return pipeline;
}

int go_audio_pipeline_start(GoAudioPipeline* pipeline) {
    if (!pipeline || pipeline->thread_started)
        return -1;
    SDL_ClearQueuedAudio(pipeline->device);
    atomic_store(&pipeline->stop, 0);
    atomic_store(&pipeline->accepting_packets, 1);
    if (pthread_create(&pipeline->thread, NULL, audio_worker, pipeline) != 0) {
        atomic_store(&pipeline->accepting_packets, 0);
        return -1;
    }
    pipeline->thread_started = 1;
    SDL_PauseAudioDevice(pipeline->device, 0);
    return 0;
}

void go_audio_pipeline_stop(GoAudioPipeline* pipeline) {
    if (!pipeline)
        return;
    atomic_store(&pipeline->accepting_packets, 0);
    if (pipeline->thread_started) {
        atomic_store(&pipeline->stop, 1);
        pthread_mutex_lock(&pipeline->lock);
        pthread_cond_broadcast(&pipeline->condition);
        pthread_mutex_unlock(&pipeline->lock);
        pthread_join(pipeline->thread, NULL);
        pipeline->thread_started = 0;
    }
    SDL_PauseAudioDevice(pipeline->device, 1);
    SDL_ClearQueuedAudio(pipeline->device);
    pthread_mutex_lock(&pipeline->lock);
    pipeline->queue_head = 0;
    pipeline->queue_tail = 0;
    pipeline->queue_count = 0;
    pthread_mutex_unlock(&pipeline->lock);
}

void go_audio_pipeline_push_rtp(GoAudioPipeline* pipeline, const uint8_t* packet, size_t length) {
    if (!pipeline || !packet || !atomic_load(&pipeline->accepting_packets))
        return;
    GoRtpPayload payload = go_rtp_parse_payload(packet, length, AUDIO_PAYLOAD_TYPE);
    if (!payload.accepted)
        return;
    atomic_fetch_add(&pipeline->rtp_packets, 1);
    if (payload.length > AUDIO_PACKET_MAX) {
        atomic_fetch_add(&pipeline->dropped_packets, 1);
        return;
    }

    pthread_mutex_lock(&pipeline->lock);
    if (pipeline->queue_count == AUDIO_QUEUE_CAPACITY) {
        atomic_fetch_add(&pipeline->dropped_packets, 1);
    } else {
        AudioPacket* target = &pipeline->queue[pipeline->queue_tail];
        target->length = (uint16_t)payload.length;
        memcpy(target->data, payload.data, payload.length);
        pipeline->queue_tail = (pipeline->queue_tail + 1) % AUDIO_QUEUE_CAPACITY;
        pipeline->queue_count++;
        pthread_cond_signal(&pipeline->condition);
    }
    pthread_mutex_unlock(&pipeline->lock);
}

GoAudioStats go_audio_pipeline_stats(GoAudioPipeline* pipeline) {
    GoAudioStats stats = {0};
    if (!pipeline)
        return stats;
    stats.rtp_packets = atomic_load(&pipeline->rtp_packets);
    stats.decoded_packets = atomic_load(&pipeline->decoded_packets);
    stats.dropped_packets = atomic_load(&pipeline->dropped_packets);
    stats.late_packets = atomic_load(&pipeline->late_packets);
    stats.queue_resets = atomic_load(&pipeline->queue_resets);
    pthread_mutex_lock(&pipeline->lock);
    stats.pending_packets = pipeline->queue_count;
    pthread_mutex_unlock(&pipeline->lock);
    stats.queued_milliseconds =
        SDL_GetQueuedAudioSize(pipeline->device) * 1000 / (48000 * 2 * sizeof(short));
    return stats;
}

void go_audio_pipeline_destroy(GoAudioPipeline* pipeline) {
    if (!pipeline)
        return;
    go_audio_pipeline_stop(pipeline);
    go_opus_destroy(pipeline->decoder);
    pthread_cond_destroy(&pipeline->condition);
    pthread_mutex_destroy(&pipeline->lock);
    free(pipeline);
}
