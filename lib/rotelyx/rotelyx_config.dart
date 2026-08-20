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
    required this.lookback,
  });

  /// Ideoa Labs production. The mailbox is store-and-forward for peers that are
  /// not both online; it never learns the sender and never sees plaintext.
  static const production = RotelyxConfig(
    mailbox: 'wss://mail-rotelyx.ideoa.co/mailbox',
    lookback: 2,
  );

  /// The sibling process from `docs/DEPLOYMENT.md`, for working offline.
  static const local = RotelyxConfig(
    mailbox: 'ws://127.0.0.1:3341/mailbox',
    lookback: 2,
  );

  /// WebSocket URL of the blind mailbox.
  final String mailbox;

  /// How many earlier hour buckets to poll alongside the current one.
  ///
  /// Covers a sender whose clock lags and a recipient who was offline across an
  /// hour boundary. Costs one extra lookup per bucket of slack.
  final int lookback;
}

/// The configuration this build uses.
const rotelyxConfig = RotelyxConfig.production;

/// The relay at `relay-rotelyx.ideoa.co` is **not** referenced here on purpose.
///
/// It forwards QUIC ciphertext for the native clients. The browser build has no
/// QUIC stack: `rotelyx-wasm` is layers 2 and 3 only, the message layer, so
/// every browser message travels through the mailbox. Adding a relay URL here
/// would imply a direct path this build cannot take.
const relayIsNativeOnly = true;
