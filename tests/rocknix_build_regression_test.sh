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
exit 1
EOF
cat >"$fake_bin/make" <<'EOF'
#!/bin/sh
: >"$MAKE_MARKER"
exit 0
EOF
for tool in dtc xxd; do
  cat >"$fake_bin/$tool" <<'EOF'
#!/bin/sh
exit 0
EOF
done
chmod +x "$fake_bin"/*

build_output="$TEST_ROOT/build-output"
if PATH="$fake_bin:/usr/bin:/bin" MAKE_MARKER="$make_marker" \
  "$ROOT/tools/build-rocknix-h700-cedrus.sh" "$kernel_tree" "$TEST_ROOT/output" \
  >"$build_output" 2>&1; then
  fail "ROCKNIX module build accepted a failed patch application"
fi
[ ! -e "$make_marker" ] || fail "ROCKNIX module build continued after a failed patch application"
grep -q "failed to apply patch" "$build_output" || fail "ROCKNIX patch failure was not reported"
[ "$(cat "$kernel_tree/drivers/staging/media/sunxi/cedrus/cedrus.c")" = "original cedrus" ] ||
  fail "ROCKNIX module build left a partial source change"
[ "$(cat "$kernel_tree/drivers/staging/media/sunxi/cedrus/cedrus_hw.c")" = "original cedrus hw" ] ||
  fail "ROCKNIX module build changed the unpatched source file"
