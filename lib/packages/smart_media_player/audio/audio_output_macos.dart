import 'package:flutter/foundation.dart';
import 'engine_soundtouch_ffi.dart';

/// 🎧 AudioOutputMacOS v3.41.1
/// 역할: Flutter ↔ SoundTouch FFI 브리지 (miniaudio 파일 기반)
/// feedPCM 없음, 파일 재생 + 실시간 파라미터 제어 전용
class AudioOutputMacOS {
  final SoundTouchFFI _ffi = SoundTouchFFI();
  bool _initialized = false;
  int _sampleRate = 44100;
  int _channels = 2;

  Future<void> init({int sampleRate = 44100, int channels = 2}) async {
    if (_initialized) return;
    _sampleRate = sampleRate;
    _channels = channels;
    debugPrint('[AudioOutputMacOS] 🎧 init (sr=$sampleRate, ch=$channels)');
    _initialized = true;
  }

  /// 🎵 파일 재생 시작
  void startWithFile(String path) {
    if (!_initialized) {
      debugPrint('[AudioOutputMacOS] ⚠️ Not initialized, auto-init');
      init();
    }
    debugPrint('[AudioOutputMacOS] ▶️ start file: $path');
    _ffi.startWithFile(path);
  }

  /// ⏹️ 정지
  void stop() {
    _ffi.stop();
    debugPrint('[AudioOutputMacOS] ⏹️ stop');
  }

  /// 🎚️ 템포(속도) 조정 (0.5~1.5)
  void setTempo(double value) {
    final v = value.clamp(0.5, 1.5);
    _ffi.setTempo(v);
  }

  /// 🎵 피치(세미톤) 조정 (-12~+12)
  void setPitch(double semitone) {
    _ffi.setPitch(semitone);
  }

  /// 🔊 볼륨(0.0~1.5)
  void setVolume(double value) {
    final v = value.clamp(0.0, 1.5);
    _ffi.setVolume(v);
  }

  /// 🧹 해제
  void dispose() {
    if (_initialized) {
      _ffi.dispose();
      _initialized = false;
      debugPrint('[AudioOutputMacOS] ⏹️ disposed');
    }
  }
}
