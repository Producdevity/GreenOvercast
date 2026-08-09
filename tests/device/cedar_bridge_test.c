#include "cedar_decoder.h"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>

static size_t find_start_code(const unsigned char* data, size_t length, size_t offset) {
    for (size_t i = offset; i + 3 < length; ++i) {
        if (data[i] == 0 && data[i + 1] == 0 &&
            (data[i + 2] == 1 || (data[i + 2] == 0 && data[i + 3] == 1)))
            return i;
    }
    return length;
}

int main(int argc, char** argv) {
    if (argc != 2)
        return 2;
    FILE* file = fopen(argv[1], "rb");
    if (!file || fseek(file, 0, SEEK_END) != 0)
        return 2;
    long file_size = ftell(file);
    if (file_size <= 0 || file_size > INT_MAX || fseek(file, 0, SEEK_SET) != 0)
        return 2;
    unsigned char* data = malloc((size_t)file_size);
    if (!data || fread(data, 1, (size_t)file_size, file) != (size_t)file_size)
        return 2;
    fclose(file);

    GoCedarDecoder* decoder = go_cedar_v1_create(1280, 720);
    if (!decoder) {
        fprintf(stderr, "CEDAR_BRIDGE init failed\n");
        return 1;
    }

    int frames = 0;
    size_t start = find_start_code(data, (size_t)file_size, 0);
    while (start < (size_t)file_size) {
        size_t prefix = data[start + 2] == 1 ? 3u : 4u;
        size_t end = find_start_code(data, (size_t)file_size, start + prefix);
        GoCedarFrame frame;
        int result = go_cedar_v1_feed(decoder, data + start, end - start, &frame);
        if (result < 0) {
            fprintf(stderr, "CEDAR_BRIDGE decode failed: %s\n", go_cedar_v1_last_error(decoder));
            return 1;
        }
        if (result > 0) {
            ++frames;
            if (frames == 1)
                printf("CEDAR_BRIDGE frame=%dx%d y_stride=%d uv_stride=%d\n", frame.width,
                       frame.height, frame.y_stride, frame.uv_stride);
        }
        start = end;
    }

    for (;;) {
        GoCedarFrame frame;
        int result = go_cedar_v1_flush(decoder, &frame);
        if (result < 0) {
            fprintf(stderr, "CEDAR_BRIDGE flush failed: %s\n", go_cedar_v1_last_error(decoder));
            return 1;
        }
        if (result == 0)
            break;
        ++frames;
    }

    go_cedar_v1_destroy(decoder);
    free(data);
    printf("CEDAR_BRIDGE frames=%d\n", frames);
    return frames == 60 ? 0 : 1;
}
