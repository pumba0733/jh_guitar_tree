// v3.39.3 — Fixed malloc alignment + Isolate shared library handle
// Dart FFI bridge for SoundTouch + AudioQueue playback
// Author: GPT-5 (JHGuitarTree Core)

import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:ffi/ffi.dart' as ffi_utils;

class SoundTouchFFI {
  late final String _libPath;
  ffi.DynamicLibrary? _lib;
  ffi.Pointer<ffi.Void>? _handle;
  external void st_enqueue_to_audioqueue(Float32List samples, int count);

  late final _STCreate _create;
  late final _STDispose _dispose;
  late final _STSetDouble _setTempo;
  late final _STSetDouble _setPitch;
  late final _STSetInt _setSampleRate;
  late final _STSetInt _setChannels;
  late final _STPutSamples _putSamples;
  late final _STReceiveSamples _receiveSamples;
  late final _STAudioStop _audioStop;
  late final _STAudioStart _audioStart;
  late final _STEnqueueToAudioQueue _enqueueToAudioQueue;


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
    _enqueueToAudioQueue = lib
        .lookupFunction<_STEnqueueToAudioQueueNative, _STEnqueueToAudioQueue>(
          'st_enqueue_to_audioqueue',
        );
    _audioStop = lib.lookupFunction<_STAudioStopNative, _STAudioStop>(
      'st_audio_stop',
    );
    _audioStart = lib.lookupFunction<_STAudioStartNative, _STAudioStart>(
      'st_audio_start',
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
    if (_handle == null || samples.isEmpty) return;
    final ptr = ffi_utils.malloc.allocate<ffi.Float>(samples.length);
    ptr.asTypedList(samples.length).setAll(0, samples);
    _putSamples(_handle!, ptr, samples.length);
    ffi_utils.malloc.free(ptr);
  }
 
    int receiveSamples(Float32List buffer, int maxCount) {
    if (_handle == null) return 0;
    final ptr = ffi_utils.malloc.allocate<ffi.Float>(buffer.length);
    final got = _receiveSamples(_handle!, ptr, maxCount);
    if (got > 0) {
      final out = ptr.asTypedList(buffer.length);
      buffer.setAll(0, out);
    }
    ffi_utils.malloc.free(ptr);
    return got;
  }

  void enqueueToAudioQueue(Float32List samples, int count) {
    if (_handle == null || samples.isEmpty) return;
    final ptr = ffi_utils.malloc.allocate<ffi.Float>(samples.length);
    ptr.asTypedList(samples.length).setAll(0, samples);
    _enqueueToAudioQueue(ptr, count);
    ffi_utils.malloc.free(ptr);
  }

  

  Future<void> startPlaybackAsync() async {
    final handlePtr = _handle?.address ?? 0;
    if (handlePtr == 0) return;
    final playFn = _audioStart;
    await Isolate.run(() {
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

typedef _STEnqueueToAudioQueueNative =
    ffi.Void Function(ffi.Pointer<ffi.Float>, ffi.Int32);
typedef _STEnqueueToAudioQueue = void Function(ffi.Pointer<ffi.Float>, int);

// -------- Native typedefs --------
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

// -------- Dart typedefs --------
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
