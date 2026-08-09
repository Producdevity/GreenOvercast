#ifndef GREENOVERCAST_AUDIO_PIPELINE_H
#define GREENOVERCAST_AUDIO_PIPELINE_H

#include <SDL2/SDL.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GoAudioPipeline GoAudioPipeline;

typedef struct {
    int rtp_packets;
    int decoded_packets;
    int dropped_packets;
    int late_packets;
    int pending_packets;
    int queue_resets;
    unsigned int queued_milliseconds;
} GoAudioStats;

GoAudioPipeline* go_audio_pipeline_create(SDL_AudioDeviceID device);
int go_audio_pipeline_start(GoAudioPipeline* pipeline);
void go_audio_pipeline_stop(GoAudioPipeline* pipeline);
void go_audio_pipeline_push_rtp(GoAudioPipeline* pipeline, const uint8_t* packet, size_t length);
GoAudioStats go_audio_pipeline_stats(GoAudioPipeline* pipeline);
void go_audio_pipeline_destroy(GoAudioPipeline* pipeline);

#ifdef __cplusplus
}
#endif

#endif
