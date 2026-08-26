/// The six C functions a voice call is made of.
///
/// # Why this is its own file
///
/// `native.dart` speaks one function, `rotelyx_call`, which takes JSON and
/// returns JSON. That shape is right for a handshake, where a request happens
/// occasionally and clarity is worth more than the allocation.
///
/// A call is the opposite. Fifty times a second, in each direction, on a thread
/// that must not stall: encoding a JSON envelope around 960 samples and parsing
/// one back would cost more than the codec it wraps. So the media path is six
/// direct symbols with no serialisation anywhere, and it lives apart so that
/// nobody reading the JSON dispatcher has to wonder why one operation is
/// different.
///
/// # What is allocated, and when
///
/// Once per call, not once per frame. The buffers below are allocated when a
/// call opens and reused for its lifetime, because malloc on the audio path is
/// the classic way to turn a working call into an intermittent one on a slow
/// phone. They are freed in [close], including when a call ends badly.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../call_api.dart';

export '../call_api.dart';

typedef OpenNative = Int64 Function(Uint64, Int32, Int32, Pointer<Uint8>, Int32);
typedef OpenDart = int Function(int, int, int, Pointer<Uint8>, int);

typedef CaptureNative = Int32 Function(
    Int64, Pointer<Int16>, Int32, Pointer<Uint8>, Int32);
typedef CaptureDart = int Function(
    int, Pointer<Int16>, int, Pointer<Uint8>, int);

typedef DeliverNative = Int32 Function(Int64, Pointer<Uint8>, Int32, Uint64);
typedef DeliverDart = int Function(int, Pointer<Uint8>, int, int);

typedef PlaybackNative = Int32 Function(Int64, Pointer<Int16>, Int32);
typedef PlaybackDart = int Function(int, Pointer<Int16>, int);

typedef StatsNative = Int32 Function(Int64, Pointer<Pointer<Utf8>>);
typedef StatsDart = int Function(int, Pointer<Pointer<Utf8>>);

typedef CloseNative = Int32 Function(Int64);
typedef CloseDart = int Function(int);

typedef FreeNative = Void Function(Pointer<Utf8>);
typedef FreeDart = void Function(Pointer<Utf8>);

/// The media symbols, looked up once.
class CallSymbols {
  CallSymbols(DynamicLibrary handle)
      : open = handle.lookupFunction<OpenNative, OpenDart>('rotelyx_call_open'),
        capture = handle
            .lookupFunction<CaptureNative, CaptureDart>('rotelyx_call_capture'),
        deliver = handle
            .lookupFunction<DeliverNative, DeliverDart>('rotelyx_call_deliver'),
        playback = handle
            .lookupFunction<PlaybackNative, PlaybackDart>('rotelyx_call_playback'),
        stats =
            handle.lookupFunction<StatsNative, StatsDart>('rotelyx_call_stats'),
        closeCall =
            handle.lookupFunction<CloseNative, CloseDart>('rotelyx_call_close'),
        free = handle.lookupFunction<FreeNative, FreeDart>('rotelyx_string_free');

  final OpenDart open;
  final CaptureDart capture;
  final DeliverDart deliver;
  final PlaybackDart playback;
  final StatsDart stats;
  final CloseDart closeCall;
  final FreeDart free;
}

/// What `rotelyx_call_open` means by a negative answer.
///
/// Returned as a number rather than a message because it is called from a path
/// that must not allocate. Translated here, once, so no caller has to remember
/// what minus three was.
String openFailure(int code) => switch (code) {
      -1 => 'that session is not open',
      -2 => 'there is no conversation to call through yet',
      -3 => 'this device is not in the conversation it is calling from',
      -4 => 'too many people are already speaking',
      -5 => 'this call has no identifier to key it with',
      _ => 'the call could not be opened ($code)',
    };

class NativeCall implements RotelyxCall {
  NativeCall._(this._lib, this._handle)
      : _pcmIn = calloc<Int16>(callFrameSamples),
        _pcmOut = calloc<Int16>(callFrameSamples),
        _datagram = calloc<Uint8>(callMaxDatagram);

  final CallSymbols _lib;
  final int _handle;

  /// Allocated once per call and reused for its life. See the header.
  final Pointer<Int16> _pcmIn;
  final Pointer<Int16> _pcmOut;
  final Pointer<Uint8> _datagram;

  bool _closed = false;

  /// Open a call on [session], or throw with the reason.
  ///
  /// [call] is the identifier both ends agreed on for this call and no other,
  /// which is what the media keys are bound to. Without it they would be a
  /// function of the MLS epoch alone, the frame counter would restart at zero,
  /// and a second call inside one epoch would encrypt under the first call's
  /// key and nonce from its first frame onwards. The engine refuses anything
  /// shorter than eight bytes rather than key a call weakly.
  static NativeCall open(
    CallSymbols lib,
    int session, {
    required String call,
    int bytesPerFrame = callBytesPerFrame,
    bool recoverLoss = false,
  }) {
    final bytes = utf8.encode(call);
    final buffer = calloc<Uint8>(bytes.length);
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      final handle =
          lib.open(session, bytesPerFrame, recoverLoss ? 1 : 0, buffer, bytes.length);
      if (handle < 0) throw CallRefused(openFailure(handle));
      return NativeCall._(lib, handle);
    } finally {
      calloc.free(buffer);
    }
  }

  @override
  Uint8List? capture(Int16List pcm) {
    if (_closed) return null;
    if (pcm.length != callFrameSamples) {
      throw ArgumentError(
          'a frame is exactly $callFrameSamples samples, got ${pcm.length}');
    }

    // Copied through a typed view rather than element by element. The loop
    // version showed up in a profile as more expensive than the codec.
    _pcmIn.asTypedList(callFrameSamples).setAll(0, pcm);

    final written = _lib.capture(
        _handle, _pcmIn, callFrameSamples, _datagram, callMaxDatagram);

    // Zero is the first frame of a call, which produces nothing while the
    // encoder fills its window. Negative is a refusal. Neither is worth
    // stopping a call for and neither is a datagram.
    if (written <= 0) return null;

    // Copied out, because the buffer is reused on the very next frame.
    return Uint8List.fromList(_datagram.asTypedList(written));
  }

  @override
  void deliver(Uint8List datagram) {
    if (_closed || datagram.isEmpty) return;
    if (datagram.length > callMaxDatagram) return;

    _datagram.asTypedList(datagram.length).setAll(0, datagram);
    _lib.deliver(_handle, _datagram, datagram.length,
        DateTime.now().millisecondsSinceEpoch);
  }

  @override
  Int16List? playback() {
    if (_closed) return null;

    final samples = _lib.playback(_handle, _pcmOut, callFrameSamples);
    if (samples <= 0) return null;

    return Int16List.fromList(_pcmOut.asTypedList(samples));
  }

  @override
  CallStats? stats() {
    if (_closed) return null;

    final out = calloc<Pointer<Utf8>>();
    try {
      final code = _lib.stats(_handle, out);
      final reply = out.value;
      if (reply == nullptr) return null;

      try {
        if (code != 0) return null;
        final json = jsonDecode(reply.toDartString());
        if (json is! Map) return null;

        final result = json['result'];
        if (result is! Map) return null;

        return CallStats(
          participants: result['participants'] as int? ?? 0,
          concealed: result['concealed'] as int? ?? 0,
          recoverable: result['recoverable'] == true,
        );
      } finally {
        _lib.free(reply);
      }
    } on Object {
      return null;
    } finally {
      calloc.free(out);
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;

    // The handle first, then the buffers. The other order leaves the library
    // holding a call whose memory has been returned, and the window between
    // them is exactly when an audio thread might still be in `capture`.
    _lib.closeCall(_handle);
    calloc.free(_pcmIn);
    calloc.free(_pcmOut);
    calloc.free(_datagram);
  }
}

/// A call that could not be opened, with the reason in words.
class CallRefused implements Exception {
  const CallRefused(this.message);
  final String message;
  @override
  String toString() => message;
}
