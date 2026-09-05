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

import 'package:rotelyx_chat/rotelyx/alerts.dart';
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

  /// Get past the unlock screen, however this run happens to arrive at it.
  ///
  /// Tests share one application and one store, so whichever test created a
  /// vault first leaves every later one already unlocked and looking at the
  /// conversation list. Tapping a choice that is not on screen fails with
  /// "found 0 widgets", which reads like the screen being broken rather than
  /// like the vault from three tests ago still being open.
  Future<void> enterApp(WidgetTester tester) async {
    await tester.pumpWidget(const RotelyxApp());
    await tester.pumpAndSettle();

    // First run of the suite: the choice, and the quickest way past it.
    final ghost = find.text('Ghost mode');
    if (ghost.evaluate().isNotEmpty) {
      await tester.tap(ghost);
      await tester.pumpAndSettle();
      return;
    }

    // A later run, after another test created a vault. The application now
    // asks for the password it was given rather than offering the choice.
    final unlock = find.text('Unlock');
    if (unlock.evaluate().isNotEmpty) {
      await tester.enterText(
          find.byType(TextField).first, 'integration-test-pass');
      await tester.tap(unlock);
      await until(tester, () => store.isUnlocked);
      await tester.pumpAndSettle();
    }
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

    // The brand is drawn rather than written, so there is no text to find: this
    // used to look for "Rotelyx" and failed every run once the wordmark became
    // an image.
    expect(find.text('Keep my chats'), findsOneWidget);
    expect(find.text('Ghost mode'), findsOneWidget);

    // The choice is what stays on the phone, and the screen has to say that
    // rather than only ask.
    expect(find.textContaining('end to end encrypted either way'),
        findsOneWidget);
  });

  testWidgets('a short passphrase is refused with a reason', (tester) async {
    await tester.pumpWidget(const RotelyxApp());
    await tester.pumpAndSettle();

    // The password field is behind the choice now, not on the first screen.
    await tester.tap(find.text('Keep my chats'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'short');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.textContaining('at least 8 characters'), findsWidgets);
    expect(store.isUnlocked, isFalse);
  });

  testWidgets('creating a vault unlocks storage and reaches the list',
      (tester) async {
    await tester.pumpWidget(const RotelyxApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Keep my chats'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'integration-test-pass');
    await tester.tap(find.text('Continue'));

    // Argon2id at 64 MiB is about a second, and that is the point of it.
    expect(await until(tester, () => store.isUnlocked), isTrue,
        reason: 'the vault was never created');

    await tester.pumpAndSettle();
    expect(find.text('New conversation'), findsOneWidget);
    expect(find.text('No conversations'), findsOneWidget);
  });

  testWidgets('skipping the vault still reaches the list', (tester) async {
    await enterApp(tester);

    expect(find.text('New conversation'), findsOneWidget);
  });

  testWidgets('pairing by phrase opens the mailbox and holds', (tester) async {
    await enterApp(tester);
    await until(tester, () => RotelyxWasm.isReady,
        budget: const Duration(seconds: 60));

    await tester.tap(find.text('New conversation'));
    await tester.pumpAndSettle();

    // The tab first, then both fields, because filling one before the tab
    // moves put the name somewhere that was not the name. `_attempt` refuses an
    // empty name on the screen rather than through the service, so the symptom
    // was the service sitting in `idle` with no error to report.
    await tester.tap(find.text('On a call'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'Ana');
    await tester.enterText(find.byType(TextField).last,
        'ui-test-${DateTime.now().millisecondsSinceEpoch}');
    await tester.pumpAndSettle();

    expect(find.text('Choose a name others will see.'), findsNothing,
        reason: 'the name went into the wrong field');

    await tester.tap(find.text('Wait here'));

    // Reaching `pairing` means the whole chain ran through the widgets: a
    // session in wasm, a rendezvous tag, a socket to production, and a
    // subscribe frame the mailbox accepted.
    final reached = await until(
        tester, () => rotelyx.state == RotelyxState.pairing,
        budget: const Duration(seconds: 60));

    expect(reached, isTrue,
        reason: 'never reached pairing; stuck in ${rotelyx.state}; '
            'last error: ${rotelyx.lastError}');
    expect(rotelyx.lastError, isNull);

    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Waiting at the meeting place'), findsOneWidget);
  });

  testWidgets('a short meeting phrase is refused by the wasm, visibly',
      (tester) async {
    await enterApp(tester);
    await until(tester, () => RotelyxWasm.isReady,
        budget: const Duration(seconds: 60));
    await tester.tap(find.text('New conversation'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'Ana');
    await tester.pumpAndSettle();

    await tester.tap(find.text('On a call'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'short');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Wait here'));
    await until(tester, () => rotelyx.state == RotelyxState.failed);
    await tester.pumpAndSettle();

    // A guessable phrase is enough to impersonate whoever it was meant for, so
    // the reason has to reach the screen rather than the console.
    expect(find.textContaining('8 characters'), findsWidgets);
  });

  testWidgets('a note to self opens and is connected', (tester) async {
    await enterApp(tester);
    await until(tester, () => RotelyxWasm.isReady,
        budget: const Duration(seconds: 60));

    // The switch the person had turned on, and the whole of the reason this
    // test exists. With it on the application asks the mailbox to wake it, a
    // mailbox started without a push key refuses, and that refusal used to
    // arrive on the error stream and fail the session outright. Everything
    // stopped: messages, notes to self and calls, permanently and with nothing
    // on screen saying why.
    store.stayConnected = true;
    alerts.start();

    await tester.tap(find.text('Write a note to myself'));
    await tester.pumpAndSettle();

    // Founded on first open rather than paired into existence, so reaching
    // `joined` is the whole of it: a session in the wasm, a socket to the
    // mailbox, and a subscribe the mailbox answered.
    final joined = await until(
        tester, () => rotelyx.state == RotelyxState.joined,
        budget: const Duration(seconds: 60));

    expect(joined, isTrue,
        reason: 'the note to self never joined; stuck in ${rotelyx.state}; '
            'last error: ${rotelyx.lastError}');

    await tester.pumpAndSettle();

    // The refusal that a mailbox with no push key used to cause, which failed
    // the session and left this screen unable to send anything.
    expect(find.text('This conversation is not connected.'), findsNothing);
  });
}
