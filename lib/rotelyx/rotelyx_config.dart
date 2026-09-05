/// Where Rotelyx Chat connects, and nowhere else.
///
/// There is deliberately no `Default` and no environment override. The comms
/// repository enforces the same rule structurally
/// (`crates/rotelyx-net/tests/no_foreign_infrastructure.rs`): a missing
/// constructor is a bug found at compile time, a wrong configuration value is a
/// bug found in production.
library;

class RotelyxConfig {
  const RotelyxConfig({
    required this.mailbox,
    required this.relay,
    required this.lookback,
  });

  /// Ideoa Labs production. The mailbox is store-and-forward for peers that are
  /// not both online; it never learns the sender and never sees plaintext.
  static const production = RotelyxConfig(
    mailbox: 'wss://m1.telyx.me/mailbox',
    relay: 'https://amber.telyx.me',
    lookback: 39,
  );

  /// The sibling process from `docs/DEPLOYMENT.md`, for working offline.
  static const local = RotelyxConfig(
    mailbox: 'ws://127.0.0.1:3341/mailbox',
    relay: 'http://127.0.0.1:3340',
    lookback: 39,
  );

  /// WebSocket URL of the blind mailbox.
  final String mailbox;

  /// Where a call is relayed through.
  ///
  /// Always relayed, and that is not a fallback for when a direct path fails.
  /// A direct path shows the other person this device's address, which on a
  /// call is the one thing worth hiding, so the media layer refuses to run on a
  /// connection that permits one.
  final String relay;

  /// How many earlier hour buckets to poll alongside the current one.
  ///
  /// # This is how long somebody can be offline
  ///
  /// A tag rotates every hour, and a message is deposited under the tag of the
  /// hour it was sent in. It can only be collected while the recipient is
  /// still asking for that hour, so this number is the whole answer to "how
  /// long can this phone be away before messages start being lost".
  ///
  /// It was two, which is three hours counting the current one. The mailbox
  /// holds an envelope for seven days, so a message sent to somebody whose
  /// phone was off overnight sat on the server, intact and paid for, with
  /// nobody left asking for it. Neither end was told: the sender saw it
  /// delivered to the mailbox and the recipient saw nothing at all.
  ///
  /// Thirty nine, so forty hours counting the current one. A night, a working
  /// day, and a margin.
  ///
  /// # Why not the seven days the envelope lives
  ///
  /// The set asked for is this window multiplied by the number of epochs whose
  /// tag keys are still held, which is three, and doubled again for a note to
  /// self, which listens on both halves. Seven days would be 168 buckets and
  /// therefore 1008 tags, against a server that takes 64 per request and 256
  /// per connection. Forty buckets is 120 tags in a conversation and 240 in a
  /// note to self, which is inside both with room left.
  ///
  /// Those limits are a defence rather than an arbitrary ceiling: a client
  /// asking for hundreds of tags is one enumerating them. Raising them to buy
  /// a longer window is a real trade and not a configuration change.
  final int lookback;
}

/// The configuration this build uses.
const rotelyxConfig = RotelyxConfig.production;

/// The relay at `amber.telyx.me` is **not** referenced here on purpose.
///
/// It forwards QUIC ciphertext for the native clients. The browser build has no
/// QUIC stack: `rotelyx-wasm` is layers 2 and 3 only, the message layer, so
/// every browser message travels through the mailbox. Adding a relay URL here
/// would imply a direct path this build cannot take.
const relayIsNativeOnly = true;
