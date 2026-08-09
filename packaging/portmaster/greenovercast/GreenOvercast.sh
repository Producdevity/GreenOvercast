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

GAMEDIR="/$directory/ports/greenovercast"
cd "$GAMEDIR" || exit 1

fail() {
  pm_show_error "$1"
  pm_finish
  exit 1
}

config_dir="$XDG_CONFIG_HOME/greenovercast"
if [ "$CFW_NAME" = "knulli" ]; then
  credential_dir="${XDG_RUNTIME_DIR:-/var/run}/greenovercast"
else
  credential_dir="$config_dir"
fi

mkdir -p "$config_dir" "$credential_dir" || fail "Unable to create GreenOvercast's storage."
chmod 700 "$credential_dir" || fail "Unable to protect GreenOvercast's private storage."

credential_file="$credential_dir/tokens.bin"
credential_key_file="$credential_dir/tokens.key"
legacy_credential_file="$credential_dir/tokens.json"
video_bootstrap_file="$credential_dir/h264-parameter-sets.bin"
catalog_file="$credential_dir/catalog.tsv"
log_file="$credential_dir/greenovercast.log"

: >"$log_file"
chmod 600 "$log_file"
exec > >(tee "$log_file") 2>&1

for private_file in "$credential_file" "$credential_key_file" "$legacy_credential_file" "$catalog_file"; do
  [ ! -e "$private_file" ] || chmod 600 "$private_file"
done

export GREENOVERCAST_TOKEN_FILE="$credential_file"
export GREENOVERCAST_TOKEN_KEY_FILE="$credential_key_file"
export GREENOVERCAST_LEGACY_TOKEN_FILE="$legacy_credential_file"
export GREENOVERCAST_H264_BOOTSTRAP_FILE="$video_bootstrap_file"
export GREENOVERCAST_CATALOG_FILE="$catalog_file"
export GREENOVERCAST_CEDAR_LIBRARY="$GAMEDIR/libgreenovercast-cedar.so"
export LD_LIBRARY_PATH="$GAMEDIR:${LD_LIBRARY_PATH:-}"
export SDL_GAMECONTROLLERCONFIG="$sdl_controllerconfig"

if [ -S /var/run/pipewire-0 ]; then
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/var/run}"
  export PIPEWIRE_RUNTIME_DIR="${PIPEWIRE_RUNTIME_DIR:-/var/run}"
fi

unset SDL_HQ_SCALER SDL_ROTATION SDL_BLITTER_DISABLED SDL_ASSERT

$ESUDO chmod +x "$GAMEDIR/webrtc_stream.aarch64"
pm_platform_helper "$GAMEDIR/webrtc_stream.aarch64"
"$GAMEDIR/webrtc_stream.aarch64" "$1"
status=$?

pm_finish
exit "$status"
