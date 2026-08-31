/// Client for the blind mailbox.
///
/// The frames this client sends, and the ones it acts on:
///
///   out  {"op":"deposit","envelope":"<b64>"}
///        {"op":"subscribe","tags":["<hex>", ...]}
///        {"op":"unsubscribe","tags":["<hex>", ...]}
///        {"op":"collected","digests":["<hex>", ...]}
///        {"op":"registerWake",...}  {"op":"revokeWake",...}
///
///   in   {"op":"ready","waiting":N}
///        {"op":"stored"}
///        {"op":"overquota","limit":N,"used":N,"tier":"..."}
///        {"op":"envelope","envelope":"<b64>"}
///        {"op":"error","message":"..."}
///        {"op":"wakeRegistered","everySeconds":N}
///
/// The server sends `dropped` and `tier` as well, and this client neither asks
/// for them nor acts on them. Counting the list is not the point: what matters
/// is that every reply saying a request **failed** has a case here. `overquota`
/// did not, so a refused deposit looked exactly like an accepted one.
///
/// **It was given one, spelled `overQuota`, and the server sends `overquota`.**
/// The server's enum is `rename_all = "lowercase"`, so a name that reads as two
/// words there arrives as one. The fix went in with the client's own spelling
/// and the bug it describes stayed live, and the test written to guard it fed
/// this client a string this client had produced. Ops are compared against what
/// the server sends now, and `default` below catches the next one.
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

import 'package:flutter/foundation.dart' show visibleForTesting;
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

  /// Feed one frame in, without a socket.
  ///
  /// Only ever called from `test/mailbox_replies_test.dart`. It exists because
  /// the defect this file carried was not in the parsing or the sending: it
  /// was a reply the switch had no case for, which is invisible to any test
  /// that drives the client through a real connection and only checks that
  /// messages arrive. What has to be checked is that a refusal is not silence.
  @visibleForTesting
  void handleFrameForTest(String text) => _onFrame(text);

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
      case 'overquota':
        // The allowance is spent and **the envelope was not stored**.
        //
        // Lowercase, because that is what the server sends. This read
        // `overQuota` for one whole release and therefore matched nothing.
        //
        // This had no case at all and no default, so a refused deposit was
        // indistinguishable from an accepted one and the message showed as
        // sent. It reaches the same channel as any other refusal, with the
        // numbers, because "try again later" is not actionable and "you have
        // used 64 of 64 MiB, it returns tomorrow" is.
        final used = frame['used'], limit = frame['limit'];
        final tier = frame['tier'] ?? 'free';
        if (used is int && limit is int) {
          _errors.add(
            'The $tier allowance is spent: ${(used / 1048576).round()} of '
            '${(limit / 1048576).round()} MiB used this period. That message '
            'was not sent. The allowance returns tomorrow.',
          );
        } else {
          _errors.add('The allowance is spent. That message was not sent.');
        }
      default:
        // An op this client does not know.
        //
        // Silence here is what let a misspelled `overQuota` sit through a
        // release: the frame fell through, a refused deposit looked accepted,
        // and nothing anywhere said a word. A name that arrives and matches
        // nothing is now visible rather than swallowed.
        //
        // Not an error to the person, because the server is free to add
        // replies this client has no use for, and telling somebody about
        // `dropped` would be noise. It goes where a developer looks.
        assert(() {
          // ignore: avoid_print
          print('mailbox: unhandled op ${frame['op']}');
          return true;
        }());
    }
  }

  /// Tell the mailbox these envelopes arrived, so it can stop holding them.
  ///
  /// Delivery peeks and removal waits for this. An envelope nobody
  /// acknowledges sits until its seven-day TTL, and a tag that fills at 256
  /// makes the server refuse further deposits: messages lost, and silently,
  /// because a refused deposit produces no error the sender can see.
  ///
  /// Send it **after** the envelope has been opened and written down, never on
  /// arrival. Not acknowledging costs re-delivery, which is recoverable and
  /// which MLS refuses as a replay so nothing is shown twice. Acknowledging
  /// something not yet stored loses it.
  ///
  /// The digest is not a capability: the server only honours one for a tag
  /// this connection is listening on, so naming somebody else's envelope does
  /// nothing.
  void collected(List<String> digests) {
    if (digests.isEmpty) return;
    _send({'op': 'collected', 'digests': digests});
  }

  void deposit(String envelope) => _send({'op': 'deposit', 'envelope': envelope});

  void subscribe(List<String> tags) => _send({'op': 'subscribe', 'tags': tags});

  /// Stop listening on these tags.
  ///
  /// A client still subscribed to a tag it has finished with is handed traffic
  /// meant for somebody else, and acknowledging any of it takes that envelope
  /// away from the reader it was for. Unsubscribing from the rendezvous tag
  /// once a conversation exists is not tidiness.
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
