/// A browser has no watch.
library;

import 'watch_api.dart';

export 'watch_api.dart';

class PlatformWatch implements Watch {
  const PlatformWatch();

  @override
  void listen() {}

  @override
  void arrived({bool silent = false}) {}

  @override
  void paired() {}
}
