#ifndef GREENOVERCAST_OPUS_ADAPTER_H
#define GREENOVERCAST_OPUS_ADAPTER_H

typedef struct GoOpus GoOpus;

GoOpus* go_opus_create(int sample_rate, int channels);
int go_opus_decode(GoOpus* go, const void* packet, int len, short* pcm, int max_samples);
void go_opus_destroy(GoOpus* go);

#endif
