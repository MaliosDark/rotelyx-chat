/// A picture and the line about it are one message.
///
/// Sending them separately is two envelopes, two notifications and two
/// bubbles, and on a busy group the line can arrive before the picture it is
/// about. The caption travels as a fourth field after the bytes, which is what
/// makes it safe to add: a build that has never heard of it takes the first
/// three fields and ignores the rest.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/attachment.dart';

void main() {
  // Big enough that a hundred and twenty characters of the encoded message
  // land inside the base64, which is where a quote's copy is cut off.
  final bytes = Uint8List.fromList(List<int>.generate(400, (i) => i % 256));

  test('what was said with a picture survives the round trip', () {
    final body = Attachment(
      name: 'photo.jpg',
      mime: 'image/jpeg',
      bytes: bytes,
      caption: 'the kitchen at four in the morning',
    ).encode();

    final back = Attachment.decode(body);
    expect(back, isNotNull);
    expect(back!.caption, 'the kitchen at four in the morning');
    expect(back.mime, 'image/jpeg');
    expect(back.bytes, bytes);
  });

  test('a separator in the caption cannot forge a field', () {
    final body = Attachment(
      name: 'photo.jpg',
      mime: 'image/jpeg',
      bytes: bytes,
      caption: 'before\x01after',
    ).encode();

    expect(Attachment.decode(body)!.caption, 'before\x01after');
  });

  test('a build that has never heard of captions still sees the picture', () {
    final captioned = Attachment(
      name: 'photo.jpg',
      mime: 'image/jpeg',
      bytes: bytes,
      caption: 'anything at all',
    ).encode();

    // What an older build does: split on the separator and read the three
    // fields it knows about. The marker carries a separator at each end, so
    // the first part is empty and the second is the marker's own word.
    final parts = captioned.split('\x01');
    expect(parts.length, 6,
        reason: 'empty, rx-file, name, type, bytes, caption');
    final withoutCaption = parts.sublist(0, 5).join('\x01');

    final old = Attachment.decode(withoutCaption);
    expect(old, isNotNull, reason: 'the picture must still open');
    expect(old!.bytes, bytes);
    expect(old.caption, isEmpty);
  });

  test('a picture with nothing said with it is unchanged on the wire', () {
    final bare =
        Attachment(name: 'photo.jpg', mime: 'image/jpeg', bytes: bytes).encode();
    expect(bare.split('\x01').length, 5,
        reason: 'empty, rx-file, name, type, bytes -- and nothing after');
    expect(Attachment.decode(bare)!.caption, isEmpty);
  });

  test('a list shows what was said rather than the word Picture', () {
    final body = Attachment(
      name: 'photo.jpg',
      mime: 'image/jpeg',
      bytes: bytes,
      caption: 'we got the flat',
    ).encode();

    expect(attachmentSummary(body), 'we got the flat');
  });

  group('a quote of a picture', () {
    test('says what it is, from the header alone', () {
      // What a reply carries: the opening of the message it answers, cut to a
      // hundred and twenty characters, which lands inside the base64.
      final body =
          Attachment(name: 'photo.jpg', mime: 'image/jpeg', bytes: bytes)
              .encode();
      final cut = body.substring(0, 120);
      expect(cut.length, lessThan(body.length),
          reason: 'the bytes are cut off, which is the case being tested');

      expect(attachmentGlimpse(cut), 'Picture');
      expect(attachmentGlimpse(cut), isNot(contains('rx-file')));
    });

    test('an animation cut in half still says GIF', () {
      final body = Attachment(
              name: 'dance.gif', mime: 'image/gif', bytes: bytes)
          .encode();
      expect(attachmentGlimpse(body.substring(0, 60)), 'GIF');
    });

    test('ordinary words are left alone', () {
      expect(attachmentGlimpse('just a sentence'), isNull);
    });
  });
}
