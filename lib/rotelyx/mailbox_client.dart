/// Client for the blind mailbox.
///
/// The wire protocol is three frames out and five in:
///
///   out  {"op":"deposit","envelope":"<b64>"}
///        {"op":"subscribe","tags":["<hex>", ...]}
///        {"op":"unsubscribe","tags":["<hex>", ...]}
///
///   in   {"op":"ready","waiting":N}
///        {"op":"stored"}
///        {"op":"fannedOut","stored":N,"asked":N}
///        {"op":"envelope","envelope":"<b64>"}
///        {"op":"error","message":"..."}
///
/// `ready` is the reply to `subscribe`, not a greeting. The server says nothing
/// at all until the client speaks, and `waiting` counts the envelopes that were
/// already queued for those tags and have just been delivered. Reading it as a
/// connection banner produces a client that opens a socket and waits for a
/// frame that is never coming, which is what this one did: see [connect].
///
/// The mailbox never learns the sender and never sees plaintext. It does learn
/// which tags are polled together and when, which is inherent to store and
/// forward, and is why the tags rotate hourly and are unlinkable without the
/// group key.
///
/// The socket underneath comes from `lib/platform/socket.dart`, so this file
/// has no idea whether it is in a browser.
library;

import 'dart:async';
import 'dart:convert';

import 'push.dart';

import '../platform/socket.dart';

/// A frame the mailbox pushed to us.
class MailboxEnvelope {
  const MailboxEnvelope(this.envelope);
  final String envelope;
}

class MailboxClient {
  MailboxClient(this.url);

  final String url;

  TextSocket? _socket;
  final _envelopes = StreamController<MailboxEnvelope>.broadcast();
  final _errors = StreamController<String>.broadcast();

  /// Envelopes pushed by the mailbox, still sealed.
  Stream<MailboxEnvelope> get envelopes => _envelopes.stream;

  /// Errors the mailbox reported, and transport failures.
  Stream<String> get errors => _errors.stream;

  /// One event per envelope the mailbox accepted.
  ///
  /// This is the only delivery signal that exists, and it is worth being exact
  /// about what it means: the envelope is in the recipient's slot. Not that
  /// they collected it, and certainly not that they read it. A mailbox that
  /// could tell you either would be a mailbox that watches its users.
  Stream<int> get accepted => _accepted.stream;
  final _accepted = StreamController<int>.broadcast();

  /// One event per `subscribe` the mailbox confirmed, carrying the backlog it
  /// delivered just before confirming.
  Stream<int> get subscribed => _subscribed.stream;
  final _subscribed = StreamController<int>.broadcast();

  /// How often the mailbox will wake this device, in seconds.
  Stream<int> get wakeInterval => _wakeInterval.stream;
  final _wakeInterval = StreamController<int>.broadcast();

  bool get isOpen => _socket?.isOpen ?? false;

  /// Open the socket.
  ///
  /// # Why this does not wait for `ready`
  ///
  /// It used to, on the reasoning that frames sent between the connection and
  /// the first server frame would be dropped by a server that was not listening
  /// yet. The reasoning was sound and the premise was wrong.
  ///
  /// `ready` is the reply to `subscribe`. The mailbox sends nothing on
  /// connection, so a client that waits for a frame before sending one waits
  /// forever, and every attempt to pair failed fifteen seconds later with "the
  /// mailbox did not respond". Confirmed against the server: `Reply::Ready {
  /// waiting }` is returned from the subscribe handler in
  /// `rotelyx-mailbox-server/src/main.rs`, after the backlog is delivered.
  ///
  /// It survived because every end to end test drove `tool/e2e/pair.js`, which
  /// subscribes on open and therefore never met it. The client that shipped
  /// could not open a mailbox at all.
  Future<void> connect() async {
    final TextSocket socket;
    try {
      socket = await connectSocket(url);
    } on SocketRefused catch (e) {
      // Translated rather than propagated. `rotelyx_service.dart` distinguishes
      // "could not reach the mailbox" from every other failure when deciding
      // whether a pairing attempt is worth retrying, and it does that by type.
      // Letting the transport's own exception escape would slip past that catch
      // and surface as an unhandled error with no state change behind it.
      throw MailboxUnreachable(e.message);
    }
    _socket = socket;

    socket.messages.listen(_onFrame);
    socket.closed.listen((why) => _errors.add('mailbox connection $why'));
  }

  void _onFrame(String text) {
    final Map<String, dynamic> frame;
    try {
      frame = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      _errors.add('the mailbox sent a frame that is not JSON');
      return;
    }

    switch (frame['op']) {
      case 'ready':
        final waiting = frame['waiting'];
        if (waiting is int) _subscribed.add(waiting);
      case 'envelope':
        final envelope = frame['envelope'];
        if (envelope is String) _envelopes.add(MailboxEnvelope(envelope));
      case 'error':
        _errors.add('mailbox refused a frame: ${frame['message']}');
      case 'wakeRegistered':
        // How often this device will be woken, in seconds, as the mailbox
        // decided. Read rather than assumed so that Settings can state the
        // real interval instead of one the client hoped for.
        final every = frame['everySeconds'];
        if (every is int) _wakeInterval.add(every);
      case 'stored':
        _accepted.add(1);
      case 'fannedOut':
        // `stored` below `asked` means a recipient's slot was full. Reported
        // rather than hidden: a silently dropped recipient looks exactly like
        // someone who stopped replying.
        final stored = frame['stored'];
        if (stored is int) _accepted.add(stored);
    }
  }

  void deposit(String envelope) => _send({'op': 'deposit', 'envelope': envelope});

  void subscribe(List<String> tags) => _send({'op': 'subscribe', 'tags': tags});

  /// Stop listening on these tags.
  ///
  /// Collection removes an envelope, so a client still subscribed to a tag it
  /// has finished with eats traffic meant for somebody else. Unsubscribing from
  /// the rendezvous tag once a conversation exists is not tidiness.
  void unsubscribe(List<String> tags) => _send({'op': 'unsubscribe', 'tags': tags});

  /// Ask to be woken on the schedule.
  ///
  /// Carries a token and **no tag**, and the absence is the point. Binding a
  /// wake to a tag would put a stable device identifier in a row beside a tag
  /// that rotates hourly, and the operator could then follow the token across
  /// every rotation and re-link the sequence the rotation exists to separate.
  ///
  /// The mailbox therefore does not know which device is behind which tag. It
  /// wakes everybody on a fixed interval, each device collects from its own
  /// tags, and the ones with nothing waiting show nothing. See `push.dart` and
  /// `docs/PUSH.md`.
  void registerWake(PushGrant grant) => _send({
        'op': 'registerWake',
        'token': grant.token,
        'kind': grant.kind,
        'secret': grant.secret,
      });

  /// Stop being woken.
  ///
  /// Sent when the user switches notifications off. A token the mailbox still
  /// holds is a device it still wakes, spending its battery for a feature
  /// somebody turned off.
  ///
  /// Carries the secret and **not** the token. That is one fewer place a device
  /// token travels, and it makes the credential the only thing that can act:
  /// naming somebody else's token achieves nothing. See [PushGrant.secret].
  void revokeWake(String secret) => _send({'op': 'revokeWake', 'secret': secret});

  void _send(Map<String, Object?> frame) {
    final socket = _socket;
    if (socket == null || !socket.isOpen) {
      _errors.add('tried to send while the mailbox connection was closed');
      return;
    }
    socket.send(jsonEncode(frame));
  }

  Future<void> close() async {
    await _socket?.close();
    _socket = null;
    await _envelopes.close();
    await _errors.close();
    await _accepted.close();
    await _subscribed.close();
    await _wakeInterval.close();
  }
}

/// The mailbox could not be reached.
///
/// Kept as its own type because `rotelyx_service.dart` distinguishes "could not
/// connect" from "connected and something went wrong" when deciding whether a
/// pairing attempt is retryable.
class MailboxUnreachable implements Exception {
  const MailboxUnreachable(this.message);
  final String message;
  @override
  String toString() => message;
}
