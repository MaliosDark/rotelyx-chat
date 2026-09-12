/// A browser has no Apple to ask.
library;

import '../rotelyx/push.dart';

Future<String?> applePushToken() async => null;

/// A browser has one origin and one storage area. There is no second process
/// to share it with.
Future<String?> sharedContainerPath() async => null;

PushTransport pushForThisPlatform() => const NoPush();

/// A browser has no extension to tell, and no container to tell it in.
Future<void> publishListeningTags(String mailbox, List<String> tags) async {}

/// A browser has no extension, so there is nothing it did to report.
Future<LastWake?> lastWake() async => null;

/// Kept so the two sides of the conditional export offer the same names.
class LastWake {
  const LastWake({
    required this.at,
    required this.decoy,
    required this.waiting,
    required this.ending,
  });

  final DateTime at;
  final bool decoy;
  final int? waiting;
  final String ending;

  String get said => 'A wake happened.';

  bool get wasBlank => false;
}
