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
    lookback: 2,
  );

  /// The sibling process from `docs/DEPLOYMENT.md`, for working offline.
  static const local = RotelyxConfig(
    mailbox: 'ws://127.0.0.1:3341/mailbox',
    relay: 'http://127.0.0.1:3340',
    lookback: 2,
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
  /// Covers a sender whose clock lags and a recipient who was offline across an
  /// hour boundary. Costs one extra lookup per bucket of slack.
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
