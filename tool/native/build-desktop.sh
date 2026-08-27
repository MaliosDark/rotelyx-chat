#!/usr/bin/env bash
#
# Build the native engine for this machine, and put it where the desktop build
# will find it.
#
#     tool/native/build-desktop.sh [--debug]
#
# # What this is for
#
# `lib/rotelyx/engine/native.dart` opens `librotelyx_mobile` by name on Linux
# and Windows, and expects it inside the process on macOS. The name says mobile
# because that is the crate that wraps the protocol behind a C ABI, and the same
# wrapper is what a desktop build wants: it is one crate packaged three ways,
# not three implementations.
#
# The desktop targets are scaffolded and this is the piece that makes them run
# rather than start and immediately report that the engine is missing.
#
# # What still has to be installed
#
#   Linux:   ninja-build, clang, libgtk-3-dev, pkg-config
#   Windows: Visual Studio with the C++ desktop workload
#   macOS:   Xcode
#
# Flutter's own `flutter doctor` reports these, and none of them is something
# this script should install on somebody's machine without being asked.
set -euo pipefail

APP="$(cd "$(dirname "$0")/../.." && pwd)"
PROTOCOL="${ROTELYX_PROTOCOL:-$HOME/comms-real-e2e}"
# `mobile` rather than `release`: this is the same C ABI library the phones
# load, and `release` aborts on panic, which makes the guard at that boundary
# do nothing. The name is historical; what it means is "unwinds".
PROFILE="mobile"
[ "${1:-}" = "--debug" ] && PROFILE="debug"

if [ ! -d "$PROTOCOL/crates/rotelyx-mobile" ]; then
  echo "no rotelyx-mobile at $PROTOCOL" >&2
  echo "set ROTELYX_PROTOCOL to the protocol repository" >&2
  exit 1
fi

case "$(uname -s)" in
  Linux)   LIB="librotelyx_mobile.so";   DEST="$APP/build/native" ;;
  Darwin)  LIB="librotelyx_mobile.dylib"; DEST="$APP/macos/Frameworks" ;;
  MINGW*|MSYS*|CYGWIN*) LIB="rotelyx_mobile.dll"; DEST="$APP/windows/native" ;;
  *) echo "unknown platform: $(uname -s)" >&2; exit 1 ;;
esac

echo "protocol $PROTOCOL"
echo "profile  $PROFILE"
echo

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

FLAGS=()
[ "$PROFILE" = "mobile" ] && FLAGS+=(--profile mobile)

RUSTFLAGS="${REMAP[*]}" \
  cargo build --manifest-path "$PROTOCOL/Cargo.toml" -p rotelyx-mobile "${FLAGS[@]}"

mkdir -p "$DEST"
cp "$PROTOCOL/target/$PROFILE/$LIB" "$DEST/$LIB"

echo
echo "  -> ${DEST#"$APP/"}/$LIB  $(du -h "$DEST/$LIB" | cut -f1)"
echo
echo "The tests already read it from build/native through LD_LIBRARY_PATH."
echo "A desktop run needs it beside the executable, or on the loader path."
