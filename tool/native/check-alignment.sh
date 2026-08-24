#!/usr/bin/env bash
#
# Verify every native library in the package will load on a sixteen kilobyte
# page device.
#
#     tool/native/check-alignment.sh [path/to/app.apk|path/to/app.aab]
#
# With no argument it reads the last release APK, building nothing.
#
# Google Play rejects an upload whose native libraries are aligned to four
# kilobytes, and a device with sixteen kilobyte pages cannot load one: dlopen
# fails and the process dies with the application already on screen. Neither
# failure is visible from a build log, so this reads the alignment back out of
# the finished files.
#
# # Why this reads the package and not android/app/src/main/jniLibs
#
# It used to read jniLibs, which holds only the libraries this project builds,
# and it passed while the package was not shippable. Every dependency with
# native code ships its own, and one of them was four kilobyte aligned:
# CameraX 1.3.4's `libimage_processing_util_jni.so`. Play looks at what is
# uploaded, so this has to as well.
set -euo pipefail

APP="$(cd "$(dirname "$0")/../.." && pwd)"
PACKAGE="${1:-$APP/build/app/outputs/flutter-apk/app-release.apk}"
WANT=16384

if [ ! -f "$PACKAGE" ]; then
  echo "no package at $PACKAGE" >&2
  echo "build one first: flutter build apk --release" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# An AAB keeps its libraries under base/lib, an APK under lib.
unzip -q -o "$PACKAGE" 'lib/*' 'base/lib/*' -d "$WORK" 2>/dev/null || true

mapfile -t LIBS < <(find "$WORK" -name '*.so' | sort)
if [ "${#LIBS[@]}" -eq 0 ]; then
  echo "no native libraries in $PACKAGE, which is itself surprising" >&2
  exit 1
fi

echo "$(basename "$PACKAGE"): ${#LIBS[@]} native libraries"
bad=0

for so in "${LIBS[@]}"; do
  # The first LOAD segment's alignment is what the loader has to satisfy.
  align="$(readelf -lW "$so" 2>/dev/null | awk '/LOAD/ {print $NF; exit}')"
  bytes=$((align))

  name="${so#"$WORK"/}"
  name="${name#base/lib/}"
  name="${name#lib/}"

  if [ "$bytes" -lt "$WANT" ]; then
    printf '  %-46s %-9s TOO SMALL\n' "$name" "$align"
    bad=$((bad + 1))
  else
    printf '  %-46s %-9s ok\n' "$name" "$align"
  fi
done

echo
if [ "$bad" -gt 0 ]; then
  echo "$bad libraries are aligned below sixteen kilobytes." >&2
  echo "Play will refuse this upload, and a device with sixteen kilobyte pages" >&2
  echo "cannot load them. If one belongs to a dependency, the fix is a newer" >&2
  echo "version of that dependency, not a flag here." >&2
  exit 1
fi

echo "every library will load on a sixteen kilobyte page device"
