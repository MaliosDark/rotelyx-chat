/// Drives the real widgets.
///
/// Everything else verified so far went through `tool/e2e/`, which drives
/// `window.rotelyx`, the same bridge the Dart calls, but not the Dart. That
/// proves the protocol and leaves the application untested: a screen that never
/// wires its button to the service would pass every one of those checks.
///
/// This taps the buttons.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:rotelyx_chat/rotelyx/rotelyx_service.dart';
import 'package:rotelyx_chat/rotelyx/rotelyx_store.dart';
import 'package:rotelyx_chat/rotelyx/rotelyx_wasm.dart';
import 'package:rotelyx_chat/ui/app.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Pumps until [ready] or the budget runs out.
  ///
  /// `pumpAndSettle` settles when animations stop, which happens long before a
  /// socket answers, so anything waiting on the network needs this instead.
  Future<bool> until(
    WidgetTester tester,
    bool Function() ready, {
    Duration budget = const Duration(seconds: 45),
  }) async {
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      if (ready()) return true;
      await tester.pump(const Duration(milliseconds: 200));
    }
    return ready();
  }

  testWidgets('the wasm module is reachable from the app', (tester) async {
    await tester.pumpWidget(const RotelyxApp());
    await tester.pumpAndSettle();

    expect(await until(tester, () => RotelyxWasm.isReady,
            budget: const Duration(seconds: 60)),
        isTrue,
        reason: 'window.rotelyx never came up');

    expect(RotelyxWasm.protocolVersion, startsWith('rotelyx/'));
    expect(RotelyxWasm.maxMembers, greaterThan(1));
  });

  testWidgets('the unlock screen offers both paths', (tester) async {
    await tester.pumpWidget(const RotelyxApp());
    await tester.pumpAndSettle();

    expect(find.text('Rotelyx'), findsWidgets);
    expect(find.text('Create vault'), findsOneWidget);
    expect(find.text('Continue without keeping anything'), findsOneWidget);

    // The passphrase is what turns on at-rest storage, so the screen has to say
    // what that changes rather than just ask for one.
    expect(find.textContaining('encrypted under that passphrase'), findsOneWidget);
  });

  testWidgets('a short passphrase is refused with a reason', (tester) async {
    await tester.pumpWidget(const RotelyxApp());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'short');
    await tester.tap(find.text('Create vault'));
    await tester.pumpAndSettle();

    expect(find.textContaining('At least 8 characters'), findsWidgets);
    expect(store.isUnlocked, isFalse);
  });

  testWidgets('creating a vault unlocks storage and reaches the list',
      (tester) async {
    await tester.pumpWidget(const RotelyxApp());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'integration-test-pass');
    await tester.tap(find.text('Create vault'));

    // Argon2id at 64 MiB is about a second, and that is the point of it.
    expect(await until(tester, () => store.isUnlocked), isTrue,
        reason: 'the vault was never created');

    await tester.pumpAndSettle();
    expect(find.text('New conversation'), findsOneWidget);
    expect(find.text('No conversations'), findsOneWidget);
  });

  testWidgets('skipping the vault still reaches the list', (tester) async {
    await tester.pumpWidget(const RotelyxApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Continue without keeping anything'));
    await tester.pumpAndSettle();

    expect(find.text('New conversation'), findsOneWidget);
  });

  testWidgets('pairing by phrase opens the mailbox and holds', (tester) async {
    await tester.pumpWidget(const RotelyxApp());
    await tester.pumpAndSettle();
    await until(tester, () => RotelyxWasm.isReady,
        budget: const Duration(seconds: 60));

    await tester.tap(find.text('Continue without keeping anything'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('New conversation'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Ana');
    await tester.enterText(fields.at(1), 'ui-test-${DateTime.now().millisecondsSinceEpoch}');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Wait here'));

    // Reaching `pairing` means the whole chain ran through the widgets: a
    // session in wasm, a rendezvous tag, a socket to production, and a
    // subscribe frame the mailbox accepted.
    final reached = await until(
        tester, () => rotelyx.state == RotelyxState.pairing,
        budget: const Duration(seconds: 60));

    expect(reached, isTrue,
        reason: 'never reached pairing; last error: ${rotelyx.lastError}');
    expect(rotelyx.lastError, isNull);

    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Waiting at the meeting place'), findsOneWidget);
  });

  testWidgets('a short meeting phrase is refused by the wasm, visibly',
      (tester) async {
    await tester.pumpWidget(const RotelyxApp());
    await tester.pumpAndSettle();
    await until(tester, () => RotelyxWasm.isReady,
        budget: const Duration(seconds: 60));

    await tester.tap(find.text('Continue without keeping anything'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New conversation'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Ana');
    await tester.enterText(fields.at(1), 'short');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Wait here'));
    await until(tester, () => rotelyx.state == RotelyxState.failed);
    await tester.pumpAndSettle();

    // A guessable phrase is enough to impersonate whoever it was meant for, so
    // the reason has to reach the screen rather than the console.
    expect(find.textContaining('8 characters'), findsWidgets);
  });
}
