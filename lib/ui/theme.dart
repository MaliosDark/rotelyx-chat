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
  static const dFaint = Color(0xFF6A6779);

  // Light, derived
  static const lBackdrop = Color(0xFFFBFBFD);
  static const lSurface = Color(0xFFFFFFFF);
  static const lRaised = Color(0xFFF3F2F7);
  static const lLine = Color(0xFFE4E2EC);
  static const lText = Color(0xFF14120F);
  static const lMuted = Color(0xFF5F5C6B);
  static const lFaint = Color(0xFF8B8899);

  // Signals. Used sparingly: a screen where everything is coloured says nothing.
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

  ThemeData get material {
    final base = isDark ? ThemeData.dark() : ThemeData.light();

    // Applied at the theme, never per widget: CanvasKit renders nothing at all
    // for an unresolved font family, so a TextStyle that names none is an
    // invisible label rather than a slightly wrong one.
    const family = 'RotelyxSans';
    const fallback = <String>['RotelyxDevanagari', 'RotelyxArabic'];

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
              bodyColor: text, displayColor: text),
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
abstract final class Type {
  static const _f = 'RotelyxSans';
  static const _fb = <String>['RotelyxDevanagari', 'RotelyxArabic'];

  static const display = TextStyle(
      fontFamily: _f, fontFamilyFallback: _fb,
      fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: -0.4);

  static const title = TextStyle(
      fontFamily: _f, fontFamilyFallback: _fb,
      fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: -0.2);

  static const body = TextStyle(
      fontFamily: _f, fontFamilyFallback: _fb, fontSize: 15, height: 1.45);

  static const label = TextStyle(
      fontFamily: _f, fontFamilyFallback: _fb,
      fontSize: 13, fontWeight: FontWeight.w600);

  static const small = TextStyle(
      fontFamily: _f, fontFamilyFallback: _fb, fontSize: 12, height: 1.4);

  /// For the safety number and anything else read aloud digit by digit.
  static const numeric = TextStyle(
      fontFamily: _f, fontFamilyFallback: _fb,
      fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 2.0);
}
