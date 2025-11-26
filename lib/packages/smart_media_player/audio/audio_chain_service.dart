// lib/packages/smart_media_player/audio/audio_chain_service.dart
//
// SmartMediaPlayer v3.8-FF — STEP 3
// Dart PCM feed 제거를 위한 호환 래퍼(stub) 버전
//
// ✔ 더 이상 Dart에서 PCM 디코드/스트림 feed를 하지 않는다.
// ✔ EngineApi와의 인터페이스를 유지하기 위해 시그니처만 보존한다.
// ✔ tempo/pitch/volume/state는 SoundTouchAudioChain 스텁에 위임한다.

import 'dart:async';
import 'dart:typed_data';

import '../../smart_media_player/audio/soundtouch_audio_chain.dart' as ac;

class AudioChainService {
  AudioChainService._();
  static final AudioChainService instance = AudioChainService._();

  final ac.SoundTouchAudioChain _chain = ac.SoundTouchAudioChain.instance;

  Duration _duration = Duration.zero;
  Duration get duration => _duration;

  double _lastPlaybackTime = 0.0;
  double get lastPlaybackTime => _lastPlaybackTime;

  /// FFmpeg Hybrid 구조 이후에는 재생 시간 SoT가 네이티브 엔진에서 오므로
  /// 여기서는 더 이상 pseudo-time 스트림을 생성하지 않는다.
  Stream<double> get playbackTime$ => const Stream.empty();

  // ================================================================
  // PUBLIC: decode + feed + duration (레거시 호환용)
  // ================================================================
  ///
  /// 기존에는:
  ///   - AudioDecoder.decodeToFloat32(path)로 PCM 디코드
  ///   - 4096*2 샘플 단위로 chunk stream 생성
  ///   - SoundTouchAudioChain.start(feed)에 Dart→FFI PCM feed
  ///
  /// FFmpeg Hybrid 이후에는 네이티브에서 전부 처리되므로,
  /// 여기서는 "빈 PCM / 0 duration / 빈 스트림"만 반환한다.
  Future<(Float32List pcm, Duration duration, Stream<Float32List> feed)>
  decodeAndPrepare(String path) async {
    _duration = Duration.zero;
    return (Float32List(0), _duration, const Stream<Float32List>.empty());
  }

  // ================================================================
  // PUBLIC: chain control (호환용 no-op)
  // ================================================================
  ///
  /// Dart PCM feed 구조는 제거되었으므로, start(feed)는 no-op로 둔다.
  Future<void> start(Stream<Float32List> feed) async {
    // no-op: FFmpeg 네이티브 엔진이 재생을 담당하게 될 예정이다.
  }

  Future<void> stop() async {
    await _chain.stop();
  }

  Future<void> startFrom(Duration d) async {
    await _chain.startFrom(d);
  }

  // ================================================================
  // PUBLIC: tempo / pitch / volume
  // ================================================================
  Future<void> setTempo(double v) async => _chain.setTempo(v);
  Future<void> setPitch(double semi) async => _chain.setPitch(semi);
  Future<void> setVolume(double v01) async => _chain.setVolume(v01);

  // ================================================================
  // RESTORE STATE
  // ================================================================
  Future<void> restoreState({
    required double tempo,
    required int pitchSemi,
    required double volume,
  }) async {
    _chain.setTempo(tempo);
    _chain.setPitch(pitchSemi.toDouble());
    _chain.setVolume(volume);
  }

  // ================================================================
  // internal for EngineApi
  // ================================================================
  void setDuration(Duration d) {
    _duration = d;
    _chain.setDuration(d);
  }

  bool get isStarted => _chain.isStarted;
}
