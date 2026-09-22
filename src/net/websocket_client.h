#ifndef GREENOVERCAST_WEBSOCKET_CLIENT_H
#define GREENOVERCAST_WEBSOCKET_CLIENT_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GoWebSocket GoWebSocket;

typedef struct {
    size_t length;
    long long offset;
    long long bytes_left;
    unsigned int flags;
} GoWebSocketFrame;

enum {
    GO_WEBSOCKET_TEXT = 1 << 0,
    GO_WEBSOCKET_BINARY = 1 << 1,
    GO_WEBSOCKET_CONTINUATION = 1 << 2,
    GO_WEBSOCKET_CLOSE = 1 << 3,
};

GoWebSocket* go_websocket_open(const char* url, const char* origin, const char* subprotocol,
                               const char* user_agent, char* error, size_t error_capacity);
int go_websocket_send(GoWebSocket* socket, const void* data, size_t length, unsigned int flags,
                      size_t* sent);
int go_websocket_receive(GoWebSocket* socket, void* output, size_t capacity,
                         GoWebSocketFrame* frame);
const char* go_websocket_last_error(const GoWebSocket* socket);
void go_websocket_close(GoWebSocket* socket);

#ifdef __cplusplus
}
#endif

#endif
