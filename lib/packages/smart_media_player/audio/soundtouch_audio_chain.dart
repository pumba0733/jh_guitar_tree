// lib/packages/smart_media_player/audio/soundtouch_audio_chain.dart
//
// 🎧 SoundTouchAudioChain — STEP 3 Stub
// FFmpeg Hybrid 엔진 도입을 위한 전처리 단계.
//
// ✔ AudioOutputMacOS / feedPcm / Timer 기반 PCM feed 제거
// ✔ tempo/pitch/volume/duration/state 인터페이스만 보존
// ✔ playbackTime / lastBuffer / lastRms는 더 이상 SoT가 아니며, 단순 상태/디버그용

import 'dart:async';
import 'dart:typed_data';

class SoundTouchAudioChain {
  SoundTouchAudioChain._();
  static final SoundTouchAudioChain instance = SoundTouchAudioChain._();

  bool _ready = false;
  bool _started = false;

  double _lastTempo = 1.0;
  double _lastPitch = 0.0;
  double _lastVol = 1.0;

  // 재생 시간 스트림 (현재는 네이티브 SoT로 대체될 예정이므로 비어 있음)
  final StreamController<double> _timeCtrl =
      StreamController<double>.broadcast();
  Stream<double> get playbackTimeStream => _timeCtrl.stream;

  // 디버그/파형용 버퍼 (현재는 외부에서 직접 채우지 않으면 항상 empty)
  Float32List _lastBuffer = Float32List(0);
  double _lastRms = 0.0;

  Float32List get lastBuffer => _lastBuffer;
  double get lastRms => _lastRms;

  // ===== duration / state =====
  Duration _duration = Duration.zero;
  Duration get duration => _duration;

  bool get isStarted => _started;

  /// 기존: 네이티브 SoundTouch/Output 초기화
  /// 지금: FFmpeg Hybrid 엔진에서 별도 초기화를 담당하므로, 여기서는 단순 플래그만.
  Future<void> init() async {
    if (_ready) return;
    _ready = true;
  }

  /// 기존: PCM stream을 받아 feedPcm() 호출
  /// 지금: Dart PCM feed 구조 제거 → no-op
  Future<void> start({required Stream<Float32List> pcmStream}) async {
    if (!_ready) await init();
    _started = true;
    // Dart→FFI PCM feed는 FFmpeg 네이티브 엔진 도입 이후 제거됨.
    // 필요하다면 나중에 FFmpeg FFI에서 lastBuffer/RMS만 가져오는 방향으로 확장.
  }

  void setTempo(double v) {
    _lastTempo = v;
    // 실제 tempo 적용은 FFmpeg 네이티브 엔진 FFI에서 처리 예정.
  }

  void setPitch(double v) {
    _lastPitch = v;
    // 실제 pitch 적용은 FFmpeg 네이티브 엔진 FFI에서 처리 예정.
  }

  void setVolume(double v) {
    _lastVol = v;
    // 실제 volume 적용은 FFmpeg 네이티브 엔진 FFI에서 처리 예정.
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;
  }

  void dispose() {
    _timeCtrl.close();
  }

  void setDuration(Duration d) {
    _duration = d;
  }

  /// 기존: 네이티브 seek + PCM feed 재시작
  /// 지금: 실제 seek는 EngineApi(FFmpeg 네이티브 엔진)에서 처리 예정.
  Future<void> startFrom(Duration d) async {
    if (!_ready) await init();
    // 여기서는 아무 것도 하지 않는다.
    // FFmpeg 엔진이 SoT를 책임지므로, Dart 레이어에서는 더 이상 pseudo seek를 하지 않는다.
  }

  // 선택적으로, 나중에 FFmpeg FFI에서 lastBuffer/RMS를 가져오도록
  // update 메서드를 추가할 수 있다.
  void updateDebugBuffer(Float32List buffer, double rms) {
    _lastBuffer = buffer;
    _lastRms = rms;
  }

  // getter들 (필요하면 디버거/로그 용으로 사용할 수 있음)
  double get lastTempo => _lastTempo;
  double get lastPitch => _lastPitch;
  double get lastVolume => _lastVol;
}
