#!/bin/sh
set -eu
umask 022

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT=${1:-$ROOT/zig-out/greenovercast.zip}
PORTMASTER_NEW=${PORTMASTER_NEW:-${2:-}}
SOURCE="$ROOT/packaging/portmaster/greenovercast"
BINARY="$ROOT/zig-out/bin/webrtc_stream"
CEDAR="$ROOT/zig-out/bin/libgreenovercast-cedar.so"
MPP_PLUGIN="$ROOT/zig-out/rockchip/libgreenovercast-mpp.so"
MPP_RUNTIME="$ROOT/zig-out/rockchip/librockchip_mpp.so.1"
MPP_PROBE="$ROOT/zig-out/rockchip/greenovercast-mpp-probe.aarch64"
AVCODEC="$ROOT/zig-out/bin/libavcodec.so.63"
AVUTIL="$ROOT/zig-out/bin/libavutil.so.61"
SWSCALE="$ROOT/zig-out/bin/libswscale.so.10"

case "$OUTPUT" in
/*) ;;
*) OUTPUT="$ROOT/$OUTPUT" ;;
esac

[ -x "$BINARY" ] || {
  echo "missing release binary: $BINARY" >&2
  exit 1
}
[ -f "$CEDAR" ] || {
  echo "missing Cedar library: $CEDAR" >&2
  exit 1
}
for mpp_file in "$MPP_PLUGIN" "$MPP_RUNTIME" "$MPP_PROBE"; do
  [ -f "$mpp_file" ] || {
    echo "missing Rockchip MPP file: $mpp_file" >&2
    exit 1
  }
done
for private_library in "$AVCODEC" "$AVUTIL" "$SWSCALE"; do
  [ -f "$private_library" ] || {
    echo "missing private library: $private_library" >&2
    exit 1
  }
done
[ -n "$PORTMASTER_NEW" ] || {
  echo "set PORTMASTER_NEW to a current PortMaster-New checkout" >&2
  exit 1
}
[ -f "$PORTMASTER_NEW/SOURCE_SETUP.txt" ] && [ -f "$PORTMASTER_NEW/tools/build_release.py" ] || {
  echo "invalid PortMaster-New checkout: $PORTMASTER_NEW" >&2
  exit 1
}

stage=$(mktemp -d "${TMPDIR:-/tmp}/greenovercast-port.XXXXXX")
cleanup() {
  rm -rf "$stage"
}
trap cleanup EXIT HUP INT TERM

checker="$stage/PortMaster-New"
port="$checker/ports/greenovercast"
mkdir -p "$checker/releases" "$checker/ports" "$(dirname -- "$OUTPUT")"
cp -R "$PORTMASTER_NEW/tools" "$checker/tools"
cp "$PORTMASTER_NEW/SOURCE_SETUP.txt" "$checker/SOURCE_SETUP.txt"
cp -R "$SOURCE" "$port"
cp "$BINARY" "$port/greenovercast/webrtc_stream.aarch64"
cp "$CEDAR" "$port/greenovercast/libgreenovercast-cedar.so"
mkdir -p "$port/greenovercast/rockchip"
cp "$MPP_PLUGIN" "$port/greenovercast/libgreenovercast-mpp.so"
cp "$MPP_RUNTIME" "$port/greenovercast/rockchip/librockchip_mpp.so.1"
cp "$MPP_PROBE" "$port/greenovercast/rockchip/greenovercast-mpp-probe.aarch64"
cp "$ROOT/vendor/mpp/LICENSES/Apache-2.0" \
  "$port/greenovercast/licenses/LICENSE.Rockchip-MPP-Apache-2.0.txt"
cp "$ROOT/vendor/mpp/LICENSES/MIT" \
  "$port/greenovercast/licenses/LICENSE.Rockchip-MPP-MIT.txt"
cp "$AVCODEC" "$port/greenovercast/libavcodec.so.63"
cp "$AVUTIL" "$port/greenovercast/libavutil.so.61"
cp "$SWSCALE" "$port/greenovercast/libswscale.so.10"
find "$port" -type f -exec chmod 644 {} +
: >"$checker/.github_check"

(
  cd "$checker"
  python3 tools/build_release.py --do-check
  python3 tools/build_gameinfo.py
  python3 tools/build_release.py --quick-build greenovercast
)

archive="$checker/releases/greenovercast.zip"
[ -f "$archive" ] || {
  echo "PortMaster did not produce greenovercast.zip" >&2
  exit 1
}

python3 - "$archive" <<'PY'
import hashlib
import sys
import zipfile

required = {
    "GreenOvercast.sh",
    "greenovercast/greenovercast.md",
    "greenovercast/gameinfo.xml",
    "greenovercast/port.json",
    "greenovercast/screenshot.png",
    "greenovercast/webrtc_stream.aarch64",
    "greenovercast/libgreenovercast-cedar.so",
    "greenovercast/libgreenovercast-mpp.so",
    "greenovercast/rockchip/librockchip_mpp.so.1",
    "greenovercast/rockchip/greenovercast-mpp-probe.aarch64",
    "greenovercast/rocknix/h700/cedrus-modules",
    "greenovercast/rocknix/h700/greenovercast_h700_overlay.ko",
    "greenovercast/rocknix/h700/sunxi-cedrus.ko",
    "greenovercast/ROCKNIX-H700-SOURCE.md",
    "greenovercast/licenses/LICENSE.Linux.txt",
    "greenovercast/licenses/LICENSE.libudev-zero.txt",
    "greenovercast/licenses/LICENSE.Rockchip-MPP-Apache-2.0.txt",
    "greenovercast/licenses/LICENSE.Rockchip-MPP-MIT.txt",
    "greenovercast/libavcodec.so.63",
    "greenovercast/libavutil.so.61",
    "greenovercast/libswscale.so.10",
}
expected_hashes = {
    "greenovercast/rocknix/h700/greenovercast_h700_overlay.ko":
        "dbad85de7238f163cf4985eb017f33866acd21e13015abe7636b2275f9e6b944",
    "greenovercast/rocknix/h700/sunxi-cedrus.ko":
        "ca1bb3534c16c4851cae1ba2ac84632f7e8ba85fa8f43fc253fe215f98d92c32",
}
with zipfile.ZipFile(sys.argv[1]) as archive:
    names = archive.namelist()
    missing = sorted(required.difference(names))
    bad_root = sorted(
        name for name in names if "/" not in name and name != "GreenOvercast.sh"
    )
    bad_hashes = sorted(
        name for name, expected in expected_hashes.items()
        if name in names and hashlib.sha256(archive.read(name)).hexdigest() != expected
    )
if missing or bad_root or bad_hashes:
    raise SystemExit(
        f"invalid PortMaster archive: missing={missing}, "
        f"bad_root={bad_root}, bad_hashes={bad_hashes}"
    )
PY

mv "$archive" "$OUTPUT"
printf 'packaged: %s\n' "$OUTPUT"
