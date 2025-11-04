// v3.35.7 — Isolate-safe FFI Bridge for SoundTouch
// 개선점:
// - DynamicLibrary를 Isolate간 직접 전달하지 않고 경로 문자열만 전달
// - startPlaybackAsync()에서 isolate 내부에서 재-open
// - 모든 함수 호출 시 handle null 가드 강화

import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:ffi/ffi.dart' as ffi_utils;

/// FFI bridge for native SoundTouch Audio Engine.
/// Provides tempo/pitch control & PCM feed via AudioQueue.
class SoundTouchFFI {
  late final String _libPath;
  ffi.DynamicLibrary? _lib;
  ffi.Pointer<ffi.Void>? _handle;

  // Lookup handles
  late final _STCreate _create;
  late final _STDispose _dispose;
  late final _STSetDouble _setTempo;
  late final _STSetDouble _setPitch;
  late final _STSetInt _setSampleRate;
  late final _STSetInt _setChannels;
  late final _STPutSamples _putSamples;
  late final _STReceiveSamples _receiveSamples;
  late final _STAudioStop _audioStop;

  SoundTouchFFI() {
    final libName = Platform.isMacOS
        ? 'libsoundtouch_ffi.dylib'
        : Platform.isWindows
        ? 'soundtouch_ffi.dll'
        : 'libsoundtouch_ffi.so';
    _libPath = libName;

    _lib = ffi.DynamicLibrary.open(libName);
    _lookupFunctions();
    _handle = _create();
  }

  void _lookupFunctions() {
    final lib = _lib!;
    _create = lib.lookupFunction<_STCreateNative, _STCreate>('st_create');
    _dispose = lib.lookupFunction<_STDisposeNative, _STDispose>('st_dispose');
    _setTempo = lib.lookupFunction<_STSetDoubleNative, _STSetDouble>(
      'st_set_tempo',
    );
    _setPitch = lib.lookupFunction<_STSetDoubleNative, _STSetDouble>(
      'st_set_pitch_semitones',
    );
    _setSampleRate = lib.lookupFunction<_STSetIntNative, _STSetInt>(
      'st_set_sample_rate',
    );
    _setChannels = lib.lookupFunction<_STSetIntNative, _STSetInt>(
      'st_set_channels',
    );
    _putSamples = lib.lookupFunction<_STPutSamplesNative, _STPutSamples>(
      'st_put_samples',
    );
    _receiveSamples = lib
        .lookupFunction<_STReceiveSamplesNative, _STReceiveSamples>(
          'st_receive_samples',
        );
    _audioStop = lib.lookupFunction<_STAudioStopNative, _STAudioStop>(
      'st_audio_stop',
    );
  }

  void init({int sampleRate = 44100, int channels = 2}) {
    if (_handle == null) _handle = _create();
    _setSampleRate(_handle!, sampleRate);
    _setChannels(_handle!, channels);
  }

  void setTempo(double tempo) {
    if (_handle != null) _setTempo(_handle!, tempo);
  }

  void setPitchSemiTones(double semi) {
    if (_handle != null) _setPitch(_handle!, semi);
  }

  void putSamples(Float32List samples) {
    if (_handle == null) return;
    final ptr = ffi_utils.malloc.allocate<ffi.Float>(samples.length * 4);
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

  /// AudioQueue playback — safe Isolate version
  Future<void> startPlaybackAsync() async {
    final path = _libPath;
    final handlePtr = _handle?.address ?? 0;
    if (handlePtr == 0) return;

    await Isolate.run(() {
      final lib = ffi.DynamicLibrary.open(path);
      final playFn = lib.lookupFunction<_STAudioStartNative, _STAudioStart>(
        'st_audio_start',
      );
      playFn(ffi.Pointer.fromAddress(handlePtr));
    });
  }

  void stop() {
    try {
      _audioStop();
    } catch (_) {}
  }

  void dispose() {
    if (_handle != null) {
      _dispose(_handle!);
      _handle = null;
    }
  }
}

// === Native typedefs ===
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
typedef _STAudioStopNative = ffi.Void Function();
typedef _STAudioStartNative = ffi.Void Function(ffi.Pointer<ffi.Void>);

// Dart typedefs
typedef _STCreate = ffi.Pointer<ffi.Void> Function();
typedef _STDispose = void Function(ffi.Pointer<ffi.Void>);
typedef _STSetDouble = void Function(ffi.Pointer<ffi.Void>, double);
typedef _STSetInt = void Function(ffi.Pointer<ffi.Void>, int);
typedef _STPutSamples =
    void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Float>, int);
typedef _STReceiveSamples =
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Float>, int);
typedef _STAudioStop = void Function();
typedef _STAudioStart = void Function(ffi.Pointer<ffi.Void>);
