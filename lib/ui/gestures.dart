/// Moving between screens with a thumb.
///
/// # Why this is one widget and not a `Navigator`
///
/// This application does not push routes. It has a handful of surfaces and one
/// piece of state that says which is showing, which is why a conversation
/// closing is a `setState` rather than a pop. That is a deliberate shape: a
/// route stack would mean the back button and the state could disagree, and on
/// a messenger the disagreement looks like a conversation that will not close.
///
/// So the gesture is a widget that reports a direction, and the screen decides
/// what that means. Nothing here knows what is behind it.
///
/// # Why the thresholds are what they are
///
/// A swipe has to be told apart from a scroll, from a drag on a message, and
/// from a thumb resting on the screen. Three things do that:
///
///   * It must start near the edge. A drag beginning in the middle of a list is
///     somebody scrolling, and treating it as navigation makes the list feel
///     like it is fighting back.
///   * It must be mostly horizontal. Measured as a ratio rather than an angle,
///     because a ratio does not need trigonometry to be read six months later.
///   * It must either travel far enough or move fast enough. Distance alone
///     ignores a quick flick, and speed alone fires on a twitch.
library;

import 'package:flutter/material.dart';

/// How close to the edge a navigating swipe has to begin, in pixels.
///
/// Wider than the system's own back gesture area on Android, which is about
/// twenty. This sits inside the application, so it only has to beat a list.
const double _edge = 44;

/// How far it has to travel, if it is not travelling quickly.
const double _distance = 90;

/// How fast it has to move, if it has not travelled far. Pixels per second.
const double _velocity = 420;

/// A swipe from the left edge, rightwards. The universal "go back".
class SwipeBack extends StatefulWidget {
  const SwipeBack({super.key, required this.child, required this.onBack});

  final Widget child;

  /// Null disables it, which is what the top-level screen wants: a gesture that
  /// does nothing still swallows the drag, and a dead zone at the edge of the
  /// screen is worse than no gesture.
  final VoidCallback? onBack;

  @override
  State<SwipeBack> createState() => _SwipeBackState();
}

class _SwipeBackState extends State<SwipeBack> {
  double _from = 0;
  double _travelled = 0;
  bool _watching = false;

  @override
  Widget build(BuildContext context) {
    if (widget.onBack == null) return widget.child;

    return GestureDetector(
      // Deferred to the child. A swipe that starts on a button should press
      // the button, and this only takes over once the drag is unambiguous.
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (details) {
        _from = details.globalPosition.dx;
        _travelled = 0;
        _watching = _from <= _edge;
      },
      onHorizontalDragUpdate: (details) {
        if (!_watching) return;
        _travelled += details.delta.dx;

        // Dragging back the other way cancels it. Somebody who changed their
        // mind halfway should not arrive anyway because they let go a pixel
        // past the threshold.
        if (_travelled < -12) _watching = false;
      },
      onHorizontalDragEnd: (details) {
        if (!_watching) return;
        _watching = false;

        final quick = details.velocity.pixelsPerSecond.dx > _velocity;
        if (_travelled > _distance || (quick && _travelled > 24)) {
          widget.onBack!();
        }
      },
      onHorizontalDragCancel: () => _watching = false,
      child: widget.child,
    );
  }
}

/// A pull down from the top of a list, to reach settings.
///
/// Separate from [SwipeBack] rather than one widget with a direction, because
/// the two answer different questions and combining them would mean a single
/// detector deciding between four outcomes on every drag.
class PullForSettings extends StatelessWidget {
  const PullForSettings({
    super.key,
    required this.child,
    required this.onReach,
  });

  final Widget child;
  final VoidCallback onReach;

  @override
  Widget build(BuildContext context) {
    return NotificationListener<OverscrollNotification>(
      // Overscroll rather than a drag detector, so this cannot fire while the
      // list still has somewhere to scroll. A gesture that steals a scroll is
      // one people learn to avoid rather than use.
      onNotification: (notification) {
        if (notification.overscroll < -22 &&
            notification.metrics.pixels <= 0) {
          onReach();
        }
        return false;
      },
      child: child,
    );
  }
}
