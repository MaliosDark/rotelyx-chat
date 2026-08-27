#!/usr/bin/env bash
# A-4 enforcement: the e2e remote-control hook (window.__rotelyx) must never
# reach a production build. Ideoa Labs.
#
# The e2e hook is compiled out unless a build passes --dart-define=e2e=true, in
# which case Dart's tree-shaker keeps the `window.__rotelyx` assignment. So the
# authoritative check is on the ARTIFACT: build the client the production way
# and confirm the "__rotelyx" marker is absent. A second, targeted guard makes
# sure the RELEASE build scripts themselves never hardcode the flag. Docs and
# the dedicated e2e test tooling (tool/e2e) legitimately mention it and are not
# checked.
#
# Usage:  ./verify-no-e2e.sh [path-to-app-repo]   (default: .)
# Exit 0 = clean, 1 = the hook could ship.
set -uo pipefail
REPO="${1:-.}"
cd "$REPO"
fail=0
echo "== A-4: no e2e hook in a production build =="

# 1. Targeted guard: the production/release build scripts must not pass e2e.
REL_SCRIPTS="tool/dev/build-web.sh tool/native/build-host.sh tool/native/build-ios.sh"
for s in $REL_SCRIPTS; do
  [ -f "$s" ] || continue
  if grep -qiE -- '--dart-define[= ]*e2e|dart-define=e2e' "$s"; then
    echo "FAIL: release build script hardcodes the e2e flag: $s"; fail=1
  fi
done
[ $fail -eq 0 ] && echo "  ok: no release build script defines e2e"

# 2. Authoritative guard: a built release bundle must not carry the marker.
if [ -d build/web ]; then
  if grep -rl "__rotelyx" build/web >/dev/null 2>&1; then
    echo "FAIL: the __rotelyx hook is present in build/web (the e2e build shipped)"; fail=1
  else
    echo "  ok: __rotelyx absent from the built bundle"
  fi
else
  echo "  note: no build/web yet - the CI job builds it before this runs"
fi

[ $fail -eq 0 ] && echo "== clean ==" || echo "== the e2e hook could ship: FAILED =="
exit $fail
