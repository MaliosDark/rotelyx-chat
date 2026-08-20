# `rendered-pair-screen.gray`

A photograph of the pairing screen as the application actually draws it,
captured by `tool/e2e/shots.py` from a release build running in Firefox, then
reduced to one brightness byte per pixel.

    520 by 460 pixels, no header, row-major

Raw rather than PNG because the test has no image decoder and does not need
one: this is the exact input `Luma` takes.

It exists so that `test/rendered_qr_test.dart` can close the last gap in the
chain. Every other test in this directory encodes a symbol in memory and reads
it back. This one starts from pixels Flutter painted, through `qr_flutter`, with
the logo composited on top by `lib/ui/brand.dart`. If the plate ever grows, if
the correction level is ever lowered, or if the module colours ever lose
contrast, this is the test that notices.

The code it contains is `RTLX1VR3ACHNMDPM4V7LPYUF35HK6`, which is also printed
in readable text on the screen it was captured from.
