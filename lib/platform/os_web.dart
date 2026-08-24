/// Platform detection in a browser, where the answer is always no.
///
/// A browser is not Android and not iOS, and saying so plainly is what lets the
/// callers keep their shape: `audioIsBuilt` is false here, so the call button is
/// absent rather than present and broken.
library;

bool get isAndroid => false;
bool get isIOS => false;
bool get isMobile => false;
