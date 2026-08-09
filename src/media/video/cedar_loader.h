#ifndef GREENOVERCAST_CEDAR_LOADER_H
#define GREENOVERCAST_CEDAR_LOADER_H

#include "cedar_decoder.h"

typedef struct GoCedarLibrary GoCedarLibrary;

GoCedarLibrary* go_cedar_library_open(int width, int height);
int go_cedar_library_ready(const GoCedarLibrary* library);
int go_cedar_library_feed(GoCedarLibrary* library, const uint8_t* annex_b, size_t length,
                          GoCedarFrame* frame);
const char* go_cedar_library_error(const GoCedarLibrary* library);
void go_cedar_library_close(GoCedarLibrary* library);

#endif
