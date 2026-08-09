#ifndef GREENOVERCAST_JSON_WRITER_H
#define GREENOVERCAST_JSON_WRITER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

int go_json_escape_string(const char* input, size_t input_length, char* output,
                          size_t output_capacity);

#ifdef __cplusplus
}
#endif

#endif
