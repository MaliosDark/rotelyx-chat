#!/usr/bin/env bash
# Run the application's tests.
#
# The suite needs the Rotelyx engine as a native library, because the tests
# exercise the real one rather than a stand in: locks, calls, verification and
# note to self all cross the C ABI. Without it every one of those fails at the
# first call with "Failed to load dynamic library", which reads like fifty
# broken tests and is one missing file. It cost an afternoon once.
#
# So this builds the library and tells the loader where it is. Run this rather
# than `flutter test` directly.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
comms="${ROTELYX_COMMS:-$here/../../../comms-real-e2e}"

if [ ! -d "$comms/crates/rotelyx-mobile" ]; then
  echo "Cannot find the protocol repository at $comms" >&2
  echo "Set ROTELYX_COMMS to where comms-real-e2e is checked out." >&2
  exit 2
fi

echo "Building the engine for this machine..."
( cd "$comms" && cargo build --release -p rotelyx-mobile )

export LD_LIBRARY_PATH="$comms/target/release:${LD_LIBRARY_PATH:-}"
export DYLD_LIBRARY_PATH="$comms/target/release:${DYLD_LIBRARY_PATH:-}"

cd "$here"
exec flutter test "$@"
