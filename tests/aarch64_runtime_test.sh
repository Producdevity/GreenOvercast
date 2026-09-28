#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
ZIG="$ROOT/.tools/zig-0.14.1/zig"
CHECK="$ROOT/tools/check-aarch64-runtime.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/greenovercast-atomics-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM
reject() {
  expected=$1
  shift
  if "$@" >"$TEST_ROOT/rejected.log" 2>&1; then
    echo "unexpected success: $*" >&2
    exit 1
  fi
  if ! grep -F "$expected" "$TEST_ROOT/rejected.log" >/dev/null; then
    cat "$TEST_ROOT/rejected.log" >&2
    echo "missing diagnostic: $expected" >&2
    exit 1
  fi
}
shared() {
  "$ZIG" build-lib -target "${3:-aarch64-linux-gnu.2.38}" -dynamic \
    -fno-compiler-rt -fallow-shlib-undefined "$1" -femit-bin="$2"
}
fixture="$TEST_ROOT/project"
mkdir -p "$fixture/tools" "$fixture/.tools/zig-0.14.1"
cp "$ROOT/tools/build-dependencies.sh" "$fixture/tools/"
ln -s "$ZIG" "$fixture/.tools/zig-0.14.1/zig"
sh "$fixture/tools/build-dependencies.sh" --toolchain-only
cat >"$TEST_ROOT/atomic.c" <<'C'
unsigned long long atomic_add(unsigned long long *value) {
    return __atomic_fetch_add(value, 1ULL, __ATOMIC_ACQ_REL);
}
C
"$ZIG" cc -target aarch64-linux-gnu.2.38 -mcpu=baseline \
  -O2 -fPIC -moutline-atomics -c "$TEST_ROOT/atomic.c" -o "$TEST_ROOT/outlined.o"
shared "$TEST_ROOT/outlined.o" "$TEST_ROOT/outlined.so"
reject '__aarch64_ldadd8_acq_rel' sh "$CHECK" "$TEST_ROOT/outlined.so"
echo 'PASS: outlined ARM64 C artifact rejected with the reported symbol'
for driver in cc c++; do
  language=c
  [ "$driver" != "c++" ] || language=c++
  "$fixture/.tools/cross/aarch64-linux-gnu/$driver" -O2 -fPIC \
    -moutline-atomics -x "$language" -c "$TEST_ROOT/atomic.c" -o "$TEST_ROOT/inline.o"
  shared "$TEST_ROOT/inline.o" "$TEST_ROOT/inline.so"
  sh "$CHECK" "$TEST_ROOT/inline.so"
  echo "PASS: $driver wrapper prevents caller flags from re-enabling outline atomics"
done
cat >"$TEST_ROOT/atomic.zig" <<'ZIG'
export fn atomic_add(value: *u64) u64 {
    return @atomicRmw(u64, value, .Add, 1, .acq_rel);
}
ZIG
for policy in +outline_atomics -outline_atomics; do
  "$ZIG" build-obj -target aarch64-linux-gnu.2.38 -mcpu="baseline$policy" \
    -O ReleaseSafe -fPIC "$TEST_ROOT/atomic.zig" -femit-bin="$TEST_ROOT/zig.o"
  shared "$TEST_ROOT/zig.o" "$TEST_ROOT/zig.so"
  case "$policy" in
    +*) reject '__aarch64_ldadd8_acq_rel' sh "$CHECK" "$TEST_ROOT/zig.so" ;;
    -*) sh "$CHECK" "$TEST_ROOT/zig.so" ;;
  esac
done
echo 'PASS: Zig target feature reproduces and removes the same ARM64 helper import'
cat >"$TEST_ROOT/defined.c" <<'C'
unsigned long long __aarch64_ldadd8_acq_rel(unsigned long long add, unsigned long long *value) {
    return __atomic_fetch_add(value, add, __ATOMIC_ACQ_REL);
}
C
"$fixture/.tools/cross/aarch64-linux-gnu/cc" -O2 -fPIC \
  -c "$TEST_ROOT/defined.c" -o "$TEST_ROOT/defined.o"
shared "$TEST_ROOT/defined.o" "$TEST_ROOT/defined.so"
sh "$CHECK" "$TEST_ROOT/defined.so"
echo 'PASS: a defined helper is not mistaken for an unresolved import'
reject '__aarch64_ldadd8_acq_rel' sh "$CHECK" "$TEST_ROOT/inline.so" "$TEST_ROOT/outlined.so"
reject 'not a linked executable' sh "$CHECK" "$TEST_ROOT/outlined.o"
"$ZIG" cc -target x86_64-linux-gnu.2.38 -O2 -fPIC \
  -c "$TEST_ROOT/atomic.c" -o "$TEST_ROOT/foreign.o"
shared "$TEST_ROOT/foreign.o" "$TEST_ROOT/foreign.so" x86_64-linux-gnu.2.38
reject 'not an AArch64 ELF' sh "$CHECK" "$TEST_ROOT/foreign.so"
reject 'usage:' sh "$CHECK"
reject 'missing.so' sh "$CHECK" "$TEST_ROOT/missing.so"
printf 'not an ELF\n' >"$TEST_ROOT/not-elf"
reject 'not-elf' sh "$CHECK" "$TEST_ROOT/not-elf"
if READELF=false sh "$CHECK" "$TEST_ROOT/inline.so" >/dev/null 2>&1; then
  echo 'reader failure was accepted' >&2
  exit 1
fi
echo 'PASS: sidecar imports, wrong architecture/type, invalid files and reader failures are rejected'
# Exercise the standalone package entry point, without invoking PortMaster.
cp "$ROOT/tools/package-portmaster.sh" "$CHECK" "$fixture/tools/"
mkdir -p "$fixture/zig-out/bin" "$fixture/zig-out/lib" "$fixture/zig-out/rockchip"
for path in bin/webrtc_stream lib/libgreenovercast-cedar.so \
  rockchip/libgreenovercast-mpp.so rockchip/librockchip_mpp.so.1 \
  rockchip/greenovercast-mpp-probe.aarch64 bin/libavcodec.so.63 \
  bin/libavutil.so.61 bin/libswscale.so.10; do
  cp "$TEST_ROOT/inline.so" "$fixture/zig-out/$path"
done
chmod +x "$fixture/zig-out/bin/webrtc_stream"
PORTMASTER_NEW= reject 'set PORTMASTER_NEW' sh "$fixture/tools/package-portmaster.sh"
cp "$TEST_ROOT/outlined.so" "$fixture/zig-out/bin/webrtc_stream"
PORTMASTER_NEW= reject '__aarch64_ldadd8_acq_rel' sh "$fixture/tools/package-portmaster.sh"
cp "$TEST_ROOT/inline.so" "$fixture/zig-out/bin/webrtc_stream"
cp "$TEST_ROOT/outlined.so" "$fixture/zig-out/bin/libavcodec.so.63"
PORTMASTER_NEW= reject '__aarch64_ldadd8_acq_rel' sh "$fixture/tools/package-portmaster.sh"
echo 'PASS: standalone packaging rejects both a broken executable and a broken bundled library'
