#include "http_client.h"

#include <curl/curl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../util/log.h"

static size_t append_response(char* data, size_t size, size_t count, void* context) {
    GoHttpResponse* response = context;
    size_t length = size * count;
    char* next = realloc(response->data, response->len + length + 1);
    if (!next)
        return 0;
    response->data = next;
    memcpy(response->data + response->len, data, length);
    response->len += length;
    response->data[response->len] = 0;
    return length;
}

void go_http_response_destroy(GoHttpResponse* response) {
    if (!response)
        return;
    free(response->data);
    free(response);
}

int go_http_response_succeeded(const GoHttpResponse* response) {
    return response && response->status >= 200 && response->status < 300;
}

GoHttpResponse* go_http_request(const char* method, const char* url, const char* body,
                                const char** headers, int header_count) {
    if (!method || !url || header_count < 0 || (header_count > 0 && !headers))
        return NULL;

    CURL* request = curl_easy_init();
    if (!request)
        return NULL;
    GoHttpResponse* response = calloc(1, sizeof(*response));
    if (!response) {
        curl_easy_cleanup(request);
        return NULL;
    }

    struct curl_slist* request_headers = NULL;
    for (int index = 0; index < header_count; index++) {
        struct curl_slist* next = curl_slist_append(request_headers, headers[index]);
        if (!next) {
            curl_slist_free_all(request_headers);
            curl_easy_cleanup(request);
            go_http_response_destroy(response);
            return NULL;
        }
        request_headers = next;
    }

    curl_easy_setopt(request, CURLOPT_URL, url);
    if (strcmp(method, "POST") == 0) {
        curl_easy_setopt(request, CURLOPT_POST, 1L);
        curl_easy_setopt(request, CURLOPT_POSTFIELDS, body ? body : "");
    } else if (strcmp(method, "DELETE") == 0) {
        curl_easy_setopt(request, CURLOPT_CUSTOMREQUEST, "DELETE");
    } else if (strcmp(method, "GET") != 0) {
        curl_easy_setopt(request, CURLOPT_CUSTOMREQUEST, method);
    }
    if (request_headers)
        curl_easy_setopt(request, CURLOPT_HTTPHEADER, request_headers);
    curl_easy_setopt(request, CURLOPT_WRITEFUNCTION, append_response);
    curl_easy_setopt(request, CURLOPT_WRITEDATA, response);
    curl_easy_setopt(request, CURLOPT_TIMEOUT, 30L);

    CURLcode result = curl_easy_perform(request);
    curl_easy_getinfo(request, CURLINFO_RESPONSE_CODE, &response->status);
    if (result != CURLE_OK) {
        fprintf(stderr, "HTTP %s %s: %s\n", method, url, curl_easy_strerror(result));
        go_http_response_destroy(response);
        response = NULL;
    } else {
        go_dbg("HTTP %ld %s (%zu bytes)\n", response->status, url, response->len);
    }

    curl_slist_free_all(request_headers);
    curl_easy_cleanup(request);
    return response;
}
