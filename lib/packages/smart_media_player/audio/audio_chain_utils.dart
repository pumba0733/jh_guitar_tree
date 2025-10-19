// lib/packages/smart_media_player/audio/audio_chain_utils.dart
// v1.0.0 — Audio DSP helpers (semitone <-> ratio, gain dB, clamps)

import 'dart:math' as math;

/// Clamp helper for double.
double clampDouble(double v, double min, double max) =>
    v < min ? min : (v > max ? max : v);

/// Clamp helper for int.
int clampInt(int v, int min, int max) => v < min ? min : (v > max ? max : v);

/// Clamp helper for num -> double.
double clampNum(num v, num min, num max) =>
    v < min ? min.toDouble() : (v > max ? max.toDouble() : v.toDouble());

/// Convert semitone shift to frequency ratio (12-TET).
/// +12 -> 2.0, 0 -> 1.0, -12 -> 0.5
double semitoneToRatio(int semitone) {
  return math.pow(2.0, semitone / 12.0).toDouble();
}

/// Convert ratio to semitone (rounded).
int ratioToSemitone(double ratio) {
  if (ratio <= 0) return 0;
  return (12.0 * (math.log(ratio) / math.ln2)).round();
}

/// Linear gain(0..?) to dB. 1.0 -> 0dB.
double linearToDb(double linear) {
  if (linear <= 0) return -120.0;
  return 20.0 * math.log(linear) / math.ln10;
}

/// dB to linear gain. 0dB -> 1.0
double dbToLinear(double db) {
  return math.pow(10.0, db / 20.0).toDouble();
}

/// Nicely quantize speed(tempo) to 0.01 step and clamp to [0.5, 1.5]
double normalizeSpeed(double speed) {
  final v = (speed * 100).round() / 100.0;
  return clampDouble(v, 0.5, 1.5);
}

/// Nicely clamp pitch semitone to [-7, 7]
int normalizePitchSemi(int semi) => clampInt(semi, -7, 7);

/// Volume percent [0..150] -> (mute, mpvVolume[0..100], postAmpDb)
/// - 0..100% : mpv volume 사용
/// - 101..150% : mpv 100 + 후단 amp(dB)로 보정
({bool mute, int mpvVolume, double postAmpDb}) splitVolume150(int percent) {
  final p = clampInt(percent, 0, 150);
  if (p == 0) {
    return (mute: true, mpvVolume: 0, postAmpDb: 0.0);
  }
  if (p <= 100) {
    return (mute: false, mpvVolume: p, postAmpDb: 0.0);
  }
  // 101~150% → mpv 100 + 나머지 1.0..1.5를 dB증폭
  final rest = p / 100.0;
  final db = linearToDb(rest);
  return (mute: false, mpvVolume: 100, postAmpDb: db);
}
