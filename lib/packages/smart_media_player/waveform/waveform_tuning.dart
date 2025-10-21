// smart_media_player/waveform/waveform_tuning.dart
// v3.30.0 | Tone Presets + dB Mapping + Live Notifier (DAW-ish defaults)

import 'dart:math' as math;
import 'package:flutter/material.dart';

enum WaveformPreset { transcribeLike, cleanPath, solidBars, ecgSigned, iosLike }

class WaveformTuning extends ChangeNotifier {
  WaveformTuning._();
  static final WaveformTuning I = WaveformTuning._();

  // ===== Layout =====
  static double panelHeight = 96.0;

  // ===== Colors =====
  Color bgColor = const Color(0xFF0D0F12);
  Color fillColorL = const Color(0xFF80D8FF);
  Color fillColorR = const Color(0xFFB388FF);
  Color strokeColorL = const Color(0xFFB3E5FC);
  Color strokeColorR = const Color(0xFFD1C4E9);

  Color loopFill = const Color(0x334FC3F7);
  Color playhead = const Color(0xFFEEEEEE);
  double playheadWidth = 1.5;

  // ===== Loudness Mapping (dB) =====
  // DAW에 가깝게: 바닥/천장을 보수적으로, 감마 과장 축소
  double dbFloor = -60.0; // was around -50
  double dbCeil = -3.0; // was around -2..0
  double loudGammaLow = 1.30; // was 1.6~2.0
  double loudGammaHigh = 1.08; // was 1.1~1.35

  // Fill & Stroke
  double fillAlpha = 0.26;
  double strokeWidth = 1.6;
  double blurSigma = 0.0;

  // Markers
  double markerWidth = 1.0;
  Color markerColor(int i) => const Color(0xFF64B5F6);

  // Signed Stroke scaling (±)
  double signedVisualScale = 1.0;

  // 전역 토글(기본 false; View에서 visualExact 켜면 무시됨)
  bool dualLayer = true;
  bool useSignedAmplitude = true;
  bool splitStereoQuadrants = true;
  bool visualExact = false;

  void applyPreset(WaveformPreset p) {
    switch (p) {
      case WaveformPreset.transcribeLike:
        dbFloor = -58;
        dbCeil = -3;
        loudGammaLow = 1.35;
        loudGammaHigh = 1.08;
        fillAlpha = 0.28;
        strokeWidth = 1.6;
        blurSigma = 0.0;
        break;
      case WaveformPreset.cleanPath:
        dbFloor = -54;
        dbCeil = -4;
        loudGammaLow = 1.25;
        loudGammaHigh = 1.05;
        fillAlpha = 0.18;
        strokeWidth = 1.4;
        blurSigma = 0.0;
        break;
      case WaveformPreset.solidBars:
        dbFloor = -60;
        dbCeil = -3;
        loudGammaLow = 1.42;
        loudGammaHigh = 1.10;
        fillAlpha = 0.36;
        strokeWidth = 1.8;
        blurSigma = 0.0;
        break;
      case WaveformPreset.ecgSigned:
        dbFloor = -55;
        dbCeil = -4;
        loudGammaLow = 1.50;
        loudGammaHigh = 1.12;
        fillAlpha = 0.20;
        strokeWidth = 1.2;
        blurSigma = 0.0;
        break;
      case WaveformPreset.iosLike:
        dbFloor = -62;
        dbCeil = -4;
        loudGammaLow = 1.28;
        loudGammaHigh = 1.06;
        fillAlpha = 0.22;
        strokeWidth = 1.5;
        blurSigma = 0.0;
        break;
    }
    notifyListeners();
  }

  // 외부에서 전역 토글 바꾸는 경우를 대비
  set setDualLayer(bool v) {
    dualLayer = v;
    notifyListeners();
  }

  set setUseSigned(bool v) {
    useSignedAmplitude = v;
    notifyListeners();
  }

  set setSplitStereo(bool v) {
    splitStereoQuadrants = v;
    notifyListeners();
  }

  set setVisualExact(bool v) {
    visualExact = v;
    notifyListeners();
  }

  // 색상 런타임 변경(옵션)
  void setColors({
    Color? bg,
    Color? fillL,
    Color? fillR,
    Color? strokeL,
    Color? strokeR,
  }) {
    if (bg != null) bgColor = bg;
    if (fillL != null) fillColorL = fillL;
    if (fillR != null) fillColorR = fillR;
    if (strokeL != null) strokeColorL = strokeL;
    if (strokeR != null) strokeColorR = strokeR;
    notifyListeners();
  }
}
