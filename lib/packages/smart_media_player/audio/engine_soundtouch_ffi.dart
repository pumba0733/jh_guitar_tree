// lib/packages/smart_media_player/audio/engine_soundtouch_ffi.dart
// v3.35.2 | Full FFI Bridge for SoundTouch (PCM integration ready)

import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart' as ffi_utils;

/// FFI bridge for SoundTouch native library (libsoundtouch_ffi)
/// Supports tempo/pitch control + PCM put/receive interface.
class SoundTouchFFI {
  // Native library and functions
  late final ffi.DynamicLibrary _lib;

  late final _STCreate _create;
  late final _STDispose _dispose;
  late final _STSetDouble _setTempo;
  late final _STSetDouble _setPitch;
  late final _STSetInt _setSampleRate;
  late final _STSetInt _setChannels;
  late final _STPutSamples _putSamples;
  late final _STReceiveSamples _receiveSamples;

  ffi.Pointer<ffi.Void>? _handle;
  double _tempo = 1.0;
  double _pitch = 0.0;

  // ───────────────────────────────
  // Constructor: load dynamic lib
  // ───────────────────────────────
  SoundTouchFFI() {
    final libName = Platform.isMacOS
        ? 'libsoundtouch_ffi.dylib'
        : Platform.isWindows
        ? 'soundtouch_ffi.dll'
        : 'libsoundtouch_ffi.so';

    _lib = ffi.DynamicLibrary.open(libName);

    // Lookup native functions
    _create = _lib.lookupFunction<_STCreateNative, _STCreate>('st_create');
    _dispose = _lib.lookupFunction<_STDisposeNative, _STDispose>('st_dispose');
    _setTempo = _lib.lookupFunction<_STSetDoubleNative, _STSetDouble>(
      'st_set_tempo',
    );
    _setPitch = _lib.lookupFunction<_STSetDoubleNative, _STSetDouble>(
      'st_set_pitch_semitones',
    );
    _setSampleRate = _lib.lookupFunction<_STSetIntNative, _STSetInt>(
      'st_set_sample_rate',
    );
    _setChannels = _lib.lookupFunction<_STSetIntNative, _STSetInt>(
      'st_set_channels',
    );
    _putSamples = _lib.lookupFunction<_STPutSamplesNative, _STPutSamples>(
      'st_put_samples',
    );
    _receiveSamples = _lib
        .lookupFunction<_STReceiveSamplesNative, _STReceiveSamples>(
          'st_receive_samples',
        );

    _handle = _create();
  }

  // ───────────────────────────────
  // Public API
  // ───────────────────────────────

  void init({int sampleRate = 44100, int channels = 2}) {
    _handle ??= _create();
    _setSampleRate(_handle!, sampleRate);
    _setChannels(_handle!, channels);
  }

  void setTempo(double tempo) {
    if (_handle == null) return;
    _setTempo(_handle!, tempo);
    _tempo = tempo;
  }

  void setPitchSemiTones(double semi) {
    if (_handle == null) return;
    _setPitch(_handle!, semi);
    _pitch = semi;
  }

  void putSamples(Float32List samples) {
    if (_handle == null) return;
    final ptr = ffi_utils.malloc.allocate<ffi.Float>(samples.lengthInBytes);
    ptr.asTypedList(samples.length).setAll(0, samples);
    _putSamples(_handle!, ptr, samples.length);
    ffi_utils.malloc.free(ptr);
  }

  Float32List receiveSamples([int maxSamples = 8192]) {
    if (_handle == null) return Float32List(0);
    final ptr = ffi_utils.malloc.allocate<ffi.Float>(maxSamples * 4);
    final got = _receiveSamples(_handle!, ptr, maxSamples);
    final out = Float32List(got)..setAll(0, ptr.asTypedList(got));
    ffi_utils.malloc.free(ptr);
    return out;
  }

  double get tempo => _tempo;
  double get pitch => _pitch;

  void dispose() {
    if (_handle != null) {
      _dispose(_handle!);
      _handle = null;
    }
  }
}

// ───────────────────────────────
// Native Type Definitions
// (UpperCamelCase for Dart lint)
// ───────────────────────────────

typedef _STCreateNative = ffi.Pointer<ffi.Void> Function();
typedef _STDisposeNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _STSetDoubleNative =
    ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Double);
typedef _STSetIntNative = ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _STPutSamplesNative =
    ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Float>, ffi.Int32);
typedef _STReceiveSamplesNative =
    ffi.Int32 Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Float>,
      ffi.Int32,
    );

// Dart callable typedefs
typedef _STCreate = ffi.Pointer<ffi.Void> Function();
typedef _STDispose = void Function(ffi.Pointer<ffi.Void>);
typedef _STSetDouble = void Function(ffi.Pointer<ffi.Void>, double);
typedef _STSetInt = void Function(ffi.Pointer<ffi.Void>, int);
typedef _STPutSamples =
    void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Float>, int);
typedef _STReceiveSamples =
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Float>, int);
