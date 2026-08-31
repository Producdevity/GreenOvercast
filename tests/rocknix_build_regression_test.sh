#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/greenovercast-rocknix-build-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

fail() {
  echo "$1" >&2
  exit 1
}

fake_bin="$TEST_ROOT/fake-bin"
kernel_tree="$TEST_ROOT/kernel"
make_marker="$TEST_ROOT/make-called"
dtc_marker="$TEST_ROOT/dtc-called"
xxd_marker="$TEST_ROOT/xxd-called"
mkdir -p "$fake_bin" "$kernel_tree"
: >"$kernel_tree/.config"
: >"$kernel_tree/Module.symvers"
mkdir -p "$kernel_tree/drivers/staging/media/sunxi/cedrus"
printf 'original cedrus\n' >"$kernel_tree/drivers/staging/media/sunxi/cedrus/cedrus.c"
printf 'original cedrus hw\n' >"$kernel_tree/drivers/staging/media/sunxi/cedrus/cedrus_hw.c"

cat >"$fake_bin/uname" <<'EOF'
#!/bin/sh
echo aarch64
EOF
cat >"$fake_bin/gcc" <<'EOF'
#!/bin/sh
echo 15.2.0
EOF
cat >"$fake_bin/sha256sum" <<'EOF'
#!/bin/sh
case "$1" in
*/.config) hash=ea1abaf7109d6132e0ecd3cee51d8e08cde5e2143813f017ed35399950482081 ;;
*/Module.symvers) hash=b95c5a532ae10737d39bac79823e1977db7ec603410b4ab2b77edabc8dd41674 ;;
*) exit 1 ;;
esac
printf '%s  %s\n' "$hash" "$1"
EOF
cat >"$fake_bin/patch" <<'EOF'
#!/bin/sh
directory=
for argument do
  [ "$argument" != --dry-run ] || exit 0
done
while [ "$#" -gt 0 ]; do
  if [ "$1" = -d ]; then
    shift
    directory=$1
    break
  fi
  shift
done
printf 'partial change\n' >>"$directory/drivers/staging/media/sunxi/cedrus/cedrus.c"
printf 'partial change\n' >>"$directory/drivers/staging/media/sunxi/cedrus/cedrus_hw.c"
exit 1
EOF
cat >"$fake_bin/make" <<'EOF'
#!/bin/sh
kernel_tree=
module_dir=
while [ "$#" -gt 0 ]; do
  case "$1" in
  -C)
    shift
    kernel_tree=$1
    ;;
  M=*) module_dir=${1#M=} ;;
  esac
  shift
done
printf '%s\n' "$module_dir" >>"$MAKE_MARKER"
case "$module_dir" in
drivers/*)
  mkdir -p "$kernel_tree/$module_dir"
  printf 'cedrus module\n' >"$kernel_tree/$module_dir/sunxi-cedrus.ko"
  ;;
/*)
  mkdir -p "$module_dir"
  printf 'overlay module\n' >"$module_dir/greenovercast_h700_overlay.ko"
  ;;
*) exit 1 ;;
esac
EOF
cat >"$fake_bin/dtc" <<'EOF'
#!/bin/sh
output=
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then
    shift
    output=$1
    break
  fi
  shift
done
[ -n "$output" ] || exit 1
: >"$output"
: >"$DTC_MARKER"
EOF
cat >"$fake_bin/xxd" <<'EOF'
#!/bin/sh
: >"$XXD_MARKER"
printf '%s\n' 'unsigned char greenovercast_h700_ve_dtbo[] = { 0 };'
EOF
chmod +x "$fake_bin"/*

build_output="$TEST_ROOT/build-output"
if PATH="$fake_bin:/usr/bin:/bin" MAKE_MARKER="$make_marker" DTC_MARKER="$dtc_marker" \
  XXD_MARKER="$xxd_marker" \
  "$ROOT/tools/build-rocknix-h700-cedrus.sh" "$kernel_tree" "$TEST_ROOT/output" \
  >"$build_output" 2>&1; then
  fail "ROCKNIX module build accepted a failed patch application"
fi
[ ! -e "$make_marker" ] || fail "ROCKNIX module build continued after a failed patch application"
grep -q "failed to apply patch" "$build_output" || fail "ROCKNIX patch failure was not reported"
[ "$(cat "$kernel_tree/drivers/staging/media/sunxi/cedrus/cedrus.c")" = "original cedrus" ] ||
  fail "ROCKNIX module build left a partial source change"
[ "$(cat "$kernel_tree/drivers/staging/media/sunxi/cedrus/cedrus_hw.c")" = "original cedrus hw" ] ||
  fail "ROCKNIX module build left a partial hardware source change"

cat >"$fake_bin/patch" <<'EOF'
#!/bin/sh
directory=
for argument do
  [ "$argument" != --dry-run ] || exit 0
done
while [ "$#" -gt 0 ]; do
  if [ "$1" = -d ]; then
    shift
    directory=$1
    break
  fi
  shift
done
printf 'applied change\n' >>"$directory/drivers/staging/media/sunxi/cedrus/cedrus.c"
printf 'applied change\n' >>"$directory/drivers/staging/media/sunxi/cedrus/cedrus_hw.c"
EOF

success_output="$TEST_ROOT/success-output"
PATH="$fake_bin:/usr/bin:/bin" MAKE_MARKER="$make_marker" DTC_MARKER="$dtc_marker" \
  XXD_MARKER="$xxd_marker" \
  "$ROOT/tools/build-rocknix-h700-cedrus.sh" "$kernel_tree" "$success_output" \
  >"$TEST_ROOT/success.log" 2>&1 || fail "ROCKNIX module build rejected a valid build"

[ "$(wc -l <"$make_marker" | tr -d ' ')" = 2 ] || fail "ROCKNIX module build did not run both make steps"
[ -e "$dtc_marker" ] || fail "ROCKNIX module build did not compile the device-tree overlay"
[ -e "$xxd_marker" ] || fail "ROCKNIX module build did not embed the device-tree overlay"
[ "$(cat "$success_output/sunxi-cedrus.ko")" = "cedrus module" ] ||
  fail "ROCKNIX module build did not copy the Cedrus module"
[ "$(cat "$success_output/greenovercast_h700_overlay.ko")" = "overlay module" ] ||
  fail "ROCKNIX module build did not copy the overlay module"
[ "$(cat "$kernel_tree/drivers/staging/media/sunxi/cedrus/cedrus.c")" = "original cedrus" ] ||
  fail "ROCKNIX module build did not restore the patched source file"
[ "$(cat "$kernel_tree/drivers/staging/media/sunxi/cedrus/cedrus_hw.c")" = "original cedrus hw" ] ||
  fail "ROCKNIX module build did not restore the patched hardware source file"
