/// Nothing reaches `dart:io` or `dart:ffi` except behind a compile time split.
///
/// # Why a test rather than care
///
/// This has now gone wrong three times, in three files, and every time it
/// compiled cleanly and failed in a browser at the moment somebody opened the
/// screen that asked:
///
///   * `calls.dart` imported the native transport directly, and the web build
///     stopped compiling at all.
///   * `call_audio.dart` read `Platform.isAndroid` for one line, and the chat
///     screen threw `Unsupported operation: Platform._operatingSystem` while
///     building its call button.
///   * `biometrics.dart` did the same, reachable from settings and the PIN
///     screen, and was found only by going looking for the second one's
///     siblings.
///
/// # What it actually checks
///
/// Not the file name. `engine/native.dart` uses `dart:ffi` and is perfectly
/// correct, because the only way anything reaches it is the conditional export
/// in `engine/backend.dart`. `engine/call_native.dart` is correct for the same
/// reason at one remove: only `native.dart` imports it.
///
/// So this walks the import graph. Every conditional export names a file for
/// the native side, and everything those reach transitively is allowed. Any
/// other file naming `dart:io` or `dart:ffi` is compiled into the web build,
/// and it is a crash waiting for whoever opens that screen in a browser.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The path a relative import resolves to, or null when it leaves `lib`.
String? resolve(String from, String relative) {
  final base = File(from).parent.uri;
  final target = base.resolve(relative).toFilePath();
  final normal = File(target).path;
  return normal.contains('/lib/') || normal.startsWith('lib/') ? normal : null;
}

void main() {
  final files = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  /// Everything the compile time split is allowed to reach.
  Set<String> nativeOnly() {
    final roots = <String>{};

    for (final f in files) {
      for (final line in f.readAsLinesSync()) {
        if (!line.contains('if (dart.library.js_interop)')) continue;

        // The first quoted path on a conditional line is the native side; the
        // second is what a browser gets instead.
        final quoted = RegExp("'([^']+\\.dart)'").allMatches(line).toList();
        if (quoted.isEmpty) continue;
        final target = resolve(f.path, quoted.first.group(1)!);
        if (target != null) roots.add(target);
      }
    }

    // And whatever those reach, at any depth.
    final seen = <String>{};
    final queue = [...roots];
    while (queue.isNotEmpty) {
      final path = queue.removeLast();
      if (!seen.add(path)) continue;

      final file = File(path);
      if (!file.existsSync()) continue;

      for (final line in file.readAsLinesSync()) {
        final match =
            RegExp("^\\s*(?:import|export)\\s+'([^':]+\\.dart)'").firstMatch(line);
        if (match == null) continue;
        final next = resolve(path, match.group(1)!);
        if (next != null && !seen.contains(next)) queue.add(next);
      }
    }
    return seen;
  }

  test('dart:io and dart:ffi stay behind the compile time split', () {
    final allowed = nativeOnly();
    expect(allowed, isNotEmpty,
        reason: 'no conditional export was found at all, so this test is '
            'looking at the wrong thing rather than passing');

    final offenders = <String>[];
    for (final f in files) {
      if (allowed.contains(f.path)) continue;

      for (final line in f.readAsLinesSync()) {
        final trimmed = line.trimLeft();
        if (!trimmed.startsWith('import ')) continue;
        if (trimmed.contains("'dart:io'") ||
            trimmed.contains("'dart:ffi'") ||
            trimmed.contains("'package:ffi/")) {
          offenders.add('${f.path}  ->  ${trimmed.trim()}');
        }
      }
    }

    expect(offenders, isEmpty,
        reason: 'these are compiled into the web build, where neither exists. '
            'Put what needs them behind a conditional export, the way '
            'platform/os.dart and rotelyx/engine/net_backend.dart do.');
  });

  test('every conditional export names two files that exist', () {
    final broken = <String>[];

    for (final f in files) {
      for (final line in f.readAsLinesSync()) {
        if (!line.contains('if (dart.library.js_interop)')) continue;

        final quoted = RegExp("'([^']+\\.dart)'").allMatches(line).toList();
        if (quoted.length < 2) {
          // The two halves are often split across two lines. Not a defect.
          continue;
        }
        for (final q in quoted) {
          final target = resolve(f.path, q.group(1)!);
          if (target != null && !File(target).existsSync()) {
            broken.add('${f.path} names ${q.group(1)} which is not there');
          }
        }
      }
    }

    expect(broken, isEmpty);
  });
}
