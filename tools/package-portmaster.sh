#!/bin/sh
set -eu
umask 022

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT=${1:-$ROOT/zig-out/greenovercast.zip}
PORTMASTER_NEW=${PORTMASTER_NEW:-${2:-}}
SOURCE="$ROOT/packaging/portmaster/greenovercast"
BINARY="$ROOT/zig-out/bin/webrtc_stream"
CEDAR="$ROOT/zig-out/bin/libgreenovercast-cedar.so"

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
chmod 644 "$port/GreenOvercast.sh" "$port/greenovercast/webrtc_stream.aarch64" \
  "$port/greenovercast/libgreenovercast-cedar.so"
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
}
missing = sorted(required.difference(names))
bad_root = sorted(name for name in names if "/" not in name and name != "GreenOvercast.sh")
if missing or bad_root:
    raise SystemExit(f"invalid PortMaster archive: missing={missing}, bad_root={bad_root}")
PY

mv "$archive" "$OUTPUT"
printf 'packaged: %s\n' "$OUTPUT"
