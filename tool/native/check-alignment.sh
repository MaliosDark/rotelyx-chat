#!/usr/bin/env bash
#
# Verify the native libraries will load on a sixteen kilobyte page device.
#
#     tool/native/check-alignment.sh
#
# Google Play rejects an upload whose native libraries are aligned to four
# kilobytes, and a device with sixteen kilobyte pages cannot load one: dlopen
# fails and the process dies with the application already on screen. Neither
# failure is visible from a build log, so this reads the alignment back out of
# the finished files.
#
# The number wanted is 0x4000. Anything smaller is a rejected upload.
set -euo pipefail

APP="$(cd "$(dirname "$0")/../.." && pwd)"
LIBS="$APP/android/app/src/main/jniLibs"
WANT=16384
bad=0

if [ ! -d "$LIBS" ]; then
  echo "no jniLibs at $LIBS. Run tool/native/build-android.sh first." >&2
  exit 1
fi

for so in "$LIBS"/*/*.so; do
  [ -e "$so" ] || continue
  abi="$(basename "$(dirname "$so")")"

  # Every LOAD segment, not just the first. One misaligned segment is enough.
  #
  # The arithmetic is done by the shell rather than by awk, because the field is
  # hexadecimal and `strtonum` is a gawk extension: on a system with mawk the
  # awk version prints nothing at all and the check passes everything.
  worst=""
  for a in $(readelf -lW "$so" | awk '/LOAD/ {print $NF}'); do
    n=$(( a ))
    if [ -z "$worst" ] || [ "$n" -lt "$worst" ]; then worst="$n"; fi
  done

  if [ -z "$worst" ]; then
    echo "  $abi  no LOAD segments, this is not a shared library" >&2
    bad=1
  elif [ "$worst" -lt "$WANT" ]; then
    printf '  %-12s %8s  TOO SMALL, needs 0x4000\n' "$abi" "$(printf '0x%x' "$worst")"
    bad=1
  else
    printf '  %-12s %8s  ok\n' "$abi" "$(printf '0x%x' "$worst")"
  fi
done

if [ "$bad" -ne 0 ]; then
  echo
  echo "Rebuild with tool/native/build-android.sh, which passes the linker flag." >&2
  exit 1
fi

echo
echo "every library will load on a sixteen kilobyte page device"
