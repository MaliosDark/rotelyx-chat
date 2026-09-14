/// Fetching a linked file on a phone or a desktop.
///
/// Everything here is a bound: what may be asked for, how long it may take, how
/// much may be read, and how many redirects may be followed. A link in a
/// message is written by somebody else, so each of those is a way to make this
/// device do something it did not intend.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'fetch_api.dart';

export 'fetch_api.dart';

/// Ask for a file, once, with every bound applied.
///
/// Returns null rather than throwing: the caller is a card in a conversation
/// and there is nothing for it to do with an exception but say it did not
/// work, which is what null means here.
Future<Fetched?> fetchLinked(String url, {int limit = fetchCeiling}) async {
  final target = Uri.tryParse(url);
  if (target == null) return null;
  if (target.scheme != 'http' && target.scheme != 'https') return null;

  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12)
    // Redirects are followed, because a link that resolves through one is
    // ordinary, and bounded, because a chain of them is a way to spend this
    // device's time.
    ..maxConnectionsPerHost = 2
    // No cookies, ever. There is no session here to carry and nothing this
    // application has that a stranger's host should be handed.
    ..userAgent = 'Rotelyx';

  try {
    final request = await client
        .getUrl(target)
        .timeout(const Duration(seconds: 12));
    request.followRedirects = true;
    request.maxRedirects = 3;

    // Nothing about this device. The default would announce the Dart version
    // and the platform, which is a fingerprint handed to whoever hosts the
    // file.
    request.headers.removeAll(HttpHeaders.acceptEncodingHeader);

    final response = await request.close().timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      client.close(force: true);
      return null;
    }

    // What the server claims, before a byte is read. A length past the ceiling
    // is refused here rather than after twelve megabytes have arrived.
    final claimed = response.contentLength;
    if (claimed > limit) {
      client.close(force: true);
      return null;
    }

    final buffer = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      buffer.add(chunk);
      if (buffer.length > limit) {
        client.close(force: true);
        return null;
      }
    }

    final type = response.headers.contentType?.mimeType ?? '';
    client.close();
    return Fetched(bytes: buffer.takeBytes(), type: type);
  } on Object {
    client.close(force: true);
    return null;
  }
}
