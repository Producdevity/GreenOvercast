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
AVCODEC="$ROOT/zig-out/bin/libavcodec.so.58"
AVUTIL="$ROOT/zig-out/bin/libavutil.so.56"
SWSCALE="$ROOT/zig-out/bin/libswscale.so.5"

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
cp "$AVCODEC" "$port/greenovercast/libavcodec.so.58"
cp "$AVUTIL" "$port/greenovercast/libavutil.so.56"
cp "$SWSCALE" "$port/greenovercast/libswscale.so.5"
chmod 644 "$port/GreenOvercast.sh" "$port/greenovercast/webrtc_stream.aarch64" \
  "$port/greenovercast/libgreenovercast-cedar.so" \
  "$port/greenovercast/libgreenovercast-mpp.so" \
  "$port/greenovercast/rockchip/librockchip_mpp.so.1" \
  "$port/greenovercast/rockchip/greenovercast-mpp-probe.aarch64" \
  "$port/greenovercast/libavcodec.so.58" \
  "$port/greenovercast/libavutil.so.56" \
  "$port/greenovercast/libswscale.so.5"
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
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    names = archive.namelist()

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
    "greenovercast/licenses/LICENSE.Rockchip-MPP-Apache-2.0.txt",
    "greenovercast/licenses/LICENSE.Rockchip-MPP-MIT.txt",
    "greenovercast/libavcodec.so.58",
    "greenovercast/libavutil.so.56",
    "greenovercast/libswscale.so.5",
}
missing = sorted(required.difference(names))
bad_root = sorted(name for name in names if "/" not in name and name != "GreenOvercast.sh")
if missing or bad_root:
    raise SystemExit(f"invalid PortMaster archive: missing={missing}, bad_root={bad_root}")
PY

mv "$archive" "$OUTPUT"
printf 'packaged: %s\n' "$OUTPUT"
