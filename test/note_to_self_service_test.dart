/// Opening the conversation with yourself, through the service the screen uses.
///
/// # Why this exists
///
/// `note_to_self_test.dart` proves the engine can do it: a device paired with
/// itself is a real two member group and a note round trips. That was true, and
/// the feature still did not work, because the screen never asked the service
/// to found one. It checked for a sealed session first and gave up when it
/// found none, which is precisely the state a conversation that has never been
/// opened is in.
///
/// A test of the pieces is not a test of the path. This one starts where the
/// button starts.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_storage/get_storage.dart';
import 'package:rotelyx_chat/rotelyx/rotelyx_service.dart';
import 'package:rotelyx_chat/rotelyx/rotelyx_store.dart';
import 'package:rotelyx_chat/rotelyx/signal.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final temporary = await Directory.systemTemp.createTemp('rotelyx-self');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => temporary.path,
    );
    await GetStorage.init();
    await store.create('a password long enough to be accepted');
  });

  test('it founds itself on first open, with no mailbox to reach', () async {
    // No mailbox in a test, and that has to be survivable: notes are written
    // locally as they are sent, so the conversation works offline and starts
    // travelling once there is somewhere to travel to.
    final opened = await rotelyx.startNoteToSelf();

    expect(opened, isTrue);
    expect(rotelyx.state, RotelyxState.joined);
    expect(rotelyx.conversationId, RotelyxService.selfConversationId);
  });

  test('and the row the list shows exists once it is open', () {
    final c = store.load(RotelyxService.selfConversationId);

    expect(c, isNotNull,
        reason: 'the screen reads the transcript from the store, so with no '
            'row there it renders "this conversation could not be opened"');
    expect(c!.title, isNotEmpty);
  });

  test('a note written to it is kept', () {
    expect(rotelyx.send('remember to check the safety number'), isTrue);

    final c = store.load(RotelyxService.selfConversationId)!;
    expect(c.messages, hasLength(1));
    expect(c.messages.first.text, 'remember to check the safety number');
    expect(c.messages.first.mine, isTrue,
        reason: 'a note to yourself is yours, on both halves of it');
  });

  // --- who a read receipt is attributed to -----------------------------------
  //
  // Here rather than in `group_receipts_test.dart` because it needs the service
  // and therefore the store, and two files owning that at once fight over it on
  // disk.
  //
  // **And before the resume test below**, not after: a restored session refuses
  // to send until its rekey commit has been delivered, and nothing here
  // delivers one. Placed after it, `send` returns false and the failure reads
  // like a broken receipt rather than a session that is doing what it says.
  //
  // `group_receipts_test.dart` covers when the tick appears. This covers the
  // name that goes in, which is where the defect was: every member of a group
  // arrived under the conversation's own name, so the second receipt looked
  // like a repeat of the first and the tick never completed.

  test('a read receipt is recorded against its sender, not the conversation', () {
    expect(rotelyx.send('who read this'), isTrue);

    final id = rotelyx.conversationId!;
    final ours = store.load(id)!.messages.where((m) => m.mine).last;

    rotelyx.deliverSignalForTest(
      Signal.read(ours.at.add(const Duration(seconds: 1))),
      from: 'Beto',
    );

    final after = store.load(id)!.messages.where((m) => m.mine).last;
    expect(after.seenBy, ['Beto'],
        reason: 'the name kept must be the member MLS authenticated. Taken from '
            '`conversationName` instead, every member of a group arrives under '
            'one name and the tick never completes');
  });

  test('opening it again resumes rather than founding a second one', () async {
    final before = store.load(RotelyxService.selfConversationId)!.messages.length;

    expect(await rotelyx.startNoteToSelf(), isTrue);

    final after = store.load(RotelyxService.selfConversationId)!;
    expect(after.messages, hasLength(before),
        reason: 'founding again would replace the group and orphan everything '
            'written into the old one');
  });

}
