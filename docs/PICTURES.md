<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../assets/images/rotelyx-wordmark-dark.png">
  <img src="../assets/images/rotelyx-wordmark-light.png" alt="Rotelyx" height="34">
</picture>

# Sending a photograph

A messenger that cannot send a picture is not a messenger. This one nearly was
not, and the reason is worth writing down because it is the kind of fault that
looks like three unrelated bugs until somebody measures it.

## The size a picture has to be

The mailbox meters by envelope. Without a capability token it takes **64 KiB**
in one, and it refuses the deposit rather than trimming it. What travels is
base64, four bytes for every three, so the picture itself has about 48 KiB
before the encoding alone overruns. Taking off the marker, the filename, the
type and what MLS wraps around all of it leaves **44 KiB**, which is
`freeAttachmentBytes` in `lib/rotelyx/attachment.dart`.

The application used to aim at 5 MB, which is the paid ceiling. So a photograph
was shrunk to 5 MB, sealed, sent, and bounced. The person saw a failure and no
reason for it.

## Why the shrinking did not help

`shrinkToFit` re-encoded as PNG, because `dart:ui`'s `toByteData` offers PNG and
raw pixels and nothing else. PNG is lossless, and lossless of a photograph is
several times the size of a lossy encoding of the same picture. Meeting 44 KiB
that way meant drawing the photograph at around three hundred pixels on its long
edge. That is a stamp, not a picture.

Adding a JPEG encoder would have been the first dependency this application took
that it does not otherwise need, and it would have been a dependency on a format
from 1992 to solve a problem that is specifically about very small files.

## So there is a codec

`lib/rotelyx/photo_codec.dart`. Both ends of a conversation are this
application, so the format between them does not have to be one anybody else can
read.

It is DCT shaped: colour separated from brightness, chroma at half resolution,
eight by eight blocks, a frequency transform, quantisation, an entropy coder.
That is the shape of JPEG and of everything that has beaten JPEG, because at
these sizes it is the shape that works. Departing from it to be different would
look worse, and looking better is the entire point.

Three things differ, and they are what pays for the file existing.

**An adaptive binary arithmetic coder** rather than Huffman tables.
Probabilities are learned from the picture as it is written instead of being
fixed in advance. Contexts are split by plane and by position within the block,
because the chance of a coefficient being zero rises steeply with frequency and
a coder that knows this spends almost nothing on the zeroes. JPEG has an
arithmetic mode that says the same thing; almost nothing implements it, for
patent reasons that expired long ago and habits that did not.

**Quantisation fitted for small files.** JPEG's tables were chosen for
photographs at a few hundred kilobytes. These are steeper in the high
frequencies, which is where a picture allowed 44 KiB has nothing to spend.

**A ten byte header.** There is no need to describe tables both sides already
have, or a colour space that is always the same one.

## What it measures

From `test/photo_codec_test.dart`, which fails if these go the wrong way:

| | |
|---|---|
| 1024 by 768 photograph | **41 KiB at 37.6 dB**, 0.43 bits per pixel |
| Brightness alone, top quality | above 50 dB |
| A picture that is not ours | refused rather than misread |

Baseline JPEG at 0.43 bits per pixel lands around 32 to 34 dB on a natural
photograph. Above 35 dB is ordinarily called good, and the difference between 28
and 32 is the difference between a picture somebody complains about and one they
do not mention.

The measurement is peak signal to noise, which is blunt and standard. It is
reported rather than asserted at a flattering threshold: the test prints the
number so that a change which quietly makes pictures worse is visible in the
output rather than only when it crosses a line.

## Choosing the size

`fitPicture` in `lib/ui/screens/picture.dart` turns two dials, in this order:

1. **Quality**, by bisection between 12 and 92. Bisection rather than a walk
   down a list of steps, so it lands near the top of what the budget allows
   instead of at whichever step happened to fit.
2. **Resolution**, only when quality alone cannot get there. A smaller picture
   of the whole scene beats a larger one quantised into mush, and both beat the
   picture being refused.

A picture that will not fit at 360 pixels on its long edge is reported as one
that cannot be sent, which is honest and does not happen with photographs.

## Choosing a picture, and keeping one

These are separate permissions and it matters which is which.

**Choosing** asks for nothing. `PHPickerViewController` on iOS and the system
document picker filtered to images on Android both run outside this application
and hand back the one file that was tapped. The library is never visible here.
The belief that the iOS photo picker cost `NSPhotoLibraryUsageDescription` is
what kept the attach button opening a list of folders; it has not been true
since iOS 14.

**Keeping** asks for the narrow one. `NSPhotoLibraryAddUsageDescription` on iOS
lets this application put one picture into the library and nothing else: it
cannot list, open or count what is there. On Android, `MediaStore` needs no
permission at all for a picture the application is inserting itself. The
description in `Info.plist` says exactly this, because the person reading it is
deciding.

Saving is offered because a photograph a friend sent and meant you to have is
not a secret being leaked. A message set to burn is gone and cannot be saved; one
that is not is theirs.

## Where this should be dropped

It does not beat AVIF, and nothing written in an afternoon does. If the engine
ever exposes a modern encoder to Dart, measure this against it with
`test/photo_codec_test.dart` and delete it without ceremony if it loses.
