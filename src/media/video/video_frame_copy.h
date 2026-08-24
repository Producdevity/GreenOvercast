#ifndef GREENOVERCAST_VIDEO_FRAME_COPY_H
#define GREENOVERCAST_VIDEO_FRAME_COPY_H

#include "video_decoder.h"

int go_video_frame_validate(const GoDecodedVideoFrame* frame, int max_width, int max_height);
int go_video_frame_copy(const GoDecodedVideoFrame* source, int max_width, int max_height,
                        uint8_t* destination_planes[3], const int destination_strides[3]);

#endif
