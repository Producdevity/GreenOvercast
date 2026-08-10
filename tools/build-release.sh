#!/bin/sh
# Build the Zig release orchestrator and its pinned native adapters.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
LIBDATACHANNEL_SOURCE=${1:?usage: build-release.sh <libdatachannel-source> <target-lib-dir> <openssl-include-dir> [output]}
TARGET_LIB_DIR=${2:?usage: build-release.sh <libdatachannel-source> <target-lib-dir> <openssl-include-dir> [output]}
OPENSSL_INCLUDE_DIR=${3:?usage: build-release.sh <libdatachannel-source> <target-lib-dir> <openssl-include-dir> [output]}
OUTPUT=${4:-$ROOT/zig-out/bin/webrtc_stream}
EXPECTED_COMMIT=c6696d157b5612df2a741d9a03b192b47ab6cefb
LIBDATACHANNEL_PATCH="$ROOT/vendor/patches/libdatachannel-0.24.3-xbox-pli.patch"
ZIG="$ROOT/.tools/zig-0.14.1/zig"
BUILD_DIR="$ROOT/.tools/build/libdatachannel-aarch64-release"
TOOLCHAIN="$BUILD_DIR/zig-aarch64-toolchain.cmake"
CC_WRAPPER="$BUILD_DIR/aarch64-cc"
CXX_WRAPPER="$BUILD_DIR/aarch64-c++"
AR_WRAPPER="$BUILD_DIR/aarch64-ar"
RANLIB_WRAPPER="$BUILD_DIR/aarch64-ranlib"
ZIG_CACHE_DIR="$ROOT/.tools/cache/zig"
OBJECT_DIR="$ROOT/.tools/build/release-aarch64"

[ -x "$ZIG" ] || {
  echo "missing Zig 0.14.1; run tools/bootstrap.sh" >&2
  exit 1
}
[ -f "$LIBDATACHANNEL_SOURCE/CMakeLists.txt" ] || {
  echo "invalid libdatachannel source directory" >&2
  exit 1
}
for library in libssl.so libcrypto.so libcurl.so libSDL2.so libopus.so \
  libavcodec.so libavutil.so libswscale.so; do
  [ -f "$TARGET_LIB_DIR/$library" ] || {
    echo "missing target library: $TARGET_LIB_DIR/$library" >&2
    exit 1
  }
done
[ -f "$OPENSSL_INCLUDE_DIR/openssl/ssl.h" ] || {
  echo "OpenSSL headers not found" >&2
  exit 1
}

actual_commit=$(git -C "$LIBDATACHANNEL_SOURCE" rev-parse HEAD)
[ "$actual_commit" = "$EXPECTED_COMMIT" ] || {
  echo "libdatachannel must be v0.24.3 at $EXPECTED_COMMIT (found $actual_commit)" >&2
  exit 1
}
[ -f "$LIBDATACHANNEL_PATCH" ] || {
  echo "missing libdatachannel Xbox PLI patch" >&2
  exit 1
}
git -C "$LIBDATACHANNEL_SOURCE" diff --quiet -- src/rtcpreceivingsession.cpp || {
  echo "libdatachannel rtcpreceivingsession.cpp has local changes" >&2
  exit 1
}
git -C "$LIBDATACHANNEL_SOURCE" apply --check "$LIBDATACHANNEL_PATCH"
git -C "$LIBDATACHANNEL_SOURCE" apply "$LIBDATACHANNEL_PATCH"
restore_libdatachannel() {
  git -C "$LIBDATACHANNEL_SOURCE" apply --reverse "$LIBDATACHANNEL_PATCH"
}
trap restore_libdatachannel EXIT HUP INT TERM

mkdir -p "$BUILD_DIR" "$OBJECT_DIR" "$ZIG_CACHE_DIR" "$(dirname -- "$OUTPUT")"
"$ROOT/tools/build-cedarx.sh" "$(dirname -- "$OUTPUT")/libgreenovercast-cedar.so"
for compiler in "$CC_WRAPPER" "$CXX_WRAPPER"; do
  driver=cc
  [ "$compiler" = "$CXX_WRAPPER" ] && driver=c++
  {
    printf '%s\n' '#!/bin/sh'
    printf 'exec "%s" %s -target aarch64-linux-gnu.2.38 "$@"\n' "$ZIG" "$driver"
  } >"$compiler"
done
{
  printf '%s\n' '#!/bin/sh'
  printf 'exec "%s" ar "$@"\n' "$ZIG"
} >"$AR_WRAPPER"
{
  printf '%s\n' '#!/bin/sh'
  printf 'exec "%s" ranlib "$@"\n' "$ZIG"
} >"$RANLIB_WRAPPER"
chmod +x "$CC_WRAPPER" "$CXX_WRAPPER" "$AR_WRAPPER" "$RANLIB_WRAPPER"

{
  printf '%s\n' 'set(CMAKE_SYSTEM_NAME Linux)'
  printf '%s\n' 'set(CMAKE_SYSTEM_PROCESSOR aarch64)'
  printf 'set(CMAKE_C_COMPILER "%s")\n' "$CC_WRAPPER"
  printf 'set(CMAKE_CXX_COMPILER "%s")\n' "$CXX_WRAPPER"
  printf 'set(CMAKE_AR "%s")\n' "$AR_WRAPPER"
  printf 'set(CMAKE_RANLIB "%s")\n' "$RANLIB_WRAPPER"
  printf '%s\n' 'set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)'
} >"$TOOLCHAIN"

export ZIG_GLOBAL_CACHE_DIR="$ZIG_CACHE_DIR"
cmake_fresh=
if [ -f "$BUILD_DIR/CMakeCache.txt" ]; then
  cached_source=$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "$BUILD_DIR/CMakeCache.txt")
  cached_build=$(sed -n 's/^CMAKE_CACHEFILE_DIR:INTERNAL=//p' "$BUILD_DIR/CMakeCache.txt")
  if [ "$cached_source" != "$LIBDATACHANNEL_SOURCE" ] || [ "$cached_build" != "$BUILD_DIR" ]; then
    cmake_fresh=--fresh
  fi
fi
cmake $cmake_fresh -S "$LIBDATACHANNEL_SOURCE" -B "$BUILD_DIR" \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS_RELEASE='-O3 -DNDEBUG' \
  -DCMAKE_CXX_FLAGS_RELEASE='-O3 -DNDEBUG' \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_SHARED_DEPS_LIBS=OFF \
  -DNO_TESTS=ON \
  -DNO_EXAMPLES=ON \
  -DNO_WEBSOCKET=ON \
  -DNO_MEDIA=OFF \
  -DUSE_GNUTLS=OFF \
  -DUSE_MBEDTLS=OFF \
  -DUSE_SYSTEM_JSON=OFF \
  -DUSE_SYSTEM_JUICE=OFF \
  -DUSE_SYSTEM_PLOG=OFF \
  -DUSE_SYSTEM_SRTP=OFF \
  -DUSE_SYSTEM_USRSCTP=OFF \
  -DOPENSSL_INCLUDE_DIR="$OPENSSL_INCLUDE_DIR" \
  -DOPENSSL_SSL_LIBRARY="$TARGET_LIB_DIR/libssl.so" \
  -DOPENSSL_CRYPTO_LIBRARY="$TARGET_LIB_DIR/libcrypto.so"
cmake --build "$BUILD_DIR" --parallel

compile_adapter() {
  source=$1
  object=$2
  "$ZIG" c++ -target aarch64-linux-gnu.2.38 -Werror -Wall -Wextra -O2 \
    -I"$ROOT/vendor/headers" -I"$ROOT/src/media/audio" \
    -I"$ROOT/src/media/video" -I"$ROOT/src/auth" -I"$ROOT/src/input" -I"$ROOT/src/ui" \
    -I"$ROOT/src/media/rtp" -I"$ROOT/src/catalog" -I"$ROOT/src/net" \
    -I"$ROOT/src/session" -I"$ROOT/src/platform" \
    -I"$OPENSSL_INCLUDE_DIR" \
    -c "$source" -o "$object"
}

compile_adapter "$ROOT/src/media/audio/opus_adapter.c" "$OBJECT_DIR/opus_adapter.o"
compile_adapter "$ROOT/src/media/audio/audio_pipeline.c" "$OBJECT_DIR/audio_pipeline.o"
compile_adapter "$ROOT/src/media/video/cedar_loader.c" "$OBJECT_DIR/cedar_loader.o"
compile_adapter "$ROOT/src/media/video/video_pipeline.c" "$OBJECT_DIR/video_pipeline.o"
compile_adapter "$ROOT/src/auth/token_store_adapter.c" "$OBJECT_DIR/token_store_adapter.o"
compile_adapter "$ROOT/src/session/webrtc_session.c" "$OBJECT_DIR/webrtc_session.o"
compile_adapter "$ROOT/src/net/http_client.c" "$OBJECT_DIR/http_client.o"
compile_adapter "$ROOT/src/ui/pixel_font.c" "$OBJECT_DIR/pixel_font.o"
compile_adapter "$ROOT/src/platform/sdl_platform.c" "$OBJECT_DIR/sdl_platform.o"
"$ZIG" build-obj "$ROOT/src/input/wire_encoder.zig" -target aarch64-linux-gnu.2.38 \
  -O ReleaseSafe -femit-bin="$OBJECT_DIR/wire_encoder.o"
"$ZIG" build-obj "$ROOT/src/input/controller.zig" \
  -target aarch64-linux-gnu.2.38 -O ReleaseSafe -lc \
  -I"$ROOT/vendor/headers" -I"$ROOT/src/input" \
  -femit-bin="$OBJECT_DIR/controller.o"
"$ZIG" build-obj "$ROOT/src/media/rtp/h264_depacketizer.zig" \
  -target aarch64-linux-gnu.2.38 -O ReleaseSafe \
  -femit-bin="$OBJECT_DIR/h264_depacketizer.o"
"$ZIG" build-obj "$ROOT/src/catalog/catalog_search.zig" \
  -target aarch64-linux-gnu.2.38 -O ReleaseSafe \
  -femit-bin="$OBJECT_DIR/catalog_search.o"
"$ZIG" build-obj "$ROOT/src/net/json_reader.zig" \
  -target aarch64-linux-gnu.2.38 -O ReleaseSafe \
  -femit-bin="$OBJECT_DIR/json_reader.o"
"$ZIG" build-obj "$ROOT/src/net/json_writer.zig" \
  -target aarch64-linux-gnu.2.38 -O ReleaseSafe \
  -femit-bin="$OBJECT_DIR/json_writer.o"
"$ZIG" build-obj "$ROOT/src/net/form_writer.zig" \
  -target aarch64-linux-gnu.2.38 -O ReleaseSafe \
  -femit-bin="$OBJECT_DIR/form_writer.o"
"$ZIG" build-obj "$ROOT/src/auth/xbox_auth.zig" \
  -target aarch64-linux-gnu.2.38 -O ReleaseSafe -lc \
  -I"$ROOT/vendor/headers" -I"$ROOT/src/auth" -I"$ROOT/src/catalog" \
  -I"$ROOT/src/input" -I"$ROOT/src/media/audio" -I"$ROOT/src/media/video" \
  -I"$ROOT/src/net" -I"$ROOT/src/session" -I"$ROOT/src/ui" \
  -femit-bin="$OBJECT_DIR/xbox_auth.o"
"$ZIG" build-obj "$ROOT/src/session/cloud_session.zig" \
  -target aarch64-linux-gnu.2.38 -O ReleaseSafe -lc \
  -I"$ROOT/vendor/headers" -I"$ROOT/src/auth" -I"$ROOT/src/catalog" \
  -I"$ROOT/src/input" -I"$ROOT/src/media/audio" -I"$ROOT/src/media/video" \
  -I"$ROOT/src/net" -I"$ROOT/src/session" -I"$ROOT/src/ui" \
  -femit-bin="$OBJECT_DIR/cloud_session.o"
"$ZIG" build-obj "$ROOT/src/ui/handheld_ui.zig" \
  -target aarch64-linux-gnu.2.38 -O ReleaseSafe -lc \
  -I"$ROOT/vendor/headers" -I"$ROOT/src/catalog" -I"$ROOT/src/input" \
  -I"$ROOT/src/ui" \
  -femit-bin="$OBJECT_DIR/handheld_ui.o"

"$ZIG" build-exe "$ROOT/src/main.zig" \
  "$OBJECT_DIR/opus_adapter.o" "$OBJECT_DIR/audio_pipeline.o" \
  "$OBJECT_DIR/cedar_loader.o" "$OBJECT_DIR/video_pipeline.o" \
  "$OBJECT_DIR/token_store_adapter.o" "$OBJECT_DIR/xbox_auth.o" \
  "$OBJECT_DIR/controller.o" \
  "$OBJECT_DIR/cloud_session.o" "$OBJECT_DIR/webrtc_session.o" \
  "$OBJECT_DIR/http_client.o" "$OBJECT_DIR/pixel_font.o" \
  "$OBJECT_DIR/handheld_ui.o" \
  "$OBJECT_DIR/sdl_platform.o" \
  "$OBJECT_DIR/wire_encoder.o" "$OBJECT_DIR/h264_depacketizer.o" \
  "$OBJECT_DIR/catalog_search.o" \
  "$OBJECT_DIR/json_reader.o" \
  "$OBJECT_DIR/json_writer.o" "$OBJECT_DIR/form_writer.o" \
  -target aarch64-linux-gnu.2.38 -O ReleaseSafe \
  -I"$ROOT/vendor/headers" -I"$ROOT/src/media/audio" \
  -I"$ROOT/src/media/video" -I"$ROOT/src/auth" -I"$ROOT/src/input" \
  -I"$ROOT/src/ui" -I"$ROOT/src/media/rtp" -I"$ROOT/src/catalog" \
  -I"$ROOT/src/net" -I"$ROOT/src/session" -I"$ROOT/src/platform" \
  -L"$TARGET_LIB_DIR" -rpath '$ORIGIN' -fstrip -femit-bin="$OUTPUT" -lc -lc++ \
  "$BUILD_DIR/libdatachannel.a" \
  "$BUILD_DIR/deps/libjuice/libjuice.a" \
  "$BUILD_DIR/deps/usrsctp/usrsctplib/libusrsctp.a" \
  "$BUILD_DIR/deps/libsrtp/libsrtp2.a" \
  -lcurl -lssl -lcrypto -lpthread -ldl -lSDL2 -lopus -lavcodec -lavutil -lswscale
rm -f "$OUTPUT.o"

printf 'built: %s\n' "$OUTPUT"
