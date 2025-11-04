// v3.35.6 — SoundTouchAudioChain (Async-safe FFI)
// 개선점: UI 블로킹 완전 제거, startPlaybackAsync 기반

import 'package:guitartree/packages/smart_media_player/audio/engine_soundtouch_ffi.dart';
import 'package:media_kit/media_kit.dart';
import 'dart:typed_data';

class SoundTouchAudioChain {
  static final SoundTouchAudioChain instance = SoundTouchAudioChain._();
  SoundTouchAudioChain._();

  SoundTouchFFI? _st;
  double _speed = 1.0;
  double _pitchSemi = 0.0;
  double _volumePercent = 100.0;

  Future<void> apply({
    required Player player,
    bool isVideo = false,
    bool muted = false,
    double volumePercent = 100.0,
    double speed = 1.0,
    double pitchSemi = 0.0,
  }) async {
    // ==== 내부 상태 갱신 ====
    _speed = speed;
    _pitchSemi = pitchSemi;
    _volumePercent = volumePercent;

    // ==== FFI 초기화 (최초 1회만) ====
    _st ??= SoundTouchFFI();
    _st!.init();

    // ==== 파라미터 적용 ====
    _st!.setTempo(_speed);
    _st!.setPitchSemiTones(_pitchSemi);

    // ==== AudioQueue 실행 (비동기, UI 블로킹 없음) ====
    await _st!.startPlaybackAsync();

    // ==== mpv 엔진은 1x 고정, 볼륨만 조절 ====
    final vol = muted ? 0.0 : (volumePercent / 100.0);
    await player.setVolume(vol);
    await player.setRate(1.0);

    print('[FFI] tempo=$_speed pitch=$_pitchSemi vol=$_volumePercent');
  }

  Future<void> reset(Player player) async {
    // tempo/pitch 초기화 후 재적용
    if (_st != null) {
      _st!.setTempo(1.0);
      _st!.setPitchSemiTones(0.0);
    }

    await apply(
      player: player,
      volumePercent: 100.0,
      speed: 1.0,
      pitchSemi: 0.0,
    );
  }

  void dispose() {
    if (_st != null) {
      _st!.stop();
      _st!.dispose();
      _st = null;
      print('[FFI] 🔚 SoundTouchAudioChain disposed');
    }
  }
}
