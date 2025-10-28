// v3.31.10 — MPV AudioChain (media_kit unified)
// 완전 교체본 — 기존 RubberBand, FFTW 제거 이후 호환 버전
import 'dart:math' as math;
import 'package:media_kit/media_kit.dart';

class MpvAudioChain {
  // ✅ 싱글턴 (instance 접근용)
  static final MpvAudioChain instance = MpvAudioChain._();
  MpvAudioChain._();

  /// 현재 설정 상태 (속도/피치/볼륨)
  double _speed = 1.0;
  double _pitchSemi = 0.0; // 세미톤 단위
  double _volumePercent = 100.0;

  // =============================
  // 🧩 적용: tempo/pitch/volume
  // =============================
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

    final vol = muted ? 0.0 : (volumePercent / 100.0);
    await player.setVolume(vol);

    await player.setRate(speed);
    await player.setPitch(_calcPitchFactor(pitchSemi));

    print(
      '[AUDIOCHAIN] apply '
      'speed=$_speed pitch=$_pitchSemi vol=$_volumePercent muted=$muted',
    );
  }

  // =============================
  // 🧩 AF 정보 조회 (mpv -af 필터 equivalent)
  // =============================
  Future<String> peekAF(Player player) async {
    final rate = player.state.rate.toStringAsFixed(3);
    final pitch = _calcPitchFactor(_pitchSemi).toStringAsFixed(3);
    return 'lavfi=[asetrate=${rate},aresample=44100],scaletempo=scale=${pitch}';
  }

  // =============================
  // 🧩 게인 계산기
  // =============================
  double computeGain() => math.pow(_volumePercent / 100.0, 0.5).toDouble();

  // =============================
  // 🧩 내부 계산 (세미톤→배속)
  // =============================
  double _calcPitchFactor(double semi) => math.pow(2.0, semi / 12.0).toDouble();

  // =============================
  // 🧩 리셋
  // =============================
  Future<void> reset(Player player) async {
    await apply(
      player: player,
      isVideo: false,
      muted: false,
      volumePercent: 100.0,
      speed: 1.0,
      pitchSemi: 0.0,
    );
  }

  // =============================
  // 🧩 디버그용
  // =============================
  void dump() {
    print('[AUDIOCHAIN] speed=$_speed pitch=$_pitchSemi vol=$_volumePercent');
  }
}
