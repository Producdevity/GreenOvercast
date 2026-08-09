#ifndef GREENOVERCAST_RTP_PACKET_H
#define GREENOVERCAST_RTP_PACKET_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t accepted;
    uint32_t marker;
    uint16_t sequence;
    uint16_t reserved;
    uint32_t timestamp;
    const uint8_t* data;
    size_t length;
} GoRtpPayload;

GoRtpPayload go_rtp_parse_payload(const uint8_t* packet, size_t length,
                                  uint8_t expected_payload_type);

#ifdef __cplusplus
}
#endif

#endif
