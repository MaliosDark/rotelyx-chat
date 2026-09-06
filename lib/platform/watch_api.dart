/// What a platform must provide to support a watch.
///
/// Mostly the watch asks and the phone answers, which is why there is so little
/// here. The two exceptions are the two things a wrist cannot find out by
/// asking: that a message has arrived, and that a pairing it started is done.
abstract interface class Watch {
  /// Begin answering the watch's questions. Safe to call twice.
  void listen();

  /// A message has just arrived. The watch is told rather than asked here,
  /// because a wrist that has to be raised to learn of a message is a wrist
  /// that learns of it too late.
  ///
  /// Nothing of the message travels. The watch is being told to look again, and
  /// what it then sees comes back through the ordinary questions.
  ///
  /// [silent] when the conversation is muted, which the wrist has to be told
  /// about because it is the wrist that decides whether to buzz. A muted
  /// conversation that still taps somebody's arm is not muted.
  void arrived({bool silent = false});

  /// A pairing the watch started has completed, so the screen showing the code
  /// can stop showing it. See `PlatformWatch` for why the phone is the one that
  /// did the handshake.
  void paired();
}

/// A platform with no watch. Every method is nothing, on purpose: a caller
/// should not have to ask which platform it is on before starting.
class NoWatch implements Watch {
  const NoWatch();

  @override
  void listen() {}

  @override
  void arrived({bool silent = false}) {}

  @override
  void paired() {}
}
