// v3.34.0 — SoundTouchAudioChain (FFI 기반)
// 완전 교체본 — mpv 필터 제거 + FFI 직결
import 'package:guitartree/packages/smart_media_player/audio/engine_soundtouch_ffi.dart';
import 'package:media_kit/media_kit.dart';

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
    _speed = speed;
    _pitchSemi = pitchSemi;
    _volumePercent = volumePercent;

    _st ??= SoundTouchFFI();
    _st!.setTempo(_speed);
    _st!.setPitchSemiTones(_pitchSemi);

    final vol = muted ? 0.0 : (volumePercent / 100.0);
    await player.setVolume(vol);
    await player.setRate(1.0); // ✅ mpv rate 고정 (SoundTouch에서 처리)

    print('[FFI] setTempo=$_speed setPitch=$_pitchSemi vol=$_volumePercent');
  }

  Future<void> reset(Player player) async {
    // 기존 SoundTouch 인스턴스 정리
    _st?.dispose();

    // 새 FFI 인스턴스 생성
    _st = SoundTouchFFI();

    // 완전 기본값(볼륨 100%, 속도 1.0, 피치 0)으로 체인 재적용
    await apply(
      player: player,
      volumePercent: 100.0,
      speed: 1.0,
      pitchSemi: 0.0,
    );
  }


  void dispose() {
    _st?.dispose();
    _st = null;
  }
}
