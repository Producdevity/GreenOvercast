#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/greenovercast-toolchain-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

fixture="$TEST_ROOT/project"
prefix="$fixture/.tools/deps/aarch64-linux-gnu"
host_prefix="$TEST_ROOT/host"
mkdir -p "$fixture/tools" "$fixture/.tools/zig-0.14.1" \
  "$prefix/lib/pkgconfig" "$host_prefix/lib/pkgconfig"
cp "$ROOT/tools/build-dependencies.sh" "$fixture/tools/"
printf '#!/bin/sh\nexit 1\n' >"$fixture/.tools/zig-0.14.1/zig"
chmod +x "$fixture/.tools/zig-0.14.1/zig"

cat >"$prefix/lib/pkgconfig/target-only.pc" <<EOF
prefix=$prefix
Name: target-only
Description: Target fixture
Version: 1.0
Libs: -L\${prefix}/lib -ltarget-only
Cflags: -I\${prefix}/include
EOF
cat >"$host_prefix/lib/pkgconfig/host-only.pc" <<EOF
prefix=$host_prefix
Name: host-only
Description: Host fixture
Version: 1.0
Libs: -L\${prefix}/lib -lhost-only
EOF

export PKG_CONFIG_PATH="$prefix/lib/pkgconfig:$host_prefix/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$host_prefix/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$TEST_ROOT/host-sysroot"
export CMAKE_PREFIX_PATH="$host_prefix"
pkg-config --exists host-only
sh "$fixture/tools/build-dependencies.sh" --toolchain-only

cat >"$fixture/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.24)
project(TargetPkgConfig NONE)
find_package(PkgConfig REQUIRED)
pkg_check_modules(TARGET_ONLY REQUIRED target-only)
pkg_check_modules(HOST_ONLY QUIET host-only)
if(HOST_ONLY_FOUND)
  message(FATAL_ERROR "Cross toolchain accepted a host pkg-config package")
endif()
if(NOT TARGET_ONLY_LIBRARY_DIRS STREQUAL "${TARGET_PREFIX}/lib")
  message(FATAL_ERROR "Cross toolchain changed the target library prefix")
endif()
if(NOT TARGET_ONLY_INCLUDE_DIRS STREQUAL "${TARGET_PREFIX}/include")
  message(FATAL_ERROR "Cross toolchain changed the target include prefix")
endif()
EOF

if ! cmake -S "$fixture" -B "$fixture/build" \
  -DCMAKE_TOOLCHAIN_FILE="$fixture/.tools/cross/aarch64-linux-gnu/toolchain.cmake" \
  -DCMAKE_PREFIX_PATH="$host_prefix" -DTARGET_PREFIX="$prefix" \
  >"$TEST_ROOT/configure.log" 2>&1; then
  cat "$TEST_ROOT/configure.log" >&2
  exit 1
fi
echo "Dependency toolchain isolation passed"
