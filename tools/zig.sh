#!/bin/sh
# Invoke the pinned zig with host shims applied. Always use this wrapper for
# zig commands; on macOS the build runner links host libc and needs the
# .tools/bin/xcrun SDK shim.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
export PATH="$ROOT/.tools/bin:$PATH"
ZIG_GLOBAL_CACHE_DIR=${ZIG_GLOBAL_CACHE_DIR:-$ROOT/.tools/cache/zig}
export ZIG_GLOBAL_CACHE_DIR
exec "$ROOT/.tools/zig-0.14.1/zig" "$@"
