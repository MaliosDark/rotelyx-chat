/// Comparing the safety number, and what happens when it changes.
///
/// # Why this is worth a test file
///
/// An audit called pairing trust-on-first-use with verification offered but not
/// required, and it was right. What made it worth fixing rather than arguing
/// about is that the safety number only started meaning something on 26 August
/// 2026: before that it was a hash of the group id, fixed when a conversation
/// was created, so it could not change and recording it would have proved
/// nothing.
///
/// Now it moves when a member or a device is added, which is the case worth
/// catching, and these are the assertions that it is caught.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_storage/get_storage.dart';
import 'package:rotelyx_chat/rotelyx/rotelyx_store.dart';

StoredConversation conversation(String id, String text) => StoredConversation(
      id: id,
      title: 'Someone',
      session: 'a-sealed-session',
      messages: [
        StoredMessage(text: text, mine: true, at: DateTime.now()),
      ],
      lastActivity: DateTime.now(),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    final dir = Directory.systemTemp.createTempSync('rotelyx-verify');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
    await GetStorage.init();
    await store.create('a passphrase nobody will guess');
  });

  test('a conversation nobody compared is not stopped, only marked', () {
    store.save(conversation('fresh', 'hello'));

    expect(store.verificationOf('fresh', '11111 22222'), Verification.never);
  });

  test('comparing it records the digits, not a flag', () {
    store.save(conversation('compared', 'hello'));
    store.markVerified('compared', '11111 22222');

    expect(store.verificationOf('compared', '11111 22222'), Verification.matches);

    // The point of storing the number rather than a boolean: a different number
    // later is a different answer, and a flag could not tell.
    expect(store.verificationOf('compared', '33333 44444'), Verification.changed);
  });

  test('a changed number survives a restart', () async {
    store.save(conversation('kept', 'hello'));
    store.markVerified('kept', '11111 22222');

    store.lock();
    expect(await store.unlock('a passphrase nobody will guess'), isTrue);

    expect(store.verificationOf('kept', '33333 44444'), Verification.changed,
        reason: 'the trusted number was not kept across a restart, so the '
            'change it exists to catch would go unnoticed');
  });

  test('accepting a changed number trusts the new one and not the old', () {
    store.save(conversation('moved', 'hello'));
    store.markVerified('moved', '11111 22222');
    store.acceptChangedNumber('moved', '33333 44444');

    expect(store.verificationOf('moved', '33333 44444'), Verification.matches);
    expect(store.verificationOf('moved', '11111 22222'), Verification.changed,
        reason: 'the old number must not still be trusted');
  });

  test('a conversation with no number yet is never reported as changed', () {
    store.save(conversation('quiet', 'hello'));
    store.markVerified('quiet', '11111 22222');

    // Before the engine has one, `null` must not read as a change and set off
    // the interruption on every cold open.
    expect(store.verificationOf('quiet', null), Verification.never);
  });
}
