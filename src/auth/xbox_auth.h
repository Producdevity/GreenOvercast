#ifndef GREENOVERCAST_XBOX_AUTH_H
#define GREENOVERCAST_XBOX_AUTH_H

#include "handheld_ui.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GoXboxAuth GoXboxAuth;

typedef enum {
    GO_XBOX_AUTH_FAILED = -1,
    GO_XBOX_AUTH_OK = 0,
    GO_XBOX_AUTH_REAUTH_REQUIRED = 1,
} GoXboxAuthResult;

GoXboxAuth* go_xbox_auth_create(void);
int go_xbox_auth_load_credentials(GoXboxAuth* auth);
int go_xbox_auth_device_sign_in(GoXboxAuth* auth, GoHandheldUi* ui);
GoXboxAuthResult go_xbox_auth_refresh(GoXboxAuth* auth);
const char* go_xbox_auth_gssv_token(const GoXboxAuth* auth);
const char* go_xbox_auth_passport_token(const GoXboxAuth* auth);
void go_xbox_auth_destroy(GoXboxAuth* auth);

#ifdef __cplusplus
}
#endif

#endif
