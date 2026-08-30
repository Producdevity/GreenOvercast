#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
KERNEL_TREE=${1:?usage: build-rocknix-h700-cedrus.sh kernel-tree [output-dir]}
OUTPUT_DIR=${2:-$ROOT/zig-out/rocknix-h700}
SOURCE_DIR="$ROOT/vendor/rocknix-h700-cedrus"
EXPECTED_CONFIG=ea1abaf7109d6132e0ecd3cee51d8e08cde5e2143813f017ed35399950482081
EXPECTED_SYMVERS=b95c5a532ae10737d39bac79823e1977db7ec603410b4ab2b77edabc8dd41674

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

for tool in dtc gcc make patch xxd; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "missing build tool: $tool" >&2
    exit 1
  }
done

[ "$(uname -m)" = "aarch64" ] || {
  echo "build the ROCKNIX module in an aarch64 environment" >&2
  exit 1
}
[ "$(gcc -dumpfullversion)" = "15.2.0" ] || {
  echo "ROCKNIX 20260801 modules require GCC 15.2.0" >&2
  exit 1
}
[ -f "$KERNEL_TREE/.config" ] && [ -f "$KERNEL_TREE/Module.symvers" ] || {
  echo "kernel tree is not prepared for external modules" >&2
  exit 1
}
[ "$(hash_file "$KERNEL_TREE/.config")" = "$EXPECTED_CONFIG" ] || {
  echo "kernel config does not match the tested ROCKNIX 20260801 build" >&2
  exit 1
}
[ "$(hash_file "$KERNEL_TREE/Module.symvers")" = "$EXPECTED_SYMVERS" ] || {
  echo "kernel symbols do not match the tested ROCKNIX 20260801 build" >&2
  exit 1
}

work=$(mktemp -d "${TMPDIR:-/tmp}/greenovercast-h700-cedrus.XXXXXX")
applied_patches=
cleanup() {
  for patch_file in $applied_patches; do
    patch -R -s -d "$KERNEL_TREE" -p1 <"$patch_file"
  done
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

apply_if_needed() {
  patch_file=$1
  if patch --batch --forward -s --dry-run -d "$KERNEL_TREE" -p1 <"$patch_file"; then
    patch --batch --forward -s -d "$KERNEL_TREE" -p1 <"$patch_file"
    applied_patches="$patch_file $applied_patches"
  elif ! patch --batch -R -s --dry-run -d "$KERNEL_TREE" -p1 <"$patch_file"; then
    echo "patch does not match the prepared kernel tree: $patch_file" >&2
    exit 1
  fi
}

apply_if_needed "$SOURCE_DIR/cedrus-h616-match.patch"
apply_if_needed "$SOURCE_DIR/cedrus-h616-sram.patch"

make -C "$KERNEL_TREE" ARCH=arm64 M=drivers/staging/media/sunxi/cedrus modules

overlay="$work/overlay"
mkdir -p "$overlay" "$OUTPUT_DIR"
cp "$SOURCE_DIR/greenovercast_h700_overlay.c" "$overlay/"
dtc -@ -I dts -O dtb \
  -o "$overlay/greenovercast_h700_ve.dtbo" \
  "$SOURCE_DIR/greenovercast_h700_ve.dts"
xxd -i -n greenovercast_h700_ve_dtbo \
  "$overlay/greenovercast_h700_ve.dtbo" >"$overlay/greenovercast_h700_ve_dtbo.h"
printf '%s\n' 'obj-m += greenovercast_h700_overlay.o' >"$overlay/Makefile"
make -C "$KERNEL_TREE" ARCH=arm64 M="$overlay" modules

cp "$KERNEL_TREE/drivers/staging/media/sunxi/cedrus/sunxi-cedrus.ko" \
  "$OUTPUT_DIR/sunxi-cedrus.ko"
cp "$overlay/greenovercast_h700_overlay.ko" \
  "$OUTPUT_DIR/greenovercast_h700_overlay.ko"

printf 'built: %s\n' "$OUTPUT_DIR"
