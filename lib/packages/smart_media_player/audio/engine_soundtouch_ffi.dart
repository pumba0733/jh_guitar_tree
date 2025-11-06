import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart' as ffi_utils;

class SoundTouchFFI {
  late final ffi.DynamicLibrary _lib;
  ffi.Pointer<ffi.Void>? _handle;

  // === typedefs ===
  late final _STCreate _create;
  late final _STDispose _dispose;
  late final _STSetDouble _setTempo;
  late final _STSetDouble _setPitch;
  late final _STSetFloat _setVolume;
  late final _STSetInt _setSampleRate;
  late final _STSetInt _setChannels;
  late final _STPutSamples _putSamples;
  late final _STReceiveSamples _receiveSamples;
  late final _STAudioStart _audioStart;
  late final _STAudioStop _audioStop;
  late final _STEnqueueToAudioQueue _enqueueToAudioQueue;

  ffi.Pointer<ffi.Float>? _sharedRecvBuf;
  ffi.Pointer<ffi.Float>? _sharedSendBuf;

  SoundTouchFFI() {
    final libName = Platform.isMacOS
        ? 'libsoundtouch_ffi.dylib'
        : Platform.isWindows
        ? 'soundtouch_ffi.dll'
        : 'libsoundtouch_ffi.so';
    _lib = ffi.DynamicLibrary.open(libName);
    _lookupFunctions();
    _handle = _create();
  }

  void _lookupFunctions() {
    final l = _lib;
    _create = l.lookupFunction<_STCreateNative, _STCreate>('st_create');
    _dispose = l.lookupFunction<_STDisposeNative, _STDispose>('st_dispose');
    _setTempo = l.lookupFunction<_STSetDoubleNative, _STSetDouble>(
      'st_set_tempo',
    );
    _setPitch = l.lookupFunction<_STSetDoubleNative, _STSetDouble>(
      'st_set_pitch_semitones',
    );
    _setVolume = l.lookupFunction<_STSetFloatNative, _STSetFloat>(
      'st_set_volume',
    );
    _setSampleRate = l.lookupFunction<_STSetIntNative, _STSetInt>(
      'st_set_sample_rate',
    );
    _setChannels = l.lookupFunction<_STSetIntNative, _STSetInt>(
      'st_set_channels',
    );
    _putSamples = l.lookupFunction<_STPutSamplesNative, _STPutSamples>(
      'st_put_samples',
    );
    _receiveSamples = l
        .lookupFunction<_STReceiveSamplesNative, _STReceiveSamples>(
          'st_receive_samples',
        );
    _audioStart = l.lookupFunction<_STAudioStartNative, _STAudioStart>(
      'st_audio_start',
    );
    _audioStop = l.lookupFunction<_STAudioStopNative, _STAudioStop>(
      'st_audio_stop',
    );
    _enqueueToAudioQueue = l
        .lookupFunction<_STEnqueueToAudioQueueNative, _STEnqueueToAudioQueue>(
          'st_enqueue_to_audioqueue',
        );
  }

  void init({int sampleRate = 44100, int channels = 2}) {
    if (_handle == null) _handle = _create();
    _setSampleRate(_handle!, sampleRate);
    _setChannels(_handle!, channels);
  }

  void startPlayback() => _audioStart(_handle!);

  void setTempo(double tempo) => _setTempo(_handle!, tempo);
  void setPitchSemiTones(double semi) => _setPitch(_handle!, semi);
  void setVolume(double vol) => _setVolume(_handle!, vol);

  void putSamples(Float32List samples) {
    if (_handle == null || samples.isEmpty) return;
    _sharedSendBuf ??= ffi_utils.malloc.allocate<ffi.Float>(samples.length);
    final ptr = _sharedSendBuf!;
    ptr.asTypedList(samples.length).setAll(0, samples);
    _putSamples(_handle!, ptr, samples.length);
  }

  int receiveSamples(Float32List buffer, int maxCount) {
    if (_handle == null) return 0;
    _sharedRecvBuf ??= ffi_utils.malloc.allocate<ffi.Float>(buffer.length);
    final ptr = _sharedRecvBuf!;
    final got = _receiveSamples(_handle!, ptr, maxCount);
    if (got > 0) buffer.setAll(0, ptr.asTypedList(buffer.length));
    return got;
  }

  void enqueueToAudioQueue(Float32List samples, int count) {
    if (_handle == null || samples.isEmpty) return;
    _sharedSendBuf ??= ffi_utils.malloc.allocate<ffi.Float>(samples.length);
    final ptr = _sharedSendBuf!;
    ptr.asTypedList(samples.length).setAll(0, samples);
    _enqueueToAudioQueue(ptr, count);
  }

  void dispose() {
    if (_sharedSendBuf != null) ffi_utils.malloc.free(_sharedSendBuf!);
    if (_sharedRecvBuf != null) ffi_utils.malloc.free(_sharedRecvBuf!);
    if (_handle != null) _dispose(_handle!);
  }
}

// === Native typedefs ===
typedef _STCreateNative = ffi.Pointer<ffi.Void> Function();
typedef _STCreate = ffi.Pointer<ffi.Void> Function();
typedef _STDisposeNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _STDispose = void Function(ffi.Pointer<ffi.Void>);
typedef _STSetDoubleNative =
    ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Double);
typedef _STSetDouble = void Function(ffi.Pointer<ffi.Void>, double);
typedef _STSetIntNative = ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _STSetInt = void Function(ffi.Pointer<ffi.Void>, int);
typedef _STSetFloatNative = ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Float);
typedef _STSetFloat = void Function(ffi.Pointer<ffi.Void>, double);
typedef _STPutSamplesNative =
    ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Float>, ffi.Int32);
typedef _STPutSamples =
    void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Float>, int);
typedef _STReceiveSamplesNative =
    ffi.Int32 Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Float>,
      ffi.Int32,
    );
typedef _STReceiveSamples =
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Float>, int);
typedef _STAudioStartNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _STAudioStart = void Function(ffi.Pointer<ffi.Void>);
typedef _STAudioStopNative = ffi.Void Function();
typedef _STAudioStop = void Function();
typedef _STEnqueueToAudioQueueNative =
    ffi.Void Function(ffi.Pointer<ffi.Float>, ffi.Int32);
typedef _STEnqueueToAudioQueue = void Function(ffi.Pointer<ffi.Float>, int);
