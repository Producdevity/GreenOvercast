#include "cedar_loader.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef GoCedarDecoder* (*CreateDecoder)(int width, int height);
typedef int (*FeedDecoder)(GoCedarDecoder* decoder, const uint8_t* data, size_t length,
                           GoCedarFrame* frame);
typedef const char* (*DecoderError)(const GoCedarDecoder* decoder);
typedef void (*DestroyDecoder)(GoCedarDecoder* decoder);

struct GoCedarLibrary {
    void* handle;
    GoCedarDecoder* decoder;
    FeedDecoder feed;
    DecoderError decoder_error;
    DestroyDecoder destroy;
    char error[256];
};

static void set_loader_error(GoCedarLibrary* library, const char* message) {
    snprintf(library->error, sizeof(library->error), "%s", message ? message : "unknown error");
}

GoCedarLibrary* go_cedar_library_open(int width, int height) {
    GoCedarLibrary* library = calloc(1, sizeof(*library));
    if (!library)
        return NULL;

    const char* path = getenv("GREENOVERCAST_CEDAR_LIBRARY");
    if (!path || !path[0])
        path = "libgreenovercast-cedar.so";
    library->handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!library->handle) {
        set_loader_error(library, dlerror());
        return library;
    }

    dlerror();
    CreateDecoder create = (CreateDecoder)dlsym(library->handle, "go_cedar_v1_create");
    library->feed = (FeedDecoder)dlsym(library->handle, "go_cedar_v1_feed");
    library->decoder_error = (DecoderError)dlsym(library->handle, "go_cedar_v1_last_error");
    library->destroy = (DestroyDecoder)dlsym(library->handle, "go_cedar_v1_destroy");
    const char* symbol_error = dlerror();
    if (symbol_error || !create || !library->feed || !library->decoder_error || !library->destroy) {
        set_loader_error(library, symbol_error ? symbol_error : "incomplete Cedar decoder ABI");
        dlclose(library->handle);
        library->handle = NULL;
        return library;
    }

    library->decoder = create(width, height);
    if (!library->decoder) {
        set_loader_error(library, "Cedar decoder initialization failed");
        return library;
    }
    return library;
}

int go_cedar_library_ready(const GoCedarLibrary* library) {
    return library && library->decoder && library->feed && library->destroy;
}

int go_cedar_library_feed(GoCedarLibrary* library, const uint8_t* annex_b, size_t length,
                          GoCedarFrame* frame) {
    if (!library || !library->decoder)
        return -1;
    int result = library->feed(library->decoder, annex_b, length, frame);
    if (result < 0)
        set_loader_error(library, library->decoder_error(library->decoder));
    return result;
}

const char* go_cedar_library_error(const GoCedarLibrary* library) {
    return library && library->error[0] ? library->error : "Cedar decoder unavailable";
}

void go_cedar_library_close(GoCedarLibrary* library) {
    if (!library)
        return;
    if (library->decoder && library->destroy)
        library->destroy(library->decoder);
    if (library->handle)
        dlclose(library->handle);
    free(library);
}
