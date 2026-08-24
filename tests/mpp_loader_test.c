#define _POSIX_C_SOURCE 200809L

#include "mpp_loader.h"

#include <assert.h>
#include <stdlib.h>
#include <string.h>

static GoMppLibrary* open_plugin(const char* path, int width) {
    assert(setenv("GREENOVERCAST_MPP_LIBRARY", path, 1) == 0);
    return go_mpp_library_open(width, 720);
}

int main(int argc, char** argv) {
    assert(argc == 4);

    GoMppLibrary* valid = open_plugin(argv[1], 1280);
    assert(go_mpp_library_ready(valid));
    assert(strcmp(go_mpp_library_path(valid), argv[1]) == 0);
    const uint8_t access_unit[] = {0, 0, 0, 1, 0x65};
    assert(go_mpp_library_submit(valid, access_unit, sizeof(access_unit)) == 1);
    GoMppFrame frame;
    assert(go_mpp_library_receive(valid, &frame) == 1);
    assert(frame.width == 4);
    assert(frame.height == 4);
    go_mpp_library_release_frame(valid, &frame);
    assert(frame.owner == NULL);
    assert(go_mpp_library_receive(valid, &frame) == 0);
    assert(go_mpp_library_reset(valid) == 0);
    const uint8_t failure[] = {0xff};
    assert(go_mpp_library_submit(valid, failure, sizeof(failure)) == -1);
    assert(strstr(go_mpp_library_error(valid), "fake runtime failure") != NULL);
    go_mpp_library_close(valid);

    GoMppLibrary* create_failure = open_plugin(argv[1], 13);
    assert(!go_mpp_library_ready(create_failure));
    assert(strstr(go_mpp_library_error(create_failure), "initialization failed") != NULL);
    go_mpp_library_close(create_failure);

    GoMppLibrary* wrong_abi = open_plugin(argv[2], 1280);
    assert(!go_mpp_library_ready(wrong_abi));
    assert(strstr(go_mpp_library_error(wrong_abi), "incompatible") != NULL);
    go_mpp_library_close(wrong_abi);

    GoMppLibrary* missing_symbol = open_plugin(argv[3], 1280);
    assert(!go_mpp_library_ready(missing_symbol));
    assert(strstr(go_mpp_library_error(missing_symbol), "go_mpp_decoder_reset") != NULL);
    go_mpp_library_close(missing_symbol);

    GoMppLibrary* missing_library = open_plugin("/not/a/real/mpp-plugin.so", 1280);
    assert(!go_mpp_library_ready(missing_library));
    assert(go_mpp_library_error(missing_library)[0] != 0);
    go_mpp_library_close(missing_library);
    unsetenv("GREENOVERCAST_MPP_LIBRARY");
    return 0;
}
