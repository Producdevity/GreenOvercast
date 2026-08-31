#include "http_client.h"

#include <curl/curl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "../util/log.h"

#define DEFAULT_RESPONSE_LIMIT (16 * 1024 * 1024)

typedef struct {
    GoHttpResponse* response;
    size_t limit;
} ResponseWriter;

typedef struct {
    GoHttpCancelRequested requested;
    void* context;
} TransferCancel;

static const char* find_ca_bundle(void) {
    const char* environment_paths[] = {
        getenv("CURL_CA_BUNDLE"),
        getenv("SSL_CERT_FILE"),
    };
    size_t environment_count = sizeof(environment_paths) / sizeof(environment_paths[0]);
    for (size_t index = 0; index < environment_count; index++) {
        const char* path = environment_paths[index];
        if (path && path[0] != '\0' && access(path, R_OK) == 0)
            return path;
    }

    static const char* system_paths[] = {
        "/etc/ssl/certs/ca-certificates.crt",
        "/etc/ssl/cert.pem",
        "/etc/ssl/cacert.pem",
        "/etc/pki/tls/certs/ca-bundle.crt",
        "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
    };
    size_t system_count = sizeof(system_paths) / sizeof(system_paths[0]);
    for (size_t index = 0; index < system_count; index++) {
        if (access(system_paths[index], R_OK) == 0)
            return system_paths[index];
    }
    return NULL;
}

static size_t append_response(char* data, size_t size, size_t count, void* context) {
    ResponseWriter* writer = context;
    GoHttpResponse* response = writer->response;
    if (count != 0 && size > SIZE_MAX / count)
        return 0;
    size_t length = size * count;
    if (length > writer->limit || response->len > writer->limit - length)
        return 0;
    if (length == SIZE_MAX || response->len > SIZE_MAX - length - 1)
        return 0;
    char* next = realloc(response->data, response->len + length + 1);
    if (!next)
        return 0;
    response->data = next;
    memcpy(response->data + response->len, data, length);
    response->len += length;
    response->data[response->len] = 0;
    return length;
}

static int transfer_cancelled(void* context, curl_off_t download_total,
                              curl_off_t download_current, curl_off_t upload_total,
                              curl_off_t upload_current) {
    (void)download_total;
    (void)download_current;
    (void)upload_total;
    (void)upload_current;
    TransferCancel* cancel = context;
    return cancel->requested(cancel->context) != 0;
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

GoHttpResponse* go_http_request_bounded_cancelable(
    const char* method, const char* url, const char* body, const char** headers,
    int header_count, size_t response_limit, GoHttpCancelRequested cancel_requested,
    void* cancel_context) {
    if (!method || !url || response_limit == 0 || header_count < 0 ||
        (header_count > 0 && !headers))
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
    ResponseWriter writer = {.response = response, .limit = response_limit};
    curl_easy_setopt(request, CURLOPT_WRITEFUNCTION, append_response);
    curl_easy_setopt(request, CURLOPT_WRITEDATA, &writer);
    curl_easy_setopt(request, CURLOPT_TIMEOUT, 30L);
    curl_easy_setopt(request, CURLOPT_NOSIGNAL, 1L);
    const char* ca_bundle = find_ca_bundle();
    if (ca_bundle)
        curl_easy_setopt(request, CURLOPT_CAINFO, ca_bundle);
    TransferCancel cancel = {.requested = cancel_requested, .context = cancel_context};
    if (cancel_requested) {
        curl_easy_setopt(request, CURLOPT_NOPROGRESS, 0L);
        curl_easy_setopt(request, CURLOPT_XFERINFOFUNCTION, transfer_cancelled);
        curl_easy_setopt(request, CURLOPT_XFERINFODATA, &cancel);
    }

    CURLcode result = curl_easy_perform(request);
    curl_easy_getinfo(request, CURLINFO_RESPONSE_CODE, &response->status);
    if (result != CURLE_OK) {
        if (result != CURLE_ABORTED_BY_CALLBACK)
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

GoHttpResponse* go_http_request_bounded(const char* method, const char* url, const char* body,
                                        const char** headers, int header_count,
                                        size_t response_limit) {
    return go_http_request_bounded_cancelable(method, url, body, headers, header_count,
                                              response_limit, NULL, NULL);
}

GoHttpResponse* go_http_request(const char* method, const char* url, const char* body,
                                const char** headers, int header_count) {
    return go_http_request_bounded(method, url, body, headers, header_count,
                                   DEFAULT_RESPONSE_LIMIT);
}
