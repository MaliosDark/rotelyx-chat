/// A link to a file, shown as the file rather than as a line of blue text.
///
/// # What this is for
///
/// Somebody pastes a link to a clip into a conversation. Every
/// messenger shows that as a link, and the person reading it leaves the
/// application to find out what it was. The picture, the animation or the track
/// is right there at the end of the link; nothing but the willingness to fetch
/// it stands between the two.
///
/// So a message whose text is a link to a file is drawn as that file: a picture
/// in the bubble, an animation that plays, a track with its cover and its
/// title. Whoever sent it hosts it, which is the point -- the mailbox carries
/// nothing, this application stores nothing, and a link costs an envelope of
/// forty characters instead of one of forty kilobytes.
///
/// # What is never done automatically
///
/// **Nothing is fetched until somebody asks for it.** Fetching reveals this
/// device's address to whoever hosts the file, and the time it was read. That
/// is exactly the correlation the blind mailbox exists to deny, and handing it
/// to any stranger who can paste a link into a conversation would be worse than
/// the leak an ordinary tracking pixel is: they would learn when their message
/// was read, from where, by a device they can then watch for.
///
/// So the card says what it is and waits. One tap, one fetch, and a sentence in
/// the card that says plainly what the tap gives away. A person who wants to
/// see a picture from somebody they trust taps it; a person who has been sent a
/// link by somebody they do not know does not have to.
///
/// The same reasoning email clients arrived at for remote images, for the same
/// reason, twenty years later than they should have.
library;

/// What kind of thing a link points at.
enum LinkKind {
  /// Drawn in the bubble, once fetched.
  picture,

  /// Drawn in the bubble and animated.
  animation,

  /// Handed to the phone's own player.
  video,

  /// Its cover and its title here, the sound in the phone's own player.
  audio,
}

/// A link in a message that points at a file worth showing.
class MediaLink {
  const MediaLink({required this.url, required this.kind, required this.name});

  /// As it was written. Kept whole, because what is fetched must be what was
  /// read: shortening or rewriting it here would show one thing and fetch
  /// another.
  final String url;

  final LinkKind kind;

  /// The last part of the path, which is what a person recognises.
  final String name;

  bool get isPicture => kind == LinkKind.picture || kind == LinkKind.animation;

  /// Who is being asked for it, for the line that says what a tap reveals.
  String get host {
    final parsed = Uri.tryParse(url);
    return parsed?.host ?? url;
  }
}

/// The extensions worth drawing, and what each one is.
///
/// Deliberately short. Every entry is a format `dart:ui` can decode in the
/// application, or one the phone certainly has a player for, and anything
/// unrecognised stays what it was: a link.
const Map<String, LinkKind> _kinds = {
  'jpg': LinkKind.picture,
  'jpeg': LinkKind.picture,
  'png': LinkKind.picture,
  'webp': LinkKind.picture,
  'bmp': LinkKind.picture,
  'gif': LinkKind.animation,
  'apng': LinkKind.animation,
  'mp4': LinkKind.video,
  'm4v': LinkKind.video,
  'webm': LinkKind.video,
  'mov': LinkKind.video,
  'mp3': LinkKind.audio,
  'm4a': LinkKind.audio,
  'aac': LinkKind.audio,
  'ogg': LinkKind.audio,
  'opus': LinkKind.audio,
  'wav': LinkKind.audio,
  'flac': LinkKind.audio,
};

final RegExp _link = RegExp(r'https?://[^\s<>"]+', caseSensitive: false);

/// Every file link in a message, in the order they appear.
///
/// Only `http` and `https`: a message is written by somebody else, and a
/// scheme is a way of pointing this phone at something that is not a file at
/// all.
List<MediaLink> mediaLinksIn(String text) {
  final found = <MediaLink>[];
  for (final match in _link.allMatches(text)) {
    var raw = match.group(0)!;

    // Trailing punctuation belongs to the sentence, not to the link: a
    // sentence ending in a link to a picture is a link and a full stop.
    while (raw.isNotEmpty && '.,;:!?)]}\'"'.contains(raw[raw.length - 1])) {
      raw = raw.substring(0, raw.length - 1);
    }

    final url = Uri.tryParse(raw);
    if (url == null || !url.hasAuthority) continue;
    if (url.scheme != 'http' && url.scheme != 'https') continue;

    final path = url.path;
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) continue;
    final extension = path.substring(dot + 1).toLowerCase();

    final kind = _kinds[extension];
    if (kind == null) continue;

    final segments = url.pathSegments;
    found.add(MediaLink(
      url: raw,
      kind: kind,
      name: segments.isEmpty ? url.host : segments.last,
    ));
  }
  return found;
}

/// What a message says once its links are drawn as what they point at.
///
/// A message that is nothing but a link shows as the file alone, the way an
/// attachment does. A message with something written around the link keeps the
/// writing.
String textWithout(String text, List<MediaLink> links) {
  var left = text;
  for (final link in links) {
    left = left.replaceFirst(link.url, '');
  }
  return left.trim();
}
