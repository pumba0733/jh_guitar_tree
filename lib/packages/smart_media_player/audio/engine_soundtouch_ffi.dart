import 'dart:ffi' as ffi;
import 'dart:typed_data';
import 'dart:io';
import 'package:ffi/ffi.dart';

// ===============================================================
//  libsoundtouch_ffi.dylib 로드
// ===============================================================
final ffi.DynamicLibrary _lib = Platform.isMacOS
    ? ffi.DynamicLibrary.open('libsoundtouch_ffi.dylib')
    : throw UnsupportedError('Only macOS supported');

// ------------------------------
// Native typedefs
// ------------------------------
typedef _st_create_native = ffi.Void Function();
typedef _st_dispose_native = ffi.Void Function();
typedef _st_feedPcm_native =
    ffi.Void Function(ffi.Pointer<ffi.Float>, ffi.Int32);

typedef _st_setTempo_native = ffi.Void Function(ffi.Float);
typedef _st_setPitch_native = ffi.Void Function(ffi.Float);
typedef _st_setVolume_native = ffi.Void Function(ffi.Float);

typedef _st_getPlaybackTime_native = ffi.Double Function();
typedef _st_copyLastBuffer_native =
    ffi.Void Function(ffi.Pointer<ffi.Float>, ffi.Int32);
typedef _st_getRmsLevel_native = ffi.Double Function();

// ------------------------------
// Dart typedefs
// ------------------------------
typedef _st_create_dart = void Function();
typedef _st_dispose_dart = void Function();
typedef _st_feedPcm_dart = void Function(ffi.Pointer<ffi.Float>, int);

typedef _st_setTempo_dart = void Function(double);
typedef _st_setPitch_dart = void Function(double);
typedef _st_setVolume_dart = void Function(double);

typedef _st_getPlaybackTime_dart = double Function();

typedef _st_copyLastBuffer_dart = void Function(ffi.Pointer<ffi.Float>, int);
typedef _st_getRmsLevel_dart = double Function();

// ------------------------------
// Bindings
// ------------------------------
final st_create = _lib.lookupFunction<_st_create_native, _st_create_dart>(
  'st_create',
);

final st_dispose = _lib.lookupFunction<_st_dispose_native, _st_dispose_dart>(
  'st_dispose',
);

final st_feedPcm = _lib.lookupFunction<_st_feedPcm_native, _st_feedPcm_dart>(
  'st_feedPcm',
);

final st_setTempo = _lib.lookupFunction<_st_setTempo_native, _st_setTempo_dart>(
  'st_set_tempo',
);

final st_setPitch = _lib.lookupFunction<_st_setPitch_native, _st_setPitch_dart>(
  'st_set_pitch_semitones',
);

final st_setVolume = _lib
    .lookupFunction<_st_setVolume_native, _st_setVolume_dart>('st_set_volume');

final st_getPlaybackTime = _lib
    .lookupFunction<_st_getPlaybackTime_native, _st_getPlaybackTime_dart>(
      'st_get_playback_time',
    );

final st_copyLastBuffer = _lib
    .lookupFunction<_st_copyLastBuffer_native, _st_copyLastBuffer_dart>(
      'st_copyLastBuffer',
    );

final st_getRmsLevel = _lib
    .lookupFunction<_st_getRmsLevel_native, _st_getRmsLevel_dart>(
      'st_getRmsLevel',
    );

// ------------------------------
// Helper
// ------------------------------
void feedPcmToFFI(Float32List pcm) {
  if (pcm.isEmpty) return;

  final ptr = calloc<ffi.Float>(pcm.length);
  for (int i = 0; i < pcm.length; i++) {
    ptr[i] = pcm[i];
  }
  st_feedPcm(ptr, pcm.length ~/ 2);
  calloc.free(ptr);
}

// =======================================================
//  SeekTo
// =======================================================

typedef st_seekTo_native = ffi.Void Function(ffi.Double);
typedef st_seekTo_dart = void Function(double);

late final st_seekTo_dart st_seekTo = _lib
    .lookup<ffi.NativeFunction<st_seekTo_native>>('st_seekTo')
    .asFunction();
