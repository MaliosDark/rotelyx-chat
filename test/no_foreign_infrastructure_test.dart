/// Fails the build if this client gains a way to contact anything but the mailbox.
///
/// Modelled on `crates/rotelyx-net/tests/no_foreign_infrastructure.rs` in the
/// protocol repository, and for the same reason: "contacts no third party" is a
/// claim that decays silently. A dependency adds a telemetry ping, someone
/// pastes a CDN link into `index.html` to fix a font, and nothing fails, the
/// app keeps working, and the property is quietly gone.
///
/// This scans the sources rather than the running app, so it catches a URL
/// before it can ever be requested.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Hosts this application is permitted to name.
///
/// Every entry needs a reason, because an allowlist nobody justifies becomes a
/// list of things somebody once wanted to allow.
const allowedHosts = <String, String>{
  'm1.telyx.me':
      'the blind mailbox: store and forward, never learns the sender, never '
          'sees plaintext',
  '127.0.0.1': 'the mailbox running locally during development',
  'localhost':
      'the same machine by its other name, in the development CSP that '
          'tool/dev/run-ui-test.sh installs. Never in a shipped build',
  'amber.telyx.me':
      'the relay calls are carried over. QUIC, so a browser cannot reach it: '
          'named in rotelyx_config.dart and in a comment there explaining why '
          'the web build does NOT use it',
  'your-server.example':
      'not contacted. Placeholder text in the field where somebody types their '
          'own mailbox, and `.example` is reserved by RFC 2606 precisely so it '
          'can never resolve to anybody',
  'example.com':
      'not contacted. It appears once, inside the sentence shown when somebody '
          'types an address that is not one, as the shape of an address',
  'rotelyx.com':
      'where invitation links point. The application never requests it: the '
          'link is built for somebody to send and the code rides in the '
          'fragment, which is not sent to any server. A phone with the '
          'application installed opens it directly through an App Link and '
          'makes no request at all',
};

/// Files that are not ours to police.
///
/// Generated output, which this test has no business policing.
bool _skip(String path) =>
    path.contains('/rotelyx/rotelyx_wasm.js') || // wasm-bindgen output
    path.contains('.dart_tool');

final _url = RegExp(r'(?:https?|wss?)://([A-Za-z0-9._-]+)');

void main() {
  test('the client names no host outside the allowlist', () {
    final root = Directory.current;
    final offenders = <String>[];

    // `tool/` is here because that is where this rotted. The mailbox moved
    // host and the shipped code moved with it, while a driver and a CSP-editing
    // sed in tool/ kept naming the old one: one connected to a host that no
    // longer answers, the other silently matched nothing and stopped doing its
    // job. Neither ships, and both are code that names a host, which is what
    // this test is for.
    final sources = [
      Directory('${root.path}/lib'),
      Directory('${root.path}/web'),
      Directory('${root.path}/tool'),
    ];

    for (final dir in sources) {
      if (!dir.existsSync()) continue;

      for (final entity in dir.listSync(recursive: true)) {
        if (entity is! File) continue;
        if (_skip(entity.path)) continue;
        if (!RegExp(r'\.(dart|html|js|json|sh|py)$').hasMatch(entity.path)) {
          continue;
        }

        final relative = entity.path.replaceFirst('${root.path}/', '');
        final lines = entity.readAsLinesSync();

        for (var i = 0; i < lines.length; i++) {
          for (final match in _url.allMatches(lines[i])) {
            final host = match.group(1)!;
            if (allowedHosts.containsKey(host)) continue;
            offenders.add('$relative:${i + 1} → $host');
          }
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'These sources name a host that is not on the allowlist. If the '
          'host is genuinely required, add it to `allowedHosts` with a reason. '
          'If it is not, this test just caught a third party being '
          'reintroduced:\n  ${offenders.join('\n  ')}',
    );
  });

  test('the mailbox is the only endpoint the configuration can point at', () {
    final config = File('${Directory.current.path}/lib/rotelyx/rotelyx_config.dart')
        .readAsStringSync();

    // The protocol repository enforces this structurally: no `Default`, no
    // constructor meaning "the library's defaults". A missing constructor is a
    // bug found at compile time; a wrong configuration value is one found in
    // production.
    expect(
      config.contains('RotelyxConfig()') && !config.contains('const RotelyxConfig({'),
      isFalse,
      reason: 'RotelyxConfig must not gain a zero-argument constructor: it '
          'would let a caller get endpoints without stating them.',
    );

    expect(
      RegExp(r'Platform\.environment|String\.fromEnvironment').hasMatch(config),
      isFalse,
      reason: 'Endpoints must not be overridable from the environment. An '
          'override is a way to repoint this client at a mailbox its user did '
          'not choose.',
    );
  });
}
