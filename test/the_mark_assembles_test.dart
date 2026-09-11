/// The mark draws at every point between scattered and assembled.
///
/// # Why this is worth a test
///
/// It is drawn from three paths written out by hand from
/// `docs/brand/rotelyx-motion.svg`, and a painter that throws takes the first
/// screen of the application with it. A crash here is not a logo that looks
/// wrong, it is an application that does not open.
///
/// The shape itself is not asserted, because a test cannot tell a good mark
/// from a bad one and pinning pixels would fail on every deliberate change.
/// What is pinned is that it paints, at the ends and in between, and that it is
/// over quickly: this is seen on every launch, so its length is a promise.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/ui/splash.dart';

void main() {
  testWidgets('the mark paints from scattered to assembled', (tester) async {
    for (final t in [0.0, 0.05, 0.3, 0.62, 0.78, 0.99, 1.0]) {
      await tester.pumpWidget(
        MaterialApp(home: Center(child: RotelyxMark(t: t))),
      );
      expect(tester.takeException(), isNull,
          reason: 'the painter threw at t=$t, which is the first screen');
      expect(find.byType(RotelyxMark), findsOneWidget);
    }
  });

  testWidgets('it covers the screen and then gets out of the way',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Splash(child: Text('the conversation list', textDirection: TextDirection.ltr)),
      ),
    );

    // The screen underneath is built from the first frame. It is not waiting
    // for anything, which is the whole point: the mark is drawn over a running
    // application rather than in front of one that has not started.
    expect(find.text('the conversation list'), findsOneWidget);
    expect(find.byType(RotelyxMark), findsOneWidget);

    // And it is gone well before anybody would call the application slow.
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(RotelyxMark), findsNothing,
        reason: 'a mark that outstays its welcome is a slow application');
    expect(find.text('the conversation list'), findsOneWidget);
  });
}
