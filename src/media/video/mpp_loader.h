#ifndef GREENOVERCAST_MPP_LOADER_H
#define GREENOVERCAST_MPP_LOADER_H

#include "mpp_decoder.h"

typedef struct GoMppLibrary GoMppLibrary;

GoMppLibrary* go_mpp_library_open(int max_width, int max_height);
int go_mpp_library_ready(const GoMppLibrary* library);
int go_mpp_library_submit(GoMppLibrary* library, const uint8_t* data, size_t length);
int go_mpp_library_receive(GoMppLibrary* library, GoMppFrame* frame);
void go_mpp_library_release_frame(GoMppLibrary* library, GoMppFrame* frame);
int go_mpp_library_reset(GoMppLibrary* library);
const char* go_mpp_library_error(const GoMppLibrary* library);
const char* go_mpp_library_path(const GoMppLibrary* library);
void go_mpp_library_close(GoMppLibrary* library);

#endif
