#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT=${1:-$ROOT/zig-out/bin/libgreenovercast-cedar.so}
OUTPUT_DIR=$(dirname -- "$OUTPUT")
TEST_OUTPUT="$OUTPUT_DIR/cedar_bridge_test"
ZIG="$ROOT/.tools/zig-0.14.1/zig"

[ -x "$ZIG" ] || {
  echo "missing Zig 0.14.1; run tools/bootstrap.sh" >&2
  exit 1
}

mkdir -p "$OUTPUT_DIR" "$ROOT/.tools/cache/zig" "$ROOT/.tools/cache/zig-local"
export ZIG_GLOBAL_CACHE_DIR="$ROOT/.tools/cache/zig"
export ZIG_LOCAL_CACHE_DIR="$ROOT/.tools/cache/zig-local"

"$ZIG" cc -target aarch64-linux-gnu.2.38 -O2 -fPIC -fvisibility=hidden -shared -s \
  -ffile-prefix-map="$ROOT"=. \
  -Wno-int-to-pointer-cast -Wno-pointer-to-int-cast -Wno-format \
  -Wno-unused-variable -Wno-unused-parameter \
  -I"$ROOT/vendor/cedarx/base/include" \
  -I"$ROOT/vendor/cedarx/common/include" \
  -I"$ROOT/vendor/cedarx/vdecoder/include" \
  -I"$ROOT/vendor/cedarx/plugin/vdecoder/h264" \
  -I"$ROOT/src/media/video" \
  "$ROOT/vendor/cedarx/base/AwPool.c" \
  "$ROOT/vendor/cedarx/base/CdxList.c" \
  "$ROOT/vendor/cedarx/base/CdxQueue.c" \
  "$ROOT/vendor/cedarx/base/CdxUtils.c" \
  "$ROOT/vendor/cedarx/vdecoder/adapter.c" \
  "$ROOT/vendor/cedarx/vdecoder/fbm.c" \
  "$ROOT/vendor/cedarx/vdecoder/sbm.c" \
  "$ROOT/vendor/cedarx/vdecoder/vdecoder.c" \
  "$ROOT/vendor/cedarx/vdecoder/videoengine.c" \
  "$ROOT/vendor/cedarx/plugin/vdecoder/h264/h264.c" \
  "$ROOT/vendor/cedarx/plugin/vdecoder/h264/h264_dec.c" \
  "$ROOT/vendor/cedarx/plugin/vdecoder/h264/h264_hal.c" \
  "$ROOT/vendor/cedarx/plugin/vdecoder/h264/h264_mmco.c" \
  "$ROOT/vendor/cedarx/plugin/vdecoder/h264/h264_nalu.c" \
  "$ROOT/src/media/video/cedar_h616_runtime.c" \
  "$ROOT/src/media/video/cedar_bridge.c" \
  -Wl,-soname,libgreenovercast-cedar.so -lpthread -ldl -o "$OUTPUT"

"$ZIG" cc -target aarch64-linux-gnu.2.38 -O2 -s -Werror -Wall -Wextra \
  -I"$ROOT/src/media/video" \
  "$ROOT/tests/device/cedar_bridge_test.c" \
  -L"$OUTPUT_DIR" -lgreenovercast-cedar -Wl,-rpath,'$ORIGIN' -o "$TEST_OUTPUT"

printf 'built: %s\n' "$OUTPUT"
printf 'built: %s\n' "$TEST_OUTPUT"
