// lib/packages/smart_media_player/widgets/waveform_view.dart
// v2.00.0 | Icon-first rail (filled Start▼, outlined Loop▽ + left/right bracket), label opt-in, label-on-top, muted colors
//          Bipolar, dpr-aware per-pixel sampling, LR-safe, normalized-aware

import 'dart:math' as math;
import 'package:flutter/material.dart';

class WaveformView extends StatefulWidget {
  /// Mono(또는 pre-mixed) 피크 0..1
  final List<double> peaks;

  /// (선택) 우측 채널 피크 0..1 — 제공되면 L/R 2줄로 그림
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

  final bool selectionMode;
  final Duration? selectionA;
  final Duration? selectionB;

  final ValueChanged<Duration>? onSeek;
  final ValueChanged<Duration>? onSelectStart;
  final ValueChanged<Duration>? onSelectUpdate;
  final void Function(Duration? a, Duration? b)? onSelectEnd;

  final double markerRailHeight;
  final Duration startCue;
  final ValueChanged<Duration>? onStartCueChanged;
  final void Function(int index)? onMarkerDragStart;
  final void Function(int index, Duration position)? onMarkerDragUpdate;
  final void Function(int index, Duration position)? onMarkerDragEnd;
  final ValueChanged<Duration>? onRailTapToSeek;

  final ValueChanged<Duration>? onLoopAChanged;
  final ValueChanged<Duration>? onLoopBChanged;

  /// peaks가 이미 (0..1)로 정규화/압축되어 있으면 true
  final bool peaksAreNormalized;

  /// NEW: 레일 텍스트(시작점/Start/End) 표시 (기본 false)
  final bool showLabels;

  /// NEW: 레이블 문자열 (국문/영문 선택)
  final String startCueLabel; // 기본 '시작점'
  final String loopStartLabel; // 기본 'Start'
  final String loopEndLabel; // 기본 'End'

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
    this.selectionMode = true,
    this.selectionA,
    this.selectionB,
    this.onSeek,
    this.onSelectStart,
    this.onSelectUpdate,
    this.onSelectEnd,
    this.markerRailHeight = 40.0,
    this.startCue = Duration.zero,
    this.onStartCueChanged,
    this.onMarkerDragStart,
    this.onMarkerDragUpdate,
    this.onMarkerDragEnd,
    this.onRailTapToSeek,
    this.onLoopAChanged,
    this.onLoopBChanged,
    this.peaksAreNormalized = false,
    this.showLabels = false,
    this.startCueLabel = '시작점',
    this.loopStartLabel = 'Start',
    this.loopEndLabel = 'End',
  });

  @override
  State<WaveformView> createState() => _WaveformViewState();
}

class _WaveformViewState extends State<WaveformView> {
  int? _dragMarkerIndex;
  bool _dragStartCue = false;
  bool _dragLoopA = false;
  bool _dragLoopB = false;

  double get _vs => widget.viewStart.clamp(0.0, 1.0);
  double get _vw => widget.viewWidth.clamp(0.02, 1.0);

  Duration _dxToDuration(double dx, double width) {
    if (widget.duration == Duration.zero) return Duration.zero;
    final tRel = (dx / width).clamp(0.0, 1.0);
    final absT = (_vs + tRel * _vw).clamp(0.0, 1.0);
    final ms = (widget.duration.inMilliseconds * absT).round();
    return Duration(milliseconds: ms);
  }

  bool _isInRail(Offset localPos, double railH) => localPos.dy <= railH;

  int _hitMarkerInRail(Offset localPos, double w, double railH) {
    if (!_isInRail(localPos, railH)) return -1;
    if (widget.duration == Duration.zero || widget.markers.isEmpty) return -1;

    const tolX = 16.0;
    for (int i = 0; i < widget.markers.length; i++) {
      final m = widget.markers[i];
      final t = (m.inMilliseconds / widget.duration.inMilliseconds).clamp(
        0.0,
        1.0,
      );
      final tx = ((t - _vs) / _vw) * w;

      if (tx >= -tolX && tx <= w + tolX) {
        if ((localPos.dx - tx).abs() <= tolX) return i;
      }

      final label =
          (widget.markerLabels != null && i < widget.markerLabels!.length)
          ? widget.markerLabels![i]
          : '';
      if (label.isNotEmpty) {
        final rect = _WavePainter.computeBubbleRect(
          tx: tx,
          w: w,
          railH: railH,
          label: label,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        );
        if (rect.inflate(4).contains(localPos)) return i;
      }
    }
    return -1;
  }

  bool _hitStartCueInRail(Offset localPos, double w, double railH) {
    if (!_isInRail(localPos, railH)) return false;
    if (widget.duration == Duration.zero) return false;
    const tolX = 18.0;
    final t = (widget.startCue.inMilliseconds / widget.duration.inMilliseconds)
        .clamp(0.0, 1.0);
    final tx = ((t - _vs) / _vw) * w;
    return (localPos.dx - tx).abs() <= tolX;
  }

  bool _hitLoopEdgeInRail(
    Offset localPos,
    double w,
    double railH, {
    required bool isA,
  }) {
    if (!_isInRail(localPos, railH)) return false;
    final d = isA ? widget.loopA : widget.loopB;
    if (d == null || widget.duration == Duration.zero) return false;
    const tolX = 16.0;
    final t = (d.inMilliseconds / widget.duration.inMilliseconds).clamp(
      0.0,
      1.0,
    );
    final tx = ((t - _vs) / _vw) * w;
    return (localPos.dx - tx).abs() <= tolX;
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.of(context).devicePixelRatio;

    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final h = c.maxHeight;
        final railH = widget.markerRailHeight.clamp(28.0, 72.0);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,

          onTapDown: (d) {
            final lp = d.localPosition;
            final t = _dxToDuration(lp.dx, w);
            if (_isInRail(lp, railH)) {
              widget.onRailTapToSeek?.call(t);
              widget.onStartCueChanged?.call(t);
              return;
            }
            widget.onSeek?.call(t);
            widget.onStartCueChanged?.call(t);
          },

          onHorizontalDragStart: (d) {
            final lp = d.localPosition;
            if (_isInRail(lp, railH)) {
              if (widget.onLoopAChanged != null &&
                  _hitLoopEdgeInRail(lp, w, railH, isA: true)) {
                _dragLoopA = true;
                return;
              }
              if (widget.onLoopBChanged != null &&
                  _hitLoopEdgeInRail(lp, w, railH, isA: false)) {
                _dragLoopB = true;
                return;
              }
              final hitMarker = _hitMarkerInRail(lp, w, railH);
              if (hitMarker >= 0) {
                _dragMarkerIndex = hitMarker;
                widget.onMarkerDragStart?.call(hitMarker);
                return;
              }
              if (_hitStartCueInRail(lp, w, railH)) {
                _dragStartCue = true;
                return;
              }
              _dragStartCue = true;
              final t = _dxToDuration(lp.dx, w);
              widget.onStartCueChanged?.call(t);
              return;
            }

            if (widget.selectionMode) {
              final t = _dxToDuration(lp.dx, w);
              widget.onSelectStart?.call(t);
            }
          },

          onHorizontalDragUpdate: (d) {
            final lp = d.localPosition;
            final t = _dxToDuration(lp.dx, w);

            if (_isInRail(lp, railH)) {
              if (_dragLoopA && widget.onLoopAChanged != null) {
                widget.onLoopAChanged!(t);
                return;
              }
              if (_dragLoopB && widget.onLoopBChanged != null) {
                widget.onLoopBChanged!(t);
                return;
              }
              if (_dragMarkerIndex != null) {
                widget.onMarkerDragUpdate?.call(_dragMarkerIndex!, t);
                return;
              }
              if (_dragStartCue) {
                widget.onStartCueChanged?.call(t);
                return;
              }
              return;
            }

            if (widget.selectionMode) {
              widget.onSelectUpdate?.call(t);
            } else {
              widget.onSeek?.call(t);
            }
          },

          onHorizontalDragEnd: (_) {
            if (_dragLoopA) {
              _dragLoopA = false;
              return;
            }
            if (_dragLoopB) {
              _dragLoopB = false;
              return;
            }
            if (_dragMarkerIndex != null) {
              final idx = _dragMarkerIndex!;
              _dragMarkerIndex = null;
              widget.onMarkerDragEnd?.call(
                idx,
                const Duration(milliseconds: -1),
              );
              return;
            }
            if (_dragStartCue) {
              _dragStartCue = false;
              return;
            }
            if (widget.selectionMode) {
              widget.onSelectEnd?.call(widget.selectionA, widget.selectionB);
            }
          },

          child: CustomPaint(
            size: Size(w, h),
            painter: _WavePainter(
              devicePixelRatio: dpr,
              peaksL: widget.peaks,
              peaksR: widget.peaksRight,
              duration: widget.duration,
              position: widget.position,
              loopA: widget.loopA,
              loopB: widget.loopB,
              loopOn: widget.loopOn,
              viewStart: _vs,
              viewWidth: _vw,
              markers: widget.markers,
              markerLabels: widget.markerLabels,
              markerColors: widget.markerColors,
              colorBar: Theme.of(context).colorScheme.primary,
              colorBarBg: Theme.of(context).colorScheme.surfaceContainerHighest,
              colorCursor: Theme.of(context).colorScheme.tertiary,
              colorLoop: Theme.of(
                context,
              ).colorScheme.secondary.withValues(alpha: 0.28),
              // NEW: 루프 엣지(아웃라인) 기본색 — 덜 튀는 중립톤
              colorLoopEdge: Theme.of(context).colorScheme.onSurfaceVariant,
              colorMarker: Theme.of(context).colorScheme.error,
              textColor: Colors.black, // 요구사항: 텍스트는 블랙 통일
              selectionA: widget.selectionA,
              selectionB: widget.selectionB,
              colorSelection: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.20),
              railHeight: railH,
              startCue: widget.startCue,
              startCueColor: Theme.of(context).colorScheme.primary,
              peaksAreNormalized: widget.peaksAreNormalized,
              // NEW: 라벨 on/off + 문자열
              showLabels: widget.showLabels,
              startCueLabel: widget.startCueLabel,
              loopStartLabel: widget.loopStartLabel,
              loopEndLabel: widget.loopEndLabel,
            ),
          ),
        );
      },
    );
  }
}

class _WavePainter extends CustomPainter {
  final double devicePixelRatio;
  final List<double> peaksL;
  final List<double>? peaksR;

  final Duration duration;
  final Duration position;
  final Duration? loopA;
  final Duration? loopB;
  final bool loopOn;
  final double viewStart;
  final double viewWidth;
  final List<Duration> markers;
  final List<String>? markerLabels;
  final List<Color?>? markerColors;

  final Color colorBar;
  final Color colorBarBg;
  final Color colorCursor;
  final Color colorLoop;
  final Color colorLoopEdge; // NEW: 루프 엣지 색(중립)
  final Color colorMarker;
  final Color textColor;

  final Duration? selectionA;
  final Duration? selectionB;
  final Color colorSelection;

  final double railHeight;
  final Duration startCue;
  final Color startCueColor;

  final bool peaksAreNormalized;

  final bool showLabels; // NEW
  final String startCueLabel; // NEW
  final String loopStartLabel; // NEW
  final String loopEndLabel; // NEW

  _WavePainter({
    required this.devicePixelRatio,
    required this.peaksL,
    required this.peaksR,
    required this.duration,
    required this.position,
    required this.loopA,
    required this.loopB,
    required this.loopOn,
    required this.viewStart,
    required this.viewWidth,
    required this.markers,
    required this.markerLabels,
    required this.markerColors,
    required this.colorBar,
    required this.colorBarBg,
    required this.colorCursor,
    required this.colorLoop,
    required this.colorLoopEdge,
    required this.colorMarker,
    required this.textColor,
    required this.selectionA,
    required this.selectionB,
    required this.colorSelection,
    required this.railHeight,
    required this.startCue,
    required this.startCueColor,
    required this.peaksAreNormalized,
    required this.showLabels,
    required this.startCueLabel,
    required this.loopStartLabel,
    required this.loopEndLabel,
  });

  double _dbMap(double a) {
    const eps = 1e-6;
    final db = 20 * math.log(a + eps) / math.ln10;
    final norm = ((db + 60.0) / 60.0).clamp(0.0, 1.0);
    return math.pow(norm, 2.2).toDouble();
  }

  double _loud(double a) {
    if (peaksAreNormalized) return a.clamp(0.0, 1.0);
    return _dbMap(a).clamp(0.0, 1.0);
  }

  static Rect computeBubbleRect({
    required double tx,
    required double w,
    required double railH,
    required String label,
    required TextStyle style,
  }) {
    final tp = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 80);

    const padH = 6.0, padV = 2.5;
    final pillW = tp.width + padH * 2;
    final pillH = tp.height + padV * 2;
    final dx = (tx - pillW / 2).clamp(2.0, w - pillW - 2.0);
    final dy = (railH - pillH - 6).clamp(2.0, railH - pillH - 2.0);
    return Rect.fromLTWH(dx, dy, pillW, pillH);
  }

  // ▼ 채워진(필드) 다운 삼각형 (시작점)
  void _drawFilledDownTriangle(
    Canvas canvas,
    double tx,
    double w,
    double topY,
    double bottomY, {
    required Color fill,
    Color? stroke,
    double strokeWidth = 1.2,
    required double widthPx,
  }) {
    final halfW = (widthPx / 2.0).clamp(4.0, 28.0);
    final path = Path()
      ..moveTo(tx, bottomY) // 아래 꼭짓점
      ..lineTo((tx - halfW).clamp(0.0, w), topY) // 좌상단
      ..lineTo((tx + halfW).clamp(0.0, w), topY) // 우상단
      ..close();
    final fillPaint = Paint()..color = fill;
    canvas.drawPath(path, fillPaint);
    if (stroke != null && strokeWidth > 0) {
      final strokePaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = stroke;
      canvas.drawPath(path, strokePaint);
    }
  }

  // ▽ 외곽선 다운 삼각형 (루프 엣지)
  void _drawStrokedDownTriangle(
    Canvas canvas,
    double tx,
    double w,
    double topY,
    double bottomY, {
    required Color stroke,
    double strokeWidth = 1.6,
    required double widthPx,
  }) {
    final halfW = (widthPx / 2.0).clamp(4.0, 24.0);
    final path = Path()
      ..moveTo(tx, bottomY)
      ..lineTo((tx - halfW).clamp(0.0, w), topY)
      ..lineTo((tx + halfW).clamp(0.0, w), topY)
      ..close();
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = stroke;
    canvas.drawPath(path, p);
  }

  // 루프 시작/끝 방향 브래킷(|) 표시
  void _drawBracket(
    Canvas canvas, {
    required double x,
    required double topY,
    required bool left,
    required Color color,
  }) {
    final len = 7.0;
    final p = Paint()
      ..strokeWidth = 2.0
      ..color = color;
    final dx = left ? (x - 10.0) : (x + 10.0);
    canvas.drawLine(Offset(dx, topY), Offset(dx, topY + len), p);
  }

  // 라벨(옵션) — 상단에, 블랙 고정
  void _drawTopLabel(
    Canvas canvas,
    double tx,
    double w,
    double railTop,
    String text,
  ) {
    if (!showLabels || text.isEmpty) return;
    final style = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      color: textColor,
    );
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 80);
    final x = (tx - tp.width / 2).clamp(2.0, w - tp.width - 2.0);
    final y = railTop + 2.0;
    tp.paint(canvas, Offset(x, y));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    final bg = Paint()..color = colorBarBg;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, w, h),
        const Radius.circular(6),
      ),
      bg,
    );

    if (peaksL.isEmpty) return;

    // ----- 가시 구간 계산 -----
    final nL = peaksL.length;
    final nR = peaksR?.length ?? 0;

    final startIdxL = (nL * viewStart).floor().clamp(0, nL - 1);
    final endIdxL = (nL * (viewStart + viewWidth)).ceil().clamp(
      startIdxL + 1,
      nL,
    );
    final visCountL = endIdxL - startIdxL;

    int startIdxR = 0, endIdxR = 0, visCountR = 0;
    if (nR > 0) {
      startIdxR = (nR * viewStart).floor().clamp(0, nR - 1);
      endIdxR = (nR * (viewStart + viewWidth)).ceil().clamp(startIdxR + 1, nR);
      visCountR = endIdxR - startIdxR;
    }

    // 파형 영역
    final railTop = 0.0;
    final railBottom = railHeight;
    final waveTop = railBottom + 2;
    final waveHeight = (h - waveTop).clamp(0.0, h);
    final half = waveHeight / 2;
    final centerY = waveTop + half;
    final gap = (half * 0.08).clamp(2.0, 8.0);

    // 선택/루프 배경
    if (selectionA != null && selectionB != null && duration > Duration.zero) {
      final a = (selectionA!.inMilliseconds / duration.inMilliseconds).clamp(
        0.0,
        1.0,
      );
      final b = (selectionB!.inMilliseconds / duration.inMilliseconds).clamp(
        0.0,
        1.0,
      );
      final left = ((a - viewStart) / viewWidth).clamp(0.0, 1.0) * w;
      final right = ((b - viewStart) / viewWidth).clamp(0.0, 1.0) * w;
      final selPaint = Paint()..color = colorSelection;
      final l = left < right ? left : right;
      final r = left < right ? right : left;
      if (r > 0 && l < w) {
        canvas.drawRect(
          Rect.fromLTWH(l, waveTop, (r - l).abs(), waveHeight),
          selPaint,
        );
      }
    }

    if (loopOn && loopA != null && loopB != null && duration != Duration.zero) {
      final a = (loopA!.inMilliseconds / duration.inMilliseconds).clamp(
        0.0,
        1.0,
      );
      final b = (loopB!.inMilliseconds / duration.inMilliseconds).clamp(
        0.0,
        1.0,
      );
      final left = ((a - viewStart) / viewWidth).clamp(0.0, 1.0) * w;
      final right = ((b - viewStart) / viewWidth).clamp(0.0, 1.0) * w;
      if (right > 0 && left < w) {
        final loopPaint = Paint()..color = colorLoop;
        canvas.drawRect(
          Rect.fromLTWH(left, waveTop, (right - left).abs(), waveHeight),
          loopPaint,
        );
      }
    }

    // 파형 (픽셀당 샘플)
    final barPaint = Paint()..color = colorBar;
    final pixelBars = (w * devicePixelRatio).floor().clamp(1, 200000);
    final stepL = visCountL / pixelBars;
    final stepR = (nR > 0) ? (visCountR / pixelBars) : 0.0;

    double pickL(int i) {
      final rel = (i * stepL).floor().clamp(0, visCountL - 1);
      final idx = (startIdxL + rel).clamp(0, nL - 1);
      return peaksL[idx].clamp(0.0, 1.0);
    }

    double pickR(int i) {
      if (nR == 0) return 0.0;
      final rel = (i * stepR).floor().clamp(0, visCountR - 1);
      final idx = (startIdxR + rel).clamp(0, nR - 1);
      return peaksR![idx].clamp(0.0, 1.0);
    }

    final barW = 1.0 / devicePixelRatio;

    for (int i = 0; i < pixelBars; i++) {
      final pL = pickL(i);
      final loudL = (pL <= 0.0) ? 0.0 : _loud(pL);
      final hL = (half - gap) * loudL;

      double? hR;
      if (nR > 0) {
        final pR = pickR(i);
        final loudR = (pR <= 0.0) ? 0.0 : _loud(pR);
        hR = (half - gap) * loudR;
      }

      final x = (i / devicePixelRatio);

      if (hL > 0.5) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, centerY - gap - hL, barW, hL),
            const Radius.circular(0.8),
          ),
          barPaint,
        );
      }

      final drawH = hR ?? hL;
      if (drawH > 0.5) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, centerY + gap, barW, drawH),
            const Radius.circular(0.8),
          ),
          barPaint,
        );
      }
    }

    // ---- Marker Rail 배경 약간 오버레이 ----
    final railPaint = Paint()..color = colorBarBg.withValues(alpha: 0.92);
    canvas.drawRect(Rect.fromLTWH(0, railTop, w, railHeight), railPaint);

    // ---- 좌표 유틸
    double txFor(Duration d) {
      final t = (d.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
      return ((t - viewStart) / viewWidth).clamp(0.0, 1.0) * w;
    }

    // ---- START (큰, 채워진 ▼ + 블랙 얇은 외곽선)
    if (duration > Duration.zero) {
      final txStart = txFor(startCue);
      final topY = railTop + 8.0; // 위쪽으로 올림
      final bottomY = railBottom - 4.0;
      _drawFilledDownTriangle(
        canvas,
        txStart,
        w,
        topY,
        bottomY,
        fill: startCueColor,
        stroke: Colors.black.withValues(alpha: 0.35),
        widthPx: 22,
      );
      _drawTopLabel(canvas, txStart, w, railTop, startCueLabel);
    }

    // ---- LOOP EDGES (중간, 외곽선 ▽ + 좌/우 브래킷)
    if (loopA != null && duration > Duration.zero) {
      final txA = txFor(loopA!);
      final topY = railTop + 10.0;
      final bottomY = railBottom - 5.0;
      _drawStrokedDownTriangle(
        canvas,
        txA,
        w,
        topY,
        bottomY,
        stroke: colorLoopEdge,
        widthPx: 18,
      );
      _drawBracket(
        canvas,
        x: txA,
        topY: topY - 6.0,
        left: true,
        color: colorLoopEdge,
      );
      _drawTopLabel(canvas, txA, w, railTop, loopStartLabel);
    }

    if (loopB != null && duration > Duration.zero) {
      final txB = txFor(loopB!);
      final topY = railTop + 10.0;
      final bottomY = railBottom - 5.0;
      _drawStrokedDownTriangle(
        canvas,
        txB,
        w,
        topY,
        bottomY,
        stroke: colorLoopEdge,
        widthPx: 18,
      );
      _drawBracket(
        canvas,
        x: txB,
        topY: topY - 6.0,
        left: false,
        color: colorLoopEdge,
      );
      _drawTopLabel(canvas, txB, w, railTop, loopEndLabel);
    }

    // ---- Markers (기존 스타일 유지, 말풍선은 상단 배치 그대로)
    if (duration > Duration.zero && markers.isNotEmpty) {
      for (int i = 0; i < markers.length; i++) {
        final m = markers[i];
        final t = (m.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
        final tx = ((t - viewStart) / viewWidth) * w;
        if (tx >= 0 && tx <= w) {
          final mkColor = (markerColors != null && i < markerColors!.length)
              ? (markerColors![i] ?? colorMarker)
              : colorMarker;

          final mPaint = Paint()
            ..color = mkColor
            ..strokeWidth = 3.0;
          canvas.drawLine(
            Offset(tx, railHeight - 6),
            Offset(tx, railHeight),
            mPaint,
          );

          final label = (markerLabels != null && i < markerLabels!.length)
              ? markerLabels![i]
              : '';
          if (label.isNotEmpty) {
            final pillBg = mkColor.withValues(alpha: 0.92);
            final onPill = pillBg.computeLuminance() > 0.55
                ? Colors.black
                : Colors.white;

            final style = TextStyle(
              fontSize: 11,
              color: onPill,
              fontWeight: FontWeight.w600,
            );
            final rect = computeBubbleRect(
              tx: tx,
              w: w,
              railH: railHeight,
              label: label,
              style: style,
            );
            final rrect = RRect.fromRectAndRadius(
              rect,
              const Radius.circular(10),
            );
            final pPaint = Paint()..color = pillBg;
            canvas.drawRRect(rrect, pPaint);

            final tp = TextPainter(
              text: TextSpan(text: label, style: style),
              textDirection: TextDirection.ltr,
              maxLines: 1,
              ellipsis: '…',
            )..layout(maxWidth: 80);
            tp.paint(canvas, Offset(rect.left + 6, rect.top + 2.5));
          }
        }
      }
    }

    // ---- Cursor
    if (duration != Duration.zero) {
      final t = (position.inMilliseconds / duration.inMilliseconds).clamp(
        0.0,
        1.0,
      );
      final cx = ((t - viewStart) / viewWidth).clamp(0.0, 1.0) * w;

      final shadow = Paint()
        ..color = Colors.black.withValues(alpha: 0.12)
        ..strokeWidth = 4.0;
      canvas.drawLine(
        Offset(cx, waveTop),
        Offset(cx, waveTop + waveHeight),
        shadow,
      );

      final cursor = Paint()
        ..color = colorCursor
        ..strokeWidth = 3.0;
      canvas.drawLine(
        Offset(cx, waveTop),
        Offset(cx, waveTop + waveHeight),
        cursor,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) {
    return old.devicePixelRatio != devicePixelRatio ||
        old.peaksL != peaksL ||
        old.peaksR != peaksR ||
        old.position != position ||
        old.loopA != loopA ||
        old.loopB != loopB ||
        old.loopOn != loopOn ||
        old.viewStart != viewStart ||
        old.viewWidth != viewWidth ||
        old.markers != markers ||
        old.markerLabels != markerLabels ||
        old.markerColors != markerColors ||
        old.colorBar != colorBar ||
        old.colorCursor != colorCursor ||
        old.colorLoop != colorLoop ||
        old.colorLoopEdge != colorLoopEdge ||
        old.colorBarBg != colorBarBg ||
        old.colorMarker != colorMarker ||
        old.textColor != textColor ||
        old.selectionA != selectionA ||
        old.selectionB != selectionB ||
        old.colorSelection != colorSelection ||
        old.railHeight != railHeight ||
        old.startCue != startCue ||
        old.startCueColor != startCueColor ||
        old.peaksAreNormalized != peaksAreNormalized ||
        old.showLabels != showLabels ||
        old.startCueLabel != startCueLabel ||
        old.loopStartLabel != loopStartLabel ||
        old.loopEndLabel != loopEndLabel;
  }
}
