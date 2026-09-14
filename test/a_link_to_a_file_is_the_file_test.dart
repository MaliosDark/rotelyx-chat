/// A link to a picture, a clip or a track is recognised as one.
///
/// What is not here is as important as what is: nothing in this file fetches
/// anything, because nothing in the application fetches anything until somebody
/// taps the card. See `lib/rotelyx/media_link.dart`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rotelyx_chat/rotelyx/media_link.dart';
import 'package:rotelyx_chat/rotelyx/track_tags.dart';

void main() {
  group('what counts as a file worth drawing', () {
    test('a picture, an animation, a clip and a track', () {
      expect(mediaLinksIn('https://a.example/one.jpg').single.kind,
          LinkKind.picture);
      expect(mediaLinksIn('https://a.example/two.GIF').single.kind,
          LinkKind.animation);
      expect(mediaLinksIn('https://a.example/three.mp4').single.kind,
          LinkKind.video);
      expect(mediaLinksIn('https://a.example/four.mp3').single.kind,
          LinkKind.audio);
    });

    test('an ordinary link is left alone', () {
      expect(mediaLinksIn('https://example.com/an/article'), isEmpty);
      expect(mediaLinksIn('have a look at https://example.com'), isEmpty);
    });

    test('only http and https', () {
      // A scheme is a way of pointing this phone at something that is not a
      // file at all, and a message is written by somebody else.
      expect(mediaLinksIn('file:///etc/passwd.png'), isEmpty);
      expect(mediaLinksIn('javascript:alert(1).jpg'), isEmpty);
      expect(mediaLinksIn('content://media/external/1.jpg'), isEmpty);
      expect(mediaLinksIn('intent://x/y.mp4#Intent;end'), isEmpty);
    });

    test('a full stop after a link belongs to the sentence', () {
      final links = mediaLinksIn('look at https://a.example/cat.jpg.');
      expect(links.single.url, 'https://a.example/cat.jpg');
    });

    test('a query string does not hide the kind', () {
      final links = mediaLinksIn('https://a.example/x.mp3?token=abc');
      expect(links.single.kind, LinkKind.audio);
      expect(links.single.url, endsWith('token=abc'),
          reason: 'what is fetched must be what was written');
    });

    test('several in one message, in the order they were written', () {
      final links = mediaLinksIn(
          'https://a.example/one.png then https://b.example/two.mp3');
      expect(links.length, 2);
      expect(links.first.host, 'a.example');
      expect(links.last.host, 'b.example');
      expect(links.last.name, 'two.mp3');
    });

    test('what is left of the message once the links are drawn', () {
      const text = 'look at this https://a.example/cat.jpg';
      expect(textWithout(text, mediaLinksIn(text)), 'look at this');

      const bare = 'https://a.example/cat.jpg';
      expect(textWithout(bare, mediaLinksIn(bare)), isEmpty,
          reason: 'a message that is only a link shows as the picture alone');
    });
  });

  group('what a track says about itself', () {
    test('title, artist and cover come out of an ID3 tag', () {
      final cover = Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]);
      final bytes = _id3(
        title: 'Nightswimming',
        artist: 'Somebody',
        cover: cover,
      );

      final tags = readTrackTags(bytes);
      expect(tags.title, 'Nightswimming');
      expect(tags.artist, 'Somebody');
      expect(tags.cover, cover);
    });

    test('a file with no tag says nothing rather than throwing', () {
      final tags = readTrackTags(Uint8List.fromList(List.filled(64, 7)));
      expect(tags.isEmpty, isTrue);
    });

    test('a tag that lies about its lengths is refused', () {
      final bytes = _id3(title: 'x', artist: 'y');
      // A frame that claims to be longer than the file.
      bytes[14] = 0x7f;
      bytes[15] = 0x7f;
      expect(() => readTrackTags(bytes), returnsNormally);
    });

    test('a truncated file is refused rather than read past', () {
      final whole = _id3(title: 'Nightswimming', artist: 'Somebody');
      for (final cut in [1, 5, 11, 20, whole.length - 1]) {
        expect(() => readTrackTags(Uint8List.sublistView(whole, 0, cut)),
            returnsNormally,
            reason: 'cut at $cut');
      }
    });
  });
}

/// The front of an MP3: "ID3", a version, a synchsafe size, then frames.
Uint8List _id3({String title = '', String artist = '', Uint8List? cover}) {
  final frames = BytesBuilder();

  void frame(String name, List<int> body) {
    frames.add(ascii.encode(name));
    final size = body.length;
    frames.add([
      (size >> 21) & 0x7f,
      (size >> 14) & 0x7f,
      (size >> 7) & 0x7f,
      size & 0x7f,
    ]);
    frames.add([0, 0]); // flags
    frames.add(body);
  }

  if (title.isNotEmpty) frame('TIT2', [3, ...utf8.encode(title)]);
  if (artist.isNotEmpty) frame('TPE1', [3, ...utf8.encode(artist)]);
  if (cover != null) {
    frame('APIC', [
      3, // UTF-8
      ...utf8.encode('image/jpeg'), 0,
      3, // front cover
      ...utf8.encode('cover'), 0,
      ...cover,
    ]);
  }

  final body = frames.takeBytes();
  final out = BytesBuilder();
  out.add(ascii.encode('ID3'));
  out.add([4, 0, 0]); // v2.4, no flags
  final size = body.length;
  out.add([
    (size >> 21) & 0x7f,
    (size >> 14) & 0x7f,
    (size >> 7) & 0x7f,
    size & 0x7f,
  ]);
  out.add(body);
  return out.takeBytes();
}
