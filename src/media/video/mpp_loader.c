#include "mpp_loader.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint32_t (*AbiVersion)(void);
typedef GoMppDecoder* (*CreateDecoder)(int max_width, int max_height);
typedef int (*SubmitDecoder)(GoMppDecoder* decoder, const uint8_t* data, size_t length);
typedef int (*ReceiveDecoder)(GoMppDecoder* decoder, GoMppFrame* frame);
typedef void (*ReleaseFrame)(GoMppDecoder* decoder, GoMppFrame* frame);
typedef int (*ResetDecoder)(GoMppDecoder* decoder);
typedef const char* (*DecoderError)(GoMppDecoder* decoder);
typedef void (*DestroyDecoder)(GoMppDecoder* decoder);

struct GoMppLibrary {
    void* handle;
    GoMppDecoder* decoder;
    SubmitDecoder submit;
    ReceiveDecoder receive;
    ReleaseFrame release_frame;
    ResetDecoder reset;
    DecoderError decoder_error;
    DestroyDecoder destroy;
    char path[512];
    char error[256];
};

static void set_loader_error(GoMppLibrary* library, const char* message) {
    snprintf(library->error, sizeof(library->error), "%s", message ? message : "unknown error");
}

static void* load_symbol(GoMppLibrary* library, const char* name) {
    dlerror();
    void* symbol = dlsym(library->handle, name);
    const char* error = dlerror();
    if (error || !symbol)
        set_loader_error(library, error ? error : "MPP plugin symbol is missing");
    return symbol;
}

GoMppLibrary* go_mpp_library_open(int max_width, int max_height) {
    GoMppLibrary* library = calloc(1, sizeof(*library));
    if (!library)
        return NULL;

    const char* path = getenv("GREENOVERCAST_MPP_LIBRARY");
    if (!path || !path[0])
        path = "libgreenovercast-mpp.so";
    if (snprintf(library->path, sizeof(library->path), "%s", path) >= (int)sizeof(library->path)) {
        set_loader_error(library, "MPP plugin path is too long");
        return library;
    }

    int flags = RTLD_NOW | RTLD_LOCAL;
#ifdef RTLD_NODELETE
    /* Older Rockchip MPP builds can run process-lifetime cleanup after decoder teardown. */
    flags |= RTLD_NODELETE;
#endif
    library->handle = dlopen(path, flags);
    if (!library->handle) {
        set_loader_error(library, dlerror());
        return library;
    }

    AbiVersion abi_version = (AbiVersion)load_symbol(library, "go_mpp_decoder_abi_version");
    if (!abi_version)
        goto fail;
    uint32_t version = abi_version();
    if (version != GO_MPP_DECODER_ABI_VERSION) {
        snprintf(library->error, sizeof(library->error),
                 "MPP plugin ABI %u is incompatible with required ABI %u", version,
                 GO_MPP_DECODER_ABI_VERSION);
        goto fail;
    }

    CreateDecoder create = (CreateDecoder)load_symbol(library, "go_mpp_decoder_create");
    library->submit = (SubmitDecoder)load_symbol(library, "go_mpp_decoder_submit");
    library->receive = (ReceiveDecoder)load_symbol(library, "go_mpp_decoder_receive");
    library->release_frame = (ReleaseFrame)load_symbol(library, "go_mpp_decoder_release_frame");
    library->reset = (ResetDecoder)load_symbol(library, "go_mpp_decoder_reset");
    library->decoder_error = (DecoderError)load_symbol(library, "go_mpp_decoder_last_error");
    library->destroy = (DestroyDecoder)load_symbol(library, "go_mpp_decoder_destroy");
    if (!create || !library->submit || !library->receive || !library->release_frame ||
        !library->reset || !library->decoder_error || !library->destroy)
        goto fail;

    library->decoder = create(max_width, max_height);
    if (!library->decoder) {
        set_loader_error(library, library->decoder_error(NULL));
        return library;
    }
    return library;

fail:
    dlclose(library->handle);
    library->handle = NULL;
    return library;
}

int go_mpp_library_ready(const GoMppLibrary* library) {
    return library && library->decoder && library->submit && library->receive &&
           library->release_frame && library->reset && library->decoder_error && library->destroy;
}

int go_mpp_library_submit(GoMppLibrary* library, const uint8_t* data, size_t length) {
    if (!go_mpp_library_ready(library))
        return -1;
    int result = library->submit(library->decoder, data, length);
    if (result < 0)
        set_loader_error(library, library->decoder_error(library->decoder));
    return result;
}

int go_mpp_library_receive(GoMppLibrary* library, GoMppFrame* frame) {
    if (!go_mpp_library_ready(library))
        return -1;
    int result = library->receive(library->decoder, frame);
    if (result < 0)
        set_loader_error(library, library->decoder_error(library->decoder));
    return result;
}

void go_mpp_library_release_frame(GoMppLibrary* library, GoMppFrame* frame) {
    if (go_mpp_library_ready(library) && frame)
        library->release_frame(library->decoder, frame);
}

int go_mpp_library_reset(GoMppLibrary* library) {
    if (!go_mpp_library_ready(library))
        return -1;
    int result = library->reset(library->decoder);
    if (result < 0)
        set_loader_error(library, library->decoder_error(library->decoder));
    return result;
}

const char* go_mpp_library_error(const GoMppLibrary* library) {
    return library && library->error[0] ? library->error : "MPP decoder unavailable";
}

const char* go_mpp_library_path(const GoMppLibrary* library) {
    return library && library->path[0] ? library->path : "libgreenovercast-mpp.so";
}

void go_mpp_library_close(GoMppLibrary* library) {
    if (!library)
        return;
    if (library->decoder && library->destroy)
        library->destroy(library->decoder);
    if (library->handle)
        dlclose(library->handle);
    free(library);
}
