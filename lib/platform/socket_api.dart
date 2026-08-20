/// What a text socket offers, stated once for both platforms.
library;

/// A connected socket carrying text frames.
abstract interface class TextSocket {
  /// Text frames as they arrive.
  Stream<String> get messages;

  /// One event when the socket ends, carrying why.
  Stream<String> get closed;

  bool get isOpen;

  void send(String text);

  Future<void> close();
}

/// The socket could not be opened, or was refused.
class SocketRefused implements Exception {
  const SocketRefused(this.message);
  final String message;
  @override
  String toString() => message;
}
