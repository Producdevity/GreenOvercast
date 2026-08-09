#ifndef GREENOVERCAST_WEBRTC_SESSION_H
#define GREENOVERCAST_WEBRTC_SESSION_H

#include "audio_pipeline.h"
#include "cloud_session.h"
#include "controller.h"
#include "video_pipeline.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GoWebrtcSession GoWebrtcSession;
typedef int (*GoWebrtcWait)(void* context, unsigned int milliseconds);

GoWebrtcSession* go_webrtc_session_create(GoCloudSession* cloud, GoVideoPipeline* video,
                                          GoAudioPipeline* audio, GoControllerInput* controller,
                                          GoWebrtcWait wait, void* wait_context,
                                          unsigned int stream_width, unsigned int stream_height);
int go_webrtc_session_setup(GoWebrtcSession* session);
int go_webrtc_session_connected(const GoWebrtcSession* session);
int go_webrtc_session_closed(const GoWebrtcSession* session);
int go_webrtc_session_failed(const GoWebrtcSession* session);
int go_webrtc_session_handshake_complete(const GoWebrtcSession* session);
void go_webrtc_session_send_gamepad(GoWebrtcSession* session);
void go_webrtc_session_request_keyframe(GoWebrtcSession* session);
void go_webrtc_session_request_video_bitrate(GoWebrtcSession* session,
                                             unsigned int bits_per_second);
void go_webrtc_session_destroy(GoWebrtcSession* session);

#ifdef __cplusplus
}
#endif

#endif
