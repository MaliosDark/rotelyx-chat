/// The shell: one place that owns which screen is showing.
///
/// No router. The app has five surfaces and a router would add a URL scheme
/// nobody asked for, and on web, deep links to a conversation would put a
/// conversation id in browser history, which is exactly the kind of trace this
/// application exists to not leave.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import '../platform/incoming_link.dart';
import '../rotelyx/invite_link.dart';

import '../rotelyx/alerts.dart';
import '../rotelyx/call_state.dart';
import '../rotelyx/calls.dart';
import '../rotelyx/lock.dart';
import '../rotelyx/rotelyx_store.dart';
import 'screens/home.dart';
import 'screens/pair.dart';
import 'screens/call.dart';
import 'screens/pin.dart';
import 'screens/settings.dart';
import 'screens/unlock.dart';
import 'brand.dart';
import 'theme.dart';
import 'widgets.dart';

enum _Surface { unlock, home, pair, settings }

class RotelyxApp extends StatefulWidget {
  const RotelyxApp({super.key});

  @override
  State<RotelyxApp> createState() => _RotelyxAppState();
}

class _RotelyxAppState extends State<RotelyxApp> with WidgetsBindingObserver {
  // Resolved at compile time, so a release build carries no way to skip the
  // unlock screen. Only for taking screenshots of a surface in isolation:
  //   flutter build web --dart-define=screen=home
  static const _forced = String.fromEnvironment('screen');

  _Surface _surface = switch (_forced) {
    'home' || 'chat' => _Surface.home,
    'pair' => _Surface.pair,
    'settings' => _Surface.settings,
    _ => _Surface.unlock,
  };
  bool _dark = true;
  Key _homeKey = UniqueKey();

  RotelyxTheme get _theme => _dark ? RotelyxTheme.dark : RotelyxTheme.light;

  StreamSubscription<CallState>? _callChanges;
  StreamSubscription<String>? _linkArrivals;

  /// An invitation that arrived from outside, waiting for the pairing screen.
  String? _arriving;

  @override
  void dispose() {
    unawaited(_callChanges?.cancel());
    unawaited(_linkArrivals?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Resumed means in front and interactive. Everything else, including the
  /// half second where a phone is being unlocked, counts as away: a
  /// notification that is not posted because the window technically existed is
  /// a message somebody never learns about.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    alerts.inForeground = state == AppLifecycleState.resumed;

    // Anything that is not on screen counts as leaving, and the grace period
    // below is what tells a file picker apart from a pocket.
    //
    // This used to watch for `hidden`, which reads better and is not delivered
    // on Android: the PIN was set, the phone was left for forty seconds, and it
    // came back to the same screen without asking. `inactive` is excluded on
    // purpose, because that is what a permission dialog produces while the
    // application is still very much in front of the person using it.
    if (lock.isSet &&
        !_locked &&
        state != AppLifecycleState.resumed &&
        state != AppLifecycleState.inactive) {
      _leftAt ??= DateTime.now();
    }

    if (state == AppLifecycleState.resumed && lock.isSet && !_locked) {
      final left = _leftAt;
      // A grace period, because choosing a photograph means leaving to another
      // activity and coming straight back, and a lock that fires on that is one
      // people switch off within a day.
      if (left != null &&
          DateTime.now().difference(left) > _grace) {
        setState(() => _locked = true);
      }
      _leftAt = null;
    }
  }

  /// Whether the PIN screen is covering everything.
  bool _locked = false;

  /// When the application was last put away, for the grace period above.
  DateTime? _leftAt;

  /// How long somebody may be away before the PIN is asked for again.
  ///
  /// Long enough to choose a photograph and come back, short enough that
  /// putting the phone down and walking off does not leave it open.
  static const _grace = Duration(seconds: 30);

  /// Take somebody to the pairing screen with an invitation already in it.
  ///
  /// It is not accepted here. The name field is still blank, and accepting on
  /// arrival would introduce this person to the other one as "anon" with no
  /// chance to say otherwise. The screen fills the field and waits.
  ///
  /// Nothing happens while the application is locked. A PIN that can be walked
  /// past by sending somebody a link is not a PIN, so the link is held and the
  /// unlock screen keeps the floor.
  void _openInvitation(String link) {
    final code = codeFromLink(link);
    if (code == null || code.isEmpty) return;
    if (!mounted) return;

    setState(() {
      _arriving = code;
      if (!_locked) _surface = _Surface.pair;
    });
  }

  @override
  void initState() {
    super.initState();

    // Locked at launch when a PIN is set, and locked again whenever the
    // application has been away. Not on every pause: a permission prompt and a
    // file picker both pause it, and demanding a PIN on the way back from
    // choosing a photograph is how people switch a lock off.
    _locked = lock.isSet;

    // Whether the application is in front, which is half of the decision about
    // whether to interrupt somebody. The other half is which conversation is
    // open, and the conversation screen reports that.
    WidgetsBinding.instance.addObserver(this);

    // Invitation links, from both directions: the one this launch was started
    // by, and any tapped while it is running. See platform/incoming_link.dart.
    _linkArrivals = incomingLinks.listen(_openInvitation);
    initialLink().then((link) {
      if (link != null) _openInvitation(link);
    });
    alerts.start();

    // A call has to appear over whatever is showing, including a locked screen
    // and including nothing. Watched here rather than in a screen, because a
    // screen that is not on cannot be the thing that decides to ring.
    calls.start();
    _callChanges = calls.changes.listen((_) {
      if (mounted) setState(() {});
    });

    // Decode the logo before the boot screen comes down, so no frame is ever
    // shown with a gap where it goes. See `warmBrand`.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) warmBrand(context);
    });

    if (_forced == 'chat') { store.create('screenshot-fixture').then((_) {
        _seedForScreenshot();
        // HomeScreen reads the store in initState, so it has to be rebuilt
        // rather than merely repainted.
        setState(() => _homeKey = UniqueKey());
      }); }
  }

  /// Screenshot fixture. Compiled out of any build that does not pass the
  /// define, so no release carries it.
  void _seedForScreenshot() {
    final now = DateTime.now();
    store.save(StoredConversation(
      id: 'screenshot',
      title: 'Ana',
      session: null,
      lastActivity: now,
      messages: [
        StoredMessage(text: 'In. That took one try.', mine: false, at: now.subtract(const Duration(minutes: 12)), author: 'Ana'),
        StoredMessage(text: 'Good. Let us compare the safety number before anything else.', mine: true, at: now.subtract(const Duration(minutes: 11))),
        StoredMessage(text: 'Calling you now, we read it out loud.', mine: false, at: now.subtract(const Duration(minutes: 10)), author: 'Ana'),
        StoredMessage(text: 'It matches. Go ahead.', mine: true, at: now.subtract(const Duration(minutes: 4))),
      ],
    ));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rotelyx',
      debugShowCheckedModeBanner: false,
      theme: _theme.material,

      // Touching anywhere that is not a field puts the keyboard away.
      //
      // # Why it is here and not on each screen
      //
      // Two screens had their own version of this and five did not, so whether
      // it worked depended on which one you were looking at. Here it wraps
      // every route, including the sheets and dialogs pushed above the home
      // one, which is why it is `builder` rather than a widget inside `home`.
      //
      // `translucent` so it sees the tap without swallowing it: a button under
      // this still gets pressed, because the deeper recogniser wins the arena.
      // `opaque` would put a sheet of glass over the whole application.
      //
      // `FocusManager.instance` rather than `FocusScope.of(context)` because
      // this context is above every route, and the focus that needs dropping
      // belongs to whichever route is on top.
      builder: (context, child) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: child,
      ),

      home: RotelyxThemeScope(
        theme: _theme,
        child: Scaffold(
          backgroundColor: _theme.backdrop,
          body: AnimatedSwitcher(
            duration: const Duration(milliseconds: 140),
            child: _current(),
          ),
        ),
      ),
    );
  }

  Widget _current() {
    // Over everything, including the PIN. Somebody whose phone is ringing
    // should be able to answer it without unlocking the application first, and
    // a call reveals nothing that the lock is protecting: no history, no
    // conversation, just who is calling.
    if (calls.state.isBusy || calls.state.phase == CallPhase.over) {
      return CallScreen(
        key: const ValueKey('call'),
        who: calls.who,
        state: calls.state,
        loop: calls.loop,
        because: calls.lastFailure,
        onAnswer: () => unawaited(calls.answer()),
        onEnd: calls.hangUp,
      );
    }

    // Before everything, including the passphrase screen. The PIN is what says
    // this phone is yours; the passphrase is what opens the history on it. In
    // that order, because somebody holding a phone they picked up should not
    // even see which conversations exist.
    if (_locked) {
      return PinScreen(
        key: const ValueKey('pin'),
        onOpened: () => setState(() => _locked = false),
      );
    }

    switch (_surface) {
      case _Surface.unlock:
        return UnlockScreen(
          key: const ValueKey('unlock'),
          onReady: () => setState(() => _surface = _Surface.home),
        );

      case _Surface.pair:
        return PairScreen(
          key: ValueKey('pair:${_arriving ?? ''}'),
          arriving: _arriving,
          onCancel: () => setState(() => _surface = _Surface.home),
          onDone: (_) => setState(() {
            // A new conversation changes the list, and the list is built once
            // in initState, so it is rebuilt rather than asked to refresh.
            _homeKey = UniqueKey();
            _surface = _Surface.home;
          }),
        );

      case _Surface.settings:
        return SettingsScreen(
          key: const ValueKey('settings'),
          dark: _dark,
          onTheme: (v) => setState(() => _dark = v),
          onClose: () => setState(() => _surface = _Surface.home),
          onWiped: () => setState(() {
            _homeKey = UniqueKey();
            _surface = _Surface.unlock;
          }),
        );

      case _Surface.home:
        return HomeScreen(
          key: _homeKey,
          onPair: () => setState(() => _surface = _Surface.pair),
          onSettings: () => setState(() => _surface = _Surface.settings),
        );
    }
  }
}

/// Skips the unlock screen when there is nothing stored and nothing to unlock.
bool get startsLocked => store.hasVault;
