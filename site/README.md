# What goes on rotelyx.com

Two files and one page. Nothing here is part of the messenger: the application
never makes a request to this domain.

## `.well-known/assetlinks.json`

What turns an invitation link into an App Link. Android fetches it once, at
install, and from then on a tap on `https://rotelyx.com/i#...` opens the
application directly, with no browser in between and no request to this site.

It must be served from `https://rotelyx.com/.well-known/assetlinks.json`,
as `application/json`, over TLS, with no redirect. Android follows no redirect
for this file and a `301` to `www.` is the usual reason verification fails
silently.

**Two fingerprints, not one.** The upload key is what signs the build on this
machine. Play App Signing then re-signs with its own key, and that is the one
on the phone, so a file listing only the upload key verifies in testing and
fails for everybody who installs from the store.

    # the upload key, once android/key.properties exists
    keytool -list -v -keystore <the keystore> -alias <the alias> \
      | grep 'SHA256:'

    # the Play signing key: Play Console, Release, Setup, App signing

Both go in the array. Fingerprints are uppercase hex separated by colons.

## `/i`

The page somebody reaches when they tap an invitation and do not have the
application. It should say what Rotelyx is and where to get it.

**It must not read the fragment.** The invitation is everything after the `#`,
and the reason a link is safe to send through anything is that a fragment never
leaves the browser. A script here that reads `location.hash` and sends it
anywhere, an analytics call, an error reporter, a preview, throws that away.

The honest page has no script at all.

## What this domain must never host

The mailboxes. They live on `telyx.me`, separately, so that whatever happens to
a website with a messenger's name on it does not happen to the place messages
are collected from. A redirect from one to the other would undo that.
