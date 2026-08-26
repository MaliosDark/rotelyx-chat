#!/usr/bin/env bash
#
# Build the Rotelyx engine for this machine, so the native wrapper can be
# tested without a phone.
#
#   tool/native/build-host.sh
#   LD_LIBRARY_PATH=build/native flutter test test/native_engine_test.dart
#
# # Why this is worth having
#
# `lib/rotelyx/engine/native.dart` is not Android code. It opens a shared
# library and speaks a JSON ABI to it, and a desktop can do both. So the exact
# wrapper a phone will run can be exercised here, in an ordinary `flutter test`,
# with no emulator and no handset.
#
# What it cannot cover is packaging: whether the `.so` reaches the APK and
# whether Android's loader finds it. That is a real gap and it is a small one,
# and it is the only part of the native path that needs a device to see.
#
# The output goes to `build/native/` rather than into the source tree, because
# it is a build artefact for this machine and belongs nowhere near the ABI
# directories that ship.

set -euo pipefail

cd "$(dirname "$0")/../.."
APP="$PWD"
PROTOCOL="${ROTELYX_PROTOCOL:-/home/serafin/comms-real-e2e}"

PROFILE=debug
CARGO_FLAGS=()
if [ "${1:-}" = "--release" ]; then
  # `mobile` rather than `release`, so what is tested here unwinds the way the
  # shipped library does. See tool/native/build-android.sh.
  PROFILE=mobile
  CARGO_FLAGS+=(--profile mobile)
fi

if [ ! -d "$PROTOCOL/crates/rotelyx-mobile" ]; then
  echo "no rotelyx-mobile at $PROTOCOL" >&2
  echo "set ROTELYX_PROTOCOL to the protocol repository" >&2
  exit 1
fi

cargo build --manifest-path "$PROTOCOL/Cargo.toml" -p rotelyx-mobile "${CARGO_FLAGS[@]}"

case "$(uname)" in
  Darwin) LIB=librotelyx_mobile.dylib ;;
  *)      LIB=librotelyx_mobile.so ;;
esac

mkdir -p "$APP/build/native"
cp "$PROTOCOL/target/$PROFILE/$LIB" "$APP/build/native/"

echo
echo "built build/native/$LIB"
echo
echo "run the tests against it with:"
echo "  LD_LIBRARY_PATH=build/native flutter test test/native_engine_test.dart"
