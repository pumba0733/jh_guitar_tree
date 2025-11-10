import 'dart:ffi' as ffi;
import 'dart:io';
import 'package:ffi/ffi.dart' as ffi_utils;

/// 🎧 SoundTouchFFI v3.41
/// mpv → SoundTouch → miniaudio 완전 통합 버전
/// feedPcm 제거, startWithFile / stop / setTempo / setPitch / setVolume 중심 구조
class SoundTouchFFI {
  late final ffi.DynamicLibrary _lib;

  late final _Create _create;
  late final _Dispose _dispose;
  late final _StartWithFile _startWithFile;
  late final _Stop _stop;
  late final _SetTempo _setTempo;
  late final _SetPitch _setPitch;
  late final _SetVolume _setVolume;

  SoundTouchFFI() {
    final libName = Platform.isMacOS
        ? 'libsoundtouch_ffi.dylib'
        : 'soundtouch_ffi.dll';
    _lib = ffi.DynamicLibrary.open(libName);

    // --- Load FFI symbols ---
    _create = _lib.lookupFunction<_CreateNative, _Create>('st_create');
    _dispose = _lib.lookupFunction<_DisposeNative, _Dispose>('st_dispose');
    _startWithFile = _lib.lookupFunction<_StartWithFileNative, _StartWithFile>(
      'st_audio_start_with_file',
    );
    _stop = _lib.lookupFunction<_StopNative, _Stop>('st_audio_stop');
    _setTempo = _lib.lookupFunction<_SetTempoNative, _SetTempo>('st_set_tempo');
    _setPitch = _lib.lookupFunction<_SetPitchNative, _SetPitch>(
      'st_set_pitch_semitones',
    );
    _setVolume = _lib.lookupFunction<_SetVolumeNative, _SetVolume>(
      'st_set_volume',
    );

    // --- Init instance ---
    _create();
  }

  /// 🎵 파일 재생 시작
  void startWithFile(String path) {
    final cPath = path.toNativeUtf8();
    _startWithFile(cPath.cast<ffi.Char>()); // ✅ 캐스팅 추가
    ffi_utils.malloc.free(cPath);
  }

  /// ⏹️ 정지
  void stop() => _stop();

  /// 🎚️ 파라미터 조정
  void setTempo(double v) => _setTempo(v);
  void setPitch(double v) => _setPitch(v);
  void setVolume(double v) => _setVolume(v);

  /// 🧹 해제
  void dispose() => _dispose();
}

// ===== Native TypeDefs =====
typedef _CreateNative = ffi.Void Function();
typedef _Create = void Function();

typedef _DisposeNative = ffi.Void Function();
typedef _Dispose = void Function();

typedef _StartWithFileNative = ffi.Void Function(ffi.Pointer<ffi.Char>);
typedef _StartWithFile = void Function(ffi.Pointer<ffi.Char>);

typedef _StopNative = ffi.Void Function();
typedef _Stop = void Function();

typedef _SetTempoNative = ffi.Void Function(ffi.Double);
typedef _SetTempo = void Function(double);

typedef _SetPitchNative = ffi.Void Function(ffi.Double);
typedef _SetPitch = void Function(double);

typedef _SetVolumeNative = ffi.Void Function(ffi.Float);
typedef _SetVolume = void Function(double);
