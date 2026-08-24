#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_DIR=${1:-$ROOT/zig-out/rockchip}
MPP_SOURCE="$ROOT/vendor/mpp"
EXPECTED_COMMIT=c08762ebfadeb4e986d2fed993bc7a54862d3ebe
BUILD_DIR="$ROOT/.tools/build/mpp-aarch64-release"
TOOLCHAIN="$ROOT/.tools/cross/aarch64-linux-gnu/toolchain.cmake"
CROSS_CXX="$ROOT/.tools/cross/aarch64-linux-gnu/c++"
ZIG="$ROOT/.tools/zig-0.14.1/zig"
ZIG_RUN="$ROOT/tools/zig.sh"

[ -x "$ZIG" ] || {
  echo "missing Zig 0.14.1; run tools/bootstrap.sh" >&2
  exit 1
}
[ -f "$MPP_SOURCE/CMakeLists.txt" ] || {
  echo "missing Rockchip MPP submodule; run tools/bootstrap.sh" >&2
  exit 1
}

actual_commit=$(git -C "$MPP_SOURCE" rev-parse HEAD)
[ "$actual_commit" = "$EXPECTED_COMMIT" ] || {
  echo "Rockchip MPP must be at $EXPECTED_COMMIT (found $actual_commit)" >&2
  exit 1
}

mkdir -p "$OUTPUT_DIR" "$ROOT/.tools/cache/zig"
export ZIG_GLOBAL_CACHE_DIR="$ROOT/.tools/cache/zig"

if [ -n "${MPP_LINK_LIBRARY:-}" ]; then
  [ -f "$MPP_LINK_LIBRARY" ] || {
    echo "MPP_LINK_LIBRARY does not exist: $MPP_LINK_LIBRARY" >&2
    exit 1
  }
  mpp_headers=${MPP_INCLUDE_DIR:-$MPP_SOURCE/inc}
  [ -f "$mpp_headers/rk_mpi.h" ] || {
    echo "MPP headers not found in $mpp_headers" >&2
    exit 1
  }
  mpp_link=$MPP_LINK_LIBRARY
  bundled_mpp=0
else
  "$ROOT/tools/build-dependencies.sh" --toolchain-only
  # MPP invokes CMAKE_LINKER directly to merge target object files with `-r`.
  cmake -S "$MPP_SOURCE" -B "$BUILD_DIR" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DCMAKE_LINKER="$CROSS_CXX" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_TEST=OFF \
    -DBUILD_SHARED_LIBS=ON
  cmake --build "$BUILD_DIR" --target rockchip_mpp --parallel
  mpp_headers="$MPP_SOURCE/inc"
  mpp_link="$BUILD_DIR/mpp/librockchip_mpp.so"
  "$ZIG_RUN" objcopy --strip-all "$BUILD_DIR/mpp/librockchip_mpp.so.0" \
    "$OUTPUT_DIR/librockchip_mpp.so.1"
  bundled_mpp=1
fi

"$ZIG_RUN" cc -target aarch64-linux-gnu.2.38 -O2 -fPIC -fvisibility=hidden -shared -s \
  -ffile-prefix-map="$ROOT"=. -Werror -Wall -Wextra \
  -I"$ROOT/src/media/video" -I"$mpp_headers" \
  "$ROOT/src/media/video/mpp_bridge.c" "$mpp_link" \
  -Wl,-z,defs -Wl,-soname,libgreenovercast-mpp.so -Wl,-rpath,'$ORIGIN' \
  -o "$OUTPUT_DIR/libgreenovercast-mpp.so"

"$ZIG_RUN" cc -target aarch64-linux-gnu.2.38 -O2 -s -Werror -Wall -Wextra \
  -I"$ROOT/src/media/video" \
  "$ROOT/src/media/video/mpp_loader.c" "$ROOT/tests/device/mpp_probe.c" \
  -ldl -Wl,-rpath,'$ORIGIN' -o "$OUTPUT_DIR/greenovercast-mpp-probe.aarch64"

"$ZIG_RUN" cc -target aarch64-linux-gnu.2.38 -O2 -s -Werror -Wall -Wextra \
  -I"$ROOT/src/media/video" \
  "$ROOT/src/media/video/mpp_loader.c" "$ROOT/tests/device/mpp_bridge_test.c" \
  -ldl -Wl,-rpath,'$ORIGIN' -o "$OUTPUT_DIR/greenovercast-mpp-bridge-test.aarch64"

file "$OUTPUT_DIR/libgreenovercast-mpp.so"
if [ "$bundled_mpp" -eq 1 ]; then
  file "$OUTPUT_DIR/librockchip_mpp.so.1"
fi
printf 'built: %s\n' "$OUTPUT_DIR/libgreenovercast-mpp.so"
printf 'built: %s\n' "$OUTPUT_DIR/greenovercast-mpp-probe.aarch64"
printf 'built: %s\n' "$OUTPUT_DIR/greenovercast-mpp-bridge-test.aarch64"
