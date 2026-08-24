#include "mpp_loader.h"

#include <stdio.h>

int main(void) {
    GoMppLibrary* library = go_mpp_library_open(1280, 720);
    printf("MPP plugin: %s\n", go_mpp_library_path(library));
    if (!go_mpp_library_ready(library)) {
        fprintf(stderr, "MPP H.264 initialization failed: %s\n", go_mpp_library_error(library));
        go_mpp_library_close(library);
        return 1;
    }
    printf("MPP H.264 initialization: success\n");
    go_mpp_library_close(library);
    return 0;
}
