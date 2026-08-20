#!/usr/bin/env bash
#
# Build the Rotelyx engine for Android and put it where Gradle will find it.
#
#   tool/native/build-android.sh [--debug]
#
# # What this produces
#
# `librotelyx_mobile.so`, one per ABI, under `android/app/src/main/jniLibs/`.
# Gradle packages everything there into the APK automatically, and at runtime
# `DynamicLibrary.open('librotelyx_mobile.so')` in `lib/rotelyx/engine/native.dart`
# finds it because an application's own `lib/<abi>` is on the loader path.
#
# # Why not cargo-ndk
#
# It is one more thing to install for what amounts to setting three environment
# variables per target. The NDK ships a clang wrapper for every ABI and API
# level; naming it directly is fewer moving parts and makes the API level
# visible rather than implied.
#
# # Release by default, and stripped
#
# A debug build of this crate is 300 MB per ABI, because the crypto stack drags
# in a great deal of generic code and debug keeps a symbol for all of it. Three
# of those is a gigabyte of APK for a library whose useful content is a few
# megabytes, and no phone should be asked to carry it.
#
# So release is the default and `--debug` is the opt-in, which is the reverse of
# the usual convention and is right here: nobody steps through this library from
# Dart, and the thing being debugged is always on the other side of the ABI.
#
# # The ABIs
#
# arm64 is every phone worth testing on. armeabi-v7a is old 32 bit devices, and
# is cheap to keep. x86_64 is the emulator, which is the difference between
# being able to try this without a handset and not. x86 is omitted: no emulator
# image has needed it for years.

set -euo pipefail

cd "$(dirname "$0")/../.."
APP="$PWD"

PROTOCOL="${ROTELYX_PROTOCOL:-/home/serafin/comms-real-e2e}"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/home/serafin/Dinter/_devtools/android/sdk}}"

# The lowest Android this application supports, from android/app/build.gradle.
# The NDK names its compilers after it, so the two cannot drift silently.
API=24

PROFILE=release
CARGO_FLAGS=(--release)
if [ "${1:-}" = "--debug" ]; then
  PROFILE=debug
  CARGO_FLAGS=()
fi

if [ ! -d "$PROTOCOL/crates/rotelyx-mobile" ]; then
  echo "no rotelyx-mobile at $PROTOCOL" >&2
  echo "set ROTELYX_PROTOCOL to the protocol repository" >&2
  exit 1
fi

NDK_ROOT="$(ls -d "$SDK"/ndk/* 2>/dev/null | sort -V | tail -1 || true)"
if [ -z "$NDK_ROOT" ]; then
  echo "no NDK under $SDK/ndk" >&2
  echo "install one with: sdkmanager 'ndk;26.1.10909125'" >&2
  exit 1
fi

HOST="$(uname | tr '[:upper:]' '[:lower:]')-x86_64"
BIN="$NDK_ROOT/toolchains/llvm/prebuilt/$HOST/bin"
if [ ! -d "$BIN" ]; then
  echo "no toolchain at $BIN" >&2
  exit 1
fi

# Sixteen kilobyte memory pages, which Google Play requires.
#
# Android has always used four kilobyte pages. Devices from Android 15 onward
# may use sixteen, and a shared library whose LOAD segments are aligned to four
# will not load on one at all: the process dies at dlopen with the application
# already on screen. Play enforces it, and from 1 November 2025 an upload whose
# native libraries are not aligned is rejected outright.
#
# Two ways to get it. NDK r27 and later default to it, and every older NDK needs
# the linker told. This asks the linker directly rather than requiring a
# particular NDK, because the flag is harmless on a toolchain that already does
# it and the alternative is a build that silently produces a rejected upload on
# whichever machine has the older toolchain installed.
#
# `tool/native/check-alignment.sh` reads the alignment back out of the finished
# libraries, because a flag that is silently ignored looks exactly like a flag
# that worked.
PAGE_FLAGS="-C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,-z,common-page-size=16384"

# Keep this machine's directory layout out of the shipped library.
#
# rustc records the absolute path of every source file it compiles, for panic
# messages and debug info, and those paths end up in the stripped release
# library too. Measured on a finished APK: 259 strings containing the build
# user's name, spelling out their home directory, their cargo registry and the
# location of the protocol repository.
#
# For an application whose argument is that it discloses nothing, shipping the
# author's directory structure inside every copy is a poor look, and it is one
# flag. `--remap-path-prefix` rewrites them at compile time; it is the same
# mechanism the reproducible-builds work uses, for the same reason.
#
# The replacements are deliberately not real paths. A panic that reports
# `/cargo/argon2-0.5.3/src/lib.rs` still names the crate and the line, which is
# everything a backtrace is for.
# Broadest first, because when several mappings match a path, rustc uses the
# **last** one. Written the other way round, the catch-all wins every time and
# cargo paths come out as `/home/build/.cargo/...` instead of `/cargo/...`,
# which discloses nothing either but is two forms of the same thing.
REMAP=(
  "--remap-path-prefix=$HOME=/home/build"
  "--remap-path-prefix=$HOME/.rustup=/rustup"
  "--remap-path-prefix=$HOME/.cargo=/cargo"
  "--remap-path-prefix=$PROTOCOL=/rotelyx"
)


echo "ndk      $NDK_ROOT"
echo "protocol $PROTOCOL"
echo "profile  $PROFILE"
echo

# target triple : android ABI directory : clang prefix
TARGETS=(
  "aarch64-linux-android:arm64-v8a:aarch64-linux-android"
  "armv7-linux-androideabi:armeabi-v7a:armv7a-linux-androideabi"
  "x86_64-linux-android:x86_64:x86_64-linux-android"
)

for entry in "${TARGETS[@]}"; do
  IFS=: read -r triple abi prefix <<< "$entry"

  if ! rustup target list --installed | grep -qx "$triple"; then
    echo "installing rust target $triple"
    rustup target add "$triple"
  fi

  CC="$BIN/${prefix}${API}-clang"
  AR="$BIN/llvm-ar"
  if [ ! -x "$CC" ]; then
    echo "no compiler at $CC" >&2
    echo "this NDK may not support API $API for $abi" >&2
    exit 1
  fi

  # Cargo reads the linker from an environment variable whose name is the
  # target triple, uppercased with dashes turned into underscores. Ring and
  # anything else with C in it read CC and AR.
  upper="$(echo "$triple" | tr 'a-z-' 'A-Z_')"
  echo "building $abi"
  env \
    "CARGO_TARGET_${upper}_LINKER=$CC" \
    "CARGO_TARGET_${upper}_RUSTFLAGS=$PAGE_FLAGS ${REMAP[*]}" \
    "CC_${triple//-/_}=$CC" \
    "AR_${triple//-/_}=$AR" \
    cargo build \
      --manifest-path "$PROTOCOL/Cargo.toml" \
      -p rotelyx-mobile \
      --target "$triple" \
      "${CARGO_FLAGS[@]}"

  dest="$APP/android/app/src/main/jniLibs/$abi"
  mkdir -p "$dest"
  cp "$PROTOCOL/target/$triple/$PROFILE/librotelyx_mobile.so" "$dest/"

  # Even a release build keeps symbol and debug sections that nothing on a
  # phone reads. The NDK's strip understands every ABI here, so use it rather
  # than the host one, which does not.
  "$BIN/llvm-strip" --strip-unneeded "$dest/librotelyx_mobile.so"

  echo "  -> jniLibs/$abi/librotelyx_mobile.so  $(du -h "$dest/librotelyx_mobile.so" | cut -f1)"
done

echo
echo "done. The next 'flutter build apk' will package these."
