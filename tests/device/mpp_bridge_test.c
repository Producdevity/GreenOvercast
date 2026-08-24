#include "mpp_loader.h"

#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    int expected_width;
    int expected_height;
    int checksum_frame_limit;
    int frames;
    uint64_t checksum;
} TestState;

static uint64_t checksum_bytes(uint64_t value, const uint8_t* data, size_t length) {
    for (size_t index = 0; index < length; ++index) {
        value ^= data[index];
        value *= UINT64_C(1099511628211);
    }
    return value;
}

static int drain_frames(GoMppLibrary* library, TestState* state) {
    for (;;) {
        GoMppFrame frame;
        int result = go_mpp_library_receive(library, &frame);
        if (result == 0)
            return 0;
        if (result < 0) {
            fprintf(stderr, "MPP frame receive failed: %s\n", go_mpp_library_error(library));
            return -1;
        }
        if (!frame.y || !frame.uv || frame.width != state->expected_width ||
            frame.height != state->expected_height || frame.y_stride < frame.width ||
            frame.uv_stride < frame.width) {
            fprintf(stderr, "invalid MPP frame: %dx%d stride=%d/%d\n", frame.width, frame.height,
                    frame.y_stride, frame.uv_stride);
            go_mpp_library_release_frame(library, &frame);
            return -1;
        }
        if (state->frames < state->checksum_frame_limit) {
            for (int row = 0; row < frame.height; ++row) {
                state->checksum =
                    checksum_bytes(state->checksum, frame.y + (size_t)row * (size_t)frame.y_stride,
                                   (size_t)frame.width);
            }
            for (int row = 0; row < (frame.height + 1) / 2; ++row) {
                state->checksum = checksum_bytes(state->checksum,
                                                 frame.uv + (size_t)row * (size_t)frame.uv_stride,
                                                 (size_t)frame.width);
            }
        }
        state->frames++;
        go_mpp_library_release_frame(library, &frame);
    }
}

static int submit_access_unit(GoMppLibrary* library, const uint8_t* data, size_t length,
                              TestState* state) {
    for (int attempt = 0; attempt < 256; ++attempt) {
        int result = go_mpp_library_submit(library, data, length);
        if (result > 0)
            return drain_frames(library, state);
        if (result < 0) {
            fprintf(stderr, "MPP access-unit submission failed: %s\n",
                    go_mpp_library_error(library));
            return -1;
        }
        if (drain_frames(library, state) != 0)
            return -1;
        usleep(1000);
    }
    fprintf(stderr, "MPP input remained backpressured\n");
    return -1;
}

static size_t start_code_length(const uint8_t* data, size_t length, size_t offset) {
    if (offset + 3 <= length && data[offset] == 0 && data[offset + 1] == 0 && data[offset + 2] == 1)
        return 3;
    if (offset + 4 <= length && data[offset] == 0 && data[offset + 1] == 0 &&
        data[offset + 2] == 0 && data[offset + 3] == 1)
        return 4;
    return 0;
}

static size_t find_next_aud(const uint8_t* data, size_t length, size_t offset) {
    while (offset + 4 <= length) {
        size_t prefix = start_code_length(data, length, offset);
        if (prefix > 0 && offset + prefix < length && (data[offset + prefix] & 0x1f) == 9)
            return offset;
        offset++;
    }
    return length;
}

static uint8_t* read_file(const char* path, size_t* length) {
    FILE* file = fopen(path, "rb");
    if (!file) {
        fprintf(stderr, "%s: %s\n", path, strerror(errno));
        return NULL;
    }
    if (fseek(file, 0, SEEK_END) != 0) {
        fclose(file);
        return NULL;
    }
    long size = ftell(file);
    if (size <= 0 || fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        return NULL;
    }
    uint8_t* data = malloc((size_t)size);
    if (!data) {
        fclose(file);
        return NULL;
    }
    size_t read = fread(data, 1, (size_t)size, file);
    int failed = read != (size_t)size || ferror(file);
    fclose(file);
    if (failed) {
        free(data);
        return NULL;
    }
    *length = read;
    return data;
}

static int parse_positive_int(const char* value) {
    char* end = NULL;
    long parsed = strtol(value, &end, 10);
    return end && *end == 0 && parsed > 0 && parsed <= INT32_MAX ? (int)parsed : -1;
}

static int parse_checksum(const char* value, uint64_t* output) {
    char* end = NULL;
    errno = 0;
    unsigned long long parsed = strtoull(value, &end, 16);
    if (errno != 0 || !end || *end != 0)
        return -1;
    *output = (uint64_t)parsed;
    return 0;
}

int main(int argc, char** argv) {
    if (argc != 5 && argc != 6) {
        fprintf(stderr,
                "usage: %s <annex-b.h264> <width> <height> <minimum-frames> "
                "[expected-checksum]\n",
                argv[0]);
        return 2;
    }
    TestState state = {
        .expected_width = parse_positive_int(argv[2]),
        .expected_height = parse_positive_int(argv[3]),
        .checksum = UINT64_C(1469598103934665603),
    };
    int minimum_frames = parse_positive_int(argv[4]);
    state.checksum_frame_limit = minimum_frames;
    if (state.expected_width < 0 || state.expected_height < 0 || minimum_frames < 0)
        return 2;
    uint64_t expected_checksum = 0;
    if (argc == 6 && parse_checksum(argv[5], &expected_checksum) != 0)
        return 2;

    size_t length = 0;
    uint8_t* data = read_file(argv[1], &length);
    if (!data) {
        fprintf(stderr, "failed to read H.264 fixture\n");
        return 1;
    }

    GoMppLibrary* library = go_mpp_library_open(state.expected_width, state.expected_height);
    if (!go_mpp_library_ready(library)) {
        fprintf(stderr, "MPP H.264 initialization failed: %s\n", go_mpp_library_error(library));
        go_mpp_library_close(library);
        free(data);
        return 1;
    }

    size_t first_aud = find_next_aud(data, length, 0);
    if (first_aud == length) {
        fprintf(stderr, "fixture contains no H.264 access-unit delimiters\n");
        go_mpp_library_close(library);
        free(data);
        return 1;
    }
    size_t access_unit_start = 0;
    size_t next_aud = find_next_aud(data, length, first_aud + 4);
    int failed = 0;
    while (access_unit_start < length) {
        size_t access_unit_end = next_aud;
        if (access_unit_end <= access_unit_start ||
            submit_access_unit(library, data + access_unit_start,
                               access_unit_end - access_unit_start, &state) != 0) {
            failed = 1;
            break;
        }
        if (access_unit_end == length)
            break;
        access_unit_start = access_unit_end;
        next_aud = find_next_aud(data, length, access_unit_start + 4);
    }
    if (!failed && drain_frames(library, &state) != 0)
        failed = 1;

    go_mpp_library_close(library);
    free(data);
    if (failed || state.frames < minimum_frames ||
        (argc == 6 && state.checksum != expected_checksum)) {
        fprintf(stderr, "decoded %d frames; expected at least %d\n", state.frames, minimum_frames);
        if (argc == 6)
            fprintf(stderr, "visible NV12 checksum: %016" PRIx64 "; expected %016" PRIx64 "\n",
                    state.checksum, expected_checksum);
        return 1;
    }
    printf("decoded frames: %d\n", state.frames);
    printf("visible frame: %dx%d\n", state.expected_width, state.expected_height);
    printf("first %d frames NV12 checksum: %016" PRIx64 "\n", minimum_frames, state.checksum);
    return 0;
}
