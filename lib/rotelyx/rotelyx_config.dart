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
    this.notifierKey,
  });

  /// Ideoa Labs production. The mailbox is store-and-forward for peers that are
  /// not both online; it never learns the sender and never sees plaintext.
  static const production = RotelyxConfig(
    mailbox: 'wss://m1.telyx.me/mailbox',
    relay: 'https://amber.telyx.me',
    lookback: 39,
    notifierKey:
        'JQEdP4gaOPmrz1e+OgRs+jMc0ukVj5d29kYlxcF1/0kUkzErdLaTjKQwI0BM/unKLRiSymViUNR+bPi5jMSoEUA9z8NMF+Fl8cg5MPOaSmkwXLSS3Ax8uES2waeo8/kDv5mv1vBG22dWXCavxMsJiSOi3cEZeUO+PcMoiCMo20eAPzatSPa98sunWDvNi2UY1Sknz2NPzotiUAEGybA0a5I5C5obXSFtttwaH+ZZ0EyMPIi60BoAo/W6ruF7FgB9cOk7kZIxAekarJBqJYSKrVwc5BUXHkuCecqRduDJplW3p8oUTwo6VXUvFIGsLDcOmXVWUjoFbsSyV3JS1QIhmroORNhDFzc63oMKRZqHoKcj8Samrdhi7aIzl+M9X7V2K5IgZnsfpYMO+buwsOlVpaEa0CYxWJcg3umozEMm7pESWwUJLcN8J3Z4eCquEAVyNSldvZQeCoIn7VpF31vLuZgDK4xT3NhaTokrXJICYoNUE0zP4cOpE4o6//UBYFdSZIPCTnYiI5a0d8sD9jUFjAW4xyyilWQD/gIoR3INtLBhartBGQCfFCgXr+WTDQlBAENjYAs2e7OGYeiilLUD8WNvzFOYc7tDUUYbZoQaU/yQrtwopxeoLuxlXdNd4NeNX8a8GYFYLHdatpShbotKdDoZXuCom3lIlDuDS/AI+vmkcIQ5PYfFWeh+h1Vbj3BJMkyXXqnMHueQstOrfxYHObCPLYJROvNCh4kgt6J2dEO6BtMeqlgTeDrDKGi4OixMnTGfxoSIXwVgxGC6xOE+4HS9TxSRi3N7NQqOtFAE6SO8nmenn7s6TtJpYDFEouQcu4MOhWW8lBNOSwuq6amRuil709KJskYa3qskS4cR1rdDoDtRjLlwJHfKnCmmEuOmYrwwSDJLFTiphvm8iXCPC8RAAABr2IwLrHGPLAlIcgMP8rfJgKiKA8C9nqVwLrHJbrU2PjCD4yd5vxCGcjTMRlKj9ypFo1xuSpVIlvuyy/BUT5JoQ7ALQ6m5SJqj0ku3z3M3tSF7GyM4HtoTEeS3RMOb/iF8+fXFVyaQUvxH9wcN4QgG5TpqCUM6URINFYxkNCdvyWVRxtWfBKk1yfXBnehVNJlUkxyMjwFgZaOLJPoP6OM8C+JheJJSkeEQNrMHRhuZgbowzaXGmticjpvEN7pti7xiv7eJdddTuTyLeMGLDxOCOdg2E9o2rGPLCoqospRNPqOWa/udBfpqfozKSNmbniU/17J1cfA5gkxv2qYTfowpHjpshXt9s+rMEAMb5NxYUuQGo/Vq/vcAQBOrdHp9MwJJmeQ6UcUO1EhUmjeUgBVS0TtAXBtwvCoUuZNUm0l+EFcK/0IAQSzP4Htk3KWUtyEu7UVImIatYHrEBtyfmmlzqEtRdRwZW0JAyyw2qGeHP6OHOOBMDDbAV3RjcaR6k0akHftEGTPJx9NnFDBkYpFtDCMYcHVWzwlhWawIImt2W9A463UGwRmn6jZeTLNVMsyG9qUXK1OZyKyXdSEIw0A7hqdiWlO6fPGcIaupCM2phauHHfRwE7/ODDviPUStHkz2yns37wrBVeTSKAkILlUF21PZpo51xjL/gtO/h2xIc/c0HuQhfUmvoYPMaQ==',
  );

  /// The sibling process from `docs/DEPLOYMENT.md`, for working offline.
  static const local = RotelyxConfig(
    mailbox: 'ws://127.0.0.1:3341/mailbox',
    relay: 'http://127.0.0.1:3340',
    lookback: 39,
  );

  /// The notifier's public key, base64, or null where there is none.
  ///
  /// # Why it is pinned here rather than asked for
  ///
  /// A wake ticket is this device's push token sealed to this key. The mailbox
  /// stores the result and hands it on without ever being able to read it,
  /// which is what lets a message wake a phone at once without anybody holding
  /// the link between the phone and the conversation.
  ///
  /// All of that rests on the key being the notifier's. A client that asked
  /// the mailbox which key to seal to would be asking the one party the
  /// sealing protects it from, and would be given whichever key that party
  /// preferred. So it lives in the build, like the relay does.
  ///
  /// Null means no ticket is left and nothing is immediate: the mailbox wakes
  /// devices on its schedule instead, which is what it did before tickets
  /// existed and remains a valid way to run.
  final String? notifierKey;

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
