// A service worker whose only job is to remove itself.
//
// # Why this file exists at this exact name
//
// `web/flutter_bootstrap.js` stops any new visitor registering a worker, and
// `web/boot.js` removes one from a browser that already has it. Between them
// they miss the case that actually happened here:
//
//   A browser registered `flutter_service_worker.js?v=...` from an older build.
//   That worker caches `index.html` and serves it ahead of the network. Every
//   later build is invisible to it, including the `boot.js` written to evict
//   it, because the cached `index.html` predates that file and never loads it.
//
// The browser is not stuck, though. It still re-fetches the worker script to
// check for updates, and that request goes to the network. So the one thing
// that can still reach such a browser is what it finds at this path.
//
// This is that: a worker that installs, refuses to wait, deletes every cache,
// unregisters itself, and reloads the pages it was controlling. After that the
// origin has no worker and no cache, and `flutter_bootstrap.js` never asks for
// another.
//
// # Why it has no fetch handler
//
// Without one, every request goes straight to the network from the moment this
// activates. That is the desired end state, and it means even the window
// between activation and unregistration serves fresh content rather than the
// cache this file is deleting.
//
// # When this can be deleted
//
// Once no browser anywhere holds a registration from a build that shipped the
// generated worker. There is no way to observe that, so it costs a few hundred
// bytes to keep and a support conversation to remove. It stays.

self.addEventListener('install', function (event) {
  // Do not queue behind the worker being replaced. The point is to take over.
  event.waitUntil(self.skipWaiting());
});

self.addEventListener('activate', function (event) {
  event.waitUntil(
    caches.keys()
      .then(function (names) {
        return Promise.all(names.map(function (name) {
          return caches.delete(name);
        }));
      })
      .then(function () {
        return self.registration.unregister();
      })
      .then(function () {
        return self.clients.matchAll({ type: 'window' });
      })
      .then(function (clients) {
        // The pages open right now were served from the cache that has just
        // been deleted, so they are still the old build. Navigating each one to
        // where it already is fetches the real thing.
        clients.forEach(function (client) {
          if ('navigate' in client) client.navigate(client.url);
        });
      })
      .catch(function () {
        // Nothing here is worth leaving a broken worker in place over.
      })
  );
});
