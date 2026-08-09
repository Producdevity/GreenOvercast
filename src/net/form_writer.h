#ifndef GREENOVERCAST_FORM_WRITER_H
#define GREENOVERCAST_FORM_WRITER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

int go_form_urlencode(const char* input, size_t input_length, char* output,
                      size_t output_capacity);

#ifdef __cplusplus
}
#endif

#endif
