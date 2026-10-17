#include "websocket_client.h"

#include <curl/curl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "http_client.h"

struct GoWebSocket {
    CURL* handle;
    struct curl_slist* headers;
    char error[CURL_ERROR_SIZE];
};

static unsigned int from_curl_flags(int flags) {
    unsigned int result = 0;
    if (flags & CURLWS_TEXT)
        result |= GO_WEBSOCKET_TEXT;
    if (flags & CURLWS_BINARY)
        result |= GO_WEBSOCKET_BINARY;
    if (flags & CURLWS_CONT)
        result |= GO_WEBSOCKET_CONTINUATION;
    if (flags & CURLWS_CLOSE)
        result |= GO_WEBSOCKET_CLOSE;
    return result;
}

static int to_curl_flags(unsigned int flags, unsigned int* result) {
    const unsigned int supported =
        GO_WEBSOCKET_TEXT | GO_WEBSOCKET_BINARY | GO_WEBSOCKET_CONTINUATION | GO_WEBSOCKET_CLOSE;
    if (!result || (flags & ~supported) != 0)
        return -1;
    *result = 0;
    if (flags & GO_WEBSOCKET_TEXT)
        *result |= CURLWS_TEXT;
    if (flags & GO_WEBSOCKET_BINARY)
        *result |= CURLWS_BINARY;
    if (flags & GO_WEBSOCKET_CONTINUATION)
        *result |= CURLWS_CONT;
    if (flags & GO_WEBSOCKET_CLOSE)
        *result |= CURLWS_CLOSE;
    return 0;
}

static int valid_header_value(const char* value) {
    return value && value[0] != '\0' && !strchr(value, '\r') && !strchr(value, '\n');
}

static int append_header(GoWebSocket* socket, const char* name, const char* value) {
    char header[1024];
    int length = snprintf(header, sizeof(header), "%s: %s", name, value);
    if (length <= 0 || length >= (int)sizeof(header))
        return -1;
    struct curl_slist* next = curl_slist_append(socket->headers, header);
    if (!next)
        return -1;
    socket->headers = next;
    return 0;
}

static void copy_error(char* output, size_t capacity, const char* message) {
    if (!output || capacity == 0)
        return;
    snprintf(output, capacity, "%s", message && message[0] ? message : "WebSocket request failed");
}

GoWebSocket* go_websocket_open(const char* url, const char* origin, const char* subprotocol,
                               const char* user_agent, char* error, size_t error_capacity) {
    if (!valid_header_value(url) || !valid_header_value(origin) ||
        !valid_header_value(subprotocol) || !valid_header_value(user_agent)) {
        copy_error(error, error_capacity, "Invalid WebSocket connection parameters");
        return NULL;
    }

    GoWebSocket* socket = calloc(1, sizeof(*socket));
    if (!socket) {
        copy_error(error, error_capacity, "WebSocket allocation failed");
        return NULL;
    }
    socket->handle = curl_easy_init();
    if (!socket->handle)
        goto fail;
    if (append_header(socket, "Origin", origin) != 0 ||
        append_header(socket, "Sec-WebSocket-Protocol", subprotocol) != 0)
        goto fail;

    curl_easy_setopt(socket->handle, CURLOPT_URL, url);
    curl_easy_setopt(socket->handle, CURLOPT_CONNECT_ONLY, 2L);
    curl_easy_setopt(socket->handle, CURLOPT_HTTPHEADER, socket->headers);
    curl_easy_setopt(socket->handle, CURLOPT_USERAGENT, user_agent);
    curl_easy_setopt(socket->handle, CURLOPT_CONNECTTIMEOUT, 15L);
    curl_easy_setopt(socket->handle, CURLOPT_TIMEOUT, 30L);
    curl_easy_setopt(socket->handle, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(socket->handle, CURLOPT_TCP_NODELAY, 1L);
    curl_easy_setopt(socket->handle, CURLOPT_ERRORBUFFER, socket->error);
    const char* ca_bundle = go_http_ca_bundle();
    if (ca_bundle)
        curl_easy_setopt(socket->handle, CURLOPT_CAINFO, ca_bundle);

    CURLcode result = curl_easy_perform(socket->handle);
    if (result != CURLE_OK) {
        if (socket->error[0] == '\0')
            snprintf(socket->error, sizeof(socket->error), "%s", curl_easy_strerror(result));
        goto fail;
    }
    return socket;

fail:
    copy_error(error, error_capacity, socket->error);
    if (socket->handle)
        curl_easy_cleanup(socket->handle);
    curl_slist_free_all(socket->headers);
    free(socket);
    return NULL;
}

int go_websocket_send(GoWebSocket* socket, const void* data, size_t length, unsigned int flags,
                      size_t* sent) {
    if (!socket || !socket->handle || !sent || (length > 0 && !data))
        return -1;
    unsigned int curl_flags = 0;
    if (to_curl_flags(flags, &curl_flags) != 0)
        return -1;
    *sent = 0;
    CURLcode result = curl_ws_send(socket->handle, data, length, sent, 0, curl_flags);
    if (result == CURLE_AGAIN)
        return 0;
    if (result != CURLE_OK) {
        snprintf(socket->error, sizeof(socket->error), "%s", curl_easy_strerror(result));
        return -1;
    }
    return 1;
}

int go_websocket_receive(GoWebSocket* socket, void* output, size_t capacity,
                         GoWebSocketFrame* frame) {
    if (!socket || !socket->handle || !output || capacity == 0 || !frame)
        return -1;
    memset(frame, 0, sizeof(*frame));
    size_t received = 0;
    const struct curl_ws_frame* metadata = NULL;
    CURLcode result = curl_ws_recv(socket->handle, output, capacity, &received, &metadata);
    if (result == CURLE_AGAIN)
        return 0;
    if (result == CURLE_GOT_NOTHING)
        return -2;
    if (result != CURLE_OK || !metadata) {
        snprintf(socket->error, sizeof(socket->error), "%s", curl_easy_strerror(result));
        return -1;
    }
    frame->length = received;
    frame->offset = metadata->offset;
    frame->bytes_left = metadata->bytesleft;
    frame->flags = from_curl_flags(metadata->flags);
    return (metadata->flags & CURLWS_CLOSE) ? -2 : 1;
}

const char* go_websocket_last_error(const GoWebSocket* socket) {
    if (!socket || socket->error[0] == '\0')
        return "WebSocket request failed";
    return socket->error;
}

void go_websocket_close(GoWebSocket* socket) {
    if (!socket)
        return;
    if (socket->handle) {
        size_t sent = 0;
        (void)curl_ws_send(socket->handle, "", 0, &sent, 0, CURLWS_CLOSE);
        curl_easy_cleanup(socket->handle);
    }
    curl_slist_free_all(socket->headers);
    free(socket);
}
