#ifndef GREENOVERCAST_JSON_READER_H
#define GREENOVERCAST_JSON_READER_H

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

int go_json_copy_string(const char* data, size_t length, const char* key, char* output,
                        size_t capacity);
int go_json_unsigned(const char* data, size_t length, const char* key, unsigned int* output);

// Heap-allocates a copy of the string value at `key`. Returns NULL when `data`
// or `key` is NULL, the key is absent, or allocation fails. Caller frees it.
static inline char* json_string(const char* data, const char* key) {
    if (!data || !key)
        return NULL;
    size_t capacity = strlen(data) + 1;
    char* value = malloc(capacity);
    if (!value)
        return NULL;
    if (go_json_copy_string(data, capacity - 1, key, value, capacity) < 0) {
        free(value);
        return NULL;
    }
    return value;
}

#ifdef __cplusplus
}
#endif

#endif
