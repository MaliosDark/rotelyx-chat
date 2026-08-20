/// The PIN lock, and the difference between a lock and a curtain.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_storage/get_storage.dart';
import 'package:rotelyx_chat/rotelyx/lock.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();

    // The lock writes outside the vault on purpose: it is consulted on a screen
    // shown before a passphrase has been given. So it needs real storage, and a
    // temporary directory is real enough.
    final temporary = await Directory.systemTemp.createTemp('rotelyx-lock');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => temporary.path,
    );
    await GetStorage.init();
  });

  setUp(() => lock.setPin(''));

  test('the right PIN opens it and a wrong one does not', () {
    lock.setPin('482913');

    expect(lock.isSet, isTrue);
    expect(lock.check('000000'), isFalse);
    expect(lock.check('48291'), isFalse, reason: 'a prefix is not the PIN');
    expect(lock.check('482913'), isTrue);
  });

  test('a correct PIN forgives the attempts spent getting to it', () {
    lock.setPin('1234');

    lock.check('0000');
    lock.check('1111');
    expect(lock.attemptsLeft, maxAttempts - 2);

    lock.check('1234');
    expect(lock.attemptsLeft, maxAttempts,
        reason: 'somebody who mistypes twice and then succeeds has not used '
            'up their allowance');
  });

  test('the attempt count survives, because force quitting must not reset it', () {
    lock.setPin('1234');
    for (var i = 0; i < 3; i++) {
      lock.check('0000');
    }

    // The count lives in storage rather than in a field, so a process that is
    // killed and started again comes back to the same number. A limit that a
    // force quit defeats is decoration.
    expect(lock.attemptsLeft, maxAttempts - 3);
  });

  test('it stops answering after too many wrong tries', () {
    lock.setPin('1234');
    for (var i = 0; i < maxAttempts; i++) {
      lock.check('0000');
    }

    expect(lock.lockedOutFor, greaterThan(0));

    // Null rather than false, so the interface can say "too many attempts"
    // instead of claiming the right PIN was wrong.
    expect(lock.check('1234'), isNull,
        reason: 'not even the correct PIN is answered during a lockout');
  });

  test('removing it removes it', () {
    lock.setPin('1234');
    expect(lock.isSet, isTrue);

    lock.setPin('');
    expect(lock.isSet, isFalse);
    expect(lock.check('anything at all'), isTrue,
        reason: 'with no PIN set there is nothing to check against');
  });

  test('changing it invalidates the old one', () {
    lock.setPin('1234');
    lock.setPin('5678');

    expect(lock.check('1234'), isFalse);
    expect(lock.check('5678'), isTrue);
  });

  test('the limits are the ones the interface promises', () {
    // Asserted rather than trusted, because these three numbers are the whole
    // defence a four digit secret has and they are quoted to the user.
    expect(minPinLength, 4);
    expect(maxAttempts, 10);
    expect(lockoutSeconds, 300);
  });

  test('a lockout is long enough to matter and short enough to survive', () {
    // Ten attempts then five minutes means a full four digit search takes
    // about three and a half days of uninterrupted work, on top of whatever
    // the key derivation costs per guess.
    const rounds = 10000 / maxAttempts;
    const seconds = rounds * lockoutSeconds;
    expect(seconds / 3600, greaterThan(24),
        reason: 'a four digit PIN must not be exhaustible in an afternoon');

    // And not permanent. A person who mistypes their own PIN is far more
    // common than an attacker, and an app that wipes itself is one a pocket
    // can destroy.
    expect(lockoutSeconds, lessThan(3600));
  });
}
