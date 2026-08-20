/// Rotelyx, by Ideoa Labs
///
/// # What does not happen here
///
/// No Firebase, no analytics, no remote configuration, no account bootstrap.
/// The only network this application opens is the WebSocket to the mailbox
/// named in `lib/rotelyx/rotelyx_config.dart`, and `web/index.html` carries a
/// Content-Security-Policy that makes that structural rather than a promise.
///
/// Startup does the least it can: local storage, then the first frame. The wasm
/// module announces itself separately and the screens wait for it, rather than
/// the boot blocking on a two megabyte download and showing a grey page for as
/// long as the network takes.
library;

import 'package:flutter/material.dart';
import 'package:get_storage/get_storage.dart';

import 'platform/host.dart';
import 'platform/apple_push.dart';
import 'rotelyx/e2e.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  useCleanUrls();

  // On iOS the conversation log goes in the App Group container, so the
  // notification extension can see the same file. Null on every other platform
  // and on an iOS build without the App Group provisioned, in which case the
  // default is used, which is this application's own container.
  //
  // Constructed rather than `GetStorage.init()`, which takes a container name
  // and no path. `GetStorage` caches by container name, so building it here
  // with the path is what makes every later `GetStorage()` elsewhere in the
  // application hand back this one. Doing it in the other order gets a cached
  // instance pointing at the wrong directory, and the symptom is history that
  // silently stops being shared with the extension.
  await GetStorage('GetStorage', await sharedContainerPath()).initStorage;

  // Render failures as readable text rather than the release build's blank grey
  // box, which is indistinguishable from an app that never started.
  ErrorWidget.builder = (FlutterErrorDetails details) => Material(
        color: const Color(0xFF1C1B23),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: SingleChildScrollView(
            child: Text(
              details.exceptionAsString(),
              style: const TextStyle(
                  color: Color(0xFFF87171), fontSize: 13, fontFamily: 'RotelyxSans'),
            ),
          ),
        ),
      );

  // Publishes the real service as `window.__rotelyx` so a driver can exercise
  // the code the buttons call, rather than a JavaScript mirror of it. Compiled
  // out unless the build was given --dart-define=e2e=true. See e2e.dart.
  installE2eHook();

  runApp(const RotelyxApp());
}
