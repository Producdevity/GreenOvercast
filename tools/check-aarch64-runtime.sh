#!/bin/sh
set -eu
export LC_ALL=C
if [ "$#" -eq 0 ]; then
  echo "usage: $0 ELF_FILE..." >&2
  exit 1
fi
reader=${READELF:-}
if [ -z "$reader" ]; then
  for candidate in llvm-readelf readelf greadelf; do
    if command -v "$candidate" >/dev/null 2>&1; then
      reader=$candidate
      break
    fi
  done
fi
[ -n "$reader" ] || { echo "missing llvm-readelf or GNU readelf; install LLVM or binutils" >&2; exit 1; }
status=0
for artifact do
  if ! symbols=$("$reader" -h -W --dyn-syms -- "$artifact" 2>&1); then
    printf '%s\n' "$symbols" >&2
    status=1
    continue
  fi
  if ! printf '%s\n' "$symbols" | grep -Eq 'Machine:[[:space:]]+AArch64[[:space:]]*$'; then
    printf '%s: not an AArch64 ELF artifact\n' "$artifact" >&2
    status=1
    continue
  fi
  if ! printf '%s\n' "$symbols" | grep -Eq 'Type:[[:space:]]+(DYN|EXEC)[[:space:]]'; then
    printf '%s: not a linked executable or shared library\n' "$artifact" >&2
    status=1
    continue
  fi
  missing=$(printf '%s\n' "$symbols" | awk '$7 == "UND" && $8 ~ /^__aarch64_/ { print $8 }' | sort -u)
  if [ -n "$missing" ]; then
    printf '%s: unresolved AArch64 runtime helpers:\n%s\n' "$artifact" "$missing" >&2
    status=1
  fi
done
exit "$status"
