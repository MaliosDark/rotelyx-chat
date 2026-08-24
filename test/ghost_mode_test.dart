/// Ghost mode turned on part way through, which has to be a curtain and not a
/// fire.
///
/// The screen tells somebody that nothing is deleted, right as their history
/// disappears in front of them. That is a promise, and this is what holds the
/// application to it.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_storage/get_storage.dart';
import 'package:rotelyx_chat/rotelyx/rotelyx_store.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final temporary = await Directory.systemTemp.createTemp('rotelyx-ghost');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => temporary.path,
    );
    await GetStorage.init();
  });

  setUp(() async {
    store.wipe();
    await store.create('a password long enough to be accepted');
    store.save(StoredConversation(
      id: 'ana',
      title: 'Ana',
      session: null,
      lastActivity: DateTime.now(),
      messages: [
        StoredMessage(text: 'this was said before', mine: true,
            at: DateTime.now()),
      ],
    ));
  });

  test('the history comes off the screen', () {
    expect(store.load('ana')!.messages, hasLength(1));

    store.goDark();

    expect(store.isDark, isTrue);
    expect(store.load('ana')!.messages, isEmpty,
        reason: 'without the key those messages cannot be read, and showing '
            'them would mean they were never sealed in the first place');
  });

  test('but the conversation is still there, by name', () {
    store.goDark();

    // Dropping the names too would leave a list of strangers with no way to
    // tell which conversation is which.
    expect(store.load('ana')!.title, 'Ana');
    expect(store.conversationIds, contains('ana'));
  });

  test('nothing written while dark reaches the disk', () async {
    store.goDark();

    final c = store.load('ana')!;
    c.messages.add(StoredMessage(
        text: 'said while dark', mine: true, at: DateTime.now()));
    store.save(c);

    // Unlocking again is the test: if that message were written, it would be
    // sitting in the vault now.
    expect(await store.unlock('a password long enough to be accepted'), isTrue);
    final after = store.load('ana')!;
    expect(after.messages.map((m) => m.text), ['this was said before']);
  });

  test('and the password brings everything back, which is the promise', () async {
    store.goDark();
    expect(store.load('ana')!.messages, isEmpty);

    expect(await store.unlock('a password long enough to be accepted'), isTrue);

    final back = store.load('ana')!;
    expect(back.messages, hasLength(1));
    expect(back.messages.first.text, 'this was said before');
  });
}
