#include "webrtc_session.h"

#include <rtc/rtc.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../util/log.h"
#include "json_reader.h"
#include "json_writer.h"

#define AUDIO_PAYLOAD_TYPE 111

struct GoWebrtcSession {
    GoCloudSession* cloud;
    GoVideoPipeline* video;
    GoAudioPipeline* audio;
    GoControllerInput* controller;
    GoWebrtcWait wait;
    void* wait_context;
    int peer;
    int input_channel;
    int control_channel;
    int message_channel;
    int chat_channel;
    int video_track;
    int audio_track;
    unsigned int stream_width;
    unsigned int stream_height;
    char install_id[37];
    atomic_int connected;
    atomic_int gathering_complete;
    atomic_int handshake_complete;
    atomic_int peer_closed;
    atomic_int peer_failed;
    atomic_int shutting_down;
    atomic_int input_ready;
    atomic_int video_bitrate_requested;
};

static void generate_install_id(char* out) {
    FILE* urandom = fopen("/dev/urandom", "rb");
    if (urandom) {
        unsigned char bytes[16];
        if (fread(bytes, 1, sizeof(bytes), urandom) == sizeof(bytes)) {
            bytes[6] = (unsigned char)((bytes[6] & 0x0f) | 0x40);
            bytes[8] = (unsigned char)((bytes[8] & 0x3f) | 0x80);
            snprintf(out, 37,
                     "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-"
                     "%02x%02x%02x%02x%02x%02x",
                     bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                     bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14],
                     bytes[15]);
            fclose(urandom);
            return;
        }
        fclose(urandom);
    }
    snprintf(out, 37, "00000000-0000-4000-8000-000000000000");
}

static void on_description(int peer, const char* sdp, const char* type, void* context) {
    (void)peer;
    (void)type;
    (void)context;
    go_dbg("Local SDP ready (%zu bytes)\n", strlen(sdp));
}

static void on_gathering_state(int peer, rtcGatheringState state, void* context) {
    (void)peer;
    GoWebrtcSession* session = context;
    go_dbg("ICE gathering: %d\n", state);
    if (state == RTC_GATHERING_COMPLETE)
        atomic_store(&session->gathering_complete, 1);
}

static void on_connection_state(int peer, rtcState state, void* context) {
    (void)peer;
    GoWebrtcSession* session = context;
    go_dbg("WebRTC state: %d\n", state);
    if (state == RTC_CONNECTED) {
        atomic_store(&session->connected, 1);
        go_dbg("WebRTC connected\n");
    } else if (state == RTC_FAILED) {
        atomic_store(&session->connected, 0);
        atomic_store(&session->peer_failed, 1);
    } else if (state == RTC_CLOSED) {
        atomic_store(&session->connected, 0);
        if (!atomic_load(&session->shutting_down))
            atomic_store(&session->peer_closed, 1);
    }
}

static void on_data_channel(int peer, int channel, void* context) {
    (void)peer;
    (void)context;
    go_dbg("Data channel received: %d\n", channel);
}

static void on_input_message(int channel, const char* data, int size, void* context) {
    (void)channel;
    (void)context;
    int length = size < 0 ? -size : size;
    if (length < 10)
        return;
    const uint8_t* packet = (const uint8_t*)data;
    uint16_t report_type = (uint16_t)packet[0] | ((uint16_t)packet[1] << 8);
    if (report_type != 16) // server coordinate-space report (type 16)
        return;
    uint32_t height = (uint32_t)packet[2] | ((uint32_t)packet[3] << 8) |
                      ((uint32_t)packet[4] << 16) | ((uint32_t)packet[5] << 24);
    uint32_t width = (uint32_t)packet[6] | ((uint32_t)packet[7] << 8) |
                     ((uint32_t)packet[8] << 16) | ((uint32_t)packet[9] << 24);
    go_dbg("Server input coordinate space: %ux%u\n", width, height);
}

static void on_audio_message(int track, const char* data, int size, void* context) {
    (void)track;
    GoWebrtcSession* session = context;
    if (atomic_load(&session->shutting_down) || size <= 0)
        return;
    go_audio_pipeline_push_rtp(session->audio, (const uint8_t*)data, (size_t)size);
}

static void on_video_message(int track, const char* data, int size, void* context) {
    (void)track;
    GoWebrtcSession* session = context;
    if (atomic_load(&session->shutting_down) || size <= 0)
        return;
    go_video_pipeline_push_rtp(session->video, (const uint8_t*)data, (size_t)size);
}

static void send_input_metadata(GoWebrtcSession* session) {
    uint8_t packet[15];
    size_t length =
        go_controller_input_encode_metadata(session->controller, packet, sizeof(packet));
    if (length == 0)
        return;
    int result = rtcSendMessage(session->input_channel, (const char*)packet, (int)length);
    go_dbg("Sent input metadata: %d\n", result);
    if (result >= 0)
        atomic_store(&session->input_ready, 1);
}

static void send_startup_messages(GoWebrtcSession* session) {
    char install_message[256];
    char capabilities_message[768];
    char dimensions_message[768];
    snprintf(install_message, sizeof(install_message),
             "{\"type\":\"Message\",\"content\":\"{\\\"clientAppInstallId\\\":"
             "\\\"%s\\\"}\",\"id\":\"greenovercast-install\","
             "\"target\":\"/streaming/properties/clientappinstallidchanged\",\"cv\":\"\"}",
             session->install_id);
    snprintf(capabilities_message, sizeof(capabilities_message),
             "{\"type\":\"Message\",\"content\":\"{\\\"supportsCustomResolution\\\":true,"
             "\\\"supportsHevc\\\":false,\\\"supportsHdr\\\":false,\\\"supportsFps\\\":30,"
             "\\\"maxWidth\\\":%u,\\\"maxHeight\\\":%u,\\\"maxBitrateKbps\\\":2000,"
             "\\\"video\\\":{\\\"width\\\":%u,\\\"height\\\":%u,"
             "\\\"maxWidth\\\":%u,\\\"maxHeight\\\":%u,"
             "\\\"maxBitrateKbps\\\":2000}}\","
             "\"id\":\"greenovercast-capabilities\","
             "\"target\":\"/streaming/characteristics/clientdevicecapabilities\","
             "\"cv\":\"\"}",
             session->stream_width, session->stream_height, session->stream_width,
             session->stream_height, session->stream_width, session->stream_height);
    snprintf(dimensions_message, sizeof(dimensions_message),
             "{\"type\":\"Message\",\"content\":\"{\\\"horizontal\\\":%u,"
             "\\\"vertical\\\":%u,\\\"preferredWidth\\\":%u,"
             "\\\"preferredHeight\\\":%u,\\\"safeAreaLeft\\\":0,"
             "\\\"safeAreaTop\\\":0,\\\"safeAreaRight\\\":%u,"
             "\\\"safeAreaBottom\\\":%u,\\\"supportsCustomResolution\\\":true}\","
             "\"id\":\"greenovercast-dimensions\","
             "\"target\":\"/streaming/characteristics/dimensionschanged\",\"cv\":\"\"}",
             session->stream_width, session->stream_height, session->stream_width,
             session->stream_height, session->stream_width, session->stream_height);
    const char* messages[] = {
        "{\"type\":\"Message\",\"content\":\"{\\\"version\\\":[0,2,0],\\\"systemUis\\\":[]}\","
        "\"id\":\"greenovercast-ui\",\"target\":\"/streaming/systemUi/configuration\",\"cv\":\"\"}",
        install_message,
        "{\"type\":\"Message\",\"content\":\"{\\\"orientation\\\":0}\","
        "\"id\":\"greenovercast-orientation\","
        "\"target\":\"/streaming/characteristics/orientationchanged\",\"cv\":\"\"}",
        "{\"type\":\"Message\",\"content\":\"{\\\"touchInputEnabled\\\":false}\","
        "\"id\":\"greenovercast-touch\","
        "\"target\":\"/streaming/characteristics/touchinputenabledchanged\",\"cv\":\"\"}",
        capabilities_message,
        dimensions_message,
    };
    for (size_t i = 0; i < sizeof(messages) / sizeof(messages[0]); i++)
        rtcSendMessage(session->message_channel, messages[i], -1);
}

void go_webrtc_session_request_keyframe(GoWebrtcSession* session) {
    if (!session)
        return;
    int pli_result = -1;
    int control_result = -1;
    if (session->video_track > 0)
        pli_result = rtcRequestKeyframe(session->video_track);
    if (session->control_channel > 0) {
        const char* message = "{\"message\":\"videoKeyframeRequested\",\"ifrRequested\":true}";
        control_result = rtcSendMessage(session->control_channel, message, -1);
    }
    go_video_pipeline_note_keyframe_request(session->video);
    if (pli_result < 0 || control_result < 0) {
        fprintf(stderr, "Keyframe request failed (PLI=%d control=%d)\n", pli_result,
                control_result);
        fflush(stderr);
    }
}

static void on_channel_open(int channel, void* context) {
    GoWebrtcSession* session = context;
    go_dbg("Channel open: %d\n", channel);
    if (channel == session->message_channel) {
        const char* message = "{\"type\":\"Handshake\",\"version\":\"messageV1\","
                              "\"id\":\"greenovercast-handshake\",\"cv\":\"0\"}";
        int result = rtcSendMessage(channel, message, -1);
        go_dbg("rtcSendMessage(handshake) = %d\n", result);
    } else if (channel == session->input_channel) {
        send_input_metadata(session);
    }
}

static void on_message_channel(int channel, const char* data, int size, void* context) {
    (void)channel;
    GoWebrtcSession* session = context;
    int length = size < 0 ? -size : size;
    char message[4096];
    int copy_length = length < (int)sizeof(message) - 1 ? length : (int)sizeof(message) - 1;
    memcpy(message, data, (size_t)copy_length);
    message[copy_length] = 0;
    go_dbg("message channel << %s\n", message);
    if (!strstr(message, "HandshakeAck"))
        return;
    atomic_store(&session->handshake_complete, 1);
    rtcSendMessage(session->control_channel,
                   "{\"message\":\"authorizationRequest\","
                   "\"accessKey\":\"4BDB3609-C1F1-4195-9B37-FEFF45DA8B8E\"}",
                   -1);
    rtcSendMessage(session->control_channel,
                   "{\"message\":\"gamepadChanged\",\"gamepadIndex\":0,"
                   "\"wasAdded\":true}",
                   -1);
    send_startup_messages(session);
    go_webrtc_session_request_keyframe(session);
}

static void on_control_message(int channel, const char* data, int size, void* context) {
    (void)channel;
    (void)context;
    int length = size < 0 ? -size : size;
    go_dbg("control channel << %.*s\n", length > 200 ? 200 : length, data);
}

GoWebrtcSession* go_webrtc_session_create(GoCloudSession* cloud, GoVideoPipeline* video,
                                          GoAudioPipeline* audio, GoControllerInput* controller,
                                          GoWebrtcWait wait, void* wait_context,
                                          unsigned int stream_width, unsigned int stream_height) {
    if (!cloud || !video || !audio || !controller || !wait || stream_width < 640 ||
        stream_width > 1920 || stream_height < 360 || stream_height > 1080)
        return NULL;
    GoWebrtcSession* session = calloc(1, sizeof(*session));
    if (!session)
        return NULL;
    session->cloud = cloud;
    session->video = video;
    session->audio = audio;
    session->controller = controller;
    session->wait = wait;
    session->wait_context = wait_context;
    session->stream_width = stream_width;
    session->stream_height = stream_height;
    session->peer = -1;
    session->input_channel = -1;
    session->control_channel = -1;
    session->message_channel = -1;
    session->chat_channel = -1;
    session->video_track = -1;
    session->audio_track = -1;
    generate_install_id(session->install_id);
    return session;
}

static int configure_peer(GoWebrtcSession* session) {
    rtcConfiguration configuration;
    memset(&configuration, 0, sizeof(configuration));
    configuration.disableAutoNegotiation = true;
    session->peer = rtcCreatePeerConnection(&configuration);
    if (session->peer < 0) {
        fprintf(stderr, "rtcCreatePeerConnection failed: %d\n", session->peer);
        return -1;
    }
    rtcSetUserPointer(session->peer, session);
    rtcSetLocalDescriptionCallback(session->peer, on_description);
    rtcSetStateChangeCallback(session->peer, on_connection_state);
    rtcSetDataChannelCallback(session->peer, on_data_channel);
    rtcSetGatheringStateChangeCallback(session->peer, on_gathering_state);

    rtcTrackInit video_configuration;
    memset(&video_configuration, 0, sizeof(video_configuration));
    video_configuration.direction = RTC_DIRECTION_RECVONLY;
    video_configuration.codec = RTC_CODEC_H264;
    video_configuration.payloadType = GO_VIDEO_PAYLOAD_TYPE;
    video_configuration.mid = "video";
    session->video_track = rtcAddTrackEx(session->peer, &video_configuration);
    if (session->video_track < 0 || rtcChainRtcpReceivingSession(session->video_track) < 0) {
        fprintf(stderr, "Failed to configure the video receiver\n");
        return -1;
    }
    rtcSetUserPointer(session->video_track, session);
    rtcSetMessageCallback(session->video_track, on_video_message);
    go_dbg("Video track: %d\n", session->video_track);

    rtcTrackInit audio_configuration;
    memset(&audio_configuration, 0, sizeof(audio_configuration));
    audio_configuration.direction = RTC_DIRECTION_RECVONLY;
    audio_configuration.codec = RTC_CODEC_OPUS;
    audio_configuration.payloadType = AUDIO_PAYLOAD_TYPE;
    audio_configuration.mid = "audio";
    session->audio_track = rtcAddTrackEx(session->peer, &audio_configuration);
    if (session->audio_track < 0 || rtcChainRtcpReceivingSession(session->audio_track) < 0) {
        fprintf(stderr, "Failed to configure the audio receiver\n");
        return -1;
    }
    rtcSetUserPointer(session->audio_track, session);
    rtcSetMessageCallback(session->audio_track, on_audio_message);
    go_dbg("Audio track: %d\n", session->audio_track);

    rtcDataChannelInit channel_configuration;
    memset(&channel_configuration, 0, sizeof(channel_configuration));
    channel_configuration.reliability.unordered = false;
    channel_configuration.reliability.unreliable = false;
    channel_configuration.protocol = "chatV1";
    session->chat_channel = rtcCreateDataChannelEx(session->peer, "chat", &channel_configuration);
    channel_configuration.protocol = "controlV1";
    session->control_channel =
        rtcCreateDataChannelEx(session->peer, "control", &channel_configuration);
    channel_configuration.reliability.unordered = true;
    channel_configuration.reliability.unreliable = true;
    channel_configuration.reliability.maxRetransmits = 0;
    channel_configuration.protocol = "1.0";
    session->input_channel = rtcCreateDataChannelEx(session->peer, "input", &channel_configuration);
    channel_configuration.reliability.unordered = false;
    channel_configuration.reliability.unreliable = false;
    channel_configuration.protocol = "messageV1";
    session->message_channel =
        rtcCreateDataChannelEx(session->peer, "message", &channel_configuration);
    if (session->chat_channel < 0 || session->control_channel < 0 || session->input_channel < 0 ||
        session->message_channel < 0) {
        fprintf(stderr, "Failed to create Xbox data channels\n");
        return -1;
    }
    go_dbg("Channels: chat=%d input=%d control=%d message=%d\n", session->chat_channel,
           session->input_channel, session->control_channel, session->message_channel);

    int channels[] = {session->chat_channel, session->control_channel, session->input_channel,
                      session->message_channel};
    for (size_t i = 0; i < sizeof(channels) / sizeof(channels[0]); i++)
        rtcSetUserPointer(channels[i], session);
    rtcSetOpenCallback(session->message_channel, on_channel_open);
    rtcSetMessageCallback(session->message_channel, on_message_channel);
    rtcSetOpenCallback(session->control_channel, on_channel_open);
    rtcSetMessageCallback(session->control_channel, on_control_message);
    rtcSetOpenCallback(session->input_channel, on_channel_open);
    rtcSetMessageCallback(session->input_channel, on_input_message);
    return rtcSetLocalDescription(session->peer, "offer") < 0 ? -1 : 0;
}

static int build_compatible_offer(const char* full_sdp, char* clean_sdp, size_t capacity) {
    char ice_ufrag[256] = {0};
    char ice_password[256] = {0};
    char fingerprint[256] = {0};
    const char* ufrag = strstr(full_sdp, "ice-ufrag:");
    const char* password = strstr(full_sdp, "ice-pwd:");
    const char* sha256 = strstr(full_sdp, "fingerprint:sha-256 ");
    if (!ufrag || !password || !sha256 || sscanf(ufrag + 10, "%255s", ice_ufrag) != 1 ||
        sscanf(password + 8, "%255s", ice_password) != 1 ||
        sscanf(sha256 + 20, "%255s", fingerprint) != 1) {
        fprintf(stderr, "Local SDP is missing ICE credentials or its DTLS fingerprint\n");
        return -1;
    }
    int length = snprintf(clean_sdp, capacity,
                          "v=0\r\n"
                          "o=- 4611731400430051 2 IN IP4 127.0.0.1\r\n"
                          "s=-\r\nt=0 0\r\n"
                          "a=group:BUNDLE video audio 0\r\n"
                          "a=ice-ufrag:%s\r\n"
                          "a=ice-pwd:%s\r\n"
                          "a=fingerprint:sha-256 %s\r\n"
                          "a=setup:actpass\r\n"
                          "m=video 9 UDP/TLS/RTP/SAVPF 102\r\n"
                          "c=IN IP4 0.0.0.0\r\na=mid:video\r\na=recvonly\r\n"
                          "a=rtpmap:102 H264/90000\r\n"
                          "a=fmtp:102 level-asymmetry-allowed=0;packetization-mode=1;"
                          "profile-level-id=42e020;max-fs=3600;max-mbps=108000\r\n"
                          "a=rtcp-fb:102 goog-remb\r\na=rtcp-fb:102 ccm fir\r\n"
                          "a=rtcp-fb:102 nack\r\na=rtcp-fb:102 nack pli\r\na=rtcp-mux\r\n"
                          "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"
                          "c=IN IP4 0.0.0.0\r\na=mid:audio\r\na=recvonly\r\n"
                          "a=rtpmap:111 opus/48000/2\r\na=rtcp-mux\r\n"
                          "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n"
                          "c=IN IP4 0.0.0.0\r\na=mid:0\r\na=sctp-port:5000\r\n"
                          "a=max-message-size:262144\r\n",
                          ice_ufrag, ice_password, fingerprint);
    if (length < 0 || (size_t)length >= capacity)
        return -1;
    return 0;
}

static void report_remote_h264_format(const char* sdp) {
    static const char prefix[] = "a=fmtp:102 ";
    const char* line = strstr(sdp, prefix);
    if (!line) {
        go_dbg("Remote H.264 format parameters: absent\n");
        return;
    }
    const char* parameters = line + strlen(prefix);
    const char* end = strpbrk(parameters, "\r\n");
    const char* escaped_end = strstr(parameters, "\\r");
    if (!escaped_end)
        escaped_end = strstr(parameters, "\\n");
    if (escaped_end && (!end || escaped_end < end))
        end = escaped_end;
    size_t length = end ? (size_t)(end - parameters) : strlen(parameters);
    go_dbg("Remote H.264 format parameters: %.*s\n", (int)length, parameters);
}

static int exchange_sdp(GoWebrtcSession* session, const char* clean_sdp) {
    const char* base_url = go_cloud_session_base_url(session->cloud);
    const char* session_path = go_cloud_session_path(session->cloud);
    if (!base_url || !session_path)
        return -1;
    char url[512];
    char escaped_sdp[8192];
    char body[16384];
    int url_length = snprintf(url, sizeof(url), "%s/%s/sdp", base_url, session_path);
    int escaped_length =
        go_json_escape_string(clean_sdp, strlen(clean_sdp), escaped_sdp, sizeof(escaped_sdp));
    if (escaped_length < 0)
        return -1;
    int body_length = snprintf(body, sizeof(body),
                               "{\"messageType\":\"offer\",\"sdp\":\"%s\",\"requestId\":\"1\","
                               "\"configuration\":{"
                               "\"chat\":{\"minVersion\":1,\"maxVersion\":1},"
                               "\"control\":{\"minVersion\":1,\"maxVersion\":3},"
                               "\"input\":{\"minVersion\":1,\"maxVersion\":9},"
                               "\"message\":{\"minVersion\":1,\"maxVersion\":1}"
                               "}}",
                               escaped_sdp);
    if (url_length < 0 || url_length >= (int)sizeof(url) || body_length < 0 ||
        body_length >= (int)sizeof(body))
        return -1;
    const char* headers[] = {"Content-Type: application/json"};
    GoHttpResponse* response =
        go_cloud_session_request(session->cloud, "POST", url, body, headers, 1);
    if (!go_http_response_succeeded(response)) {
        go_http_response_destroy(response);
        return -1;
    }
    go_http_response_destroy(response);

    char* server_sdp = NULL;
    go_dbg("Polling for server answer...\n");
    for (int attempt = 0; attempt < 20; attempt++) {
        if (session->wait(session->wait_context, attempt == 0 ? 10000 : 5000) != 0)
            return -1;
        response = go_cloud_session_request(session->cloud, "GET", url, NULL, headers, 1);
        if (!go_http_response_succeeded(response)) {
            go_http_response_destroy(response);
            continue;
        }
        if (!response->data || response->len == 0) {
            go_http_response_destroy(response);
            continue;
        }
        if (strstr(response->data, "ConnectionExchangeFailed") &&
            !strstr(response->data, "Exclusive")) {
            fprintf(stderr, "  SDP exchange failed: %.200s\n", response->data);
            go_http_response_destroy(response);
            return -1;
        }
        server_sdp = json_string(response->data, "sdp");
        if (server_sdp) {
            go_dbg("Server SDP: %d chars\n", (int)strlen(server_sdp));
            go_http_response_destroy(response);
            break;
        }
        go_dbg("poll %d: no SDP in %zu bytes\n", attempt + 1, response->len);
        go_http_response_destroy(response);
    }
    if (!server_sdp) {
        fprintf(stderr, "SDP exchange timed out\n");
        return -1;
    }
    report_remote_h264_format(server_sdp);
    go_dbg("Setting remote description (%d bytes)...\n", (int)strlen(server_sdp));
    int result = rtcSetRemoteDescription(session->peer, server_sdp, "answer");
    free(server_sdp);
    go_dbg("SetRemoteDescription: %d\n", result);
    return result < 0 ? -1 : 0;
}

static int exchange_ice_candidates(GoWebrtcSession* session) {
    const char* base_url = go_cloud_session_base_url(session->cloud);
    const char* session_path = go_cloud_session_path(session->cloud);
    if (!base_url || !session_path)
        return -1;
    char url[512];
    int url_length = snprintf(url, sizeof(url), "%s/%s/ice", base_url, session_path);
    if (url_length < 0 || url_length >= (int)sizeof(url))
        return -1;
    const char* headers[] = {"Content-Type: application/json"};
    char local_description[16384];
    int description_length =
        rtcGetLocalDescription(session->peer, local_description, sizeof(local_description));
    int local_candidate_count = 0;
    if (description_length > 0) {
        char* line = local_description;
        while (line < local_description + description_length) {
            char* end = strchr(line, '\n');
            if (!end)
                break;
            *end = 0;
            if (strncmp(line, "a=candidate:", 12) == 0) {
                char candidate[2048];
                char body[4096];
                int candidate_length = snprintf(candidate, sizeof(candidate), "%s", line + 2);
                int body_length = snprintf(body, sizeof(body), "{\"candidate\":\"%s\"}", candidate);
                if (candidate_length >= 0 && candidate_length < (int)sizeof(candidate) &&
                    body_length >= 0 && body_length < (int)sizeof(body)) {
                    GoHttpResponse* response =
                        go_cloud_session_request(session->cloud, "POST", url, body, headers, 1);
                    int succeeded = go_http_response_succeeded(response);
                    go_http_response_destroy(response);
                    if (!succeeded)
                        return -1;
                    local_candidate_count++;
                }
            }
            *end = '\n';
            line = end + 1;
        }
    }
    go_dbg("Posted %d local ICE candidate(s)\n", local_candidate_count);
    if (session->wait(session->wait_context, 3000) != 0)
        return -1;

    GoHttpResponse* response =
        go_cloud_session_request(session->cloud, "GET", url, NULL, headers, 1);
    int remote_candidate_count = 0;
    if (go_http_response_succeeded(response) && response->data) {
        char* search = response->data;
        while (*search) {
            char* candidate_start = strstr(search, "a=candidate:");
            if (!candidate_start)
                break;
            candidate_start += 12;
            char* candidate_end = strchr(candidate_start, '\\');
            if (!candidate_end)
                candidate_end = strchr(candidate_start, '"');
            if (!candidate_end)
                break;
            int candidate_length = (int)(candidate_end - candidate_start);
            while (candidate_length > 0 && (candidate_start[candidate_length - 1] == ' ' ||
                                            candidate_start[candidate_length - 1] == '\n' ||
                                            candidate_start[candidate_length - 1] == '\r')) {
                candidate_length--;
            }
            char candidate[512];
            if (candidate_length > 0 && candidate_length < (int)sizeof(candidate) - 1) {
                int length = snprintf(candidate, sizeof(candidate), "candidate:%.*s",
                                      candidate_length, candidate_start);
                if (length > 0 && length < (int)sizeof(candidate) &&
                    rtcAddRemoteCandidate(session->peer, candidate, "0") >= 0) {
                    remote_candidate_count++;
                }
            }
            search = candidate_end + 1;
        }
    }
    go_http_response_destroy(response);
    go_dbg("Added %d remote ICE candidate(s); waiting 5s for ICE...\n", remote_candidate_count);
    return session->wait(session->wait_context, 5000) == 0 ? 0 : -1;
}

int go_webrtc_session_setup(GoWebrtcSession* session) {
    if (!session || session->peer >= 0)
        return -1;
    rtcInitLogger(go_debug_enabled() ? RTC_LOG_INFO : RTC_LOG_WARNING, NULL);
    if (configure_peer(session) < 0)
        return -1;
    go_dbg("Waiting for ICE gathering...\n");
    for (int i = 0; i < 120 && !atomic_load(&session->gathering_complete); i++) {
        if (session->wait(session->wait_context, 500) != 0)
            return -1;
    }

    char full_sdp[16384];
    int sdp_length = rtcGetLocalDescription(session->peer, full_sdp, sizeof(full_sdp));
    if (sdp_length <= 0) {
        fprintf(stderr, "Failed to get local description\n");
        return -1;
    }
    go_dbg("Full local SDP: %d bytes (gathering %s)\n", sdp_length,
           atomic_load(&session->gathering_complete) ? "complete" : "incomplete");
    char clean_sdp[4096];
    if (build_compatible_offer(full_sdp, clean_sdp, sizeof(clean_sdp)) < 0)
        return -1;
    go_dbg("Exchanging SDP (%d bytes)...\n", (int)strlen(clean_sdp));
    if (exchange_sdp(session, clean_sdp) < 0)
        return -1;
    return exchange_ice_candidates(session);
}

int go_webrtc_session_connected(const GoWebrtcSession* session) {
    return session ? atomic_load(&session->connected) : 0;
}

int go_webrtc_session_closed(const GoWebrtcSession* session) {
    return session ? atomic_load(&session->peer_closed) : 0;
}

int go_webrtc_session_failed(const GoWebrtcSession* session) {
    return session ? atomic_load(&session->peer_failed) : 1;
}

int go_webrtc_session_handshake_complete(const GoWebrtcSession* session) {
    return session ? atomic_load(&session->handshake_complete) : 0;
}

void go_webrtc_session_send_gamepad(GoWebrtcSession* session) {
    if (!session || session->input_channel < 0 || !atomic_load(&session->input_ready))
        return;
    uint8_t packet[38];
    size_t length = go_controller_input_encode(session->controller, packet, sizeof(packet));
    if (length > 0)
        rtcSendMessage(session->input_channel, (const char*)packet, (int)length);
}

void go_webrtc_session_request_video_bitrate(GoWebrtcSession* session,
                                             unsigned int bits_per_second) {
    if (!session || session->video_track <= 0 || !go_video_pipeline_has_media(session->video))
        return;
    int expected = 0;
    if (!atomic_compare_exchange_strong(&session->video_bitrate_requested, &expected, 1))
        return;
    int result = rtcRequestBitrate(session->video_track, bits_per_second);
    go_dbg("Requested video bitrate: %u kbps (result=%d)\n", bits_per_second / 1000, result);
}

void go_webrtc_session_destroy(GoWebrtcSession* session) {
    if (!session)
        return;
    atomic_store(&session->shutting_down, 1);
    if (session->peer >= 0) {
        rtcClosePeerConnection(session->peer);
        if (session->chat_channel >= 0)
            rtcDeleteDataChannel(session->chat_channel);
        if (session->control_channel >= 0)
            rtcDeleteDataChannel(session->control_channel);
        if (session->input_channel >= 0)
            rtcDeleteDataChannel(session->input_channel);
        if (session->message_channel >= 0)
            rtcDeleteDataChannel(session->message_channel);
        if (session->video_track >= 0)
            rtcDeleteTrack(session->video_track);
        if (session->audio_track >= 0)
            rtcDeleteTrack(session->audio_track);
        rtcDeletePeerConnection(session->peer);
        rtcCleanup();
    }
    free(session);
}
