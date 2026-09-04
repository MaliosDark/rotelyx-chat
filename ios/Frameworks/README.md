# `ios/Frameworks/`

`RotelyxEngine.xcframework` goes here. It is a build artefact, not source, and
it is not committed: it is several megabytes per slice and it is reproducible
from the protocol repository in one command.

```bash
tool/native/build-ios.sh          # on a Mac
```

## What the Xcode project already does with it

Both steps below are in `Runner.xcodeproj` now, as build settings rather than
as anything anybody has to remember. They were written here as manual Xcode
steps because there was no Mac to try them on; the first build on one showed
that one of the two was not enough.

**1. `-force_load`, so the archive is linked at all.**

```
-force_load $(SRCROOT)/Frameworks/RotelyxEngine.xcframework/ios-arm64/librotelyx_mobile.a
```

Every call into the engine goes through `dart:ffi`, which looks symbols up by
name at runtime. Nothing in the compiled Swift references any of them, so as far
as the linker can tell the whole archive is unreachable and it takes only the
members something asks for, which is none of them.

Set per SDK, because the device slice and the simulator slice are different
files and a build for one cannot link the other:
`OTHER_LDFLAGS[sdk=iphoneos*]` takes `ios-arm64`,
`OTHER_LDFLAGS[sdk=iphonesimulator*]` takes `ios-arm64_x86_64-simulator`.

**2. `-Wl,-u` on the three ABI symbols, so the link survives dead stripping.**

```
-Wl,-u,_rotelyx_call -Wl,-u,_rotelyx_string_free -Wl,-u,_rotelyx_abi_version
```

This is the half that was missing, and it fails silently in the worst way: the
build succeeds, the application launches, and it reports that the engine is not
loaded. `-force_load` loads the objects; it does not anchor them. Release builds
run `-dead_strip`, and in an executable a global symbol is not a root of that
walk — only the entry point and what it reaches. So the linker pulled in 119 MB
and then threw all of it away, and the finished binary was 400 KB with not one
engine symbol in it.

`-u` names a symbol as undefined before the link starts, which makes it a root,
and everything it reaches is kept. With it the binary is 3.6 MB and

```
xcrun dyld_info -exports build/ios/Release-iphoneos/Runner.app/Runner
```

lists `_rotelyx_call`, `_rotelyx_string_free` and `_rotelyx_abi_version`. That
export table is what `dlsym` reads, so it is the thing worth checking after any
change to the linker flags: a binary of roughly the right size proves the code
arrived, and those three names prove it can be found.

This is also why `lib/rotelyx/engine/native.dart` uses
`DynamicLibrary.process()` on iOS rather than opening a file: after this, the
symbols are already in the process.

## Why iOS is static and Android is not

Android loads `librotelyx_mobile.so` from the application's own `lib/<abi>`
directory, which is on the loader path, so `DynamicLibrary.open` finds it by
name. iOS will not load a shared library out of an application bundle, so the
engine is linked in instead. Same crate, same ABI, two ways of arriving.
