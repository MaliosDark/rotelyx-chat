/// Revoking a member, and whether this client can do it at all.
///
/// # Why this file exists
///
/// The engine has had `Group::remove` for weeks, the browser and the desktop
/// could call it, and the phone could not: `removeMember` was on the wasm
/// surface and not on the C ABI, so the operation existed everywhere except
/// the one client that gets lost and stolen. Nothing failed, because nothing
/// asked. A capability missing from a client is invisible to every test that
/// only exercises what the client does.
///
/// So this checks the reachability rather than the cryptography, which
/// `rotelyx-crypto` already covers: that the path from a screen to a commit
/// exists on whatever engine this build runs, and that removal takes the one
/// handle it can safely take.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_storage/get_storage.dart';
import 'package:rotelyx_chat/rotelyx/rotelyx_wasm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    final dir = Directory.systemTemp.createTempSync('rotelyx-revoke');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
    await GetStorage.init();
  });

  test('the engine this build runs can revoke, and names members by key', () {
    final ana = RotelyxWasm.newSession('ana');
    final beto = RotelyxWasm.newSession('beto');
    ana.found();

    final package = beto.keyPackage();
    final invitation = ana.invite(package);
    beto.join(invitation.welcome, invitation.ratchetTree);

    // The labels are claims and two members may make the same one, so removal
    // cannot take a label. It takes the signature key, which is what MLS
    // authenticates, and `rosterDetail` is the only thing that carries it.
    final detail = jsonDecode(ana.rosterDetail()) as List;
    expect(detail, hasLength(2));

    final keys = [
      for (final m in detail.cast<Map<String, dynamic>>()) m['key'] as String,
    ];
    expect(keys.toSet(), hasLength(2),
        reason: 'two members must never share the handle removal takes');

    final betoKey = (detail.cast<Map<String, dynamic>>())
        .firstWhere((m) => m['label'] == 'beto')['key'] as String;

    // A commit, not a local setting. If this came back empty there would be
    // nothing to deliver and the removed device would go on reading.
    final commit = ana.removeMember(betoKey);
    expect(commit, isNotEmpty);

    expect(ana.memberCount, 1, reason: 'the remover moved to an epoch without them');

    ana.dispose();
    beto.dispose();
  });

  test('removing somebody who is not there is refused rather than pretended', () {
    final ana = RotelyxWasm.newSession('ana');
    ana.found();

    // A key belonging to nobody in this group. Reporting success here would be
    // the worst outcome: somebody told a device was revoked when it was not.
    const stranger = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
    expect(() => ana.removeMember(stranger), throwsA(anything));

    ana.dispose();
  });
}
