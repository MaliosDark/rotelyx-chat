/// The mailboxes this build knows by name, and how to talk about the rest.
///
/// # Why there is a list at all rather than a lookup
///
/// A service that told each device where its mailbox is would be a request from
/// every phone, every launch, to one host. That host would learn the address of
/// every user, when they open the application and how often, which is precisely
/// what the blind mailbox is built not to learn. It would also be the single
/// thing whose failure stops anybody from starting.
///
/// So the list is compiled in. Adding one costs a release, and mailboxes are
/// infrastructure rather than content: they do not change weekly.
///
/// # Why anybody may run their own
///
/// If the mailbox can only be ours then "we cannot see who you talk to" is a
/// promise. If it can be theirs, it is a property. That is the whole argument
/// of this application and it is worth the complication.
///
/// # Why an unknown one is shown rather than refused
///
/// An invitation carries the mailbox it was made on, because two people whose
/// builds point at different hosts otherwise wait in places the other never
/// visits. Combined with mailboxes anybody can run, that means an invitation
/// can send you to a host its sender chose.
///
/// It cannot read anything: everything is sealed before it arrives. It can see
/// your address, when you connect and how often, which for somebody who
/// installed this for that reason is the thing they were avoiding. Refusing
/// outright would break self hosting, which is the point. So it is named, and
/// named as unfamiliar, and the person decides. A visible decision is not the
/// same risk as a silent one.
library;

/// One place messages wait.
class Mailbox {
  const Mailbox({required this.url, required this.name});

  /// The WebSocket URL, which is what everything else uses.
  final String url;

  /// What it is called. Neutral on purpose: this string travels inside
  /// invitations, which go through other people's messengers, and a name like
  /// `london` would tell everyone carrying that message where its sender is.
  final String name;

  // There is deliberately no country here.
  //
  // It used to say "United Kingdom", and that was a claim this application had
  // no way to support. Everything else here is built so that nothing has to be
  // taken on trust: a safety number is compared, the cryptography is published,
  // the code can be read. A sentence naming a jurisdiction can only be
  // believed, and it is the sort of sentence that stays on screen long after
  // the machine it describes has moved.
  //
  // The network does not back it up either. These hosts sit behind a content
  // network, so the address anybody resolves is anycast and belongs to no
  // particular country. The application would have been asserting something
  // that a person checking would find contradicted.
  //
  // What is worth saying is the part that can be checked: whether the mailbox
  // is one this build ships with or one somebody added. That distinction is a
  // fact about the running application. Where a server physically sits is a
  // claim about the world, and it belongs where claims belong, which is a page
  // somebody can hold us to rather than a label inside the product.

  /// The host, for showing without the scheme and path.
  String get host => Uri.tryParse(url)?.host ?? url;
}

/// The mailboxes shipped with this build.
const knownMailboxes = <Mailbox>[
  Mailbox(url: 'wss://m1.telyx.me/mailbox', name: 'slate'),
];

/// The one used when nothing else has been chosen.
Mailbox get defaultMailbox => knownMailboxes.first;

/// The entry for [url], or null when this build has never heard of it.
Mailbox? knownMailbox(String url) {
  final host = Uri.tryParse(url)?.host;
  if (host == null || host.isEmpty) return null;

  for (final m in knownMailboxes) {
    if (m.host == host) return m;
  }
  return null;
}

/// How to describe a mailbox to somebody about to use it.
///
/// Never null, because every path that shows a mailbox has to say something,
/// and "unknown" said plainly is more useful than a blank.
({String title, String detail, bool familiar}) describeMailbox(String url) {
  final known = knownMailbox(url);
  if (known != null) {
    return (
      title: known.name,
      detail: 'One of ours. It still only sees that you connected, never what '
          'you say.',
      familiar: true,
    );
  }

  final host = Uri.tryParse(url)?.host;
  return (
    title: host == null || host.isEmpty ? 'an unreadable address' : host,
    detail: 'Not one of ours. Whoever runs it will see when you connect and '
        'from where, though never what you say.',
    familiar: false,
  );
}

/// Whether a string is usable as a mailbox address.
///
/// Deliberately strict about the scheme. A `ws://` mailbox is one anybody on
/// the path can read the tags of, and tags are the metadata this design spends
/// everything to protect.
String? mailboxProblem(String input) {
  final text = input.trim();
  if (text.isEmpty) return 'Enter an address.';

  final uri = Uri.tryParse(text);
  if (uri == null || uri.host.isEmpty) {
    return 'That is not an address. It looks like wss://example.com/mailbox';
  }

  if (uri.scheme == 'ws') {
    return 'That address is not encrypted. It has to start with wss://';
  }
  if (uri.scheme != 'wss') {
    return 'A mailbox address starts with wss://';
  }

  return null;
}
