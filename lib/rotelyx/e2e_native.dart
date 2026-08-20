/// The test hook on a platform with no JavaScript to publish it to.
library;

/// Whether the hook is compiled in at all. Always false here: there is nothing
/// to install, and a native driver would attach through the Dart VM service
/// rather than through a global.
const e2eEnabled = false;

/// Does nothing, on purpose.
void installE2eHook() {}
