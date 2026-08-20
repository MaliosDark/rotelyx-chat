/// The application starts.
///
/// # What it checks
///
/// That the application builds a frame without throwing. That is a low bar and
/// it is worth having: every screen behind it is covered by the tests that
/// exercise the rules, and the one thing those cannot catch is a widget tree
/// that will not assemble at all.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_storage/get_storage.dart';
import 'package:rotelyx_chat/ui/app.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();

    // `get_storage` asks `path_provider` where to write, and a plain VM test
    // has no platform to answer. A temporary directory is enough: nothing here
    // asserts on what reaches disk.
    final temporary = await Directory.systemTemp.createTemp('rotelyx-widget');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => temporary.path,
    );

    await GetStorage.init();
  });

  testWidgets('the application assembles a frame', (tester) async {
    // A phone, because that is what this is for and what the layout is written
    // against. The desktop width is a separate test below, and it found a real
    // overflow the first time it ran.
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const RotelyxApp());

    // One pump, not `pumpAndSettle`. The boot sequence decodes the brand
    // images, and `pumpAndSettle` waits for animations that a headless test
    // never finishes.
    await tester.pump();

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('it assembles at a desktop width too', (tester) async {
    // Added when the desktop targets were scaffolded, and it failed on the
    // first run: a row overflowed by 49 pixels at 800 by 600. That is the size
    // a small window actually is, and until there was a desktop build nothing
    // ever laid the application out at it.
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const RotelyxApp());
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('and in a window somebody has made narrow', (tester) async {
    tester.view.physicalSize = const Size(600, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const RotelyxApp());
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
