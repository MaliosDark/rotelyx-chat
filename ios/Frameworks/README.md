# `ios/Frameworks/`

`RotelyxEngine.xcframework` goes here. It is a build artefact, not source, and
it is not committed: it is several megabytes per slice and it is reproducible
from the protocol repository in one command.

```bash
tool/native/build-ios.sh          # on a Mac
```

## The two steps Xcode needs afterwards

**1. Add it to the Runner target as Do Not Embed.**

Runner target, General, Frameworks Libraries and Embedded Content, add
`RotelyxEngine.xcframework`, set Embed to **Do Not Embed**. It is a static
library, so it is linked into the Runner binary at build time; embedding would
copy an archive into the bundle that nothing ever loads.

**2. Add `-force_load` to Other Linker Flags.**

```
-force_load $(SRCROOT)/Frameworks/RotelyxEngine.xcframework/ios-arm64/librotelyx_mobile.a
```

Without it the application builds, launches, and then reports that the engine is
not loaded.

The reason is worth knowing, because the symptom points at packaging and the
cause is the linker. Every call into the engine goes through `dart:ffi`, which
looks symbols up by name at runtime. Nothing in the compiled Swift or
Objective-C references any of them, so as far as the linker can tell the entire
archive is unreachable, and it drops it. `-force_load` says keep it anyway.

This is also why `lib/rotelyx/engine/native.dart` uses
`DynamicLibrary.process()` on iOS rather than opening a file: after this, the
symbols are already in the process.

## Why iOS is static and Android is not

Android loads `librotelyx_mobile.so` from the application's own `lib/<abi>`
directory, which is on the loader path, so `DynamicLibrary.open` finds it by
name. iOS will not load a shared library out of an application bundle, so the
engine is linked in instead. Same crate, same ABI, two ways of arriving.
