/// A browser has no Apple to ask.
library;

import '../rotelyx/push.dart';

Future<String?> applePushToken() async => null;

/// A browser has one origin and one storage area. There is no second process
/// to share it with.
Future<String?> sharedContainerPath() async => null;

PushTransport pushForThisPlatform() => const NoPush();
