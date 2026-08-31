#!/bin/sh
# Queue a PortMaster archive for autoinstall on a target reached over SSH.
# Usage: tools/deploy.sh <host> <archive>
set -eu

HOST=${1:?usage: deploy.sh <host> <archive>}
ARCHIVE=${2:?usage: deploy.sh <host> <archive>}

[ -f "$ARCHIVE" ] || {
  echo "archive not found: $ARCHIVE" >&2
  exit 1
}

case "$ARCHIVE" in
*.zip) ;;
*)
  echo "expected a PortMaster zip archive" >&2
  exit 1
  ;;
esac

remote_dir=$(ssh "$HOST" 'for path in \
  /opt/system/Tools/PortMaster/autoinstall \
  /opt/tools/PortMaster/autoinstall \
  "$HOME/.local/share/PortMaster/autoinstall" \
  /mnt/mmc/MUOS/PortMaster/autoinstall \
  /mnt/mmc/ports/autoinstall \
  /mnt/SDCARD/Persistent/portmaster/PortMaster/autoinstall \
  /roms/ports/PortMaster/autoinstall \
  /userdata/roms/ports/autoinstall; do
    if [ -d "$path" ]; then
      printf "%s\n" "$path"
      exit 0
    fi
  done
  exit 1') || {
  echo "PortMaster autoinstall directory not found on $HOST" >&2
  exit 1
}

name=$(basename "$ARCHIVE")
scp -q "$ARCHIVE" "$HOST:$remote_dir/.$name.tmp"
ssh "$HOST" "chmod 644 '$remote_dir/.$name.tmp' && mv '$remote_dir/.$name.tmp' '$remote_dir/$name'"
printf 'queued: %s:%s/%s\n' "$HOST" "$remote_dir" "$name"
printf 'launch PortMaster from the device frontend to install it\n'
