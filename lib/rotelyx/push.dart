/// Waking a device that is not running.
///
/// # Why there is an abstraction rather than a call to FCM
///
/// Which service carries the wake signal is a platform detail: FCM on Play,
/// UnifiedPush on F-Droid, APNs on iOS, and APNs directly, since Firebase on
/// iOS is a wrapper around a call the server can make itself.
///
/// What is **not** a platform detail is how a token gets registered, and that
/// is the part that can quietly undo the mailbox's blindness. So the registrar
/// is the interface and the transport is the implementation, rather than the
/// other way round.
///
/// # The problem this interface exists to make hard to get wrong
///
/// A device token is stable for months. A mailbox tag rotates every hour,
/// precisely so two tags from one member cannot be linked without the group
/// key.
///
/// The obvious registration, "wake token Y when something lands for tag X",
/// puts both in one row. The operator then follows the stable token across
/// every rotation and re-links the whole sequence. On the wire the tags still
/// look unlinkable; the table beside them says otherwise. The adversary is
/// ADV-4, the mailbox operator, which is us.
///
/// # Why one token per tag does not fix it, although it sounds like it should
///
/// The batch scheme, a separate token per tag burned on use, is the right shape
/// for a transport that can mint tokens. **APNs cannot.** A device has one
/// token, and it is the same string in every row. Registering it a hundred
/// times against a hundred tags produces a hundred rows that all say the same
/// device, which links the tags together exactly as before. The scheme was
/// designed against the wrong constraint and it is written down here rather
/// than quietly dropped, because it reads as sound until you try to build it.
///
/// # What actually removes the linkage
///
/// **Stop binding the wake to arrival.** The mailbox wakes every registered
/// device on a fixed schedule, whether or not anything arrived for it. The
/// device wakes, collects from its own tags, and shows a notification only if
/// there was something.
///
/// The mailbox then stores a token and no tag beside it. There is nothing to
/// link, by construction rather than by policy, and Apple sees a heartbeat that
/// is identical for every user and carries no information about who was
/// messaged. That is better than what Signal does, which pushes on arrival and
/// therefore hands Apple the timing of every conversation.
///
/// It costs latency, up to the interval, and it costs the battery of wakes that
/// find nothing. Both are real, both are the user's to weigh, and the interval
/// is stated in Settings rather than buried.
///
/// See `docs/PUSH.md`.
library;

import '../platform/apple_push.dart';

/// A device that may be woken.
///
/// Deliberately carries **no tag**, and that is the whole design. See the
/// header of this file.
class PushGrant {
  const PushGrant({
    required this.token,
    required this.secret,
    this.kind = defaultKind,
    this.onSchedule = true,
  });

  /// The platform token to wake. Opaque here on purpose.
  final String token;

  /// What proves a later revocation came from this device.
  ///
  /// # Why a token cannot be its own credential
  ///
  /// The first version of this let a revocation name a token and nothing else,
  /// so anybody who learned a token could take that phone off the schedule.
  /// Nothing was disclosed by it, and it required already knowing a token, so
  /// it is a silencing rather than a leak. It is still the worse failure of the
  /// two: somebody whose notifications were switched off by a stranger goes on
  /// believing they are switched on.
  ///
  /// So a token is an address and an address is not a credential. This is made
  /// up here, kept on this device, and presented again to revoke. The mailbox
  /// stores only its hash, so a stolen registry file yields the power to be
  /// woken and not the power to silence.
  final String secret;

  /// Which service the mailbox calls to spend it.
  ///
  /// `apns` today, and the field exists so that adding UnifiedPush later is a
  /// value rather than a second table. Not `fcm`: on iOS, Firebase does not
  /// deliver anything itself, it relays to APNs, so using it would mean Apple
  /// sees the push and Google sees it too, in exchange for nothing.
  final String kind;

  /// The service a grant names when nothing says otherwise.
  ///
  /// Named rather than repeated as a literal, because a wake ticket has to
  /// name the same one: a ticket sealed as `fcm` and a registration made as
  /// `apns` are a device the notifier opens and then cannot deliver to, and
  /// nothing on either side would say so.
  static const defaultKind = 'apns';

  /// Whether this device wants the mailbox's schedule as well as its tickets.
  ///
  /// True is the mailbox's own answer for a client that says nothing, and it
  /// is the private one: every registered device woken on one rhythm is a
  /// device the push service cannot pick out of the others by when it is
  /// woken.
  ///
  /// False asks to be woken only when something arrives. That is immediate,
  /// and it costs the rhythm: this device's pushes become the times its
  /// correspondents send, blunted only by the decoys the notifier adds. On an
  /// iPhone it also stops the schedule's contentless wakes, which until Apple
  /// grants the filtering entitlement arrive as blank notifications.
  final bool onSchedule;
}

/// What a platform must provide to support waking.
abstract interface class PushTransport {
  /// A stable name for what is carrying the notification, shown in settings.
  ///
  /// Users deserve to know whether Google is in the path, and an app that hides
  /// which service it uses is making that choice for them.
  String get name;

  /// Ask the platform for a token, or null when the user declined or the
  /// platform has no push at all, which is the case on the web build, and is
  /// not an error.
  Future<String?> obtainToken();
}

/// Registers a device with the mailbox as wakeable.
abstract interface class PushRegistrar {
  /// Say "wake this device on the schedule". Nothing else is said.
  Future<void> register(PushGrant grant);

  /// Withdraw it.
  Future<void> revoke(String token);
}

/// The build has no push, and says so.
///
/// This is what the web target uses. FCM's web SDK loads from `gstatic.com`,
/// which the Content-Security-Policy refuses, correctly, since it would put
/// Google back in the page after the whole point of removing it. Waking a tab
/// that is not open is a mobile concern and belongs in the mobile build.
class NoPush implements PushTransport {
  const NoPush();

  @override
  String get name => 'none: this device is not woken from outside';

  @override
  Future<String?> obtainToken() async => null;
}

/// Waking an iPhone, through Apple and through nobody else.
///
/// # Why not Firebase, decided rather than assumed
///
/// Firebase cannot deliver to an iPhone. It relays to APNs, which means a push
/// sent through Firebase is seen by Apple, who was always going to see it, and
/// by Google, who was not. It also puts the Firebase SDK in the binary, which
/// registers an instance identifier with Google at launch and turns an App
/// Privacy answer of "Data Not Collected" into a list.
///
/// Calling APNs is less work, not more: the mailbox signs a JWT with a `.p8`
/// key and posts to `api.push.apple.com`. The application carries no SDK at
/// all, only the two calls the operating system already provides.
///
/// # What Apple learns anyway, stated plainly
///
/// That this device received a push, and when. There is no way around it on
/// iOS: the platform does not permit a background socket, so a device that is
/// not running can only be woken by Apple. The payload carries no content, and
/// timing is blurred by the decoy schedule described in `docs/PUSH.md`, but
/// the fact of a delivery reaches Apple. Android does not pay this, which is
/// why Android holds its own connection instead.
class ApnsPush implements PushTransport {
  const ApnsPush();

  @override
  String get name => 'Apple, directly. Not through Firebase';

  @override
  Future<String?> obtainToken() => applePushToken();
}

/// What this build uses.
///
/// Android is deliberately [NoPush]: it holds its own connection through a
/// foreground service and notifies itself, so there is no third party in the
/// path at all. See `android/.../ConnectionService.kt`.
final PushTransport pushTransport = pushForThisPlatform();
