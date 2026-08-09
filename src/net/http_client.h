#ifndef GREENOVERCAST_HTTP_CLIENT_H
#define GREENOVERCAST_HTTP_CLIENT_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char* data;
    size_t len;
    long status;
} GoHttpResponse;

GoHttpResponse* go_http_request(const char* method, const char* url, const char* body,
                                const char** headers, int header_count);
int go_http_response_succeeded(const GoHttpResponse* response);
void go_http_response_destroy(GoHttpResponse* response);

#ifdef __cplusplus
}
#endif

#endif
