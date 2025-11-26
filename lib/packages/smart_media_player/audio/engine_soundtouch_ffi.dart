// lib/packages/smart_media_player/audio/engine_soundtouch_ffi.dart

import 'dart:ffi' as ffi;
import 'dart:typed_data';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// ===============================================================
///  SmartMediaPlayer v3.8-FF — STEP 2
///  engine_soundtouch_ffi.dart (FFI 계층 최종본)
///
///  네이티브 엔진: FFmpeg + SoundTouch + miniaudio
///  C++ 심볼:
///    - void   st_create()
///    - void   st_dispose()
///    - bool   st_openFile(const char* path)
///    - void   st_close()
///    - void   st_set_tempo(float t)
///    - void   st_set_pitch_semitones(float semi)
///    - void   st_set_volume(float v)
///    - double st_get_playback_time()          // seconds (레거시)
///    - double st_getDurationMs()              // ms
///    - double st_getPositionMs()              // ms (SoT)
///    - void   st_seekToMs(double ms)
///    - void   st_copyLastBuffer(float* dst, int maxFrames)
///    - double st_getRmsLevel()
///    - void   st_feed_pcm(float* data, int frames) // no-op
///
///  Dart 쪽에서:
///    - st_create / st_dispose : 엔진 수명 관리
///    - stOpenFile(String path) / stCloseFile()
///    - st_setTempo / st_setPitch / st_setVolume
///    - stGetDuration(), stGetPosition(), stGetPlaybackTimeSeconds()
///    - stSeekTo(Duration / ms)
///    - stGetLastBuffer(), stGetRmsLevel()
///    - feedPcmToFFI(...)는 기존호환용 no-op 래퍼
/// ===============================================================

ffi.DynamicLibrary _openNativeLibrary() {
  if (Platform.isMacOS) {
    // 앱 번들 내 Frameworks/libsoundtouch_ffi.dylib 기준
    return ffi.DynamicLibrary.open('libsoundtouch_ffi.dylib');
  }
  throw UnsupportedError(
    'SmartMediaPlayer native engine is only supported on macOS for now.',
  );
}

final ffi.DynamicLibrary _lib = _openNativeLibrary();

/// ------------------------------
/// Native typedefs
/// ------------------------------

typedef _st_create_native = ffi.Void Function();
typedef _st_dispose_native = ffi.Void Function();

typedef _st_setTempo_native = ffi.Void Function(ffi.Float);
typedef _st_setPitch_native = ffi.Void Function(ffi.Float);
typedef _st_setVolume_native = ffi.Void Function(ffi.Float);

typedef _st_getPlaybackTime_native = ffi.Double Function();
typedef _st_getDurationMs_native = ffi.Double Function();
typedef _st_getPositionMs_native = ffi.Double Function();

typedef _st_seekToMs_native = ffi.Void Function(ffi.Double);

typedef _st_copyLastBuffer_native =
    ffi.Void Function(ffi.Pointer<ffi.Float>, ffi.Int32);

typedef _st_getRmsLevel_native = ffi.Double Function();

typedef _st_openFile_native = ffi.Bool Function(ffi.Pointer<Utf8>);
typedef _st_close_native = ffi.Void Function();

typedef _st_feedPcm_native =
    ffi.Void Function(ffi.Pointer<ffi.Float>, ffi.Int32);

/// ------------------------------
/// Dart typedefs
/// ------------------------------

typedef _st_create_dart = void Function();
typedef _st_dispose_dart = void Function();

typedef _st_setTempo_dart = void Function(double);
typedef _st_setPitch_dart = void Function(double);
typedef _st_setVolume_dart = void Function(double);

typedef _st_getPlaybackTime_dart = double Function();
typedef _st_getDurationMs_dart = double Function();
typedef _st_getPositionMs_dart = double Function();

typedef _st_seekToMs_dart = void Function(double);

typedef _st_copyLastBuffer_dart = void Function(ffi.Pointer<ffi.Float>, int);

typedef _st_getRmsLevel_dart = double Function();

typedef _st_openFile_dart = bool Function(ffi.Pointer<Utf8>);
typedef _st_close_dart = void Function();

typedef _st_feedPcm_dart = void Function(ffi.Pointer<ffi.Float>, int);

/// ===============================================================
/// Raw FFI bindings (C 심볼과 1:1 매핑)
/// ===============================================================

final _st_create = _lib.lookupFunction<_st_create_native, _st_create_dart>(
  'st_create',
);

final _st_dispose = _lib.lookupFunction<_st_dispose_native, _st_dispose_dart>(
  'st_dispose',
);

final _st_setTempo = _lib
    .lookupFunction<_st_setTempo_native, _st_setTempo_dart>('st_set_tempo');

final _st_setPitch = _lib
    .lookupFunction<_st_setPitch_native, _st_setPitch_dart>(
      'st_set_pitch_semitones',
    );

final _st_setVolume = _lib
    .lookupFunction<_st_setVolume_native, _st_setVolume_dart>('st_set_volume');

final _st_getPlaybackTime = _lib
    .lookupFunction<_st_getPlaybackTime_native, _st_getPlaybackTime_dart>(
      'st_get_playback_time',
    );

final _st_getDurationMs = _lib
    .lookupFunction<_st_getDurationMs_native, _st_getDurationMs_dart>(
      'st_getDurationMs',
    );

final _st_getPositionMs = _lib
    .lookupFunction<_st_getPositionMs_native, _st_getPositionMs_dart>(
      'st_getPositionMs',
    );

final _st_seekToMs = _lib
    .lookupFunction<_st_seekToMs_native, _st_seekToMs_dart>('st_seekToMs');

final _st_copyLastBuffer = _lib
    .lookupFunction<_st_copyLastBuffer_native, _st_copyLastBuffer_dart>(
      'st_copyLastBuffer',
    );

final _st_getRmsLevel = _lib
    .lookupFunction<_st_getRmsLevel_native, _st_getRmsLevel_dart>(
      'st_getRmsLevel',
    );

final _st_openFile = _lib
    .lookupFunction<_st_openFile_native, _st_openFile_dart>('st_openFile');

final _st_close = _lib.lookupFunction<_st_close_native, _st_close_dart>(
  'st_close',
);

/// feedPcm (레거시/테스트용, 네이티브는 no-op)
final st_feedPcm = _lib.lookupFunction<_st_feedPcm_native, _st_feedPcm_dart>(
  'st_feed_pcm',
);

/// ===============================================================
/// Public low-level API (기존 이름 유지)
///  - 다른 Dart 파일에서 이미 사용 중인 심볼은 그대로 노출
/// ===============================================================

/// 엔진 생성 / 디바이스 초기화
final st_create = _st_create;

/// 엔진 해제 / 디바이스 정리
final st_dispose = _st_dispose;

/// Tempo (배속) 설정: 0.5 ~ 1.5
final st_setTempo = _st_setTempo;

/// Pitch (세미톤) 설정: -12 ~ +12
final st_setPitch = _st_setPitch;

/// Volume 설정: 0.0 ~ 1.0
final st_setVolume = _st_setVolume;

/// 레거시 재생 시간 (초 단위 SOT)
final st_getPlaybackTime = _st_getPlaybackTime;

/// 내부 SoT(ms) 기반 seek — 기존 st_seekTo 이름과 호환 유지.
/// 인수 단위: milliseconds.
void st_seekTo(double positionMs) {
  _st_seekToMs(positionMs);
}

/// ===============================================================
/// High-level helpers (Step 2에서 새로 추가되는 FFI 래퍼)
/// ===============================================================

/// 엔진 초기화 헬퍼
void stInitEngine() {
  st_create();
}

/// 엔진 완전 종료 헬퍼
void stDisposeEngine() {
  st_dispose();
}

/// 파일 열기 (FFmpeg 디코더 + SoundTouch + miniaudio 준비)
/// - path: UTF-8 경로 (macOS 파일시스템 경로)
/// - return: true = 성공, false = 실패
bool stOpenFile(String path) {
  final ptr = path.toNativeUtf8();
  try {
    final ok = _st_openFile(ptr);
    return ok;
  } finally {
    calloc.free(ptr);
  }
}

/// 현재 열려 있는 파일 닫기.
/// 디코더 스레드 및 FFmpeg 컨텍스트를 정리.
void stCloseFile() {
  _st_close();
}

/// 총 길이(Duration) — FFmpeg duration 기준 (ms → Duration)
Duration stGetDuration() {
  final ms = _st_getDurationMs();
  if (ms.isNaN || ms.isInfinite) {
    return Duration.zero;
  }
  return Duration(milliseconds: ms.round());
}

/// 현재 위치(Duration) — SoT 기준 (ms → Duration)
Duration stGetPosition() {
  final ms = _st_getPositionMs();
  if (ms.isNaN || ms.isInfinite) {
    return Duration.zero;
  }
  return Duration(milliseconds: ms.round());
}

/// 재생 시간(초) — 기존 st_get_playback_time 래핑
double stGetPlaybackTimeSeconds() {
  final sec = _st_getPlaybackTime();
  if (sec.isNaN || sec.isInfinite) return 0.0;
  return sec;
}

/// ms 단위 seek (SoT 기준)
void stSeekToDuration(Duration position) {
  final ms = position.inMilliseconds.toDouble();
  _st_seekToMs(ms);
}

/// 최근 출력 버퍼(stereo, interleaved)를 가져온다.
/// - maxFrames: 최대 프레임 수 (기본 4096, 네이티브 BUF_FRAMES와 동일)
/// - return: 길이 = frames * 2(float32) 인 Float32List
Float32List stGetLastBuffer({int maxFrames = 4096}) {
  if (maxFrames <= 0) {
    return Float32List(0);
  }

  final frames = maxFrames;
  final samples = frames * 2; // stereo
  final ptr = calloc<ffi.Float>(samples);

  try {
    _st_copyLastBuffer(ptr, frames);
    final out = Float32List(samples);
    for (var i = 0; i < samples; i++) {
      out[i] = ptr[i];
    }
    return out;
  } finally {
    calloc.free(ptr);
  }
}

/// RMS 레벨 (0.0 ~ 1.0 근처 double)
double stGetRmsLevel() {
  final rms = _st_getRmsLevel();
  if (rms.isNaN || rms.isInfinite) return 0.0;
  return rms;
}

/// ===============================================================
/// Legacy PCM feed helper (현 시점에서는 네이티브에서 no-op)
///  - 기존 soundtouch_audio_chain 테스트 코드 호환용
/// ===============================================================

void feedPcmToFFI(Float32List pcm) {
  if (pcm.isEmpty) return;

  final ptr = calloc<ffi.Float>(pcm.length);
  try {
    for (var i = 0; i < pcm.length; i++) {
      ptr[i] = pcm[i];
    }
    // 네이티브 st_feed_pcm은 지금은 no-op이지만
    // 심볼 mismatch 크래시 방지를 위해 정확하게 호출한다.
    st_feedPcm(ptr, pcm.length ~/ 2);
  } finally {
    calloc.free(ptr);
  }
}

/// ===============================================================
/// Optional: 임시 play/pause 헬퍼
///  - STEP 1 C++ 엔진에는 별도 play/pause 심볼이 없으므로
///    여기서는 "open 후 자동 재생" 전제를 유지한다.
///  - pause는 임시로 volume=0.0을 사용하고,
///    resume은 1.0(또는 호출자가 관리하는 값)으로 되돌리는 식으로
///    EngineApi에서 래핑 가능.
/// ===============================================================

/// (임시) 재생 시작: 현재 구조에서는 stOpenFile 이후 자동 재생이므로 no-op.
void stPlay() {
  // 필요 시 나중에 네이티브 st_play() 심볼 추가 후 교체.
}

/// (임시) 재생 일시정지: 볼륨을 0으로 내려 mute 수준만 제공.
/// 실제 pause/resume는 추후 C++ 심볼이 생기면 그때 교체.
void stPause() {
  st_setVolume(0.0);
}
