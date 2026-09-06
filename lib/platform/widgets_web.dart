/// A browser has no widgets.
library;

import 'widgets_api.dart';

export 'widgets_api.dart';

class PlatformWidgets implements Widgets {
  const PlatformWidgets();

  @override
  void put({
    required int homeWaiting,
    required String homeWho,
    required int lockWaiting,
    required String lockWho,
  }) {}

  @override
  void burning({DateTime? burnsAt, int waiting = 1}) {}
}

/// Nothing to refresh.
///
/// Named here as well as in the native half, and that is not decoration: the
/// callers say `refreshWidgets()` unconditionally, so the web build has to have
/// the name or it does not compile. A conditional export is only as good as the
/// two sides matching.
void refreshWidgets() {}
