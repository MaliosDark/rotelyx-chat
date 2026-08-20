#!/usr/bin/env bash
#
# Build the web client. Use this rather than `flutter build web` directly.
#
#   tool/dev/build-web.sh [extra flutter arguments]
#
# Three things have to be true of the output and only one of them is a flag.
#
# 1. `--no-web-resources-cdn`
#
#    Without it the bootstrap fetches the CanvasKit renderer from
#    `gstatic.com` on every page load, and the local copy that ships in the
#    output is simply not used. That is a third party in the request path of an
#    application whose entire claim is that it has none.
#
# 2. `--pwa-strategy=none`
#
#    Stops the generated service worker being written with real caching code.
#    It does not stop registration: `web/flutter_bootstrap.js` handles that.
#
# 3. The self-destructing service worker, installed after the build
#
#    `--pwa-strategy=none` writes an empty `flutter_service_worker.js` over
#    whatever is in `web/`, so the file cannot simply live there. It has to be
#    put back afterwards, which is the whole reason this script exists.
#
#    An empty worker would be enough to stop new caching, but only once it
#    activates, and a replacement worker waits for every tab to close first. A
#    browser holding a stale build would keep serving it until the user closed
#    the application entirely, which is precisely the state nobody diagnoses.
#    The real one in `web/flutter_service_worker.js` skips the wait, deletes
#    the caches, unregisters itself and reloads what it was controlling.
#
# Getting any of the three wrong produces a build that looks correct and is
# not, which is why they are here and not in anybody's shell history.

set -euo pipefail

cd "$(dirname "$0")/../.."

flutter build web --release --no-web-resources-cdn --pwa-strategy=none "$@"

# Work out where the build actually went, since callers pass -o.
out="build/web"
prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ] || [ "$prev" = "--output" ]; then out="$arg"; fi
  prev="$arg"
done

cp web/flutter_service_worker.js "$out/flutter_service_worker.js"

echo
echo "built $out"
echo "  canvaskit local:   $(grep -c 'useLocalCanvasKit":true' "$out/flutter_bootstrap.js" || true)"
# Comments are stripped first. The loader library defines a parameter of that
# name, and web/flutter_bootstrap.js quotes the very form it exists to avoid,
# so a plain grep counts two matches that are not calls.
echo "  registers worker:  $(grep -v '^[[:space:]]*//' "$out/flutter_bootstrap.js" | grep -c '_flutter.loader.load({' || true)  (0 is correct)"
echo "  worker self-erases: $(grep -c 'unregister' "$out/flutter_service_worker.js" || true)  (1 or more is correct)"
