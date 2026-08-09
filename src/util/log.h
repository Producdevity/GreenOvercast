#ifndef GREENOVERCAST_LOG_H
#define GREENOVERCAST_LOG_H

#include <stdio.h>
#include <stdlib.h>

// Debug output is off by default and gated on the GREENOVERCAST_DEBUG env var,
// checked once per translation unit. Keep error paths on stderr unconditionally.
static inline int go_debug_enabled(void) {
    static int cached = -1;
    if (cached == -1) {
        cached = getenv("GREENOVERCAST_DEBUG") != NULL;
    }
    return cached;
}

#define go_dbg(...) do { if (go_debug_enabled()) fprintf(stderr, __VA_ARGS__); } while (0)

#endif
