#!/bin/sh
# Run the widget tests against a debug build.
#
# The shipped CSP names the mailbox in connect-src and nothing else, which is
# the point of it. A debug build also needs to reach the Dart VM service over
# ws://127.0.0.1:<random port>, and that is neither the mailbox nor 'self'
# because the port differs, so the tool waits forever for a connection the
# browser already refused.
#
# Rather than loosen what ships, this swaps in a development policy for the
# length of the run and puts the real one back, including on failure.
set -e

cd "$(dirname "$0")/../.."
INDEX=web/index.html
BACKUP=$(mktemp)

restore() { cp "$BACKUP" "$INDEX"; rm -f "$BACKUP"; echo "production CSP restored"; }
trap restore EXIT INT TERM

cp "$INDEX" "$BACKUP"

# Only connect-src changes, and only to add the loopback debug service.
sed -i "s|connect-src 'self' blob: data: wss://mail-rotelyx.ideoa.co;|connect-src 'self' blob: data: wss://mail-rotelyx.ideoa.co ws://127.0.0.1:* ws://localhost:*;|" "$INDEX"
echo "CSP de desarrollo instalada"

flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/ui_test.dart \
  -d chrome
