#ifndef GREENOVERCAST_CLOUD_SESSION_H
#define GREENOVERCAST_CLOUD_SESSION_H

#include "handheld_ui.h"
#include "http_client.h"
#include "xbox_auth.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GoCloudSession GoCloudSession;

typedef struct {
    int keepalive_successes;
    int keepalive_failures;
} GoCloudSessionStats;

GoCloudSession* go_cloud_session_create(GoXboxAuth* auth, GoHandheldUi* ui);
const char* go_cloud_session_base_url(const GoCloudSession* session);
const char* go_cloud_session_path(const GoCloudSession* session);
GoHttpResponse* go_cloud_session_request(GoCloudSession* session, const char* method,
                                         const char* url, const char* body,
                                         const char** extra_headers, int extra_header_count);
int go_cloud_session_start_game(GoCloudSession* session, const char* title_id);
int go_cloud_session_wait_for_state(GoCloudSession* session, const char* target, int max_polls);
int go_cloud_session_connect(GoCloudSession* session);
int go_cloud_session_start_keepalive(GoCloudSession* session);
void go_cloud_session_stop_keepalive(GoCloudSession* session);
void go_cloud_session_end(GoCloudSession* session);
GoCloudSessionStats go_cloud_session_stats(const GoCloudSession* session);
void go_cloud_session_destroy(GoCloudSession* session);

#ifdef __cplusplus
}
#endif

#endif
