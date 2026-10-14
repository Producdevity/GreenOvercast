#ifndef GREENOVERCAST_CONSOLES_H
#define GREENOVERCAST_CONSOLES_H

#include <stdbool.h>
#include <stddef.h>

#include "handheld_ui.h"
#include "xbox_auth.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Mirrors consoles_parser.zig's Console (checked at compile time in
 * consoles.zig). All strings are NUL-terminated. */
typedef struct {
    char device_name[128];
    char server_id[64];
    char power_state[32];
    char console_type[32];
    char play_path[192];
    bool out_of_home_warning;
    bool wireless_warning;
} GoConsole;

/* Fetches the account's consoles (GET /v6/servers/home, home token + host from
 * xbox_auth). Returns how many were written to `out` (0 when home streaming
 * is unavailable for this account, e.g. no linked console), or -1 on request
 * failure. Neither case is fatal: the cloud flow is unaffected. `ui` may be
 * NULL; it only sizes the X-MS-Device-Info header. */
int go_consoles_fetch(GoXboxAuth* auth, GoHandheldUi* ui, GoConsole* out, size_t capacity);

#ifdef __cplusplus
}
#endif

#endif
