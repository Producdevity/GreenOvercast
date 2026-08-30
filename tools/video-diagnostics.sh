#!/bin/sh
set -u

app_dir=${1:-.}
mpp_plugin=${GREENOVERCAST_MPP_LIBRARY:-$app_dir/libgreenovercast-mpp.so}
if [ -f "$app_dir/rockchip/greenovercast-mpp-probe.aarch64" ]; then
  mpp_probe="$app_dir/rockchip/greenovercast-mpp-probe.aarch64"
  private_mpp_dir="$app_dir/rockchip"
else
  mpp_probe="$app_dir/greenovercast-mpp-probe.aarch64"
  private_mpp_dir="$app_dir"
fi

printf 'Architecture: %s\n' "$(uname -m)"
printf 'Userspace bits: %s\n' "$(getconf LONG_BIT 2>/dev/null || printf unknown)"
printf 'Kernel: %s\n' "$(uname -r)"
printf 'Libc: %s\n' "$(getconf GNU_LIBC_VERSION 2>/dev/null || printf unknown)"
printf 'Decoder preference: %s\n' "${GREENOVERCAST_VIDEO_DECODER:-auto}"

printf 'Device-tree compatible:\n'
compatible_found=0
for compatible_path in /proc/device-tree/compatible /sys/firmware/devicetree/base/compatible; do
  if [ -r "$compatible_path" ]; then
    tr '\0' '\n' <"$compatible_path"
    compatible_found=1
    break
  fi
done
[ "$compatible_found" -eq 1 ] || printf 'unavailable\n'

printf 'V4L2 media devices:\n'
v4l2_found=0
for device in /dev/media* /dev/video*; do
  if [ -e "$device" ]; then
    ls -l "$device"
    v4l2_found=1
  fi
done
[ "$v4l2_found" -eq 1 ] || printf 'none\n'

printf 'MPP plugin: %s\n' "$mpp_plugin"
if [ ! -f "$mpp_plugin" ]; then
  printf 'MPP plugin status: missing\n'
else
  file "$mpp_plugin" 2>/dev/null || true
  if command -v ldd >/dev/null 2>&1; then
    printf 'MPP dependencies using firmware libraries:\n'
    LD_LIBRARY_PATH="$app_dir:${LD_LIBRARY_PATH:-}" ldd "$mpp_plugin" 2>&1
  fi
  if [ -f "$mpp_probe" ] && [ ! -x "$mpp_probe" ]; then
    if ! chmod +x "$mpp_probe" 2>/dev/null; then
      printf 'MPP probe: unable to make executable\n'
    fi
  fi
  if [ -x "$mpp_probe" ]; then
    printf 'MPP firmware probe:\n'
    if ! GREENOVERCAST_MPP_LIBRARY="$mpp_plugin" \
      LD_LIBRARY_PATH="$app_dir:${LD_LIBRARY_PATH:-}" \
      "$mpp_probe"; then
      if [ -f "$private_mpp_dir/librockchip_mpp.so.1" ]; then
        printf 'MPP private-runtime probe:\n'
        GREENOVERCAST_MPP_LIBRARY="$mpp_plugin" \
          LD_LIBRARY_PATH="$private_mpp_dir:$app_dir:${LD_LIBRARY_PATH:-}" \
          "$mpp_probe" || true
      fi
    fi
  else
    printf 'MPP probe: missing\n'
  fi
fi
