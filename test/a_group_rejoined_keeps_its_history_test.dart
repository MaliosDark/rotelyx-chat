/// Being welcomed back into a group you are already in.
///
/// # Why this exists
///
/// A device can fall out of a conversation without anybody doing anything
/// wrong: MLS applies commits in order, every envelope is sealed for one
/// member, and a commit that is missed cannot be resent by anyone. The device
/// then sits at its epoch reading noise while the group talks on, and the only
/// way back in is to be welcomed again.
///
/// The welcome makes a live session with the *same group id* -- a group id is
/// fixed when the group is founded and does not move when the epoch does, when
/// somebody joins, or when somebody is removed. Before this, joining again also
/// made a second row: the messages, the name, the picture and the mute setting
/// stayed in the first one and the conversation appeared twice with everything
/// in the wrong half. It happened for real, to five rooms at once.
///
/// So: the row is found by its group id and adopted. What is pinned here is
/// that the lookup works, that it is never fooled into merging two different
/// conversations, and that a group id once written is never quietly replaced.
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
    temporary = await Directory.systemTemp.createTemp('rotelyx-rejoin-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => temporary.path,
    );
    await GetStorage.init();
  });

  setUp(() => store.wipe());

  StoredConversation conversation(
    String id, {
    String? group,
    String title = 'The neighbours',
    List<StoredMessage>? messages,
  }) =>
      StoredConversation(
        id: id,
        groupId: group,
        title: title,
        session: null,
        messages: messages ?? [],
        lastActivity: DateTime.fromMillisecondsSinceEpoch(1757000000000),
      );

  test('the row for a group is found by the group, not by its name', () {
    store.save(conversation('1757000000000', group: 'aa11'));
    store.save(conversation('1757000000001', group: 'bb22', title: 'Work'));

    expect(store.idForGroup('aa11'), '1757000000000');
    expect(store.idForGroup('bb22'), '1757000000001');
  });

  test('a group this device has never been in is not somebody else', () {
    store.save(conversation('1757000000000', group: 'aa11'));

    // The pairing screen mints a new row when this is null. Returning any
    // existing row here would pour one conversation's messages into another.
    expect(store.idForGroup('cc33'), isNull);
    expect(store.idForGroup(''), isNull);
  });

  test('rejoining keeps what the old row held', () {
    final said = StoredMessage(
      text: 'before the split',
      mine: false,
      at: DateTime.fromMillisecondsSinceEpoch(1757000000000),
    );
    store.save(conversation(
      '1757000000000',
      group: 'aa11',
      title: 'The neighbours',
      messages: [said],
    )..muted = true);

    // What the pairing screen does when the welcome lands: ask which row this
    // group is, and use it instead of making one.
    final adopted = store.idForGroup('aa11');
    expect(adopted, isNotNull);

    final back = store.load(adopted!)!;
    expect(back.messages.single.text, 'before the split');
    expect(back.title, 'The neighbours');
    expect(back.muted, isTrue, reason: 'the settings are the same group’s');
    expect(store.conversationIds.length, 1, reason: 'no second row');
  });

  group('writing down which group a row is', () {
    test('a row written before the field had one gets it on the next open', () {
      store.save(conversation('1757000000000'));
      expect(store.load('1757000000000')!.groupId, isNull);

      store.rememberGroup('1757000000000', 'aa11');

      expect(store.load('1757000000000')!.groupId, 'aa11');
      expect(store.idForGroup('aa11'), '1757000000000');
    });

    test('one already written is never replaced by another', () {
      // Otherwise one row would start answering for a second conversation,
      // and the next rejoin would pour that one's messages in here.
      store.save(conversation('1757000000000', group: 'aa11'));

      store.rememberGroup('1757000000000', 'bb22');

      expect(store.load('1757000000000')!.groupId, 'aa11');
      expect(store.idForGroup('bb22'), isNull);
    });

    test('nothing is written for a row that is not there', () {
      store.rememberGroup('no-such-row', 'aa11');
      expect(store.idForGroup('aa11'), isNull);
    });
  });

  test('the group id survives being sealed and read back', () async {
    // The tests above run with nothing written down, where a conversation is
    // held in memory as the object that was handed over. This one unlocks, so
    // the row makes the whole trip: JSON, sealed, back off the disk.
    await store.create('a passphrase nobody will guess');
    store.save(conversation('1757000000000', group: 'aa11'));

    // Shut the vault and open it again, so the read below is a real read off
    // the disk rather than the object that was handed over.
    store.lock();
    expect(await store.unlock('a passphrase nobody will guess'), isTrue);

    expect(store.load('1757000000000')?.groupId, 'aa11');
    expect(store.idForGroup('aa11'), '1757000000000');
  });
}
