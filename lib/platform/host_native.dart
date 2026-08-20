/// Everything that is not a browser.
///
/// Both of these are browser concerns with no counterpart on a phone. They are
/// present and empty rather than absent, so callers do not have to ask which
/// platform they are on before doing something ordinary.
library;

/// No URLs to keep clean: an application has no address bar.
void useCleanUrls() {}

/// No boot screen to dismiss. The platform shows its own launch image and
/// removes it when the first frame is drawn.
void appReady() {}
