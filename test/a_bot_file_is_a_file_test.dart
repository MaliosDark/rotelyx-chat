// A file a bot sends, as the bot library builds it, is a file to the app.
//
// The marker is not "rx-file": it is the unit separator, "rx-file", the unit
// separator, and the bot library said "rx-file" for an evening, so a picture
// an agent shared arrived on a phone as nine hundred characters of base64.
// The body here is built the way `bot-examples/rotelyx_bot.py` builds it.

import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/attachment.dart';

void main() {
  test('what a bot sends as a file decodes as one', () {
    final bytes = List<int>.generate(3000, (i) => (i * 7) & 0xff);
    final body = '\x01rx-file\x01'
        '${Uri.encodeComponent('photo.jpg')}\x01'
        '${Uri.encodeComponent('image/jpeg')}\x01'
        '${base64Encode(bytes)}';
    expect(Attachment.looksLikeAttachment(body), isTrue);
    final file = Attachment.decode(body);
    expect(file, isNotNull);
    expect(file!.mime, 'image/jpeg');
    expect(file.isImage, isTrue);
    expect(file.bytes.length, 3000);
    // And what the app itself packs reads back the same way.
    expect(Attachment.decode(file.encode())!.bytes, file.bytes);
  });
}
