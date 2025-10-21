// lib/packages/smart_media_player/waveform/waveform_view.dart
// v3.31.4 | Center-mirrored + Filled (고정) + A/B 핸들 표시

import 'dart:math' as math;
import 'package:flutter/material.dart';

enum WaveDrawMode { auto, bars, candles, path } // 호환용(미사용)

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

  // 🔥 신규: 핸들 표기
  final bool showHandles;

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
    final vw = widget.viewWidth.clamp(0.02, 1.0);

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
      ),
      size: const Size(double.infinity, 160),
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
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (left.isEmpty ||
        size.width <= 0 ||
        size.height <= 0 ||
        duration <= Duration.zero)
      return;

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
      ..color = const Color(0xFF6EA8FE).withOpacity(0.55);
    final fill2 = Paint()
      ..style = PaintingStyle.fill
      ..color = const Color(0xFF9AD0F9).withOpacity(0.55);
    final linePos = Paint()
      ..color = const Color(0xFF1F4AFF)
      ..strokeWidth = 1.2;
    final loopFill = Paint()..color = const Color(0xFF66CCFF).withOpacity(0.15);

    if (!splitStereo || right == null || right!.isEmpty) {
      final centerY = height * 0.5;
      final halfH = height * 0.48;
      _drawCenterFillPath(
        canvas,
        left,
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
        left,
        startIdx,
        step,
        count,
        0,
        width,
        topCenter,
        halfH,
        fill1,
      );
      _drawCenterFillPath(
        canvas,
        right!,
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

    // 루프 오버레이
    double xOf(Duration t) {
      final f = t.inMilliseconds / duration.inMilliseconds;
      final v = ((f - viewStart) / viewWidth).clamp(0.0, 1.0);
      return (v * width);
    }

    if (loopOn && loopA != null && loopB != null) {
      final xa = xOf(loopA!);
      final xb = xOf(loopB!);
      final r = Rect.fromLTWH(math.min(xa, xb), 0, (xa - xb).abs(), height);
      canvas.drawRect(r, loopFill);
    }

    // 재생 포지션 라인
    final xp = xOf(position);
    canvas.drawLine(Offset(xp, 0), Offset(xp, height), linePos);

    // 🔹 A/B 핸들(삼각깃발)
    if (showHandles) {
      final handlePaintA = Paint()..color = const Color(0xFF0F6FFF);
      final handlePaintB = Paint()..color = const Color(0xFF00B894);

      if (loopA != null)
        _drawHandle(canvas, xOf(loopA!), height, handlePaintA, isA: true);
      if (loopB != null)
        _drawHandle(canvas, xOf(loopB!), height, handlePaintB, isA: false);
    }
  }

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
    if (topPts.length < 2 || botPts.length < 2) return;

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

  void _drawHandle(
    Canvas canvas,
    double x,
    double height,
    Paint p, {
    required bool isA,
  }) {
    // 위쪽 삼각형(+약간의 막대)로 깃발 느낌
    const double triW = 8;
    const double triH = 10;
    final double top = 0;
    final Path tri = Path()
      ..moveTo(x, top)
      ..lineTo(x - triW * 0.6, top + triH)
      ..lineTo(x + triW * 0.6, top + triH)
      ..close();
    canvas.drawPath(tri, p);
    // 얇은 기둥
    canvas.drawRect(Rect.fromLTWH(x - 0.75, top + triH, 1.5, height - triH), p);
  }

  @override
  bool shouldRepaint(covariant _CenterFilledPainter old) {
    return left != old.left ||
        right != old.right ||
        splitStereo != old.splitStereo ||
        position != old.position ||
        duration != old.duration ||
        loopA != old.loopA ||
        loopB != old.loopB ||
        loopOn != old.loopOn ||
        viewStart != old.viewStart ||
        viewWidth != old.viewWidth ||
        showHandles != old.showHandles;
  }
}
