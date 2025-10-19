// lib/packages/smart_media_player/waveform/waveform_tuning.dart
// Waveform 튜닝 파라미터 & 맵핑 유틸 (한 곳에서 모두 조절)
// - loudness/log 맵, dB 맵, 오토게인 clamp, 스무딩, fill alpha

import 'dart:math' as math;

enum WaveformPreset {
  transcribeLike, // 권장 디폴트: 보기 좋은 로그/감마 + 가벼운 오토게인
  cleanPath, // 오토게인 최소, 선형에 가까움
  solidBars, // 막대형 대비 강조
  ecgSigned, // 부호 파형 전용(시그널 그대로)
}

class WaveformTuning {
  WaveformTuning._();
  static final WaveformTuning I = WaveformTuning._();
  
  // 👇 전역 파형 높이 (헤더+파형 전체 높이 아님, 파형 캔버스 자체 높이)
  static const double panelHeight = 100.0; // 100~130 권장, 더 줄여도 OK

  

  // 현재 프리셋(앱 설정에서 바꿀 수 있게 해도 됨)
  WaveformPreset preset = WaveformPreset.transcribeLike;

  // ===== 공통 파라미터 =====
  // 로그/감마 맵 영역
  double loudGammaLow = 2.2; // 아주 작은 구간 감마
  double loudGammaHigh = 1.4; // 큰 구간 감마
  double dbFloor = -60.0; // dB 맵 하한
  double dbCeil = 0.0; // dB 맵 상한(0dB = full scale)

  // 오토게인
  double autoGainMedianTarget = 0.65; // 중간값을 이 정도로 맞춤
  double autoGainClampMin = 0.80; // 줌아웃시 최소 클램프
  double autoGainClampMax = 1.00;

  // 스무딩(줌 레벨에 따라 radius 추천)
  int smoothingRadiusWide = 2; // 크게 축소됐을 때
  int smoothingRadiusMid = 1; // 중간
  int smoothingRadiusTight = 0; // 크게 확대됐을 때

  // 캔버스 fill alpha (줌아웃일수록 살짝 진하게)
  double fillAlphaMin = 0.06;
  double fillAlphaMax = 0.16;
  double fillAlphaSwitchLo = 0.05; // barsPerPixel 저배율 경계
  double fillAlphaSwitchHi = 0.30; // barsPerPixel 고배율 경계

  // 부호 파형(ECG) 전용: 평균/피크 블렌딩 가중
  double signedMeanWeightWide = 0.40; // 크게 축소
  double signedMeanWeightTight = 0.85; // 크게 확대

  // 부호 파형(ECG) 전용: 시각 스케일 보정 계수(기존 0.9를 프리셋으로 이동)
  double signedVisualScale = 0.90;

  // ===== 튜닝 함수들 =====
  // “보기 좋은” 라우드니스 맵 (0..1 -> 0..1)
  double loud(double a, {bool visualExact = false}) {
    if (visualExact) return a.clamp(0.0, 1.0);
    const eps = 1e-9;
    final db = 20 * math.log(a.clamp(0.0, 1.0) + eps) / math.ln10; // -inf..0
    final x = ((db - dbFloor) / (dbCeil - dbFloor)).clamp(0.0, 1.0);
    // 살짝 감마
    return math.pow(x, 1.1).toDouble();
  }

  // dB 맵(히스토그램/레벨 전용)
  double dbMapped(double a) {
    if (a <= 0.0) return 0.0;
    const eps = 1e-9;
    final db = 20 * math.log(a + eps) / math.ln10;
    return ((db - dbFloor) / (dbCeil - dbFloor)).clamp(0.0, 1.0);
  }

  // 줌 의존 오토게인 클램프 (pixelBars는 화면 픽셀 수)
  double zoomGainClamp(int pixelBars, {bool visualExact = false}) {
    if (visualExact) return 1.0;
    // 0.80 ~ 1.00 선형 보간
    final t = (pixelBars / 600.0).clamp(0.0, 1.0);
    return (autoGainClampMin + t * (autoGainClampMax - autoGainClampMin)).clamp(
      autoGainClampMin,
      autoGainClampMax,
    );
  }

  // 줌 의존 스무딩 radius
  int smoothingRadiusForViewWidth(double viewWidth) {
    if (viewWidth >= 0.92) return smoothingRadiusWide;
    if (viewWidth >= 0.75) return smoothingRadiusMid;
    return smoothingRadiusTight;
  }

  // barsPerPixel 기반 fill alpha
  double fillAlphaByBarsPerPixel(double barsPerPixel) {
    if (barsPerPixel <= fillAlphaSwitchLo) return fillAlphaMin;
    if (barsPerPixel >= fillAlphaSwitchHi) return fillAlphaMax;
    final t =
        (barsPerPixel - fillAlphaSwitchLo) /
        (fillAlphaSwitchHi - fillAlphaSwitchLo);
    return fillAlphaMin + t * (fillAlphaMax - fillAlphaMin);
  }

  // 부호파형 평균/피크 블렌딩 가중(줌 아웃일수록 평균 비중↑)
  double signedBlendWeight(double span) {
    final t = ((span - 1.0) / 10.0).clamp(0.0, 1.0);
    return signedMeanWeightTight * (1.0 - t) + signedMeanWeightWide * t;
  }
}
