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

typedef int (*GoHttpCancelRequested)(void* context);

GoHttpResponse* go_http_request(const char* method, const char* url, const char* body,
                                const char** headers, int header_count);
GoHttpResponse* go_http_request_bounded(const char* method, const char* url, const char* body,
                                        const char** headers, int header_count,
                                        size_t response_limit);
GoHttpResponse* go_http_request_bounded_cancelable(
    const char* method, const char* url, const char* body, const char** headers,
    int header_count, size_t response_limit, GoHttpCancelRequested cancel_requested,
    void* cancel_context);
/* Same as go_http_request, but with an explicit timeout instead of the
 * default 30s. Intended for best-effort/optional requests (e.g. xHome
 * discovery) that must never hold up an unrelated, time-sensitive flow. */
GoHttpResponse* go_http_request_with_timeout(const char* method, const char* url, const char* body,
                                             const char** headers, int header_count,
                                             long timeout_seconds);
int go_http_response_succeeded(const GoHttpResponse* response);
void go_http_response_destroy(GoHttpResponse* response);

#ifdef __cplusplus
}
#endif

#endif
