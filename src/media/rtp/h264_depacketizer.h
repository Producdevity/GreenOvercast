#ifndef GREENOVERCAST_H264_DEPACKETIZER_H
#define GREENOVERCAST_H264_DEPACKETIZER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GoH264Depacketizer GoH264Depacketizer;

typedef struct {
    uint32_t timestamp;
    uint32_t has_idr;
    uint32_t has_sps;
    uint32_t has_pps;
} GoH264AccessUnit;

typedef struct {
    uint32_t accepted;
    uint32_t timestamp;
    uint32_t missing_packets;
    uint32_t late_packets;
    uint32_t discontinuities;
    uint32_t access_units;
    uint32_t frame_nals;
    uint32_t idr_nals;
    uint32_t parameter_nals;
    uint32_t auxiliary_nals;
    uint32_t requires_keyframe;
} GoH264FeedResult;

typedef void (*GoH264AccessUnitCallback)(void* context, const uint8_t* data, size_t length,
                                         const GoH264AccessUnit* info);

GoH264Depacketizer* go_h264_depacketizer_create(uint8_t expected_payload_type);
void go_h264_depacketizer_destroy(GoH264Depacketizer* depacketizer);
int go_h264_depacketizer_set_bootstrap(GoH264Depacketizer* depacketizer, const uint8_t* data,
                                       size_t length);
int go_h264_depacketizer_take_bootstrap(GoH264Depacketizer* depacketizer, uint8_t* output,
                                        size_t capacity, size_t* length);
GoH264FeedResult go_h264_depacketizer_feed(GoH264Depacketizer* depacketizer,
                                           const uint8_t* packet, size_t length,
                                           GoH264AccessUnitCallback callback, void* context);

#ifdef __cplusplus
}
#endif

#endif
