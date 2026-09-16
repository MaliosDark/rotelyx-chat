/// Where Rotelyx Chat connects, and nowhere else.
///
/// There is deliberately no `Default` and no environment override. The comms
/// repository enforces the same rule structurally
/// (`crates/rotelyx-net/tests/no_foreign_infrastructure.rs`): a missing
/// constructor is a bug found at compile time, a wrong configuration value is a
/// bug found in production.
library;

/// How long one addressing bucket lasts, in seconds.
///
/// # Why this is a constant and not four copies of a number
///
/// It was `/ 3600` written out in the terminal client, the desktop client, the
/// browser and here. Four copies of one number that have to agree exactly: a
/// client that disagrees derives a different address, deposits where nobody is
/// listening, and nothing anywhere raises an error. The envelope sits until it
/// expires. The Rust half is `TAG_BUCKET_SECONDS` in `rotelyx-mailbox`, and
/// these two are the pair that must not drift.
///
/// # Why an hour, and what a shorter one would cost
///
/// An address is a pseudonym for a recipient that lasts as long as the bucket,
/// so a shorter one gives an operator less material to build a profile from.
/// It is also the number that decides how long a phone can be offline and
/// still find its mail: a recipient looks under one address per bucket and a
/// subscription may carry 64 of them.
///
/// An hour with [RotelyxConfig.lookback] at 39 is forty addresses and forty
/// hours of grace. Ten minute buckets on the same budget of 64 give under
/// eleven hours, which is a phone that stops finding what arrived while its
/// owner was asleep. Every address also carries a wake ticket, so the count is
/// the number of seals performed on every reconnection too.
const int tagBucketSeconds = 3600;

class RotelyxConfig {
  const RotelyxConfig({
    required this.mailbox,
    required this.relay,
    required this.lookback,
    this.notifierKey,
    this.room,
    this.frontUrl,
    this.frontKey,
    this.constellation,
  });

  /// Ideoa Labs production. The mailbox is store-and-forward for peers that are
  /// not both online; it never learns the sender and never sees plaintext.
  static const production = RotelyxConfig(
    mailbox: 'wss://orvexa.telyx.me/mailbox',
    relay: 'https://amber.telyx.me',
    // Read from https://amber.telyx.me/room on 12 September 2026. It changes
    // only if the relay's identity file does.
    room:
        'eyJpZCI6IjBkZjQ4ZWU5M2QzZDAwZTFjNGJjMjRlYjA5ZTg4MTY1MjBhMWYwY2ZlOWFhMGNjY2I0M2Y2MTZmZjkyNWZjZGUiLCJhZGRycyI6W3siUmVsYXkiOiJodHRwczovL2FtYmVyLnRlbHl4Lm1lLyJ9XX0',
    lookback: 39,
    // The constellation: a conversation's mail is kept on two of these three,
    // chosen per address, so one going down loses nothing and no single
    // mailbox sees the whole. Compiled in for the same reason the mailbox list
    // is: a device that asked a server where its mailboxes are would hand that
    // server the address of every user and the hour they opened the app.
    constellation: '{"version":1,"replicas":2,"mailboxes":['
        '{"id":"orvexa","url":"wss://orvexa.telyx.me/mailbox",'
        '"front":"wss://orvexa.telyx.me",'
        '"frontKey":"IRaaG+kHAAeYEghyhABQ6mgimYLNCpmIjapWv8Rc+6GgNiA/OtiZoKW3oDCLLPoxhGd85dd827Yp6UWy0cg/7ridKop4hKUjcQnL1aaYXfAMeQQ9KcOtUDxhF4RelNe8kpVTayZav0MxGYI7avowAhwPSUZUD4W4SKVitPoZtkc+spNhiBepJ1A8xtdw2mK36qkFaQhcYMNQhszPxKlACGJaaVHMyHI9ZyAVkBwtGKRrLeHFC3lNO8PPTkk3EHeBY7ylXpwventWVLay3sgEKaSDudU5Fsd0kgQd29wRkOKTKZXAZeJsbeoMM3bCGzmIVEGQMDgg1gwjtpiWogKnIeQXvhGaTXhWVFhojcUFP5uykNFY94YPc0yOHrBnVXQZ48I2oVZi4VmPaWdNDDGc8gDCMdlGhNNKrEYgiwY4RQWmr/en5TQ674qDMJiUCbXLJ0UshZe4ImdLrFq7mdKEpFC3HdO5iLd4eHBr96rLQbqe+TfPyjhSmmarUdYZjhRdSEe020oT4+FrdMpwubkPAXs7nAMSsfx9MuUzeXUjnpBeQsdxmmwQvxXPcIMW6ieuV8pzuYUgTrK67wqRBvtxaBUwh3qWEKgikgDHIIVJOVGvB0hR+lQuM4IWcamiV+Mg2/bBIbFdIWQYN5d947sjzQlkg4N99MkNQQJIeEOstYhlA8tW30JV19UMoROpafOTkJBS0UI9dEUOY9wEUXLDJaMugDHG+iVwwYZuG4xnN4BVCvd282UcQ8lm8LBofIVZlLW9NHElX6IR98pN/YVmMpGF30dTi4ATjgBJYPNm8WZBpFo+20J52MN8E4m5TbtYEuB1EEEB+HwOSAtxXQyT/5Q6LaDCp0jDGxcg2bAPaymAyOtgf4IytMYzvZBl/rJ/YMyLtVyi59Uy/uoN+MBwXLZIJLhgmtYLc8siQLuqrmZxe6aNgtpCZftaiOMZwnQbaSUZmmuZXeuTVbURUMYBuNeLpEC8hEJmnSdMqBhhBppcKVwbztlb41RQMJu2WKhQNThoP/uuZscoi3ygY8KQZes+w7RkLbFb1CuklpaLKeIo42F2IDIfFnBgkwRCUPV/R8qGqCUWrMWCqTMh00KXPHYMAhVapFWRKdI6BQJ7QGlJahGPbkN7/6K5w/xk1ywPnxnLhSG3RzAL+PoGL4QIdoWgTiF4AqZKowhzo9UZdmJMk9e7akJVFXS58gun5NZ304RYbryJSeBKSTxLZdiSVPZOXNGiWDAy6mamyWpsDuhSJ1lUNISoyme3wVuuKaeL1uqLdayu1yCmovtcVhY+lIuk/oeaaeqSzyqYMpZvT1ecY2oK63RjjuOfZjRYTzF1jCl7SvOYNuEVgbOPYAsuY9ogqnMbTtmT+Sw5UUPATSWRqCyg7DhGosuCqDKnY+t9oqCILohR8QiwTUBKFPnO5VE8wqxKLbRob/Nq0ZQrYoFZu7Agw9aMC9VCuTiK9yYbFqUv/6lB+HoBBICtJshQmhUtgxcPIhlikSWcChGJ8lMm0/om/LHJizBg9ZcDLYIKAyRnV+0WygwRAN/Y5rszimxkorb1bIsWLtX8qFL2Yr3G6WN8V4G+k2EZHLo3q0h/wTRm0rhC5fO38MHUA4JgGw=="},'
        '{"id":"caelix","url":"wss://caelix.telyx.me/mailbox",'
        '"front":"wss://caelix.telyx.me",'
        '"frontKey":"eqV0jdamwCKc3Lm+8weKmSphs2i5ikwiGms1XheL3EafRoVJ/5GSwltP6oY01nyDU+kE9kV1kcRIcVK+UsE0vopS0obHkJmv46h97Lg6NwspULCON5O8LJWtJTFtP9CWeJmUToA7tsia4VawaJgHd1wX2jVr1NRE8LAXRUgt8vHDM1yfZ3hu5oHCSqswaHEUeVUUx6hxC1Vo8tEGzoubMVkDCrRRWTIIqVMGCaleqZmGavpaOoFeL/y46bmjjJphymqHuHxk8tRhF7yNsArLkaeVcGx87aXKiuOClxaKg7VS3QQYbahzTdfHA+F4gByPcjLOZAI8RYAM7JEWF0HDskzA/DRs1qIhckqafjgZVxbOKZZtYliNC+sToyJ0hUWaySYWaoiaOYhejsTBDJdW5gucp/impMgSv1MpGcwWWCcBIzpxgmSjUsV1xEWYQ8MjE+ixeKoxWghQDKWqFATFKciNQ2IV2Igix1cCBQIcbnMQFYDJfghY5HSKimw4e0WSVTav82W8hFVWwQQh2LJEbbZW1IxK5UwIXWW7vQh/I+wBxWFBhwhn2EZflOWrCfmZPPZabVx0DpOsOwaKShBV2/O1eSMAsSdgZfnB4DqUTdwlYvnAIcwf1uVDz8OYP6ZiZTi5qdKKAOR9+GrFOHtKUbUghZYeODc6+gp4tYKUUxq5z+Gp37Bbl4h+Iagtm2woDrpPwXFtTQWQy1anMSQ+0eiY1GCc/CBv4wY8fxIzpno3ORirHnlO6sHMfhEDejmWU8xQNTVlUakbpFSxhkqoIFNYvuMZoIa0SvB6zEos8YaA40u+10l4Hai16rydU5gXZPnNSYgYE8dd1KiBhDoyAWLG+/GE5nDGIVeWM3J1RHuhJFWQsnoP5oyeaXVhEjiChLZrwqqzLqKOvMCTTUXGg1wu5QxA7jB7oaVzDYoNoFrIfZx5weF7TXJSDfdibbSFt+nA6KQrz3GUJ8YxB8KREoPPEJq/4ZlMWaJnZsxcD0ED6esIhPlHmIkRcfPK62Vv3fdMKfSq/gKEtFpvcUvEG2VRJhx5McM3EjywNcEmD/si7RI8L1VgAzm/lys2w/VjMFeQOMq86GwnRXRQbtKjj4sgvsGiX0q8qfDNFQMgwmJivVFgCSIVGmEeFPzM0yG5tfUY4ac+GpSWRzO9L3idzUds3zIDPKtVOkwEjzOejOoed7CImtjBiPSgWjt4jaV309cUdcYsJSMpQUuxtxQH5VdMZoNXzuaHI3EtBlMzW+CERneZ9LuxPvm2nvmTDJu4RrB3XEOLuVCmNggILOAv1JYMv4KA86YRpGlt96VCYZYbMkFjuEkzlGC6YAfDUxJta0XE7AZnMxUrzCR5IUNuApJO6RSJVsFWvqEzTYW78AMANelpmvUUo1thNUrE54Nd3ktURDtNNDKxoUKkbYIOVLlgwRGMIjZXTTRXncVIhch4yJCfPkBoy7UPqKdtCHZPDUc9QimlpHpftTEvrwZHD1AsuptlTIZJM5hzEYOf2RHHpryXnBFH2BFmviLDaRK4/MiNbFGb5XWB6w4Dbqmbd88tOoHy9nGLF7ghwaQ6xVT8Y/PvaVqGQdk8sTHb00HhrmUqsIAcSabqz6BEEapOKQ=="},'
        '{"id":"nyxara","url":"wss://nyxara.telyx.me/mailbox",'
        '"front":"wss://nyxara.telyx.me",'
        '"frontKey":"QBDF22M1lodX4fc0BmpmMgO+znV1GIOCwssWsAcbwLbNmacq+6mTBfowjIsZ00oGncNMh4XKxdFcONPJcghRy3CK0lIDItgbbJivm5B4EtMHJgQyjVq9YveX6+B1igpivlkw2oQFy1tH2OpcIefNI4MLxiy+TpNfAILBKwKfx4IHIqNFwZa6XmZ3zPO6/eSR+olH+LhER/pEoRN3cAp4eum75YCTvpFLwIcEfjsAEEmT/5qEeFcHQkso0/FXu0ursbRxOLCgPnxsoJrNAMIhOBoVJAmOsPvHetRTFhQs81uFy5UBC4uwEodh/4cRMMWFXOWxeWJHJbEn3PJY4hs/9ZciU4y7HvxvRAoQcIaSF2yJnym4czAKTChSoVZ3yJCZNzLLC5Mnefa1YmCfK8dmWraGRzzKf1UamxSiqAlE/sTHZcUA4XRIYgoOdOckiPYiQustYIy4X2latOCp7me9U/YgJEgpWguGmiOueHabLNtGR9oMC7iR0ug9nYGlFJiZgWjKCDROkSIFerVbJothDjKAQtlJ1EtY7CC2d2QID7W9jLBozhh/27THFNjJ7fYM/AoW1aO48evMVLR2b/yvN3xSDctcsbVyiDQ8z6kDi5IE7MYTa9Qno4ZZgEYO/wBCV9uE1skFzhILo8nLlXOktsYNRxqt70w2LyQT76eRAB2tIBd4cbWOzyyz+Ct+FZm4+Xp4S+wD4Pk4sByl0jLGbLxQ00tIDyhFu/Brv3VgDoEOYdsKJRlnZkOjjuiCVjdzj8shY8os+xSslimabwx7BiugVfA7HmCM8xYNzSkLDNKjHqiyu7wDMBemXmRtA+G3TaWGVlWfEzQpRkrGSmE/hCdjApNxMQVxDUVZzimmJsxTw2EWKcC4q/qEQQtFonXB9OkAautgC5uFv2QK5iRm3IkPHgOlcHJ2UGmNfsJhBnNzY+NKzfeI5SAtRZzJqMxfe2YBk7hYnOEG/IKFRwQwqld6A0wIJeBzgxJfOdAcqwe5Y4EKxnp4WDVwK4B+SIxr6tbFrPApxScDa0WfxKoMNiVwTMiJAXZl7zIK/PtgE4TMaQoiX/iB+dh8CEFbOeRuMGyE4TRSW0ksCAhSHSqbqhcyjJttvzOKcEA4nwtSBZGR6LuP77e9KhkMQJiVEdSixjzGWGR0OppntlAYmoUBPDYg43ebYgQEX0gf9gl/gYV8THm/tYVAPTE8m9QFfxO6gVBSNBealgNh9UrOp6I6PTGMz/nKiHeEmrZEiNRWeFAtZmvGLiaYxwg5RiIyLncY+lFq8SW4Ptkp0qLERJeIvoC5tQeZrcA7dBkVLUSSBERWggNU6JYEFEPCFPgLfsFzLGtJyHaJZsPJzBBbPsclpnWv0xJqczA8opSNqKDPLQV/Y6qQfjmGnfRMDFWpI3lNdtkW17qLnNy98NnJq6o87Ja5jgCuANmBeyONpUwOZoZa8pC9dOaurFAP/dCy2ZvPMHoQCGGLLdIGqXEMMZtNYBtF7Myq6gskZbeB8wElFOUuizw3i0ihQ7VMMvRJNKspSZe5gU3oxvtVyU5Z9RPDcmQ4W3/BHDmZgixUtnT+qbuLf8L0Rbwrhb+eHPSGxvvYAM4dvECCrYFupm3RQ4kxdg=="}'
        ']}',
    notifierKey:
        'JQEdP4gaOPmrz1e+OgRs+jMc0ukVj5d29kYlxcF1/0kUkzErdLaTjKQwI0BM/unKLRiSymViUNR+bPi5jMSoEUA9z8NMF+Fl8cg5MPOaSmkwXLSS3Ax8uES2waeo8/kDv5mv1vBG22dWXCavxMsJiSOi3cEZeUO+PcMoiCMo20eAPzatSPa98sunWDvNi2UY1Sknz2NPzotiUAEGybA0a5I5C5obXSFtttwaH+ZZ0EyMPIi60BoAo/W6ruF7FgB9cOk7kZIxAekarJBqJYSKrVwc5BUXHkuCecqRduDJplW3p8oUTwo6VXUvFIGsLDcOmXVWUjoFbsSyV3JS1QIhmroORNhDFzc63oMKRZqHoKcj8Samrdhi7aIzl+M9X7V2K5IgZnsfpYMO+buwsOlVpaEa0CYxWJcg3umozEMm7pESWwUJLcN8J3Z4eCquEAVyNSldvZQeCoIn7VpF31vLuZgDK4xT3NhaTokrXJICYoNUE0zP4cOpE4o6//UBYFdSZIPCTnYiI5a0d8sD9jUFjAW4xyyilWQD/gIoR3INtLBhartBGQCfFCgXr+WTDQlBAENjYAs2e7OGYeiilLUD8WNvzFOYc7tDUUYbZoQaU/yQrtwopxeoLuxlXdNd4NeNX8a8GYFYLHdatpShbotKdDoZXuCom3lIlDuDS/AI+vmkcIQ5PYfFWeh+h1Vbj3BJMkyXXqnMHueQstOrfxYHObCPLYJROvNCh4kgt6J2dEO6BtMeqlgTeDrDKGi4OixMnTGfxoSIXwVgxGC6xOE+4HS9TxSRi3N7NQqOtFAE6SO8nmenn7s6TtJpYDFEouQcu4MOhWW8lBNOSwuq6amRuil709KJskYa3qskS4cR1rdDoDtRjLlwJHfKnCmmEuOmYrwwSDJLFTiphvm8iXCPC8RAAABr2IwLrHGPLAlIcgMP8rfJgKiKA8C9nqVwLrHJbrU2PjCD4yd5vxCGcjTMRlKj9ypFo1xuSpVIlvuyy/BUT5JoQ7ALQ6m5SJqj0ku3z3M3tSF7GyM4HtoTEeS3RMOb/iF8+fXFVyaQUvxH9wcN4QgG5TpqCUM6URINFYxkNCdvyWVRxtWfBKk1yfXBnehVNJlUkxyMjwFgZaOLJPoP6OM8C+JheJJSkeEQNrMHRhuZgbowzaXGmticjpvEN7pti7xiv7eJdddTuTyLeMGLDxOCOdg2E9o2rGPLCoqospRNPqOWa/udBfpqfozKSNmbniU/17J1cfA5gkxv2qYTfowpHjpshXt9s+rMEAMb5NxYUuQGo/Vq/vcAQBOrdHp9MwJJmeQ6UcUO1EhUmjeUgBVS0TtAXBtwvCoUuZNUm0l+EFcK/0IAQSzP4Htk3KWUtyEu7UVImIatYHrEBtyfmmlzqEtRdRwZW0JAyyw2qGeHP6OHOOBMDDbAV3RjcaR6k0akHftEGTPJx9NnFDBkYpFtDCMYcHVWzwlhWawIImt2W9A463UGwRmn6jZeTLNVMsyG9qUXK1OZyKyXdSEIw0A7hqdiWlO6fPGcIaupCM2phauHHfRwE7/ODDviPUStHkz2yns37wrBVeTSKAkILlUF21PZpo51xjL/gtO/h2xIc/c0HuQhfUmvoYPMaQ==',
  );

  /// The sibling process from `docs/DEPLOYMENT.md`, for working offline.
  static const local = RotelyxConfig(
    mailbox: 'ws://127.0.0.1:3341/mailbox',
    relay: 'http://127.0.0.1:3340',
    lookback: 39,
  );

  /// Where the relay's room answers, for group calls, or null where the relay
  /// runs none.
  ///
  /// # What it is
  ///
  /// An endpoint address like the one a phone prints for itself. A relay
  /// started with `--room` prints it once and serves it at `/room`, and it
  /// stays the same for as long as the relay keeps its identity file. Each
  /// participant in a call with more than two people dials this instead of
  /// each other, sends the relay one stream and receives everybody else's
  /// back. The relay cannot read any of it. Without this a call between more
  /// than two people does not exist: it is two of them hearing each other.
  ///
  /// # Why it is written here and not fetched
  ///
  /// The application contacts the mailbox and the relay and nothing else, and
  /// a test fails the build if any code names another host. Reading `/room`
  /// would be one more request to a host already on that list, which is fine,
  /// and it would be the first HTTP request this application makes, which is
  /// a platform split and a code path for a value that changes as often as
  /// the relay URL does. So it is configured beside the relay URL, and read
  /// from `/room` by whoever sets it.
  final String? room;

  /// A front to reach the mailbox through, or null to connect straight to it.
  ///
  /// When set, the whole device runs its conversations as sealed sessions
  /// inside one connection to this URL, so the mailbox sees sessions with no
  /// address and no way to group them. `frontKey` is the mailbox's public
  /// front key, base64, which the front serves at `/front-key`. Both null is
  /// the behaviour every build has had: one connection per conversation
  /// straight to the mailbox. See `docs/FRONT.md`.
  final String? frontUrl;
  final String? frontKey;

  /// The constellation this build talks to, or null for a single mailbox.
  ///
  /// The directory as JSON: the mailboxes and how many of them hold each
  /// address. When set, the device keeps every conversation on the two the
  /// address places it on rather than on one server, so a mailbox going down
  /// loses nothing and no single operator sees the whole of a conversation.
  ///
  /// Null is the behaviour every build before this had: one mailbox, the one
  /// named by [mailbox], which is the single-replica case of the same rule.
  /// [mailbox] is still where an invitation without a constellation points, and
  /// still the host this build is checked against.
  ///
  /// Compiled in rather than fetched, for the reason `mailboxes.dart` gives for
  /// the mailbox list: a device that asked a server which mailboxes to use
  /// would be telling that server the address of every user and when they
  /// opened the application. Changing the set costs a release, which is the
  /// right price for infrastructure.
  final String? constellation;

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
