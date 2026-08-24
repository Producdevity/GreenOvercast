#!/bin/sh
set -eu

if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != "--toolchain-only" ]; }; then
  echo "usage: $0 [--toolchain-only]" >&2
  exit 1
fi

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TOOLS="$ROOT/.tools"
DOWNLOADS="$TOOLS/downloads"
SOURCES="$TOOLS/sources"
BUILDS="$TOOLS/build/dependencies-aarch64"
PREFIX="$TOOLS/deps/aarch64-linux-gnu"
ZIG="$TOOLS/zig-0.14.1/zig"
CROSS="$TOOLS/cross/aarch64-linux-gnu"
CC_WRAPPER="$CROSS/cc"
CXX_WRAPPER="$CROSS/c++"
AR_WRAPPER="$CROSS/ar"
RANLIB_WRAPPER="$CROSS/ranlib"
TOOLCHAIN="$CROSS/toolchain.cmake"

[ -x "$ZIG" ] || {
  echo "missing Zig 0.14.1; run tools/bootstrap.sh" >&2
  exit 1
}

for command_name in cmake curl make patch perl python3 tar; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "missing build tool: $command_name" >&2
    exit 1
  }
done

mkdir -p "$DOWNLOADS" "$SOURCES" "$BUILDS" "$PREFIX" "$CROSS" "$TOOLS/cache/zig"

write_wrapper() {
  wrapper=$1
  driver=$2
  {
    printf '%s\n' '#!/bin/sh'
    printf 'exec "%s" %s -target aarch64-linux-gnu.2.38 -ffile-prefix-map="%s"=. "$@"\n' \
      "$ZIG" "$driver" "$ROOT"
  } >"$wrapper"
  chmod +x "$wrapper"
}

write_wrapper "$CC_WRAPPER" cc
write_wrapper "$CXX_WRAPPER" c++
{
  printf '%s\n' '#!/bin/sh'
  printf 'exec "%s" ar "$@"\n' "$ZIG"
} >"$AR_WRAPPER"
{
  printf '%s\n' '#!/bin/sh'
  printf 'exec "%s" ranlib "$@"\n' "$ZIG"
} >"$RANLIB_WRAPPER"
chmod +x "$AR_WRAPPER" "$RANLIB_WRAPPER"

{
  printf '%s\n' 'set(CMAKE_SYSTEM_NAME Linux)'
  printf '%s\n' 'set(CMAKE_SYSTEM_PROCESSOR aarch64)'
  printf 'set(CMAKE_C_COMPILER "%s")\n' "$CC_WRAPPER"
  printf 'set(CMAKE_CXX_COMPILER "%s")\n' "$CXX_WRAPPER"
  printf 'set(CMAKE_AR "%s")\n' "$AR_WRAPPER"
  printf 'set(CMAKE_RANLIB "%s")\n' "$RANLIB_WRAPPER"
  printf 'set(CMAKE_FIND_ROOT_PATH "%s")\n' "$PREFIX"
  printf '%s\n' 'set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)'
  printf '%s\n' 'set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)'
  printf '%s\n' 'set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)'
  printf '%s\n' 'set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)'
  printf '%s\n' 'set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)'
} >"$TOOLCHAIN"

if [ "${1:-}" = "--toolchain-only" ]; then
  exit 0
fi

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

fetch_source() {
  archive_name=$1
  source_name=$2
  source_url=$3
  expected_hash=$4
  archive="$DOWNLOADS/$archive_name"
  source_dir="$SOURCES/$source_name"

  if [ ! -f "$archive" ]; then
    echo "fetching $source_url"
    curl -fL --retry 3 "$source_url" -o "$archive"
  fi
  actual_hash=$(hash_file "$archive")
  [ "$actual_hash" = "$expected_hash" ] || {
    echo "sha256 mismatch for $archive_name" >&2
    exit 1
  }
  if [ ! -d "$source_dir" ]; then
    tar -xf "$archive" -C "$SOURCES"
  fi
  [ -d "$source_dir" ] || {
    echo "archive did not contain $source_name" >&2
    exit 1
  }
}

fetch_source openssl-3.5.7.tar.gz openssl-3.5.7 \
  https://github.com/openssl/openssl/releases/download/openssl-3.5.7/openssl-3.5.7.tar.gz \
  a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8
fetch_source curl-8.20.0.tar.xz curl-8.20.0 \
  https://curl.se/download/curl-8.20.0.tar.xz \
  63fe2dc148ba0ceae89922ef838f7e5c946272c2e78b7c59fab4b79d3ce2b896
fetch_source opus-1.6.1.tar.gz opus-1.6.1 \
  https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz \
  6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
fetch_source ffmpeg-4.4.8.tar.xz ffmpeg-4.4.8 \
  https://ffmpeg.org/releases/ffmpeg-4.4.8.tar.xz \
  c73848c4ae283d9eaee7be3b276affbc3543380483555500d0dd2c9b7e1c39c3
fetch_source SDL2-2.28.5.tar.gz SDL2-2.28.5 \
  https://github.com/libsdl-org/SDL/releases/download/release-2.28.5/SDL2-2.28.5.tar.gz \
  332cb37d0be20cb9541739c61f79bae5a477427d79ae85e352089afdaf6666e4

export ZIG_GLOBAL_CACHE_DIR="$TOOLS/cache/zig"

if [ ! -f "$BUILDS/.openssl-3.5.7-static" ]; then
  openssl_build="$BUILDS/openssl-3.5.7-static"
  openssl_stage="$BUILDS/openssl-3.5.7-static-stage"
  mkdir -p "$openssl_build" "$openssl_stage"
  cp "$CC_WRAPPER" "$openssl_build/cc"
  cp "$AR_WRAPPER" "$openssl_build/ar"
  cp "$RANLIB_WRAPPER" "$openssl_build/ranlib"
  (
    cd "$openssl_build"
    env -u CPPFLAGS -u CFLAGS -u CXXFLAGS -u LDFLAGS \
      CC=./cc AR=./ar RANLIB=./ranlib \
      "$SOURCES/openssl-3.5.7/Configure" linux-aarch64 \
      --prefix=/usr --libdir=lib --openssldir=/etc/ssl \
      no-shared no-tests no-docs no-apps no-module -fPIC
    make -j4 build_libs
    make install_dev DESTDIR="$openssl_stage"
  )
  mkdir -p "$PREFIX/include" "$PREFIX/lib"
  cp -R "$openssl_stage/usr/include/openssl" "$PREFIX/include/"
  cp "$openssl_stage/usr/lib/libcrypto.a" "$openssl_stage/usr/lib/libssl.a" "$PREFIX/lib/"
  : >"$BUILDS/.openssl-3.5.7-static"
fi

if [ ! -f "$BUILDS/.opus-1.6.1-static" ]; then
  opus_build="$BUILDS/opus-1.6.1-static"
  cmake -S "$SOURCES/opus-1.6.1" -B "$opus_build" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DOPUS_BUILD_PROGRAMS=OFF \
    -DOPUS_BUILD_TESTING=OFF
  cmake --build "$opus_build" --parallel
  cmake --install "$opus_build"
  : >"$BUILDS/.opus-1.6.1-static"
fi

if [ ! -f "$BUILDS/.curl-8.20.0-static-http" ]; then
  curl_build="$BUILDS/curl-8.20.0-static-http"
  cmake -S "$SOURCES/curl-8.20.0" -B "$curl_build" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_CURL_EXE=OFF \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_STATIC_LIBS=ON \
    -DBUILD_TESTING=OFF \
    -DHTTP_ONLY=ON \
    -DCURL_USE_OPENSSL=ON \
    -DOPENSSL_ROOT_DIR="$PREFIX" \
    -DOPENSSL_USE_STATIC_LIBS=ON \
    -DCURL_USE_LIBPSL=OFF \
    -DCURL_USE_LIBSSH2=OFF \
    -DCURL_USE_LIBSSH=OFF \
    -DCURL_USE_GSASL=OFF \
    -DCURL_USE_GSSAPI=OFF \
    -DUSE_NGHTTP2=OFF \
    -DUSE_NGTCP2=OFF \
    -DUSE_QUICHE=OFF \
    -DCURL_ZLIB=OFF \
    -DCURL_BROTLI=OFF \
    -DCURL_ZSTD=OFF \
    -DUSE_LIBIDN2=OFF \
    -DCURL_DISABLE_LDAP=ON \
    -DCURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
  cmake --build "$curl_build" --parallel
  cmake --install "$curl_build"
  : >"$BUILDS/.curl-8.20.0-static-http"
fi

if [ ! -f "$BUILDS/.sdl2-2.28.5-link" ]; then
  sdl_build="$BUILDS/SDL2-2.28.5-link"
  cmake -S "$SOURCES/SDL2-2.28.5" -B "$sdl_build" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_BUILD_TYPE=Release \
    -DSDL_SHARED=ON \
    -DSDL_STATIC=OFF \
    -DSDL_TEST=OFF \
    -DSDL_TESTS=OFF \
    -DSDL_ALSA=OFF \
    -DSDL_JACK=OFF \
    -DSDL_PIPEWIRE=OFF \
    -DSDL_PULSEAUDIO=OFF \
    -DSDL_X11=OFF \
    -DSDL_WAYLAND=OFF \
    -DSDL_KMSDRM=OFF \
    -DSDL_OPENGL=OFF \
    -DSDL_OPENGLES=OFF \
    -DSDL_VULKAN=OFF \
    -DSDL_HIDAPI=OFF \
    -DSDL_LIBUDEV=OFF \
    -DSDL_SYSTEM_ICONV=OFF \
    -DSDL_IBUS=OFF \
    -DSDL_FCITX=OFF
  cmake --build "$sdl_build" --parallel
  cmake --install "$sdl_build"
  : >"$BUILDS/.sdl2-2.28.5-link"
fi

if [ ! -f "$BUILDS/.ffmpeg-4.4.8-h264-shared" ]; then
  ffmpeg_build="$BUILDS/ffmpeg-4.4.8-h264-shared"
  ffmpeg_patch="$ROOT/vendor/patches/ffmpeg-4.4.8-glibc-sysctl.patch"
  if grep -q '^check_func  sysctl$' "$SOURCES/ffmpeg-4.4.8/configure"; then
    patch -d "$SOURCES/ffmpeg-4.4.8" -p1 <"$ffmpeg_patch"
  elif ! grep -q '^check_func_headers sys/sysctl.h sysctl$' "$SOURCES/ffmpeg-4.4.8/configure"; then
    echo "FFmpeg source does not match the pinned patch" >&2
    exit 1
  fi
  mkdir -p "$ffmpeg_build"
  nm_tool=$(command -v llvm-nm || command -v nm)
  (
    cd "$ffmpeg_build"
    env -u CPPFLAGS -u CFLAGS -u CXXFLAGS -u LDFLAGS \
      "$SOURCES/ffmpeg-4.4.8/configure" \
      --prefix="$PREFIX" \
      --arch=aarch64 \
      --target-os=linux \
      --cc="$CC_WRAPPER" \
      --cxx="$CXX_WRAPPER" \
      --ar="$AR_WRAPPER" \
      --ranlib="$RANLIB_WRAPPER" \
      --nm="$nm_tool" \
      --enable-cross-compile \
      --enable-shared \
      --disable-static \
      --enable-pic \
      --disable-autodetect \
      --disable-all \
      --enable-avcodec \
      --enable-avutil \
      --enable-swscale \
      --enable-decoder=h264 \
      --enable-parser=h264 \
      --enable-pthreads \
      --disable-network \
      --disable-iconv \
      --disable-programs \
      --disable-doc \
      --disable-debug \
      --disable-stripping \
      --extra-cflags="-O3 -ffile-prefix-map=$ROOT=."
    make -j4
    make install-libs install-headers
  )
  : >"$BUILDS/.ffmpeg-4.4.8-h264-shared"
fi

for required in \
  "$PREFIX/lib/libssl.a" \
  "$PREFIX/lib/libcrypto.a" \
  "$PREFIX/lib/libcurl.a" \
  "$PREFIX/lib/libopus.a" \
  "$PREFIX/lib/libSDL2.so" \
  "$PREFIX/lib/libavcodec.so.58" \
  "$PREFIX/lib/libavutil.so.56" \
  "$PREFIX/lib/libswscale.so.5"; do
  [ -e "$required" ] || {
    echo "dependency build did not produce $required" >&2
    exit 1
  }
done

printf 'dependencies: %s\n' "$PREFIX"
