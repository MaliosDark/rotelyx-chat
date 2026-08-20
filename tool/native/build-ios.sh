#!/usr/bin/env bash
#
# Build the Rotelyx engine for iOS as an XCFramework.
#
#   tool/native/build-ios.sh [--release]
#
# **Must run on a Mac.** The iOS targets need Apple's linker and SDKs, which
# exist nowhere else. Everything up to this point, including the Rust targets
# themselves, was prepared on Linux; this is the one step that cannot be.
#
# # Why a static library rather than a shared one
#
# iOS will not load a shared library from the application bundle the way Android
# will. The engine is linked into the Runner binary, which is why
# `lib/rotelyx/engine/native.dart` uses `DynamicLibrary.process()` there: the
# symbols are already in the process and there is no file to open.
#
# # Why an XCFramework rather than one .a
#
# A device is arm64 and the simulator on Apple silicon is also arm64, with a
# different ABI. `lipo` cannot hold both in one archive because the slices
# collide. An XCFramework holds them side by side and Xcode picks.
#
# # What it produces, and what to do with it
#
#   ios/Frameworks/RotelyxEngine.xcframework
#
# Add it to the Runner target in Xcode: select Runner, General, Frameworks
# Libraries and Embedded Content, add the xcframework, and set it to
# **Do Not Embed**. It is static; embedding it would copy an archive into the
# bundle that nothing loads.
#
# Then make sure the symbols survive. A static library contributes nothing the
# linker sees a reference to, and every call here goes through `dart:ffi` at
# runtime, so from the linker's point of view nothing is referenced. Add to
# Other Linker Flags:
#
#   -force_load $(SRCROOT)/Frameworks/RotelyxEngine.xcframework/ios-arm64/librotelyx_mobile.a
#
# Without it the application builds, launches, and then reports that the engine
# is not loaded, which reads as a packaging failure and is a linker one.

set -euo pipefail

cd "$(dirname "$0")/../.."
APP="$PWD"
PROTOCOL="${ROTELYX_PROTOCOL:-$HOME/comms-real-e2e}"

PROFILE=debug
CARGO_FLAGS=()
if [ "${1:-}" = "--release" ]; then
  PROFILE=release
  CARGO_FLAGS+=(--release)
fi

if [ "$(uname)" != "Darwin" ]; then
  echo "this has to run on macOS: the iOS targets need Apple's linker" >&2
  exit 1
fi

if [ ! -d "$PROTOCOL/crates/rotelyx-mobile" ]; then
  echo "no rotelyx-mobile at $PROTOCOL" >&2
  exit 1
fi

DEVICE=aarch64-apple-ios
SIM_ARM=aarch64-apple-ios-sim
SIM_X86=x86_64-apple-ios

for triple in "$DEVICE" "$SIM_ARM" "$SIM_X86"; do
  rustup target list --installed | grep -qx "$triple" || rustup target add "$triple"
  echo "building $triple"
  cargo build --manifest-path "$PROTOCOL/Cargo.toml" \
    -p rotelyx-mobile --target "$triple" "${CARGO_FLAGS[@]}"
done

OUT="$APP/ios/Frameworks"
rm -rf "$OUT/RotelyxEngine.xcframework"
mkdir -p "$OUT" "$APP/build/ios-sim"

# The two simulator slices are different architectures of the same ABI, so they
# combine. The device slice stays on its own.
lipo -create \
  "$PROTOCOL/target/$SIM_ARM/$PROFILE/librotelyx_mobile.a" \
  "$PROTOCOL/target/$SIM_X86/$PROFILE/librotelyx_mobile.a" \
  -output "$APP/build/ios-sim/librotelyx_mobile.a"

# A header, so Xcode has something to describe the library with. `dart:ffi`
# looks symbols up by name and never reads it, but an XCFramework wants one.
HEADERS="$APP/build/ios-headers"
mkdir -p "$HEADERS"
cat > "$HEADERS/rotelyx.h" <<'HEADER'
// The Rotelyx engine's C ABI. Three symbols; see crates/rotelyx-mobile.
#ifndef ROTELYX_H
#define ROTELYX_H
#include <stdint.h>
int32_t rotelyx_call(const char *request_json, char **response_json);
void rotelyx_string_free(char *s);
const char *rotelyx_abi_version(void);
#endif
HEADER
cat > "$HEADERS/module.modulemap" <<'MAP'
module RotelyxEngine {
    header "rotelyx.h"
    export *
}
MAP

xcodebuild -create-xcframework \
  -library "$PROTOCOL/target/$DEVICE/$PROFILE/librotelyx_mobile.a" -headers "$HEADERS" \
  -library "$APP/build/ios-sim/librotelyx_mobile.a" -headers "$HEADERS" \
  -output "$OUT/RotelyxEngine.xcframework"

echo
echo "built $OUT/RotelyxEngine.xcframework"
echo "Add it to the Runner target as Do Not Embed, and add -force_load."
echo "See the comment at the top of this script."
