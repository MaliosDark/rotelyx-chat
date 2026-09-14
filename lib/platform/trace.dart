/// One line to wherever this platform's log is.
///
/// Native writes to standard error, because the phone this was first needed on
/// shows nothing below error level in its log, and a trace nobody can read is
/// not a trace. The browser has a console and `print` reaches it.
library;

export 'trace_native.dart' if (dart.library.js_interop) 'trace_web.dart';
