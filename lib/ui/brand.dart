/// The logo, and the QR code that carries it.
///
/// # The logo
///
/// There are two files, not one. The lockup is drawn in near-white with a
/// purple accent, which disappears on a light background, so `-dark` is the
/// version for dark surfaces and `-light` is its counterpart. Picking between
/// them from the current theme is the whole job, and doing it in one place is
/// why it is a widget rather than an `Image.asset` repeated on every screen.
///
/// # The logo inside the QR code
///
/// A QR code carries far more than the data it encodes. At the highest of the
/// four correction levels, close to a third of the symbol can be destroyed and
/// the payload still comes back intact, because Reed-Solomon reconstructs it.
/// That budget is what makes a logo in the middle possible: those modules are
/// not a hole in the data, they are damage the arithmetic repairs.
///
/// Two things make it safe rather than lucky:
///
///   * The correction level is fixed at the highest setting, not left to the
///     encoder's judgement.
///   * The plate is 24 percent of the symbol's width, so it covers under six
///     percent of its area, well inside the budget and nowhere near any of the
///     three corner squares a scanner needs to find the code at all.
///
/// And it is not taken on faith. `test/meeting_code_test.dart` builds the same
/// symbol, destroys exactly the square this widget draws over, photographs it
/// at an angle under poor light, and decodes it. That test fails if the plate
/// ever grows past what the code can carry.
library;

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../platform/host.dart';

import 'theme.dart';
import 'widgets.dart';

/// Every brand image, so they can be decoded before anything shows one.
const _brandImages = <String>[
  'assets/images/rotelyx-wordmark-dark.png',
  'assets/images/rotelyx-wordmark-light.png',
  'assets/images/rotelyx-lockup-dark.png',
  'assets/images/rotelyx-lockup-light.png',
  'assets/images/rotelyx-mark.png',
];

/// Decode the brand images, then tell the boot screen it may go.
///
/// # Why this exists
///
/// `Image.asset` decodes asynchronously, and the engine paints its first frame
/// as soon as the layout is known. So the first frame of the unlock screen has
/// a gap where the logo goes, and the logo arrives a moment later.
///
/// `web/boot.js` used to remove the boot screen on that first frame, which
/// uncovered exactly that gap. Since the boot screen is already showing the
/// same mark, holding it until these are decoded makes the handover invisible.
///
/// Failure is not propagated. A brand image that will not load is a cosmetic
/// problem, and refusing to start the application over one would turn it into
/// a fatal one.
Future<void> warmBrand(BuildContext context) async {
  for (final path in _brandImages) {
    try {
      // `onError` as well as the catch. Without it `precacheImage` also reports
      // through `FlutterError.onError`, so a brand image that will not decode
      // prints a caught exception banner to the console even though nothing
      // went wrong: the widgets fall back to the name and the application
      // carries on. A console full of exceptions nobody should act on is how
      // the one that matters gets missed.
      await precacheImage(AssetImage(path), context, onError: (_, __) {});
    } on Object {
      // Handled by each widget's errorBuilder, which falls back to the name.
    }
  }

  appReady();
}

/// The full lockup: the mark above the word.
class RxWordmark extends StatelessWidget {
  const RxWordmark({super.key, this.height = 84});

  final double height;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    return Image.asset(
      t.isDark
          ? 'assets/images/rotelyx-wordmark-dark.png'
          : 'assets/images/rotelyx-wordmark-light.png',
      height: height,
      fit: BoxFit.contain,
      // Centred. It was pinned left, which put it against the edge of a phone
      // and read as an alignment mistake rather than as a choice.
      alignment: Alignment.center,
      // A missing asset renders as nothing under CanvasKit, which would look
      // like a layout bug rather than a packaging one. The name is better.
      errorBuilder: (_, __, ___) =>
          Text('Rotelyx', style: Type.display.copyWith(color: t.text)),
    );
  }
}

/// The horizontal lockup, for headers.
///
/// A separate asset rather than the same one rotated. The brand lockup is
/// vertical, the mark above the word, and a title bar gives it about twenty
/// pixels of height: at that size the word underneath is four pixels tall and
/// reads as a smudge. `tool/brand/build.py` composes the horizontal version
/// from the same two pieces of the source artwork.
class RxLockup extends StatelessWidget {
  const RxLockup({super.key, this.height = 22});

  final double height;

  @override
  Widget build(BuildContext context) {
    final t = RotelyxThemeScope.of(context);
    return Image.asset(
      t.isDark
          ? 'assets/images/rotelyx-lockup-dark.png'
          : 'assets/images/rotelyx-lockup-light.png',
      height: height,
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) =>
          Text('Rotelyx', style: Type.title.copyWith(color: t.text)),
    );
  }
}

/// Just the mark, for places too small for the word.
class RxMark extends StatelessWidget {
  const RxMark({super.key, this.size = 32, this.radius = 8});

  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Image.asset('assets/images/rotelyx-mark.png',
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
                  width: size,
                  height: size,
                  color: Tone.accent,
                )),
      );
}

/// How much of the symbol's width the logo plate takes.
///
/// Kept here as a named constant because `test/meeting_code_test.dart` asserts
/// against the same number. Raising it without running that test is how a
/// beautiful code that nothing can scan gets shipped.
const logoShare = 0.24;

/// A meeting code drawn as a QR, with the mark set into it.
///
/// Always on white, in both themes. A scanner needs dark modules on a light
/// field, and inverting a QR for the sake of a dark mode is a decision that
/// looks considered and breaks perhaps half the cameras that meet it.
class RxQrCode extends StatelessWidget {
  const RxQrCode(this.data, {super.key, this.size = 264});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    final plate = size * logoShare;

    return Container(
      padding: const EdgeInsets.all(Metrics.pad),
      decoration: BoxDecoration(
        // The quiet zone. A QR with content pressed against its edge is
        // markedly harder to find, and the standard asks for four modules of
        // margin for exactly this reason.
        color: Colors.white,
        borderRadius: BorderRadius.circular(Metrics.radius + 4),
      ),
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            QrImageView(
              data: data,
              size: size,
              version: QrVersions.auto,
              // The highest of the four levels, chosen rather than defaulted.
              // Everything above depends on this number.
              errorCorrectionLevel: QrErrorCorrectLevel.H,
              backgroundColor: Colors.white,
              eyeStyle: const QrEyeStyle(
                eyeShape: QrEyeShape.square,
                color: Color(0xFF0B0A0F),
              ),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: Color(0xFF0B0A0F),
              ),
              gapless: true,
            ),
            // The white ring around the mark is not decoration. It separates
            // the logo from the modules beside it so a scanner reads a clean
            // boundary instead of a smear.
            Container(
              width: plate,
              height: plate,
              padding: EdgeInsets.all(plate * 0.08),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(plate * 0.24),
              ),
              child: RxMark(size: plate, radius: plate * 0.18),
            ),
          ],
        ),
      ),
    );
  }
}
