/// A browser tab does not fetch other people's files.
///
/// It could, and the reason it does not is the page's own content policy: this
/// application is served with a policy that allows connections to the mailbox
/// and to nothing else, which is a promise the page makes about itself and
/// worth more than showing a picture inline.
library;

import 'fetch_api.dart';

export 'fetch_api.dart';

Future<Fetched?> fetchLinked(String url, {int limit = fetchCeiling}) async =>
    null;
