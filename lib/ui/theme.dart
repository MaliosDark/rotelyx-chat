/// The design system.
///
/// # The idea it is built on
///
/// Every other private messenger hides its cryptography, on the theory that it
/// frightens people. That is the right call when the crypto is the same as
/// everyone else's and the product is competing on being friendly.
///
/// Rotelyx has properties the mass-market apps do not: a post-quantum key
/// schedule, no account or directory of any kind, and calls that are relayed on
/// purpose so the person ringing you never learns your address. Hiding those is
/// giving away the only argument that distinguishes it.
///
/// So the surface shows them (the safety number, the epoch, the route a
/// message took) as ordinary furniture rather than as a security panel nobody
/// opens. The restraint is in the styling, not in what is said.
///
/// # Why dark is the base
///
/// Dark is the default in this category and reads as the serious option, so it
/// is designed first and light is derived from it rather than the other way
/// round, which is how light-first palettes end up with a washed out dark mode.
library;

import 'package:flutter/material.dart';

/// Brand and surface colours.
///
/// `accent` is the purple from `docs/brand/`. Everything else is a neutral
/// ramp: a messenger is mostly text on panels, and a second hue competing with
/// the accent makes the accent stop meaning anything.
abstract final class Tone {
  // Brand
  static const accent = Color(0xFF6A31EE);
  static const accentSoft = Color(0xFF8B5CF6);
  static const accentDim = Color(0x336A31EE);

  // Dark, designed first
  static const dBackdrop = Color(0xFF0B0A0F);
  static const dSurface = Color(0xFF141319);
  static const dRaised = Color(0xFF1C1B23);
  static const dLine = Color(0xFF2A2833);
  static const dText = Color(0xFFF2F1F5);
  static const dMuted = Color(0xFF9B98A8);
  // Lifted from 0xFF6A6779, which measured 3.11:1 against a raised card and
  // so failed AA for body text. This is 4.51:1 there and 5.23:1 on the
  // backdrop, with the hue moved two degrees so it stays the violet grey the
  // rest of the palette is built on rather than becoming a stock grey.
  static const dFaint = Color(0xFF848197);

  // Light, derived
  static const lBackdrop = Color(0xFFFBFBFD);
  static const lSurface = Color(0xFFFFFFFF);
  static const lRaised = Color(0xFFF3F2F7);
  static const lLine = Color(0xFFE4E2EC);
  static const lText = Color(0xFF14120F);
  static const lMuted = Color(0xFF5F5C6B);
  static const lFaint = Color(0xFF8B8899);

  // Signals. Used sparingly: a screen where everything is coloured says nothing.
  /// The burn. Not a second accent: it belongs to one event and appears
  /// nowhere else, which is what keeps it meaning something.
  static const fire = Color(0xFFFF7A18);

  static const good = Color(0xFF34D399);
  static const warn = Color(0xFFFBBF24);
  static const bad = Color(0xFFF87171);
}

/// One place for the values that repeat, so spacing stays on a rhythm instead
/// of drifting a pixel at a time.
abstract final class Metrics {
  static const gap = 8.0;
  static const pad = 16.0;
  static const wide = 24.0;

  static const radius = 14.0;
  static const bubble = 18.0;
  static const pill = 999.0;

  /// Below this the two panes collapse into one.
  static const compact = 900.0;
}

class RotelyxTheme {
  const RotelyxTheme({
    required this.backdrop,
    required this.surface,
    required this.raised,
    required this.line,
    required this.text,
    required this.muted,
    required this.faint,
    required this.isDark,
  });

  final Color backdrop, surface, raised, line, text, muted, faint;
  final bool isDark;

  static const dark = RotelyxTheme(
    backdrop: Tone.dBackdrop,
    surface: Tone.dSurface,
    raised: Tone.dRaised,
    line: Tone.dLine,
    text: Tone.dText,
    muted: Tone.dMuted,
    faint: Tone.dFaint,
    isDark: true,
  );

  static const light = RotelyxTheme(
    backdrop: Tone.lBackdrop,
    surface: Tone.lSurface,
    raised: Tone.lRaised,
    line: Tone.lLine,
    text: Tone.lText,
    muted: Tone.lMuted,
    faint: Tone.lFaint,
    isDark: false,
  );

  /// The bubble a message of ours sits in. Accent-filled, because outgoing is
  /// the one thing that should be unmistakable at a glance.
  Color get mine => Tone.accent;
  Color get mineText => Colors.white;
  Color get theirs => raised;
  Color get theirsText => text;

  /// Every Material default lifted one step in weight.
  ///
  /// `.apply` changes the family and the colour but keeps the weights the
  /// Material baseline was drawn with, which are set for dark text on a light
  /// page. This interface is the other way round.
  static const _weights = TextTheme(
    displayLarge: TextStyle(fontWeight: FontWeight.w700),
    displayMedium: TextStyle(fontWeight: FontWeight.w700),
    displaySmall: TextStyle(fontWeight: FontWeight.w700),
    headlineLarge: TextStyle(fontWeight: FontWeight.w700),
    headlineMedium: TextStyle(fontWeight: FontWeight.w700),
    headlineSmall: TextStyle(fontWeight: FontWeight.w700),
    titleLarge: TextStyle(fontWeight: FontWeight.w700),
    titleMedium: TextStyle(fontWeight: FontWeight.w600),
    titleSmall: TextStyle(fontWeight: FontWeight.w600),
    bodyLarge: TextStyle(fontWeight: FontWeight.w500),
    bodyMedium: TextStyle(fontWeight: FontWeight.w500),
    bodySmall: TextStyle(fontWeight: FontWeight.w500),
    labelLarge: TextStyle(fontWeight: FontWeight.w600),
    labelMedium: TextStyle(fontWeight: FontWeight.w600),
    labelSmall: TextStyle(fontWeight: FontWeight.w600),
  );

  ThemeData get material {
    final base = isDark ? ThemeData.dark() : ThemeData.light();

    // Applied at the theme, never per widget: CanvasKit renders nothing at all
    // for an unresolved font family, so a TextStyle that names none is an
    // invisible label rather than a slightly wrong one.
    const family = 'RotelyxSans';
    const fallback = <String>['RotelyxWide', 'RotelyxDevanagari', 'RotelyxArabic'];

    return base.copyWith(
      scaffoldBackgroundColor: backdrop,
      canvasColor: surface,
      dividerColor: line,
      colorScheme: base.colorScheme.copyWith(
        primary: Tone.accent,
        secondary: Tone.accentSoft,
        surface: surface,
        error: Tone.bad,
      ),
      textTheme: base.textTheme
          .apply(fontFamily: family, fontFamilyFallback: fallback,
              bodyColor: text, displayColor: text)
          .merge(_weights),
      primaryTextTheme: base.primaryTextTheme
          .apply(fontFamily: family, fontFamilyFallback: fallback),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: Tone.accent,
        selectionColor: Tone.accentDim,
      ),
    );
  }
}

/// Type scale. Named for the job, not the size, so a change is one edit.
///
/// Manrope sets about seven percent narrower than the face it replaced, and
/// this is light text on a near black ground, where the strokes bloom and run
/// into each other. Both push the same way, so running text is tracked out
/// rather than in. Only the two largest sizes are tracked negative, which is
/// ordinary: tight fitting reads as deliberate at display size and as illegible
/// at reading size.
abstract final class Type {
  static const _f = 'RotelyxSans';
  static const _fb = <String>['RotelyxWide', 'RotelyxDevanagari', 'RotelyxArabic'];

  static const display = TextStyle(
      fontFamily: _f, fontFamilyFallback: _fb,
      fontSize: 29, fontWeight: FontWeight.w800, letterSpacing: -0.5,
      height: 1.12);

  static const title = TextStyle(
      fontFamily: _f, fontFamilyFallback: _fb,
      fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.2,
      height: 1.25);

  /// Medium rather than regular, because this is light text on a near black
  /// ground. A stroke that looks correct as black on white thins out when the
  /// polarity flips, and Manrope is a light face to begin with.
  static const body = TextStyle(
      fontFamily: _f, fontFamilyFallback: _fb,
      fontSize: 15.5, fontWeight: FontWeight.w500, height: 1.45,
      letterSpacing: 0.15);

  static const label = TextStyle(
      fontFamily: _f, fontFamilyFallback: _fb,
      fontSize: 13.5, fontWeight: FontWeight.w600, letterSpacing: 0.1);

  static const small = TextStyle(
      fontFamily: _f, fontFamilyFallback: _fb,
      fontSize: 12, fontWeight: FontWeight.w500, height: 1.4,
      letterSpacing: 0.2);

  /// For the safety number and anything else read aloud digit by digit.
  ///
  /// Tabular figures so the digits sit in a fixed column: two people comparing
  /// a number over a call need the same groups in the same places on both
  /// screens.
  static const numeric = TextStyle(
      fontFamily: _f, fontFamilyFallback: _fb,
      fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 2.0,
      fontFeatures: [FontFeature.tabularFigures()]);
}

/// Motion. Every duration in the interface comes from here.
///
/// Nothing runs longer than 400 ms. A messenger is opened dozens of times a
/// day, and a curve that reads as considered on the first open is the
/// application feeling slow by the thirtieth.
abstract final class Motion {
  /// A bubble arriving, a screen replacing another.
  static const enter = Duration(milliseconds: 300);
  static const enterCurve = Curves.easeOutCubic;

  /// A sheet rising from the thumb.
  static const sheet = Duration(milliseconds: 350);
  static const sheetCurve = Curves.easeOutCubic;

  /// Press feedback, which has to land before a person can notice waiting.
  static const press = Duration(milliseconds: 100);
  static const pressCurve = Curves.easeIn;

  /// Per item, on first paint only, never on an update.
  static const stagger = Duration(milliseconds: 50);

  /// A dialog taking focus.
  static const dialog = Duration(milliseconds: 200);
  static const dialogCurve = Curves.easeOutBack;

  /// The one place a longer curve reads as deliberate rather than sluggish.
  static const theme = Duration(milliseconds: 400);
  static const themeCurve = Curves.easeInOut;
}
