/// What a platform must provide to support home and lock screen widgets.
///
/// One method, because a widget never asks anything: it is drawn by a separate
/// process on a schedule the system owns, and what it shows has to be waiting
/// for it. This pushes.
abstract interface class Widgets {
  /// Put what each surface is allowed to show where its widget can read it.
  ///
  /// Two of everything, because a home screen and a lock screen are not the
  /// same question and the person sets them separately.
  void put({
    required int homeWaiting,
    required String homeWho,
    required int lockWaiting,
    required String lockWho,
  });

  /// Show that a message is counting down, or take the countdown away.
  ///
  /// [burnsAt] is the soonest deadline and [waiting] how many are running, or
  /// null when nothing is. A deadline rather than a duration, because the
  /// system moves the number itself and a phone that has been asleep should
  /// wake up already right rather than start counting from waking.
  void burning({DateTime? burnsAt, int waiting});
}

/// A platform with no widgets. Every method is nothing, on purpose.
class NoWidgets implements Widgets {
  const NoWidgets();

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
