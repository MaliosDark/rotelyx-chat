// Flutter's bootstrap, written out so it registers no service worker.
//
// # Why override it at all
//
// The generated bootstrap always emits
//
//     _flutter.loader.load({ serviceWorkerSettings: { serviceWorkerVersion: ... } })
//
// and `--pwa-strategy=none` does not change that. It only empties
// `flutter_service_worker.js`, so the worker still registers and still takes
// control of the page. Passing no settings at all is the only way to skip it:
// the loader logs "Null serviceWorker configuration. Skipping." and moves on.
//
// # Why this application must not have one
//
// A service worker pins a build inside the browser and answers from it ahead of
// the network. That is the failure mode the README already warns about in
// another guise: an old build still loads, still pairs, and then silently fails
// to interoperate because the message path moved underneath it. Nothing about
// that is visible to the person holding it.
//
// It cost real time here. A worker registered by an earlier build kept serving
// its cached copy through several rebuilds, while every check on the serving
// side correctly reported that the new files were going out.
//
// And it buys nothing. Every conversation needs the mailbox, so an offline
// Rotelyx has nothing to do.
//
// `web/boot.js` removes any worker a browser already registered, which this
// file cannot do on its own.
//
// # Maintenance
//
// The two tokens are substituted by `flutter build web`. Keep them, and keep
// this file minimal: anything else here is a copy of framework code that will
// drift from the framework.

{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load();
