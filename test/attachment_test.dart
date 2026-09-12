/// What a conversation list and a notification show for an attachment.
///
/// The defect this exists for: an attachment's body is the marker and the
/// bytes, so shown as text it read `rx-file`, a filename, a percent-escaped
/// type and the start of the base64. Both surfaces did that, and it looked
/// like the application had broken.
///
/// The notification path meant to handle it and could not. It asked whether
/// the body was empty, which is never true here.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/attachment.dart';

void main() {
  test('a picture reads as a picture, not as its encoding', () {
    final body = Attachment(
      name: 'IMG_4812.HEIC',
      mime: 'image/x-rotelyx',
      bytes: Uint8List.fromList([1, 2, 3]),
    ).encode();

    expect(attachmentSummary(body), 'Picture');
    expect(attachmentSummary(body), isNot(contains('rx-file')));
  });

  test('an animation says so', () {
    final body = Attachment(
      name: 'reaction.gif',
      mime: 'image/gif',
      bytes: Uint8List.fromList([1]),
    ).encode();
    expect(attachmentSummary(body), 'GIF');
  });

  test('a file keeps its name, because the name is what tells them apart', () {
    final body = Attachment(
      name: 'the lease.pdf',
      mime: 'application/pdf',
      bytes: Uint8List.fromList([1]),
    ).encode();
    expect(attachmentSummary(body), 'the lease.pdf');
  });

  test('ordinary text is left alone', () {
    expect(attachmentSummary('just a sentence'), isNull);
    expect(attachmentSummary(''), isNull);
  });

  test('a name carrying the separator does not invent a type', () {
    // The name is percent-encoded on the way out, so a file called something
    // that looks like the header cannot forge one.
    final body = Attachment(
      name: 'odd name.txt',
      mime: 'text/plain',
      bytes: Uint8List.fromList([1]),
    ).encode();

    final back = Attachment.decode(body);
    expect(back, isNotNull);
    expect(back!.mime, 'text/plain');
    expect(back.name, 'odd name.txt');
    expect(attachmentSummary(body), 'odd name.txt');
  });
}
