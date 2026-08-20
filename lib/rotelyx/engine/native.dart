/// The engine on a phone or a desktop, reached through `dart:ffi`.
///
/// # Three symbols, not forty two
///
/// `rotelyx-mobile` exposes the whole engine as one call:
///
/// ```c
/// int32_t     rotelyx_call(const char *request_json, char **response_json);
/// void        rotelyx_string_free(char *s);
/// const char *rotelyx_abi_version(void);
/// ```
///
/// A request is `{"op":"session.send","handle":1,"text":"hi"}` and a reply is
/// `{"ok":true,"result":...}` or `{"ok":false,"error":"..."}`. Adding an
/// operation changes neither side's boilerplate, and there is exactly one place
/// in this file where a string crosses the boundary rather than forty two.
///
/// The cost is a JSON encode per call. These calls happen when a person does
/// something, so it is free. Audio will not be able to afford it, and the
/// protocol repository already says so: a call moves fifty frames a second in
/// each direction and needs a second entry point with raw buffers. That entry
/// point does not exist yet, and neither do calls.
///
/// # Memory
///
/// Every reply is an owned C string, on success and on failure alike, so there
/// is one cleanup path. [_call] frees it in a `finally` before it can return or
/// throw, which is the only discipline this file needs to get right.
///
/// Sessions and keys are integer handles into a registry the library holds, not
/// pointers. A bug here cannot free one twice or fabricate one; the worst it
/// can do is send a handle that no longer exists and get an error back.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'api.dart';
import 'call_native.dart';
import 'net_native.dart';

typedef _CallNative = Int32 Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>);
typedef _CallDart = int Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);
typedef _VersionNative = Pointer<Utf8> Function();
typedef _VersionDart = Pointer<Utf8> Function();

/// The request and reply shape this wrapper was written against.
///
/// Checked once at load. A library built from a newer protocol repository with
/// an incompatible shape says so here, rather than misreading a reply somewhere
/// deep in a handshake and failing as though the network were at fault.
const _expectedAbi = '1';

class _Library {
  _Library(this.handle)
      : call = handle.lookupFunction<_CallNative, _CallDart>('rotelyx_call'),
        free = handle.lookupFunction<_FreeNative, _FreeDart>('rotelyx_string_free'),
        abiVersion =
            handle.lookupFunction<_VersionNative, _VersionDart>('rotelyx_abi_version');

  final DynamicLibrary handle;
  final _CallDart call;
  final _FreeDart free;
  final _VersionDart abiVersion;

  static _Library? _loaded;
  static String? _failure;

  /// Open the library for whichever platform this is.
  ///
  /// Android and Linux load a shared object by name from the usual search path,
  /// which for an application is its own `lib/<abi>` directory. iOS and macOS
  /// link it statically into the runner, so the symbols are already in the
  /// process and `DynamicLibrary.process()` finds them without a file.
  static _Library? open() {
    if (_loaded != null || _failure != null) return _loaded;

    try {
      final DynamicLibrary handle;
      if (Platform.isAndroid) {
        handle = DynamicLibrary.open('librotelyx_mobile.so');
      } else if (Platform.isIOS || Platform.isMacOS) {
        handle = DynamicLibrary.process();
      } else if (Platform.isLinux) {
        handle = DynamicLibrary.open('librotelyx_mobile.so');
      } else if (Platform.isWindows) {
        handle = DynamicLibrary.open('rotelyx_mobile.dll');
      } else {
        _failure = 'no Rotelyx engine is built for ${Platform.operatingSystem}';
        return null;
      }

      final library = _Library(handle);
      final abi = library.abiVersion().toDartString();
      if (abi != _expectedAbi) {
        _failure = 'the engine speaks ABI $abi and this build expects '
            '$_expectedAbi. The native library and the application are from '
            'different versions.';
        return null;
      }

      _loaded = library;
      return library;
    } on Object catch (e) {
      _failure = 'could not load the Rotelyx engine: $e';
      return null;
    }
  }

  static String? get failure {
    open();
    return _failure;
  }

  /// The media symbols, looked up on first use.
  ///
  /// Separate from the three above because a call is the only thing that needs
  /// them, and a build that never places one should not fail to start because
  /// the library it found predates them.
  static CallSymbols? get media {
    final library = open();
    if (library == null) return null;
    try {
      return _media ??= CallSymbols(library.handle);
    } on ArgumentError {
      // The symbols are missing, which means this library was built before
      // calls existed. Reported as "no calls here" rather than as a crash.
      return null;
    }
  }

  static CallSymbols? _media;

  /// The transport symbols, looked up on first use.
  ///
  /// Separate again, and for a stronger reason than the media ones: this is the
  /// only part of the engine that opens a socket. A build that never places a
  /// call never looks these up, and a library that predates them reports "no
  /// calls here" rather than failing to load.
  static NetSymbols? get transport {
    final library = open();
    if (library == null) return null;
    try {
      return _transport ??= NetSymbols(library.handle);
    } on ArgumentError {
      return null;
    }
  }

  static NetSymbols? _transport;
}

/// Send one request and return its `result`, or throw.
Object? _call(Map<String, Object?> request) {
  final library = _Library.open();
  if (library == null) {
    throw RotelyxUnavailable(_Library.failure ?? 'the Rotelyx engine is not loaded');
  }

  final encoded = jsonEncode(request).toNativeUtf8();
  final slot = calloc<Pointer<Utf8>>();
  try {
    library.call(encoded, slot);

    // Set on success and on failure alike, so this is the only path that has
    // to free it, and the status code is not what decides.
    final replyPtr = slot.value;
    if (replyPtr == nullptr) {
      throw const RotelyxEngineError('the engine returned nothing');
    }

    final String raw;
    try {
      raw = replyPtr.toDartString();
    } finally {
      library.free(replyPtr);
    }

    final reply = jsonDecode(raw) as Map<String, dynamic>;
    if (reply['ok'] == true) return reply['result'];
    throw RotelyxEngineError('${reply['error'] ?? 'the engine refused the call'}');
  } finally {
    calloc.free(encoded);
    calloc.free(slot);
  }
}

/// The hour since the Unix epoch, which is how tags rotate.
///
/// The same expression as `bucket()` in `web/rotelyx_bridge.js`, deliberately.
/// Two devices on different platforms have to land on the same tag, so this is
/// the one number that must not drift between the two wrappers.
int _bucket() => DateTime.now().millisecondsSinceEpoch ~/ 3600000;

String _string(Object? value) => value is String ? value : '';

List<String> _strings(Object? value) => value is List
    ? value.map((e) => e is String ? e : '$e').toList(growable: false)
    : const <String>[];

int _int(Object? value) => value is int ? value : 0;

// -----------------------------------------------------------------------------

class _NativeKey implements RotelyxKey {
  _NativeKey(this.handle);
  final int handle;
  var _gone = false;

  @override
  void dispose() {
    if (_gone) return;
    _gone = true;
    try {
      _call({'op': 'key.free', 'handle': handle});
    } on Object {
      // Releasing something the engine has already dropped is not a failure
      // worth propagating out of a disposal.
    }
  }
}

/// Bind this device's transport endpoint, for calls.
///
/// Null when the library has no transport, which is a build from before calls
/// existed rather than a failure worth showing anybody.
RotelyxEndpoint? openEndpoint({
  required String identityHex,
  required String relay,
}) {
  final symbols = _Library.transport;
  if (symbols == null) return null;
  return RotelyxEndpoint.open(symbols, identityHex: identityHex, relay: relay);
}

/// Open a voice call on a live session.
///
/// Returns null when this build has no media symbols, which is a library built
/// before calls existed rather than a failure worth reporting to a user.
/// Throws [CallRefused] when the library has them and says no, because that
/// carries a reason somebody can act on.
RotelyxCall? openNativeCall(RotelyxSession session,
    {int bytesPerFrame = callBytesPerFrame, bool recoverLoss = false}) {
  final symbols = _Library.media;
  if (symbols == null) return null;
  if (session is! _NativeSession) return null;

  return NativeCall.open(symbols, session.handle,
      bytesPerFrame: bytesPerFrame, recoverLoss: recoverLoss);
}

class _NativeSession implements RotelyxSession {
  _NativeSession(this.handle);
  final int handle;
  var _gone = false;

  Object? _op(String op, [Map<String, Object?> args = const {}]) =>
      _call({'op': op, 'handle': handle, ...args});

  @override
  String keyPackage() => _string(_op('session.keyPackage'));

  @override
  String hybridPublicKey() => _string(_op('session.hybridPublicKey'));

  @override
  String safetyNumber() => _string(_op('session.safetyNumber'));

  @override
  List<String> roster() => _strings(_op('session.roster'));

  @override
  int get epoch => _int(_op('session.epoch'));

  @override
  int get memberCount => _int(_op('session.memberCount'));

  @override
  void found() => _op('session.found');

  @override
  RotelyxInvitation invite(String keyPackageB64) {
    final result = _op('session.invite', {'keyPackage': keyPackageB64});
    final map = result is Map ? result : const {};
    return RotelyxInvitation(
      commit: _string(map['commit']),
      welcome: _string(map['welcome']),
      ratchetTree: _string(map['ratchetTree']),
    );
  }

  @override
  void join(String welcomeB64, String ratchetTreeB64) =>
      _op('session.join', {'welcome': welcomeB64, 'ratchetTree': ratchetTreeB64});

  @override
  String encapsulateTo(String hybridPublicKeyB64) =>
      _string(_op('session.encapsulateTo', {'hybridPublicKey': hybridPublicKeyB64}));

  @override
  void openPq(String ciphertextB64) =>
      _op('session.openPq', {'ciphertext': ciphertextB64});

  @override
  String commitPq() => _string(_op('session.commitPq'));

  @override
  List<String> beginGroupPq(List<String> hybridPublicKeys) =>
      _strings(_op('session.beginGroupPq', {'hybridPublicKeys': hybridPublicKeys}));

  @override
  void openGroupPq(String wrappedB64) =>
      _op('session.openGroupPq', {'wrapped': wrappedB64});

  @override
  String send(String text) => _string(_op('session.send', {'text': text}));

  @override
  String? receive(String messageB64) {
    final result = _op('session.receive', {'message': messageB64});
    return result is String ? result : null;
  }

  @override
  String myTag() => _string(_op('session.myTag', {'timeBucket': _bucket()}));

  @override
  List<String> myPollingTags(int lookback) => _strings(
      _op('session.myPollingTags', {'timeBucket': _bucket(), 'lookback': lookback}));

  @override
  List<String> recipientTags() =>
      _strings(_op('session.recipientTags', {'timeBucket': _bucket()}));

  @override
  List<String> commitRecipientTags() =>
      _strings(_op('session.commitRecipientTags', {'timeBucket': _bucket()}));

  @override
  List<String> sealForGroup(String ciphertextB64) => _strings(_op(
      'session.sealForGroup', {'ciphertext': ciphertextB64, 'timeBucket': _bucket()}));

  @override
  List<String> sealCommitForGroup(String ciphertextB64) =>
      _strings(_op('session.sealCommitForGroup',
          {'ciphertext': ciphertextB64, 'timeBucket': _bucket()}));

  @override
  String openMine(String envelopeB64, int lookback) =>
      _string(_op('session.openMine', {
        'envelope': envelopeB64,
        'timeBucket': _bucket(),
        'lookback': lookback,
      }));

  @override
  String sealSession(RotelyxKey key) => _string(
      _op('session.sealSession', {'key': (key as _NativeKey).handle}));

  @override
  void dispose() {
    if (_gone) return;
    _gone = true;
    try {
      _call({'op': 'session.free', 'handle': handle});
    } on Object {
      // As for keys: a disposal is not a place to raise.
    }
  }
}

class _NativeEngine implements RotelyxEngine {
  const _NativeEngine();

  @override
  bool get ready => _Library.open() != null;

  @override
  String? get error => _Library.failure;

  @override
  String? get version {
    try {
      return _string(_call({'op': 'protocol.version'}));
    } on Object {
      return null;
    }
  }

  @override
  int get maxMembers {
    try {
      return _int(_call({'op': 'protocol.maxMembers'}));
    } on Object {
      return 0;
    }
  }

  /// Immediate. The library is linked into the process or sitting in the
  /// application's own `lib/` directory; there is no download and nothing to
  /// wait for. It is a future so that callers need not know that.
  @override
  Future<void> whenReady({Duration timeout = const Duration(seconds: 30)}) async {
    if (_Library.open() == null) {
      throw RotelyxUnavailable(_Library.failure ?? 'the Rotelyx engine is not loaded');
    }
  }

  @override
  RotelyxSession newSession(String label) =>
      _NativeSession(_int(_call({'op': 'session.new', 'label': label})));

  @override
  RotelyxSession unsealSession(String blob, RotelyxKey key) => _NativeSession(_int(
      _call({'op': 'session.unseal', 'blob': blob, 'key': (key as _NativeKey).handle})));

  @override
  RotelyxKey newKey(String passphrase) =>
      _NativeKey(_int(_call({'op': 'key.create', 'passphrase': passphrase})));

  @override
  RotelyxKey unlockKey(String passphrase, String blob) => _NativeKey(
      _int(_call({'op': 'key.unlock', 'passphrase': passphrase, 'blob': blob})));

  @override
  String rendezvousTag(String phrase) =>
      _string(_call({'op': 'rendezvous.tag', 'passphrase': phrase}));

  @override
  String sealUnder(String tagHex, String payloadB64) =>
      _string(_call({'op': 'rendezvous.seal', 'tag': tagHex, 'payload': payloadB64}));

  @override
  String openUnder(String envelopeB64, String tagHex) => _string(
      _call({'op': 'rendezvous.open', 'envelope': envelopeB64, 'tag': tagHex}));

  @override
  String sealBlob(RotelyxKey key, String dataB64) => _string(
      _call({'op': 'key.sealBlob', 'key': (key as _NativeKey).handle, 'data': dataB64}));

  @override
  String openBlob(RotelyxKey key, String blobB64) => _string(
      _call({'op': 'key.openBlob', 'key': (key as _NativeKey).handle, 'blob': blobB64}));
}

/// The engine for this platform.
RotelyxEngine createEngine() => const _NativeEngine();
