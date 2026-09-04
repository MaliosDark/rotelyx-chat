/// What "forgets when you close it" has to mean.
///
/// Without a passphrase there is no key, so nothing can be sealed and nothing
/// is written down. That is intended. What was not intended is that a
/// conversation vanished the instant it was created: `save` returned at its
/// first line and the conversation list read only from disk, so pairing
/// succeeded and left an empty screen behind.
///
/// It survived every check because the automated tests either unlock first or
/// never open the list. It took pairing a phone with a browser to see it.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_storage/get_storage.dart';
import 'package:rotelyx_chat/rotelyx/rotelyx_store.dart';

void main() {
  late Directory temporary;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();

    // `get_storage` asks `path_provider` where to write, and a plain VM test
    // has no platform to answer. Pointing it at a temporary directory is
    // enough: the assertions below are about what is *not* written.
    temporary = await Directory.systemTemp.createTemp('rotelyx-store-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => temporary.path,
    );

    await GetStorage.init();
  });

  // Nothing is torn down. `get_storage` writes asynchronously and keeps a
  // handle open, so deleting its directory makes a later write throw from
  // outside any `try` this test can put around it, which failed the suite about
  // one run in three with an error that pointed nowhere. The operating system
  // clears its own temporary directory.

  setUp(() {
    // Each test starts with nothing kept and nothing unlocked.
    store.wipe();
  });

  test('a conversation saved without a passphrase is still there this run', () {
    expect(store.isUnlocked, isFalse);

    store.save(StoredConversation(
      id: 'one',
      title: 'Ana',
      session: null,
      messages: [],
      lastActivity: DateTime.now(),
    ));

    expect(store.load('one')?.title, 'Ana');
    expect(store.loadAll().map((c) => c.id), contains('one'));
    expect(store.conversationIds, contains('one'));
  });

  /// The host has to still be listening where the phrase points.
  ///
  /// A host answers knocks for the life of a conversation, so somebody given
  /// the phrase can arrive days later. The tag that says where lived only in a
  /// field on the service, so closing the application ended it: the newcomer
  /// knocked, nobody was there, and the only thing that happened was the word
  /// "knocking" on their screen forever. Neither side was told.
  test('the meeting place a host answers at survives being written down', () {
    store.save(StoredConversation(
      id: 'one',
      title: 'Ana',
      session: null,
      messages: [],
      lastActivity: DateTime.now(),
      meetingTag: 'a1b2c3',
    ));

    expect(store.load('one')?.meetingTag, 'a1b2c3');
  });

  /// A guest never has one, and a conversation from before this was kept has
  /// none written down. Both have to load rather than throw.
  test('a conversation with no meeting place still loads', () {
    store.save(StoredConversation(
      id: 'two',
      title: 'Bea',
      session: null,
      messages: [],
      lastActivity: DateTime.now(),
    ));

    expect(store.load('two')?.title, 'Bea');
    expect(store.load('two')?.meetingTag, isNull);
  });

  test('remembering one later reaches the stored conversation', () {
    store.save(StoredConversation(
      id: 'three',
      title: 'Cira',
      session: null,
      messages: [],
      lastActivity: DateTime.now(),
    ));

    store.rememberMeetingTag('three', 'ddee11');
    expect(store.load('three')?.meetingTag, 'ddee11');
  });

  test('several are listed newest first', () {
    final now = DateTime.now();
    for (final entry in [('a', 3), ('b', 1), ('c', 2)]) {
      store.save(StoredConversation(
        id: entry.$1,
        title: entry.$1,
        session: null,
        messages: [],
        lastActivity: now.subtract(Duration(minutes: entry.$2)),
      ));
    }
    expect(store.loadAll().map((c) => c.id).toList(), ['b', 'c', 'a']);
  });

  test('locking forgets them, which is the whole promise', () {
    store.save(StoredConversation(
      id: 'one',
      title: 'Ana',
      session: null,
      messages: [],
      lastActivity: DateTime.now(),
    ));
    expect(store.loadAll(), isNotEmpty);

    store.lock();
    expect(store.loadAll(), isEmpty);
  });

  test('removing one takes it out of the list', () {
    store.save(StoredConversation(
      id: 'one',
      title: 'Ana',
      session: null,
      messages: [],
      lastActivity: DateTime.now(),
    ));
    store.remove('one');
    expect(store.load('one'), isNull);
    expect(store.loadAll(), isEmpty);
  });

  test('nothing reaches disk while there is no key', () {
    store.save(StoredConversation(
      id: 'one',
      title: 'Ana',
      session: null,
      messages: [],
      lastActivity: DateTime.now(),
    ));

    // The point of the mode. The conversation is readable now and there is no
    // sealed blob behind it, so there is nothing for a later passphrase, or
    // anybody with the device, to open.
    expect(store.sessionBlob('one'), isNull);
    expect(GetStorage().read('rotelyx.log.one'), isNull);
    expect(GetStorage().read('rotelyx.index'), isNull);
  });
}
