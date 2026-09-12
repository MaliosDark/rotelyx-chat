/// A browser hands a pasted picture to the page as an event rather than
/// answering a question about it, and this application does not listen for
/// one yet. Offering nothing is the honest answer.
library;

import 'pasted_api.dart';

export 'pasted_api.dart';

Future<bool> hasPastedImage() async => false;

Future<PastedImage?> pastedImage() async => null;
