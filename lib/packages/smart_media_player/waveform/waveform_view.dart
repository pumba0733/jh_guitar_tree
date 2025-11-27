// lib/packages/smart_media_player/waveform/waveform_view.dart
// v3.31.7 | Center-mirrored + Filled + A/B 핸들 + 말풍선 마커(개선)

import 'dart:math' as math;
import 'package:flutter/material.dart';

enum WaveDrawMode { auto, bars, candles, path } // 호환용(미사용)

// ============================================================
// WaveformView QA 로깅 헬퍼
// ============================================================
const bool kSmpWaveformLogEnabled = false; // 🔇 기본은 로그 OFF

DateTime? _lastWaveformLogAt;

void _logWaveform(String message) {
  if (!kSmpWaveformLogEnabled) return;

  final now = DateTime.now();
  // 너무 자주 찍히는 것 방지: 최소 500ms 이상 간격
  if (_lastWaveformLogAt != null &&
      now.difference(_lastWaveformLogAt!) < const Duration(milliseconds: 500)) {
    return;
  }
  _lastWaveformLogAt = now;

  debugPrint('[WF] $message');
}

class WaveformView extends StatefulWidget {
  final List<double> peaks;
  final List<double>? peaksRight;

  final Duration duration;
  final Duration position;
  final Duration? loopA;
  final Duration? loopB;
  final bool loopOn;

  final List<Duration> markers;
  final List<String>? markerLabels;
  final List<Color?>? markerColors;

  final double viewStart; // 0..1
  final double viewWidth; // 0..1

  final bool dualLayer;
  final bool useSignedAmplitude;
  final bool splitStereoQuadrants;
  final WaveDrawMode drawMode;

  final List<double>? rmsLeft; // 0..1
  final List<double>? rmsRight; // 0..1
  final List<double>? signedLeft; // 미사용
  final List<double>? signedRight; // 미사용

  final List<double>? bandEnergyLeft; // 미사용
  final List<double>? bandEnergyRight; // 미사용

  final bool visualExact;
  final bool preferTuningFlags;

  // 스타일 고정값
  final bool mirrorAroundCenter; // 항상 true 가정
  final bool fillInterior; // 항상 true 가정
  final bool showCenterLine; // 사용 안 함

  // 🔥 신규: 핸들 표기 + 시작점
  final bool showHandles;
  final Duration? startCue;
  final bool showStartCue;

  const WaveformView({
    super.key,
    required this.peaks,
    this.peaksRight,
    required this.duration,
    required this.position,
    this.loopA,
    this.loopB,
    this.loopOn = false,
    this.markers = const [],
    this.markerLabels,
    this.markerColors,
    this.viewStart = 0.0,
    this.viewWidth = 1.0,
    this.dualLayer = true,
    this.useSignedAmplitude = false,
    this.splitStereoQuadrants = false,
    this.drawMode = WaveDrawMode.auto,
    this.rmsLeft,
    this.rmsRight,
    this.signedLeft,
    this.signedRight,
    this.bandEnergyLeft,
    this.bandEnergyRight,
    this.visualExact = true,
    this.preferTuningFlags = false,
    this.mirrorAroundCenter = true,
    this.fillInterior = true,
    this.showCenterLine = false,
    this.showHandles = false,
    this.startCue,
    this.showStartCue = true,
  });

  @override
  State<WaveformView> createState() => _WaveformViewState();
}

class _WaveformViewState extends State<WaveformView> {
  @override
  Widget build(BuildContext context) {
    final left = widget.rmsLeft ?? widget.peaks;
    final right = widget.rmsRight ?? widget.peaksRight;

    final vs = widget.viewStart.clamp(0.0, 1.0);
    final vw = widget.viewWidth.clamp(0.02, 1.0); // 🔒 최소 2% 이상

    return CustomPaint(
      painter: _CenterFilledPainter(
        left: left,
        right: right,
        splitStereo: widget.splitStereoQuadrants,
        position: widget.position,
        duration: widget.duration,
        loopA: widget.loopA,
        loopB: widget.loopB,
        loopOn: widget.loopOn,
        viewStart: vs,
        viewWidth: vw,
        showHandles: widget.showHandles,
        markers: widget.markers,
        markerLabels: widget.markerLabels,
        markerColors: widget.markerColors,
        startCue: widget.startCue,
        showStartCue: widget.showStartCue,
      ),
      size: const Size(double.infinity, 100),
    );
  }
}

class _CenterFilledPainter extends CustomPainter {
  final List<double> left;
  final List<double>? right;
  final bool splitStereo;
  final Duration position, duration;
  final Duration? loopA, loopB;
  final bool loopOn;
  final double viewStart, viewWidth;
  final bool showHandles;
  final List<Duration> markers;
  final List<String>? markerLabels;
  final List<Color?>? markerColors;
  final Duration? startCue;
  final bool showStartCue;

  _CenterFilledPainter({
    required this.left,
    required this.right,
    required this.splitStereo,
    required this.position,
    required this.duration,
    required this.loopA,
    required this.loopB,
    required this.loopOn,
    required this.viewStart,
    required this.viewWidth,
    required this.showHandles,
    required this.markers,
    this.markerLabels,
    this.markerColors,
    this.startCue,
    this.showStartCue = true,
  });

  // --- helpers ---
  Duration _clampDur(Duration v, Duration min, Duration max) {
    if (v < min) return min;
    if (v > max) return max;
    return v;
  }

  double _xOf(
    Duration t, {
    required Duration duration,
    required double viewStart,
    required double viewWidth,
    required Size size,
  }) {
    if (duration <= Duration.zero) return 0.0;
    final safe = _clampDur(t, Duration.zero, duration);
    final f = safe.inMilliseconds / duration.inMilliseconds;
    final vw = viewWidth <= 0 ? 1.0 : viewWidth;
    final v = ((f - viewStart) / vw).clamp(0.0, 1.0);
    return v * size.width;
  }

  @override
  void paint(Canvas canvas, Size size) {
    _logWaveform(
      'paint() width=${size.width}, height=${size.height}, samples=${left.length}',
    );

    if (left.isEmpty ||
        size.width <= 0 ||
        size.height <= 0 ||
        duration <= Duration.zero) {
      return;
    }

    final width = size.width;
    final height = size.height;

    // === 뷰포트 샘플 범위 ===
    final startIdx = (left.length * viewStart).floor().clamp(
      0,
      left.length - 1,
    );
    final endIdx = (left.length * (viewStart + viewWidth)).ceil().clamp(
      startIdx + 1,
      left.length,
    );
    final span = (endIdx - startIdx).clamp(1, left.length);

    // 픽셀 당 1 포인트 근사 다운샘플링(항상 면 채움 고정)
    final pixelCount = width.toInt().clamp(1, span);
    final step = math.max(1, span ~/ pixelCount);
    final count = math.max(2, span ~/ step);

    // 스타일
    final fill1 = Paint()
      ..style = PaintingStyle.fill
      ..color = const Color(0x8C6EA8FE); // 파형 기본색
    final fill2 = Paint()
      ..style = PaintingStyle.fill
      ..color = const Color(0x8C9AD0F9);
    final loopFill = Paint()..color = const Color(0x2666CCFF); // 루프 영역 (16% 투명)
    final linePos = Paint()
      ..color = const Color(0xFF1F4AFF)
      ..strokeWidth = 1.2;

    // 🔹 Normalize amplitude (left 채널 기준)
    double maxAbs = 0.0;
    for (final v in left) {
      final av = v.abs();
      if (av > maxAbs) maxAbs = av;
    }
    if (maxAbs < 1e-6) maxAbs = 1.0; // avoid div0
    final double gain = 1.0 / maxAbs;

    if (!splitStereo || right == null || right!.isEmpty) {
      final centerY = height * 0.5;
      final halfH = height * 0.48;
      _drawCenterFillPath(
        canvas,
        left.map((e) => e * gain).toList(),
        startIdx,
        step,
        count,
        0,
        width,
        centerY,
        halfH,
        fill1,
      );
    } else {
      final halfHeight = height / 2;
      final topCenter = halfHeight * 0.5;
      final bottomCenter = halfHeight + halfHeight * 0.5;
      final halfH = halfHeight * 0.48;

      _drawCenterFillPath(
        canvas,
        left.map((e) => e * gain).toList(),
        startIdx,
        step,
        count,
        0,
        width,
        topCenter,
        halfH,
        fill1,
      );

      // 지역 변수로 고정
      final rightNN = right!;
      _drawCenterFillPath(
        canvas,
        rightNN,
        startIdx,
        step,
        count,
        0,
        width,
        bottomCenter,
        halfH,
        fill2,
      );
    }

    // 루프 오버레이 (SoT 안전 클램프)
    double xOfLocal(Duration t) {
      if (duration <= Duration.zero) return 0.0;
      final safe = _clampDur(t, Duration.zero, duration);
      final f = safe.inMilliseconds / duration.inMilliseconds;
      final vw = viewWidth <= 0 ? 1.0 : viewWidth;
      final v = ((f - viewStart) / vw).clamp(0.0, 1.0);
      return v * width;
    }

    if (loopOn && loopA != null && loopB != null) {
      final aSafe = _clampDur(loopA!, Duration.zero, duration);
      final bSafe = _clampDur(loopB!, Duration.zero, duration);
      final xa = xOfLocal(aSafe);
      final xb = xOfLocal(bSafe);
      final r = Rect.fromLTWH(math.min(xa, xb), 0, (xa - xb).abs(), height);
      canvas.drawRect(r, loopFill);
    }

    // 재생 포지션 라인 (SoT 클램프 적용)
    final posSafe = _clampDur(position, Duration.zero, duration);
    final xp = xOfLocal(posSafe);
    canvas.drawLine(Offset(xp, 0), Offset(xp, height), linePos);

    // 🔹 A/B 핸들(삼각깃발)
    if (showHandles) {
      final handlePaintA = Paint()..color = const Color(0xFF0F6FFF);
      final handlePaintB = Paint()..color = const Color(0xFF00B894);

      if (loopA != null) {
        final aSafe = _clampDur(loopA!, Duration.zero, duration);
        _drawHandle(canvas, xOfLocal(aSafe), height, handlePaintA, isA: true);
      }
      if (loopB != null) {
        final bSafe = _clampDur(loopB!, Duration.zero, duration);
        _drawHandle(canvas, xOfLocal(bSafe), height, handlePaintB, isA: false);
      }
    }

    // === MARKERS (개선 UI만 사용) ===
    _drawMarkersEnhanced(
      canvas,
      size,
      markers,
      markerLabels,
      markerColors,
      viewStart,
      viewWidth,
    );

    // === START CUE FLAG ===
    if (showStartCue && startCue != null) {
      final sx = _xOf(
        _clampDur(startCue!, Duration.zero, duration),
        duration: duration,
        viewStart: viewStart,
        viewWidth: viewWidth,
        size: size,
      );
      final p = Paint()..color = const Color(0xFFE53935);
      canvas.drawLine(
        Offset(sx, 0),
        Offset(sx, size.height),
        p..strokeWidth = 1,
      );
      final flag = Path()
        ..moveTo(sx, 0)
        ..lineTo(sx + 6, 10)
        ..lineTo(sx - 6, 10)
        ..close();
      canvas.drawPath(flag, p);
    }
  }

  // --- 점선 세로선
  void _drawDashedVLine(
    Canvas canvas,
    double x,
    double height, {
    double dash = 4,
    double gap = 3,
    required Paint paint,
  }) {
    double y = 0;
    while (y < height) {
      final y2 = math.min(y + dash, height);
      canvas.drawLine(Offset(x, y), Offset(x, y2), paint);
      y += dash + gap;
    }
  }

  void _drawMarkersEnhanced(
    Canvas canvas,
    Size size,
    List<Duration> times,
    List<String>? labels,
    List<Color?>? colors,
    double viewStart,
    double viewWidth,
  ) {
    if (times.isEmpty || duration <= Duration.zero) return;

    final width = size.width;
    final height = size.height;
    final durMs = duration.inMilliseconds.toDouble();

    double xOf(Duration t) {
      final safe = _clampDur(t, Duration.zero, duration);
      final f = safe.inMilliseconds / durMs;
      final vw = viewWidth <= 0 ? 1.0 : viewWidth;
      final v = ((f - viewStart) / vw).clamp(0.0, 1.0);
      return v * width;
    }

    // 기준선(세로선) 스타일: 얇고, 반투명, 점선
    final baseLine = Paint()
      ..strokeWidth = 0.9
      ..color = const Color(0xFF37474F).withValues(alpha: 0.35);

    // 말풍선 파라미터
    const double topY = 4;
    const double badgeH = 20;
    const double padX = 6;
    const double tailH = 6;
    const double radius = 6;

    for (int i = 0; i < times.length; i++) {
      final x = xOf(times[i]);

      // 1) 기준선(점선)
      _drawDashedVLine(canvas, x, height, dash: 4, gap: 3, paint: baseLine);

      // 2) 말풍선 내용
      final label =
          (labels != null && i < labels.length && (labels[i].isNotEmpty))
          ? labels[i]
          : null;
      if (label == null) continue;

      // 텍스트 측정
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Colors.black87,
            height: 1.1,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: math.max(40, width * 0.5));

      final w = tp.width + padX * 2;
      final h = badgeH; // 고정 높이
      final rect = Rect.fromLTWH(x + 4, topY, w, h);

      // 배경색
      Color base = const Color(0xFFFFF3A5); // 부드러운 크림
      if (colors != null && i < colors.length && colors[i] != null) {
        base = colors[i]!.withValues(alpha: 0.85);
      }
      final bg = Paint()..color = base;

      // 미세 그림자
      final shadow = Paint()
        ..color = Colors.black.withValues(alpha: 0.08)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);

      // 꼬리(세로선 방향)
      final tail = Path()
        ..moveTo(x + 8, topY + h)
        ..lineTo(x + 12, topY + h + tailH)
        ..lineTo(x + 16, topY + h)
        ..close();

      // 배지 RRect
      final rrect = RRect.fromRectAndRadius(
        rect,
        const Radius.circular(radius),
      );

      // 그림자 → 배경 → 꼬리 → 경계선 → 텍스트
      canvas.drawRRect(rrect, shadow);
      canvas.drawRRect(rrect, bg);
      canvas.drawPath(tail, bg);
      final border = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..color = Colors.black.withValues(alpha: 0.08);
      canvas.drawRRect(rrect, border);

      tp.paint(
        canvas,
        Offset(rect.left + padX, rect.top + (h - tp.height) / 2),
      );
    }
  }

  // 중심 기준 채움 파형
  void _drawCenterFillPath(
    Canvas canvas,
    List<double> src,
    int startIdx,
    int step,
    int count,
    double x0,
    double width,
    double centerY,
    double halfH,
    Paint fill,
  ) {
    final dx = width / count;
    final List<Offset> topPts = <Offset>[];
    final List<Offset> botPts = <Offset>[];

    double x = x0;
    for (int i = 0; i < count; i++) {
      final idx = (startIdx + i * step).clamp(0, src.length - 1);
      final a = src[idx].clamp(0.0, 1.0);
      final yTop = centerY - a * halfH;
      final yBot = centerY + a * halfH;
      topPts.add(Offset(x, yTop));
      botPts.add(Offset(x, yBot));
      x += dx;
    }
    if (topPts.length < 2 || botPts.length < 2) {
      return;
    }

    final path = Path()..moveTo(topPts.first.dx, topPts.first.dy);
    for (int i = 1; i < topPts.length; i++) {
      path.lineTo(topPts[i].dx, topPts[i].dy);
    }
    for (int i = botPts.length - 1; i >= 0; i--) {
      path.lineTo(botPts[i].dx, botPts[i].dy);
    }
    path.close();
    canvas.drawPath(path, fill);
  }

  // A/B 핸들
  void _drawHandle(
    Canvas canvas,
    double x,
    double height,
    Paint p, {
    required bool isA,
  }) {
    const double triW = 8;
    const double triH = 10;
    final double top = 0;
    final Path tri = Path()
      ..moveTo(x, top)
      ..lineTo(x - triW * 0.6, top + triH)
      ..lineTo(x + triW * 0.6, top + triH)
      ..close();
    canvas.drawPath(tri, p);
    canvas.drawRect(Rect.fromLTWH(x - 0.75, top + triH, 1.5, height - triH), p);
  }

  @override
  bool shouldRepaint(covariant _CenterFilledPainter old) {
    // 🔵 viewport·zoom·range·markers 등 “전체 페인트가 필요한 경우”
    final heavy =
        left != old.left ||
        right != old.right ||
        splitStereo != old.splitStereo ||
        duration != old.duration ||
        loopA != old.loopA ||
        loopB != old.loopB ||
        loopOn != old.loopOn ||
        viewStart != old.viewStart ||
        viewWidth != old.viewWidth ||
        showHandles != old.showHandles ||
        markers != old.markers ||
        markerLabels != old.markerLabels ||
        markerColors != old.markerColors ||
        startCue != old.startCue ||
        showStartCue != old.showStartCue;

    if (heavy) return true;

    // 🔴 position-only 변경 → 여기서는 false (position-only layer에서 그린다)
    if (position != old.position) return false;

    return false;
  }
}
