// Everything that has to happen around the application rather than inside it.
//
// Two jobs, unrelated to each other except that both must run before the user
// sees anything: evicting a service worker, and taking down the boot screen.
//
// # Why this is a file rather than an inline script
//
// `script-src 'self'` in the Content-Security-Policy refuses inline code. That
// is the policy doing its job, and it has bitten this project before: a
// diagnostic hook written inline never ran, and every automated check reported
// a clean console for hours while the real one was full of errors.

// -----------------------------------------------------------------------------
// Evicting any service worker, which this application must not have
// -----------------------------------------------------------------------------
//
// A service worker pins a build inside the browser and answers from it ahead of
// the network. For most applications that is offline support. Here it is the
// failure mode the README warns about in another guise: an old build still
// loads, still pairs, and then silently fails to interoperate because the
// message path moved underneath it. Nothing about that is visible to the person
// holding it. They simply have a client that does not work and no reason to
// suspect why.
//
// It buys nothing in exchange. Every conversation needs the mailbox, so an
// offline Rotelyx has nothing to do.
//
// `web/flutter_bootstrap.js` stops a new one being registered. That does
// nothing for a browser that registered one earlier, which will keep serving
// its cached copy indefinitely, so the worker has to be actively removed and
// the caches with it. This ran for real: a stale worker held an old build
// through several rebuilds while every check on the serving side correctly
// reported that the new files were going out.
(function () {
  if (!('serviceWorker' in navigator)) return;

  navigator.serviceWorker.getRegistrations().then(function (registrations) {
    if (!registrations.length) return;

    var work = registrations.map(function (r) { return r.unregister(); });

    if (window.caches) {
      work.push(caches.keys().then(function (names) {
        return Promise.all(names.map(function (n) { return caches.delete(n); }));
      }));
    }

    Promise.all(work).then(function () {
      // This page came from the cache that was just deleted, so it is still the
      // old build. One reload fetches the real one.
      //
      // Guarded, because a reload triggered by something that runs on every
      // load is a loop, and a loop here would be an application that never
      // starts.
      if (sessionStorage.getItem('rotelyx.evicted')) return;
      sessionStorage.setItem('rotelyx.evicted', '1');
      window.location.reload();
    });
  }).catch(function () {
    // A browser that refuses to enumerate registrations is a browser with
    // nothing to evict, and this is not worth failing a boot over.
  });
})();

// -----------------------------------------------------------------------------
// Taking down the boot screen
// -----------------------------------------------------------------------------
//
// # Why there is one
//
// The engine is CanvasKit plus a WebAssembly build of the message layer, and on
// a cold load that is several seconds of nothing. Before the splash existed
// those seconds were a blank white page: no name, no mark, no sign the page was
// doing anything, on an application that is otherwise near-black.
//
// # Why the first painted frame is the wrong moment to remove it
//
// `Image.asset` decodes asynchronously. The engine paints as soon as the layout
// is known, which is before the logo on that layout has finished decoding, so
// dismissing the splash there uncovers a screen with a hole where the mark
// should be. It fills a fraction of a second later, and that fraction reads as
// the logo being missing and then popping in. It is what a person notices and
// reports, and it is invisible to every check that waits for the app to settle.
//
// Since the splash is itself showing the mark, holding it until the application
// has decoded its own copy makes the handover invisible: the same image is on
// screen throughout.
//
// # The signals, in order of how much they can be trusted
//
//   1. `window.rotelyxAppReady()`, called by `lib/ui/app.dart` once the brand
//      images are decoded. The one that means what it says.
//   2. `flutter-first-frame`, plus a grace period, if the application painted
//      but never called in. Covers a failure before the precache completes.
//   3. A `<flutter-view>` element appearing, in case a future engine stops
//      dispatching that event.
//   4. A deadline, because a splash that outlives a failed boot hides the error
//      the user needs to see.
(function () {
  var splash = document.getElementById('rotelyx-boot');
  if (!splash) return;

  var gone = false;

  function dismiss() {
    if (gone) return;
    gone = true;
    observer.disconnect();
    window.clearTimeout(deadline);

    splash.classList.add('rotelyx-boot-out');
    // Removed rather than left transparent: an element covering the page still
    // swallows every click, which would look exactly like a frozen app.
    window.setTimeout(function () {
      if (splash.parentNode) splash.parentNode.removeChild(splash);
    }, 420);
  }

  window.rotelyxAppReady = dismiss;

  function afterGrace() {
    window.setTimeout(dismiss, 2500);
  }

  window.addEventListener('flutter-first-frame', afterGrace);

  var observer = new MutationObserver(function () {
    if (document.querySelector('flutter-view, flt-glass-pane, flt-scene-host')) {
      afterGrace();
    }
  });
  observer.observe(document.body, { childList: true, subtree: true });

  var deadline = window.setTimeout(dismiss, 15000);
})();
