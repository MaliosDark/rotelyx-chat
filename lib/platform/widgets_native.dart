/// The widgets, fed from the application.
///
/// # Why the filtering happens here and not in the widget
///
/// A widget draws what is in the shared container and nothing else, so a
/// setting enforced at this end is a setting the widget cannot get wrong.
/// Choosing "nothing" does not mean a name is written and then hidden: it
/// means no name is written. What is refused never leaves the application.
///
/// # Why there are two of everything
///
/// A home screen sits behind the passcode: whoever is looking has already been
/// let in, and can open the application anyway. A lock screen is read by
/// whoever the phone is lying in front of, with no passcode, no face and no
/// intent. They are different amounts of public and the person sets them
/// separately.
library;

import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../rotelyx/rotelyx_store.dart';
import 'widgets_api.dart';

export 'widgets_api.dart';

const MethodChannel _channel = MethodChannel('rotelyx/widgets');
const MethodChannel _burn = MethodChannel('rotelyx/burn');

class PlatformWidgets implements Widgets {
  const PlatformWidgets();

  /// iOS only. Android widgets are a different mechanism and are not built
  /// here yet; announcing support for them by writing to a container nothing
  /// reads would be worse than not having them.
  bool get _wired => Platform.isIOS;

  @override
  void put({
    required int homeWaiting,
    required String homeWho,
    required int lockWaiting,
    required String lockWho,
  }) {
    if (!_wired) return;
    _channel.invokeMethod<void>('put', {
      'homeWaiting': homeWaiting,
      'homeWho': homeWho,
      'lockWaiting': lockWaiting,
      'lockWho': lockWho,
    }).catchError((_) {});
  }

  @override
  void burning({DateTime? burnsAt, int waiting = 1}) {
    if (!_wired) return;
    if (burnsAt == null) {
      _burn.invokeMethod<void>('hide').catchError((_) {});
      return;
    }
    _burn.invokeMethod<void>('show', {
      'burnsAt': burnsAt.millisecondsSinceEpoch,
      'waiting': waiting,
    }).catchError((_) {});
  }
}

/// Work out what each surface may show, and push it.
///
/// Called whenever the count could have moved: a message arriving, a
/// conversation being read, the settings changing.
void refreshWidgets() {
  const widgets = PlatformWidgets();

  final all = store.loadAll();
  final waiting = all.where((c) => c.hasUnread).toList()
    ..sort((a, b) => b.lastActivity.compareTo(a.lastActivity));

  int count(FaceDetail detail) =>
      detail == FaceDetail.nothing ? 0 : waiting.length;

  String who(FaceDetail detail) => detail == FaceDetail.name
      ? (waiting.isEmpty ? '' : waiting.first.displayTitle)
      : '';

  final home = store.homeWidgetDetail;
  final lock = store.lockWidgetDetail;

  widgets.put(
    homeWaiting: count(home),
    homeWho: who(home),
    lockWaiting: count(lock),
    lockWho: who(lock),
  );

  _refreshBurning(widgets, all);
}

/// Put the soonest burning message on the lock screen, or take it off.
///
/// # Why this one is not behind a setting
///
/// Every other surface here is off until somebody turns it on, because every
/// other surface says something about who is talking to you. This says how long
/// is left and nothing else: no name, no conversation, not a word of the
/// message. It leaks less than the notification that already arrived.
///
/// And it is the one thing in this application with real urgency. A message you
/// do not read in time is not late, it is gone, and a countdown you had to know
/// to switch on is a countdown that is off for the person who needed it.
void _refreshBurning(Widgets widgets, List<StoredConversation> all) {
  final deadlines = <DateTime>[
    for (final c in all)
      for (final m in c.messages)
        if (!m.mine && !m.burnt && m.burnAt != null) m.burnAt!,
  ]..sort();

  if (deadlines.isEmpty) {
    widgets.burning();
    return;
  }

  // One countdown, not one per message. Two flames in the Dynamic Island is two
  // things fighting over a space the width of a thumbnail; the count says there
  // are several and the deadline is the soonest of them.
  widgets.burning(burnsAt: deadlines.first, waiting: deadlines.length);
}
