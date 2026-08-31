#!/bin/bash

umask 077

XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}

if [ -d "/opt/system/Tools/PortMaster/" ]; then
  controlfolder="/opt/system/Tools/PortMaster"
elif [ -d "/opt/tools/PortMaster/" ]; then
  controlfolder="/opt/tools/PortMaster"
elif [ -d "$XDG_DATA_HOME/PortMaster/" ]; then
  controlfolder="$XDG_DATA_HOME/PortMaster"
else
  controlfolder="/roms/ports/PortMaster"
fi

source "$controlfolder/control.txt"
[ -f "${controlfolder}/mod_${CFW_NAME}.txt" ] && source "${controlfolder}/mod_${CFW_NAME}.txt"
get_controls

# AmberELEC's shared GO-Super mapping exposes R36S R3 as Guide.
case "$sdl_controllerconfig" in
190000004b4800000011000000010000,GO-Super\ Gamepad,*guide:b15,*)
  sdl_controllerconfig=${sdl_controllerconfig/,guide:b15,/,rightstick:b15,guide:b16,}
  ;;
esac

GAMEDIR="/$directory/ports/greenovercast"
cd "$GAMEDIR" || exit 1

rocknix_h700_modules="$GAMEDIR/rocknix/h700/cedrus-modules"

finish() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$CFW_NAME" = "ROCKNIX" ] && [ -x "$rocknix_h700_modules" ]; then
    $ESUDO "$rocknix_h700_modules" unload ||
      echo "Unable to unload the ROCKNIX H700 video decoder." >&2
  fi
  pm_finish
  exit "$status"
}
trap finish EXIT HUP INT TERM

fail() {
  pm_show_error "$1"
  exit 1
}

config_dir="$XDG_CONFIG_HOME/greenovercast"
artwork_cache_dir="$config_dir/artwork"
credential_dir="$config_dir"

mkdir -p "$config_dir" "$credential_dir" "$artwork_cache_dir" || fail "Unable to create GreenOvercast's storage."
chmod 700 "$credential_dir" || fail "Unable to protect GreenOvercast's private storage."

credential_file="$credential_dir/tokens.bin"
credential_key_file="$credential_dir/tokens.key"
video_bootstrap_file="$credential_dir/h264-parameter-sets.bin"
catalog_file="$credential_dir/catalog.tsv"
settings_file="$config_dir/settings.tsv"
log_file="$credential_dir/greenovercast.log"

: >"$log_file"
chmod 600 "$log_file"
exec > >(tee "$log_file") 2>&1

for private_file in "$credential_file" "$credential_key_file" "$catalog_file"; do
  [ ! -e "$private_file" ] || chmod 600 "$private_file"
done

if [ "$CFW_NAME" = "ROCKNIX" ] && [ -f "$rocknix_h700_modules" ]; then
  $ESUDO chmod +x "$rocknix_h700_modules"
  $ESUDO "$rocknix_h700_modules" load ||
    fail "Unable to start the ROCKNIX H700 video decoder."
fi

export GREENOVERCAST_TOKEN_FILE="$credential_file"
export GREENOVERCAST_TOKEN_KEY_FILE="$credential_key_file"
export GREENOVERCAST_H264_BOOTSTRAP_FILE="$video_bootstrap_file"
export GREENOVERCAST_CATALOG_FILE="$catalog_file"
export GREENOVERCAST_SETTINGS_FILE="$settings_file"
export GREENOVERCAST_ARTWORK_CACHE_DIR="$artwork_cache_dir"
export GREENOVERCAST_CEDAR_LIBRARY="$GAMEDIR/libgreenovercast-cedar.so"
export GREENOVERCAST_MPP_LIBRARY="$GAMEDIR/libgreenovercast-mpp.so"
export LD_LIBRARY_PATH="$GAMEDIR:${LD_LIBRARY_PATH:-}"
export SDL_GAMECONTROLLERCONFIG="$sdl_controllerconfig"

if [ -e /dev/vpu_service ] && { [ ! -r /dev/vpu_service ] || [ ! -w /dev/vpu_service ]; }; then
  $ESUDO chgrp video /dev/vpu_service && $ESUDO chmod 660 /dev/vpu_service
fi

for compatible_file in /proc/device-tree/compatible /sys/firmware/devicetree/base/compatible; do
  if [ -r "$compatible_file" ] && tr '\0' '\n' <"$compatible_file" | grep -q '^rockchip,'; then
    $ESUDO chmod +x "$GAMEDIR/rockchip/greenovercast-mpp-probe.aarch64"
    if ! GREENOVERCAST_MPP_LIBRARY="$GREENOVERCAST_MPP_LIBRARY" \
      LD_LIBRARY_PATH="$LD_LIBRARY_PATH" \
      "$GAMEDIR/rockchip/greenovercast-mpp-probe.aarch64" >/dev/null 2>&1; then
      export LD_LIBRARY_PATH="$GAMEDIR/rockchip:$LD_LIBRARY_PATH"
    fi
    break
  fi
done

if [ -S /var/run/pipewire-0 ]; then
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/var/run}"
  export PIPEWIRE_RUNTIME_DIR="${PIPEWIRE_RUNTIME_DIR:-/var/run}"
fi

unset SDL_HQ_SCALER SDL_ROTATION SDL_BLITTER_DISABLED

$ESUDO chmod +x "$GAMEDIR/webrtc_stream.aarch64"
pm_platform_helper "$GAMEDIR/webrtc_stream.aarch64"
"$GAMEDIR/webrtc_stream.aarch64" "$1"
status=$?
exit "$status"
