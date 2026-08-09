#ifndef GREENOVERCAST_VIDEO_PIPELINE_H
#define GREENOVERCAST_VIDEO_PIPELINE_H

#include <SDL2/SDL.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GO_VIDEO_PAYLOAD_TYPE 102

typedef struct GoVideoPipeline GoVideoPipeline;

typedef struct {
    int rtp_packets;
    int payload_packets;
    int rejected_packets;
    int last_rejected_payload_type;
    int access_units;
    int decoded_frames;
    int rendered_frames;
    int frame_nals;
    int idr_nals;
    int parameter_nals;
    int auxiliary_nals;
    unsigned int last_timestamp;
    int synced;
    int discontinuities;
    int missing_packets;
    int late_packets;
    int decoder_send_errors;
    int decoder_receive_errors;
    int last_decoder_error;
    int keyframe_requests;
    int pending_packets;
    int dropped_packets;
} GoVideoStats;

GoVideoPipeline* go_video_pipeline_create(SDL_Renderer* renderer, const char* bootstrap_path);
int go_video_pipeline_start(GoVideoPipeline* pipeline);
void go_video_pipeline_stop(GoVideoPipeline* pipeline);
void go_video_pipeline_set_crop_aspect(GoVideoPipeline* pipeline, unsigned int width,
                                       unsigned int height);
void go_video_pipeline_push_rtp(GoVideoPipeline* pipeline, const uint8_t* packet, size_t length);
void go_video_pipeline_render(GoVideoPipeline* pipeline);
int go_video_pipeline_needs_keyframe(const GoVideoPipeline* pipeline);
int go_video_pipeline_has_media(const GoVideoPipeline* pipeline);
void go_video_pipeline_note_keyframe_request(GoVideoPipeline* pipeline);
GoVideoStats go_video_pipeline_stats(GoVideoPipeline* pipeline);
int go_video_pipeline_destroy(GoVideoPipeline* pipeline);

#ifdef __cplusplus
}
#endif

#endif
