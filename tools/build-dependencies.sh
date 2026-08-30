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
LIBDATACHANNEL_SOURCE="$ROOT/vendor/libdatachannel"
LIBDATACHANNEL_BUILD="$TOOLS/build/libdatachannel-aarch64-release"
LIBDATACHANNEL_COMMIT=c6696d157b5612df2a741d9a03b192b47ab6cefb
LIBDATACHANNEL_PATCH="$ROOT/vendor/patches/libdatachannel-0.24.3-xbox-pli.patch"
MPP_SOURCE="$ROOT/vendor/mpp"
MPP_BUILD="$TOOLS/build/mpp-aarch64-release"
MPP_COMMIT=c08762ebfadeb4e986d2fed993bc7a54862d3ebe

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

[ -f "$LIBDATACHANNEL_SOURCE/CMakeLists.txt" ] || {
  echo "missing libdatachannel submodule; run tools/bootstrap.sh" >&2
  exit 1
}
[ -f "$MPP_SOURCE/CMakeLists.txt" ] || {
  echo "missing Rockchip MPP submodule; run tools/bootstrap.sh" >&2
  exit 1
}

actual_libdatachannel_commit=$(git -C "$LIBDATACHANNEL_SOURCE" rev-parse HEAD)
[ "$actual_libdatachannel_commit" = "$LIBDATACHANNEL_COMMIT" ] || {
  echo "libdatachannel must be at $LIBDATACHANNEL_COMMIT (found $actual_libdatachannel_commit)" >&2
  exit 1
}
actual_mpp_commit=$(git -C "$MPP_SOURCE" rev-parse HEAD)
[ "$actual_mpp_commit" = "$MPP_COMMIT" ] || {
  echo "Rockchip MPP must be at $MPP_COMMIT (found $actual_mpp_commit)" >&2
  exit 1
}

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

fetch_file() {
  file_name=$1
  file_url=$2
  expected_hash=$3
  destination="$DOWNLOADS/$file_name"

  if [ ! -f "$destination" ]; then
    echo "fetching $file_url"
    curl -fL --retry 3 "$file_url" -o "$destination"
  fi
  actual_hash=$(hash_file "$destination")
  [ "$actual_hash" = "$expected_hash" ] || {
    echo "sha256 mismatch for $file_name" >&2
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
fetch_source ffmpeg-9.0.tar.xz ffmpeg-9.0 \
  https://ffmpeg.org/releases/ffmpeg-9.0.tar.xz \
  7f607a00dd0d28a729d5a4811205812eef01cf6ef6155025febb6f36a9062d52
fetch_file ffmpeg-9.0-v4l2-request.patch \
  https://raw.githubusercontent.com/ROCKNIX/distribution/e9e6b8531df13bc9058ca1771dab5f0c4fd5e98e/packages/multimedia/ffmpeg/patches/v4l2-request/0001-v4l2-request.patch \
  afd04c202c27081c355d8d34b58a52c4141de26433007e27ed6e0d2093d10d3c
fetch_source libudev-zero-1.0.3.tar.gz libudev-zero-1.0.3 \
  https://github.com/illiliti/libudev-zero/archive/refs/tags/1.0.3.tar.gz \
  0bd89b657d62d019598e6c7ed726ff8fed80e8ba092a83b484d66afb80b77da5
fetch_source libdrm-2.4.128.tar.xz libdrm-2.4.128 \
  https://dri.freedesktop.org/libdrm/libdrm-2.4.128.tar.xz \
  3bb35db8700c2a0b569f2c6729a53f5495786856b310854c8de57782a22bddac
fetch_source SDL2-2.28.5.tar.gz SDL2-2.28.5 \
  https://github.com/libsdl-org/SDL/releases/download/release-2.28.5/SDL2-2.28.5.tar.gz \
  332cb37d0be20cb9541739c61f79bae5a477427d79ae85e352089afdaf6666e4

export ZIG_GLOBAL_CACHE_DIR="$TOOLS/cache/zig"
export SOURCE_DATE_EPOCH=0

if [ ! -f "$BUILDS/.openssl-3.5.7-static-reproducible" ]; then
  openssl_build="$BUILDS/openssl-3.5.7-static-reproducible"
  openssl_stage="$BUILDS/openssl-3.5.7-static-reproducible-stage"
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
  : >"$BUILDS/.openssl-3.5.7-static-reproducible"
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

if [ ! -f "$BUILDS/.libudev-zero-1.0.3-static" ]; then
  make -C "$SOURCES/libudev-zero-1.0.3" clean
  make -C "$SOURCES/libudev-zero-1.0.3" \
    CC="$CC_WRAPPER" AR="$AR_WRAPPER" CFLAGS="-O2" libudev.a
  make -C "$SOURCES/libudev-zero-1.0.3" \
    PREFIX="$PREFIX" LIBDIR="$PREFIX/lib" INCLUDEDIR="$PREFIX/include" \
    PKGCONFIGDIR="$PREFIX/lib/pkgconfig" install-static
  : >"$BUILDS/.libudev-zero-1.0.3-static"
fi

if [ ! -f "$BUILDS/.libdrm-2.4.128-v4l2-headers" ]; then
  mkdir -p "$PREFIX/include/libdrm"
  cp "$SOURCES/libdrm-2.4.128/include/drm/drm.h" \
    "$SOURCES/libdrm-2.4.128/include/drm/drm_fourcc.h" \
    "$SOURCES/libdrm-2.4.128/include/drm/drm_mode.h" \
    "$PREFIX/include/libdrm/"
  : >"$BUILDS/.libdrm-2.4.128-v4l2-headers"
fi

if [ ! -f "$BUILDS/.ffmpeg-9.0-h264-mjpeg-v4l2-request-shared" ]; then
  ffmpeg_build="$BUILDS/ffmpeg-9.0-h264-mjpeg-v4l2-request-shared"
  ffmpeg_source="$SOURCES/ffmpeg-9.0"
  ffmpeg_request_patch="$DOWNLOADS/ffmpeg-9.0-v4l2-request.patch"
  ffmpeg_portable_patch="$ROOT/vendor/patches/ffmpeg-9.0-v4l2-request-portable.patch"
  if [ ! -f "$ffmpeg_source/.greenovercast-v4l2-request-patched" ]; then
    patch -d "$ffmpeg_source" -p1 <"$ffmpeg_request_patch"
    patch -d "$ffmpeg_source" -p1 <"$ffmpeg_portable_patch"
    find "$ffmpeg_source" -name '*.orig' -delete
    : >"$ffmpeg_source/.greenovercast-v4l2-request-patched"
  fi
  mkdir -p "$ffmpeg_build"
  nm_tool=$(command -v llvm-nm || command -v nm)
  (
    cd "$ffmpeg_build"
    env -u CPPFLAGS -u CFLAGS -u CXXFLAGS -u LDFLAGS \
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" \
      "$ffmpeg_source/configure" \
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
      --enable-decoder=mjpeg \
      --enable-parser=h264 \
      --enable-v4l2-request \
      --enable-libudev \
      --disable-libdrm \
      --enable-hwaccel=h264_v4l2request \
      --enable-pthreads \
      --disable-network \
      --disable-iconv \
      --disable-programs \
      --disable-doc \
      --disable-debug \
      --disable-stripping \
      --extra-cflags="-O3 -I$PREFIX/include/libdrm -ffile-prefix-map=$ROOT=." \
      --extra-ldflags="-L$PREFIX/lib"
    make -j4
    make install-libs install-headers
  )
  : >"$BUILDS/.ffmpeg-9.0-h264-mjpeg-v4l2-request-shared"
fi

if [ ! -f "$LIBDATACHANNEL_BUILD/.greenovercast-$LIBDATACHANNEL_COMMIT" ]; then
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

  cmake_fresh=
  if [ -f "$LIBDATACHANNEL_BUILD/CMakeCache.txt" ]; then
    cached_source=$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "$LIBDATACHANNEL_BUILD/CMakeCache.txt")
    cached_build=$(sed -n 's/^CMAKE_CACHEFILE_DIR:INTERNAL=//p' "$LIBDATACHANNEL_BUILD/CMakeCache.txt")
    if [ "$cached_source" != "$LIBDATACHANNEL_SOURCE" ] || [ "$cached_build" != "$LIBDATACHANNEL_BUILD" ]; then
      cmake_fresh=--fresh
    fi
  fi
  cmake $cmake_fresh -S "$LIBDATACHANNEL_SOURCE" -B "$LIBDATACHANNEL_BUILD" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS_RELEASE="-O3 -DNDEBUG -ffile-prefix-map=$ROOT=." \
    -DCMAKE_CXX_FLAGS_RELEASE="-O3 -DNDEBUG -ffile-prefix-map=$ROOT=." \
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
    -DOPENSSL_INCLUDE_DIR="$PREFIX/include" \
    -DOPENSSL_SSL_LIBRARY="$PREFIX/lib/libssl.a" \
    -DOPENSSL_CRYPTO_LIBRARY="$PREFIX/lib/libcrypto.a"
  cmake --build "$LIBDATACHANNEL_BUILD" --parallel
  : >"$LIBDATACHANNEL_BUILD/.greenovercast-$LIBDATACHANNEL_COMMIT"
  restore_libdatachannel
  trap - EXIT HUP INT TERM
fi

if [ ! -f "$MPP_BUILD/.greenovercast-$MPP_COMMIT" ]; then
  cmake -S "$MPP_SOURCE" -B "$MPP_BUILD" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DCMAKE_LINKER="$CXX_WRAPPER" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_TEST=OFF \
    -DBUILD_SHARED_LIBS=ON
  cmake --build "$MPP_BUILD" --target rockchip_mpp --parallel
  : >"$MPP_BUILD/.greenovercast-$MPP_COMMIT"
fi

for required in \
  "$PREFIX/lib/libssl.a" \
  "$PREFIX/lib/libcrypto.a" \
  "$PREFIX/lib/libcurl.a" \
  "$PREFIX/lib/libopus.a" \
  "$PREFIX/lib/libSDL2.so" \
  "$PREFIX/lib/libavcodec.so.63" \
  "$PREFIX/lib/libavutil.so.61" \
  "$PREFIX/lib/libswscale.so.10" \
  "$LIBDATACHANNEL_BUILD/libdatachannel.a" \
  "$LIBDATACHANNEL_BUILD/deps/libjuice/libjuice.a" \
  "$LIBDATACHANNEL_BUILD/deps/usrsctp/usrsctplib/libusrsctp.a" \
  "$LIBDATACHANNEL_BUILD/deps/libsrtp/libsrtp2.a" \
  "$MPP_BUILD/mpp/librockchip_mpp.so" \
  "$MPP_BUILD/mpp/librockchip_mpp.so.0"; do
  [ -e "$required" ] || {
    echo "dependency build did not produce $required" >&2
    exit 1
  }
done

printf 'dependencies: %s\n' "$PREFIX"
