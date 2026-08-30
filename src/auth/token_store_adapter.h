#ifndef GREENOVERCAST_TOKEN_STORE_ADAPTER_H
#define GREENOVERCAST_TOKEN_STORE_ADAPTER_H

#include <stddef.h>

int go_token_store_load(const char* credential_path, const char* key_path, char* refresh_token,
                        size_t refresh_token_capacity);
int go_token_store_save(const char* credential_path, const char* key_path,
                        const char* refresh_token);
int go_token_store_delete(const char* credential_path, const char* key_path);

#endif
