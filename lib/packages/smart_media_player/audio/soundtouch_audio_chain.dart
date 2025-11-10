import 'package:flutter/foundation.dart';
import 'audio_output_macos.dart';

/// 🎧 SoundTouchAudioChain v3.41 Final
/// - mpv(비디오) + miniaudio(PCM 출력) + SoundTouch(변조) 완전분리 구조
/// - UI ↔ SoundTouchAudioChain ↔ AudioOutputMacOS ↔ FFI
class SoundTouchAudioChain {
  SoundTouchAudioChain._();
  static final SoundTouchAudioChain instance = SoundTouchAudioChain._();

  final AudioOutputMacOS _audio = AudioOutputMacOS();

  double _lastTempo = 1.0;
  double _lastPitch = 0.0;
  double _lastVol = 1.0;

  bool _ready = false;
  bool _started = false;
  bool get isStarted => _started;

  /// 초기화 (한 번만)
  Future<void> init() async {
    if (_ready) return;
    await _audio.init(sampleRate: 44100, channels: 2);
    _ready = true;
    debugPrint('[SoundTouchAudioChain] ✅ Ready');
  }

  /// 🎵 오디오 파일 재생 시작
  Future<void> startWithFile(String path) async {
    if (!_ready) await init();
    debugPrint('[SoundTouchAudioChain] ▶ startWithFile($path)');
    _audio.startWithFile(path);
    _started = true;
  }

  /// ⏹️ 정지
  void stop() {
    _audio.stop();
    _started = false;
  }

  /// 🎚️ 템포 조절
  void setTempo(double value) {
    _lastTempo = value;
    _audio.setTempo(value);
  }

  /// 🎵 피치 조절
  void setPitch(double value) {
    _lastPitch = value;
    _audio.setPitch(value);
  }

  /// 🔊 볼륨 조절
  void setVolume(double value) {
    _lastVol = value;
    _audio.setVolume(value);
  }

  /// 🔁 파라미터 재적용 (슬라이더 초기화 시)
  void reapply() {
    _audio.setTempo(_lastTempo);
    _audio.setPitch(_lastPitch);
    _audio.setVolume(_lastVol);
  }

  /// 해제
  void dispose() {
    _audio.dispose();
    _ready = false;
    _started = false;
  }
}
