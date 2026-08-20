// Diagnostic capture, in a file rather than inline.
//
// This started as an inline <script> and the CSP blocked it, `script-src
// 'self'` does not cover inline code. The hook never ran, so every automated
// check reported "no errors" while the browser console was full of them. An
// external file is same-origin and allowed.
window.__errs = [];
window.__pushErr = function (m) { window.__errs.push(String(m)); };
window.addEventListener('error', function (e) {
  window.__errs.push(String(e.message) + ' @ ' + (e.filename || '') + ':' + (e.lineno || ''));
});
window.addEventListener('unhandledrejection', function (e) {
  window.__errs.push('rejection: ' + String(e.reason && (e.reason.stack || e.reason.message || e.reason)));
});
['error', 'warn', 'log', 'info'].forEach(function (level) {
  var real = console[level];
  console[level] = function () {
    try {
      window.__errs.push(level + ': ' + Array.prototype.map.call(arguments, String).join(' '));
    } catch (e) {}
    real.apply(console, arguments);
  };
});
