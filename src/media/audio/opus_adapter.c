/* Minimal declarations for the libopus ABI provided by the target firmware. */
#include <stdint.h>
#include <stdlib.h>

#include "opus_adapter.h"

typedef int32_t opus_int32;
typedef int16_t opus_int16;

typedef struct OpusDecoder OpusDecoder;

extern OpusDecoder* opus_decoder_create(opus_int32 Fs, int channels, int* error);
extern int opus_decode(OpusDecoder* st, const unsigned char* data, opus_int32 len, opus_int16* pcm,
                       int frame_size, int decode_fec);
extern void opus_decoder_destroy(OpusDecoder* st);

struct GoOpus {
    OpusDecoder* dec;
    int channels;
};

GoOpus* go_opus_create(int sample_rate, int channels) {
    int err = 0;
    OpusDecoder* d = opus_decoder_create(sample_rate, channels, &err);
    if (err != 0 || !d)
        return NULL;
    GoOpus* go = (GoOpus*)malloc(sizeof(GoOpus));
    if (!go) {
        opus_decoder_destroy(d);
        return NULL;
    }
    go->dec = d;
    go->channels = channels;
    return go;
}

/* Returns number of samples decoded (per channel * channels), or negative on error. */
int go_opus_decode(GoOpus* go, const void* packet, int len, short* pcm, int max_samples) {
    int frame = opus_decode(go->dec, (const unsigned char*)packet, len, (opus_int16*)pcm,
                            max_samples / go->channels, 0);
    if (frame < 0)
        return frame;
    return frame * go->channels;
}

void go_opus_destroy(GoOpus* go) {
    if (go) {
        opus_decoder_destroy(go->dec);
        free(go);
    }
}
