#!/usr/bin/env python3
"""Derive every brand asset this client uses from the two source files.

    python3 tool/brand/build.py

# Why this exists

The source artwork is two files in the protocol repository: a vertical lockup
in a light-on-dark and a dark-on-light rendering, plus a square mark. Everything
the application shows is cut, scaled or composed from those. Doing that by hand
once is fine; doing it by hand again six months later produces assets that no
longer match, and nobody notices because each one looks plausible on its own.

# What it makes, and where each one is used

    assets/images/rotelyx-wordmark-{dark,light}.png   the vertical lockup
        The unlock screen and the empty conversation pane, where there is room
        for the mark above the word.

    assets/images/rotelyx-lockup-{dark,light}.png     a horizontal lockup
        Title bars. The vertical lockup at twenty pixels of height puts the
        word at four pixels, which reads as a smudge, so the two pieces are
        recomposed side by side instead.

    assets/images/rotelyx-mark.png                    the square mark
        Anywhere too small for the word, and the plate inside a QR code.

    web/rotelyx-boot.png                              the boot splash
        A copy outside the Flutter asset bundle on purpose: it has to paint
        before the engine that would serve it has finished loading.

    web/favicon.png, web/icons/Icon-{192,512}.png     browser and installed app
    web/icons/Icon-maskable-{192,512}.png             with the safe-area inset

    android/.../mipmap-*/ic_launcher.png              the launcher icon
    android/.../drawable*/rotelyx_splash.png          the launch screen mark

The Android ones replace what `flutter create` leaves behind, which is the
Flutter logo and a white launch screen. Both are visible before a single line of
this application runs: the icon in the drawer, and the white flash between
tapping it and the engine painting. Neither should say Flutter and neither
should be white on an application that is otherwise near black.

`-dark` means "for dark surfaces", so it is the light-on-dark artwork. Getting
that backwards yields a logo that is invisible rather than wrong, which is
harder to spot in a screenshot than it sounds.
"""

import os

from PIL import Image

BRAND = "/home/serafin/comms-real-e2e/docs/brand"
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Where the vertical lockup separates. Measured from the source rather than
# guessed: these are the rows where the alpha channel is empty right across.
SPLIT_ABOVE = 552
SPLIT_BELOW = 626


def trimmed(image):
    """Crop to the artwork, discarding transparent margin."""
    box = image.getchannel("A").getbbox()
    return image.crop(box) if box else image


def source(tone):
    return Image.open(f"{BRAND}/rotelyx-logo-{tone}.png").convert("RGBA")


def wordmark(tone, out):
    """The vertical lockup, with breathing room so it never touches an edge."""
    art = trimmed(source(tone))
    pad = round(art.width * 0.03)
    canvas = Image.new("RGBA", (art.width + 2 * pad, art.height + 2 * pad), (0, 0, 0, 0))
    canvas.paste(art, (pad, pad))
    canvas.thumbnail((720, 720), Image.LANCZOS)
    canvas.save(out)
    return canvas.size


def lockup(tone, out, height=160):
    """The horizontal lockup, composed from the two halves of the vertical one."""
    art = source(tone)
    mark = trimmed(art.crop((0, 0, art.width, SPLIT_ABOVE)))
    word = trimmed(art.crop((0, SPLIT_BELOW, art.width, art.height)))

    m = mark.resize((round(mark.width * height / mark.height), height), Image.LANCZOS)

    # The word is set to cap height against the mark rather than matched to it,
    # which is what keeps the mark reading as the dominant element.
    word_height = round(height * 0.42)
    w = word.resize(
        (round(word.width * word_height / word.height), word_height), Image.LANCZOS
    )

    gap = round(height * 0.13)
    canvas = Image.new("RGBA", (m.width + gap + w.width, height), (0, 0, 0, 0))
    canvas.paste(m, (0, 0), m)
    canvas.paste(w, (m.width + gap, (height - w.height) // 2), w)
    canvas.save(out)
    return canvas.size


def icons():
    """Browser and installed-application icons, from the square mark."""
    mark = Image.open(f"{BRAND}/rotelyx-mark.png").convert("RGBA")
    made = []

    for size, name in [(192, "Icon-192.png"), (512, "Icon-512.png")]:
        out = os.path.join(ROOT, "web", "icons", name)
        mark.resize((size, size), Image.LANCZOS).save(out)
        made.append((name, (size, size)))

    # A maskable icon may be cropped to a circle by the platform, so the mark is
    # inset into the safe area: the standard reserves the middle 80 percent.
    for size, name in [(192, "Icon-maskable-192.png"), (512, "Icon-maskable-512.png")]:
        inner = round(size * 0.8)
        canvas = Image.new("RGBA", (size, size), (11, 10, 15, 255))
        canvas.paste(mark.resize((inner, inner), Image.LANCZOS),
                     ((size - inner) // 2, (size - inner) // 2))
        canvas.save(os.path.join(ROOT, "web", "icons", name))
        made.append((name, (size, size)))

    favicon = os.path.join(ROOT, "web", "favicon.png")
    mark.resize((32, 32), Image.LANCZOS).save(favicon)
    made.append(("favicon.png", (32, 32)))
    return made


# Android launcher densities. The numbers are the standard buckets, and the
# names are what the resource system looks for.
LAUNCHER = [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144),
            ("xxxhdpi", 192)]

# The launch screen mark, per density. Larger than the icon because it sits in
# the middle of a screen rather than in a grid of other icons.
SPLASH = [("mdpi", 120), ("hdpi", 180), ("xhdpi", 240), ("xxhdpi", 360),
          ("xxxhdpi", 480)]


# The notification icon, per density. Android draws the small icon as a
# silhouette: every colour is discarded and only the alpha channel survives, so
# a full-colour mark arrives as a solid square. These are the mark's alpha,
# painted white, which is what the system expects to be given.
NOTIFY = [("mdpi", 24), ("hdpi", 36), ("xhdpi", 48), ("xxhdpi", 72),
          ("xxxhdpi", 96)]


def notification_icon():
    """A white silhouette of the mark, for the status bar.

    # Where the shape comes from, and where it does not

    From the **top of the vertical lockup**, not from `rotelyx-mark.png`.

    Android draws a notification's small icon as a silhouette: every colour is
    discarded and only the alpha channel survives. `rotelyx-mark.png` is the
    square app-icon rendering and it is opaque edge to edge, so its alpha
    channel is a filled rectangle. Feeding it to this produced a solid white
    square in the status bar and in every notification, which is exactly what
    the comment above it warned about and exactly what shipped.

    `rotelyx-logo-dark.png` is the artwork with a real alpha channel, 82 percent
    of it transparent. Its top portion, above `SPLIT_ABOVE`, is the mark on its
    own. That is a shape rather than a rectangle, which is what the system needs
    to be given.
    """
    art = source("dark")
    mark = trimmed(art.crop((0, 0, art.width, SPLIT_ABOVE)))

    # White everywhere, with the artwork's own alpha. Anything else is thrown
    # away by the system anyway, and doing it here means what ships is what will
    # be drawn rather than a surprise on the device.
    white = Image.new("RGBA", mark.size, (255, 255, 255, 0))
    white.putalpha(mark.getchannel("A"))
    return white


def android():
    """The launcher icon and the launch screen, replacing Flutter's defaults."""
    mark = Image.open(f"{BRAND}/rotelyx-mark.png").convert("RGBA")
    res = os.path.join(ROOT, "android", "app", "src", "main", "res")
    made = []

    for name, size in LAUNCHER:
        out = os.path.join(res, f"mipmap-{name}")
        os.makedirs(out, exist_ok=True)
        mark.resize((size, size), Image.LANCZOS).save(
            os.path.join(out, "ic_launcher.png"))
        made.append((f"mipmap-{name}/ic_launcher.png", size))

    # The launch screen mark, transparent so the drawable's colour shows behind
    # it. The wordmark rather than the square, because this is the middle of a
    # screen and there is room for the name.
    wordmark = Image.open(
        os.path.join(ROOT, "assets", "images", "rotelyx-wordmark-dark.png"))
    for name, width in SPLASH:
        out = os.path.join(res, f"drawable-{name}")
        os.makedirs(out, exist_ok=True)
        height = round(wordmark.height * width / wordmark.width)
        wordmark.resize((width, height), Image.LANCZOS).save(
            os.path.join(out, "rotelyx_splash.png"))
        made.append((f"drawable-{name}/rotelyx_splash.png", width))

    # The status bar icon. Padded to a square with a tenth of a margin, because
    # the system draws it inside a fixed box and artwork pressed to the edge is
    # clipped on some launchers.
    silhouette = notification_icon()
    for name, size in NOTIFY:
        out = os.path.join(res, f"drawable-{name}")
        os.makedirs(out, exist_ok=True)
        inner = round(size * 0.8)
        canvas = Image.new("RGBA", (size, size), (255, 255, 255, 0))
        art = silhouette.copy()
        art.thumbnail((inner, inner), Image.LANCZOS)
        canvas.paste(art, ((size - art.width) // 2, (size - art.height) // 2))
        canvas.save(os.path.join(out, "ic_notification.png"))
        made.append((f"drawable-{name}/ic_notification.png", size))

    return made


def main():
    images = os.path.join(ROOT, "assets", "images")
    os.makedirs(images, exist_ok=True)
    os.makedirs(os.path.join(ROOT, "web", "icons"), exist_ok=True)

    for tone in ("dark", "light"):
        out = os.path.join(images, f"rotelyx-wordmark-{tone}.png")
        print(f"  rotelyx-wordmark-{tone}.png   {wordmark(tone, out)}")

    for tone in ("dark", "light"):
        out = os.path.join(images, f"rotelyx-lockup-{tone}.png")
        print(f"  rotelyx-lockup-{tone}.png     {lockup(tone, out)}")

    mark = Image.open(f"{BRAND}/rotelyx-mark.png").convert("RGBA")
    mark.save(os.path.join(images, "rotelyx-mark.png"))
    print(f"  rotelyx-mark.png              {mark.size}")

    # The splash is the dark wordmark, since the boot screen is the application
    # backdrop and never follows the system theme.
    boot = Image.open(os.path.join(images, "rotelyx-wordmark-dark.png"))
    boot.save(os.path.join(ROOT, "web", "rotelyx-boot.png"))
    print(f"  web/rotelyx-boot.png          {boot.size}")

    for name, size in icons():
        print(f"  web/.../{name:<24} {size}")

    for name, size in android():
        print(f"  android/.../{name:<34} {size}")


if __name__ == "__main__":
    main()
