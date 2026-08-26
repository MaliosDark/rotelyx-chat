/// An invitation as something you can send in a message.
///
/// # Why the code sits after a hash
///
/// The fragment of a URL is never sent to the server. That is not a promise
/// this project makes, it is how HTTP works: a browser opening
/// `https://rotelyx.com/i#<code>` asks the host for `/i` and keeps everything
/// after the hash to itself. So the invitation cannot be logged by the site it
/// appears to point at, and anybody can confirm that with the network tab
/// rather than taking our word for it.
///
/// With Android App Links verified it is better still. A phone that has this
/// application installed opens it directly and never makes the request at all.
/// The site is reached only by somebody who does not have the app yet, which is
/// exactly who needs to be told where to get it.
///
/// # Why the mailbox travels inside the code
///
/// It used not to, because there was one mailbox and both sides were compiled
/// against it. With more than one, two people whose builds point at different
/// hosts wait at places the other never visits, and neither side has anything
/// to report: no error, no timeout worth showing, just a conversation that
/// never starts. So the invitation says where to meet.
///
/// # What this deliberately does not do
///
/// It does not shorten anything. A short link is a lookup on somebody's server,
/// which turns an invitation nobody can see into an invitation one host resolves
/// and could keep. The code is long and it stays long.
library;

import 'dart:convert';

/// Where invitation links point.
///
/// The application's own domain, and separate from the mailbox hosts on
/// purpose: this one is a website that has to be reachable by a browser, and
/// they are infrastructure.
const inviteHost = 'rotelyx.com';

/// The path the link uses. Short because it is typed by nobody and read by
/// everybody.
const invitePath = '/i';

/// Wrap a raw invitation code into something sendable.
String inviteLink(String code) => 'https://$inviteHost$invitePath#$code';

/// The code inside a link, or null when this is not one.
///
/// Accepts a bare code too. People paste what they were given, and what they
/// were given depends on which version of the application produced it.
String? codeFromLink(String input) {
  final text = input.trim();
  if (text.isEmpty) return null;

  if (!text.startsWith('http://') && !text.startsWith('https://')) {
    // Not a link. Assume it is the code itself, and let the decoder decide.
    return text;
  }

  final uri = Uri.tryParse(text);
  if (uri == null) return null;

  // The fragment, which is where the code lives. `Uri` percent decodes it, and
  // base64 has no characters that survive that differently, so what comes out
  // is what went in.
  final fragment = uri.fragment;
  if (fragment.isEmpty) return null;

  return fragment;
}

/// Read the mailbox an invitation names, or null when it names none.
///
/// Null is not a failure. Codes made before mailboxes had names carry no host,
/// and the honest answer for those is the one this build is configured with.
String? mailboxFromCode(String code) {
  try {
    final json = jsonDecode(utf8.decode(base64Decode(code.trim())));
    if (json is! Map) return null;
    final host = json['mailbox'];
    return host is String && host.isNotEmpty ? host : null;
  } on Object {
    return null;
  }
}

/// When an invitation stops working, or null when it never does.
///
/// Null also covers a code from before invitations carried an expiry. Those
/// are honestly unlimited: there is nothing in them to check.
DateTime? expiryOfCode(String code) {
  try {
    final json = jsonDecode(utf8.decode(base64Decode(code.trim())));
    if (json is! Map) return null;
    final at = json['expires'];
    if (at is! int || at <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(at);
  } on Object {
    return null;
  }
}

/// Whether this invitation is past its time.
///
/// The same tolerance the service applies, so a screen never says an
/// invitation is dead while the code that accepts it would still take it.
bool codeHasExpired(String code, {Duration skew = const Duration(minutes: 5)}) {
  final at = expiryOfCode(code);
  return at != null && DateTime.now().isAfter(at.add(skew));
}
