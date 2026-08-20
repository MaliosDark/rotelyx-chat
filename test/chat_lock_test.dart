/// A locked conversation is sealed, not hidden.
///
/// # The one assertion that matters
///
/// `the vault key alone does not open it`. Everything else here is behaviour;
/// that one is the difference between a lock and a padlock painted on a
/// curtain. If it ever fails, somebody has made a locked conversation readable
/// to anything that can open the vault, which is what the person who set the
/// PIN believed they were preventing.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_storage/get_storage.dart';
import 'package:rotelyx_chat/rotelyx/rotelyx_store.dart';

StoredConversation conversation(String id, String text) => StoredConversation(
      id: id,
      title: 'Ana',
      session: null,
      lastActivity: DateTime(2026),
      messages: [
        StoredMessage(text: text, mine: false, at: DateTime(2026)),
      ],
    );

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final temporary = await Directory.systemTemp.createTemp('rotelyx-chatlock');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => temporary.path,
    );
    await GetStorage.init();
    await store.create('a passphrase nobody will guess');
  });

  test('a locked conversation is not readable without its PIN', () {
    store.save(conversation('one', 'the secret'));
    store.lockChat('one', '4821');

    expect(store.isLocked('one'), isTrue);
    expect(store.load('one'), isNotNull, reason: 'open in this run');

    // A restart, or the application being locked, closes it.
    store.lock();
    expect(store.unlock('a passphrase nobody will guess'), completion(isTrue));
  });

  test('the vault key alone does not open it', () async {
    // The assertion this file exists for.
    store.save(conversation('two', 'the other secret'));
    store.lockChat('two', '1234');

    store.lock();
    await store.unlock('a passphrase nobody will guess');

    // The vault is open. The conversation is not.
    expect(store.load('two'), isNull,
        reason: 'a locked conversation readable from the vault key alone is a '
            'padlock painted on a curtain');

    expect(store.openChat('two', '0000'), isFalse);
    expect(store.load('two'), isNull, reason: 'and a wrong PIN changes nothing');

    expect(store.openChat('two', '1234'), isTrue);
    final opened = store.load('two');
    expect(opened, isNotNull);
    expect(opened!.messages.first.text, 'the other secret');
  });

  test('a locked conversation is not written back unlocked by accident', () async {
    store.save(conversation('three', 'kept'));
    store.lockChat('three', '9999');
    final held = store.load('three')!;

    store.lock();
    await store.unlock('a passphrase nobody will guess');

    // Something saves it while it is shut. Refusing is right: writing it under
    // the vault key alone would quietly take the lock off.
    store.save(held);

    expect(store.load('three'), isNull);
    expect(store.openChat('three', '9999'), isTrue);
    expect(store.load('three')!.messages.first.text, 'kept');
  });

  test('taking the PIN off needs it to be open', () async {
    store.save(conversation('four', 'plain again'));
    store.lockChat('four', '5555');

    store.lock();
    await store.unlock('a passphrase nobody will guess');

    store.unlockChat('four');
    expect(store.isLocked('four'), isTrue, reason: 'it was not open');

    store.openChat('four', '5555');
    store.unlockChat('four');

    expect(store.isLocked('four'), isFalse);
    expect(store.load('four')!.messages.first.text, 'plain again');
  });

  test('locking the application closes every conversation', () async {
    store.save(conversation('five', 'shut'));
    store.lockChat('five', '7777');
    expect(store.load('five'), isNotNull);

    store.lock();
    await store.unlock('a passphrase nobody will guess');

    expect(store.load('five'), isNull,
        reason: 'a conversation left open after the vault shuts is one the '
            'vault did not shut');
  });

  test('what stays visible while it is locked, stated', () async {
    // Not a leak to be fixed: the row has to exist or nobody can find the
    // conversation to unlock it. Pinned here so it is a decision rather than
    // something somebody discovers.
    store.save(conversation('six', 'hidden'));
    store.lockChat('six', '3333');

    store.lock();
    await store.unlock('a passphrase nobody will guess');

    expect(store.conversationIds.contains('six'), isTrue,
        reason: 'the conversation is listed, and only its contents are shut');
    expect(store.load('six'), isNull);
  });

  test('the PIN is never stored', () async {
    store.save(conversation('seven', 'x'));
    store.lockChat('seven', 'a-memorable-pin');

    // Every value in the box, scanned. A PIN that appears anywhere is one a
    // stolen profile directory hands over.
    final everything = store.debugAllValues().map((v) => '$v').join(' ');
    expect(everything.contains('a-memorable-pin'), isFalse);
    expect(base64Encode(utf8.encode(everything)).contains('a-memorable-pin'),
        isFalse);
  });
}
