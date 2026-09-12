/// Blocking, which the App Store requires and which has to be real.
///
/// The requirement is a way to block an abusive user. What most messengers
/// can offer is receiving a message and not drawing it, because the address
/// it arrived at belongs to the account rather than to the sender. Here MLS
/// authenticates the sending leaf, so the member's own key is known before
/// anything is written down, and this pins that nothing from them gets past
/// that point.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_storage/get_storage.dart';
import 'package:rotelyx_chat/rotelyx/rotelyx_store.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final temporary = await Directory.systemTemp.createTemp('rotelyx-blocked');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => temporary.path,
    );
    await GetStorage.init();
    await store.create('a passphrase nobody will guess');
  });

  StoredConversation conversation(String id) {
    final c = StoredConversation(
      id: id,
      title: 'A conversation',
      session: '',
      messages: [],
      lastActivity: DateTime.now(),
    );
    store.save(c);
    return c;
  }

  test('a conversation starts with nobody blocked', () {
    final c = conversation('block-none');
    expect(c.blocked, isEmpty);
    expect(store.load('block-none')!.blocked, isEmpty);
  });

  test('a block survives being written down and read back', () {
    conversation('block-kept');
    final c = store.load('block-kept')!;
    c.blocked.add('a-members-key');
    store.save(c);

    expect(store.load('block-kept')!.blocked, ['a-members-key'],
        reason: 'a block that is forgotten on restart is not a block');
  });

  test('blocking is per conversation, because a key is per conversation', () {
    conversation('block-here');
    conversation('block-there');

    final here = store.load('block-here')!;
    here.blocked.add('same-looking-key');
    store.save(here);

    // No accounts means no person to block across conversations. The same
    // human in another conversation is another key, and saying otherwise
    // would be claiming a link this application does not have.
    expect(store.load('block-there')!.blocked, isEmpty);
  });

  test('a report is written down and kept', () {
    conversation('reports');
    final at = DateTime.fromMillisecondsSinceEpoch(1700000000000);

    store.recordReport('reports', reportedAt: at, reason: 'Spam', by: 'Ana');
    expect(store.load('reports')!.reports, hasLength(1));
    expect(store.load('reports')!.reports.first, contains('Spam'));
    expect(store.load('reports')!.reports.first, contains('Ana'));
  });

  test('the same report twice is one report', () {
    conversation('reports-twice');
    final at = DateTime.fromMillisecondsSinceEpoch(1700000000000);

    store.recordReport('reports-twice',
        reportedAt: at, reason: 'Spam', by: 'Ana');
    store.recordReport('reports-twice',
        reportedAt: at, reason: 'Spam', by: 'Ana');

    expect(store.load('reports-twice')!.reports, hasLength(1));
  });

  test('reports are bounded, because flooding them is the same abuse', () {
    conversation('reports-many');
    for (var i = 0; i < 80; i++) {
      store.recordReport('reports-many',
          reportedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000 + i),
          reason: 'Spam',
          by: 'Ana');
    }
    expect(store.load('reports-many')!.reports, hasLength(50));
  });

  test('a reason cannot forge the separator', () {
    conversation('reports-forged');
    store.recordReport('reports-forged',
        reportedAt: DateTime.fromMillisecondsSinceEpoch(1),
        reason: 'Spam|1700|Somebody else',
        by: 'Ana');

    final row = store.load('reports-forged')!.reports.first;
    expect(row.split('|'), hasLength(3),
        reason: 'a reason carrying the separator would invent fields');
  });

  test('clearing takes them all', () {
    conversation('reports-cleared');
    store.recordReport('reports-cleared',
        reportedAt: DateTime.fromMillisecondsSinceEpoch(1),
        reason: 'Spam',
        by: 'Ana');
    store.clearReports('reports-cleared');
    expect(store.load('reports-cleared')!.reports, isEmpty);
  });
}
