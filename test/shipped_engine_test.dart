/// The engine that ships must be the engine that was fixed.
///
/// # Why this test exists
///
/// An audit found the app shipping a WebAssembly module built three days before
/// the fix it depended on, and Android libraries built two days before it. The
/// Dart called the corrected API; the binaries did not implement it. Source and
/// artifact had drifted apart and nothing noticed, because every other test
/// runs against a library built on the spot from current source rather than
/// against the one in the tree.
///
/// The native library is a prebuilt binary committed here, and Gradle packages
/// it without compiling it, so a source change does not reach a phone until
/// somebody remembers to run the build script. This is that somebody.
///
/// # Why a version marker rather than a hash
///
/// A hash would have to be regenerated on every build and would fail for
/// reasons that have nothing to do with correctness. What is checked instead is
/// the one string that changes when the construction changes: the safety
/// number's domain separation context. It moved from v1 to v2 when the
/// fingerprint stopped being a hash of the group id, so an artifact still
/// carrying v1 is an artifact from before that fix, whatever its date says.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The context string the current engine derives its safety number under.
///
/// Raise this when the construction changes again, in the same commit that
/// changes it, and this test will refuse every artifact built before.
const expected = 'rotelyx conversation fingerprint v2';

/// And the one it must no longer contain.
const superseded = 'rotelyx conversation fingerprint v1';

/// Every compiled engine this repository ships.
const shipped = [
  'web/rotelyx/rotelyx_wasm_bg.wasm',
  'android/app/src/main/jniLibs/arm64-v8a/librotelyx_mobile.so',
  'android/app/src/main/jniLibs/armeabi-v7a/librotelyx_mobile.so',
  'android/app/src/main/jniLibs/x86_64/librotelyx_mobile.so',
];

bool _contains(List<int> haystack, String needle) {
  final n = needle.codeUnits;
  outer:
  for (var i = 0; i + n.length <= haystack.length; i++) {
    for (var j = 0; j < n.length; j++) {
      if (haystack[i + j] != n[j]) continue outer;
    }
    return true;
  }
  return false;
}

void main() {
  for (final path in shipped) {
    test('$path ships the current engine', () {
      final file = File(path);
      expect(file.existsSync(), isTrue,
          reason: '$path is missing. Run tool/native/build-android.sh, or '
              'rebuild rotelyx-wasm and copy it into web/rotelyx/.');

      final bytes = file.readAsBytesSync();

      expect(_contains(bytes, superseded), isFalse,
          reason: '$path was built before the safety number was fixed. It is '
              'the old engine and it ships to users. Rebuild it.');

      expect(_contains(bytes, expected), isTrue,
          reason: '$path does not carry $expected. Either it predates the '
              'current engine or the marker moved without this test moving '
              'with it.');
    });
  }
}
