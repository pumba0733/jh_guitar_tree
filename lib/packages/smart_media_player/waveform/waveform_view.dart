// ========================= WaveformView =========================

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'waveform_tuning.dart';


enum WaveDrawMode { auto, bars, candles, path }

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

  /// 레일 텍스트(시작점/Start/End) 표시
  final bool showLabels;

  /// 레이블 문자열
  final String startCueLabel; // 기본 '시작점'
  final String loopStartLabel; // 기본 'Start'
  final String loopEndLabel; // 기본 'End'

  /// NEW: LOD 제공 시 자동 선택
  final List<double>? peaksLow;
  final List<double>? peaksMid;
  final List<double>? peaksHigh;
  final List<double>? peaksRightLow;
  final List<double>? peaksRightMid;
  final List<double>? peaksRightHigh;

  /// NEW: 그리기 모드 힌트
  final WaveDrawMode drawMode;

  /// NEW: 확대시 path 전환 임계(픽셀당 막대 수)
  final double pathSwitchBarsPerPixel;

  /// NEW: 캔들 전환 임계(픽셀당 막대 수)
  final double candleSwitchBarsPerPixel;

  /// NEW: 경로 곡률
  final double pathCurviness;

  /// NEW: 비교용(오토게인/DB맵 끄기)
  final bool visualExact;

    /// NEW: 스테레오를 위/아래 두 밴드(각 밴드에 0-기준선)로 분할 렌더
  final bool splitStereoQuadrants; // 기본 false

  /// NEW: 부호(±)를 파형에 그대로 반영 (ECG 스타일 단일선)
  final bool useSignedAmplitude; // 기본 false


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
    // LOD
    this.peaksLow,
    this.peaksMid,
    this.peaksHigh,
    this.peaksRightLow,
    this.peaksRightMid,
    this.peaksRightHigh,
    // Draw
    this.drawMode = WaveDrawMode.auto,
    this.pathSwitchBarsPerPixel = 0.33,
    this.candleSwitchBarsPerPixel = 0.85,
    this.pathCurviness = 0.55,
    // Compare
    this.visualExact = false,

    // NEW
    this.splitStereoQuadrants = false,
    this.useSignedAmplitude = false,
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
            } else {
              widget.onSeek?.call(t);
              widget.onStartCueChanged?.call(t);
            }
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
              final t = _dxToDuration(d.localPosition.dx, w);
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
              peaksLowL: widget.peaksLow,
              peaksMidL: widget.peaksMid,
              peaksHighL: widget.peaksHigh,
              peaksLowR: widget.peaksRightLow,
              peaksMidR: widget.peaksRightMid,
              peaksHighR: widget.peaksRightHigh,
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
              colorLoopEdge: Theme.of(context).colorScheme.onSurfaceVariant,
              colorMarker: Theme.of(context).colorScheme.error,
              textColor: Colors.black,
              selectionA: widget.selectionA,
              selectionB: widget.selectionB,
              colorSelection: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.20),
              railHeight: railH,
              startCue: widget.startCue,
              startCueColor: Theme.of(context).colorScheme.primary,
              peaksAreNormalized: widget.peaksAreNormalized,
              showLabels: widget.showLabels,
              startCueLabel: widget.startCueLabel,
              loopStartLabel: widget.loopStartLabel,
              loopEndLabel: widget.loopEndLabel,
              forceDrawMode: widget.drawMode,
              candleSwitchBarsPerPixel: widget.candleSwitchBarsPerPixel,
              pathSwitchBarsPerPixel: widget.pathSwitchBarsPerPixel,
              pathCurviness: widget.pathCurviness,
              visualExact: widget.visualExact,
              splitStereoQuadrants: widget.splitStereoQuadrants,
              useSignedAmplitude: widget.useSignedAmplitude,

            ),
          ),
        );
      },
    );
  }
}

class _WavePainter extends CustomPainter {
  final double devicePixelRatio;

  // Base peaks (fallback)
  final List<double> peaksL;
  final List<double>? peaksR;

  // Optional LODs
  final List<double>? peaksLowL;
  final List<double>? peaksMidL;
  final List<double>? peaksHighL;
  final List<double>? peaksLowR;
  final List<double>? peaksMidR;
  final List<double>? peaksHighR;

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
  final Color colorLoopEdge;
  final Color colorMarker;
  final Color textColor;

  final Duration? selectionA;
  final Duration? selectionB;
  final Color colorSelection;

  final double railHeight;
  final Duration startCue;
  final Color startCueColor;

  final bool peaksAreNormalized;
  final bool showLabels;
  final String startCueLabel;
  final String loopStartLabel;
  final String loopEndLabel;

  // Draw controls
  final WaveDrawMode forceDrawMode;
  final double candleSwitchBarsPerPixel;
  final double pathSwitchBarsPerPixel;
  final double pathCurviness;

  // Compare
  final bool visualExact;
  final bool splitStereoQuadrants;
  final bool useSignedAmplitude;


  

  _WavePainter({
    required this.devicePixelRatio,
    required this.peaksL,
    required this.peaksR,
    required this.peaksLowL,
    required this.peaksMidL,
    required this.peaksHighL,
    required this.peaksLowR,
    required this.peaksMidR,
    required this.peaksHighR,
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
    required this.forceDrawMode,
    required this.candleSwitchBarsPerPixel,
    required this.pathSwitchBarsPerPixel,
    required this.pathCurviness,
    required this.visualExact,
    required this.splitStereoQuadrants,
    required this.useSignedAmplitude,

  });

  // ===== Pixel helpers =====
  double _pxAlign(double x) =>
      (x * devicePixelRatio).round() / devicePixelRatio;
  double get _hair => (1.0 / devicePixelRatio);

  // ===== Loudness mapping (two-stage gamma) =====
 



  // ===== Auto-gain with hysteresis =====
  double? _agLastL, _agLastR;
  int? _agLastMs;

  double _autoGainScale(List<double> src, int beg, int end) {
    if (visualExact) return 1.0;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (_agLastMs != null && (nowMs - _agLastMs!) < 120) {
      return _agLastL ?? 1.0;
    }

    final len = (end - beg).clamp(8, src.length);
    if (len <= 8) return _agLastL ?? 1.0;

    const pick = 128;
    final step = math.max(1, (len / pick).floor());
    final buf = <double>[];
    for (int i = beg; i < end; i += step) {
      buf.add(src[i]);
    }
    buf.sort();
    final med = buf[buf.length ~/ 2];
    final raw = (med <= 1e-6) ? 1.0 : (0.65 / med).clamp(0.6, 2.0);

    final prev = _agLastL ?? raw;
    final rising = raw > prev;
    final alpha = rising ? 0.5 : 0.12;
    final smoothed = (prev + alpha * (raw - prev)).clamp(0.6, 2.0);

    _agLastL = smoothed;
    _agLastMs = nowMs;
    return smoothed;
  }

  double _autoGainScaleR(List<double> src, int beg, int end) {
    if (visualExact) return 1.0;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (_agLastMs != null && (nowMs - _agLastMs!) < 120) {
      return _agLastR ?? 1.0;
    }
    final len = (end - beg).clamp(8, src.length);
    if (len <= 8) return _agLastR ?? 1.0;

    const pick = 128;
    final step = math.max(1, (len / pick).floor());
    final buf = <double>[];
    for (int i = beg; i < end; i += step) {
      buf.add(src[i]);
    }
    buf.sort();
    final med = buf[buf.length ~/ 2];
    final raw = (med <= 1e-6) ? 1.0 : (0.65 / med).clamp(0.6, 2.0);

    final prev = _agLastR ?? raw;
    final rising = raw > prev;
    final alpha = rising ? 0.5 : 0.12;
    final smoothed = (prev + alpha * (raw - prev)).clamp(0.6, 2.0);

    _agLastR = smoothed;
    _agLastMs = nowMs;
    return smoothed;
  }

  // ===== Phase-locked fractional min/max =====
  // 픽셀 칼럼이 덮는 [startIdx, startIdx+span) 구간의 min/max를
  // 경계 분수까지 선형보간해 반영한다.
  (double minV, double maxV) _pickMinMaxFrac(
    List<double> src,
    double startIdx,
    double span,
  ) {
    if (src.isEmpty || span <= 0) return (1.0, 0.0);

    final double endIdx = startIdx + span;

    int a = startIdx.floor().clamp(0, src.length - 1);
    int b = endIdx.ceil().clamp(a + 1, src.length);

    double minV = double.infinity;
    double maxV = -double.infinity;

    // 왼쪽 경계 분수
    final leftFrac = startIdx - a; // 0..1
    final vA0 = src[a];
    final vA1 = (a + 1 < src.length) ? src[a + 1] : vA0;
    final vEdgeL = vA0 * (1.0 - leftFrac) + vA1 * leftFrac;
    if (vEdgeL < minV) minV = vEdgeL;
    if (vEdgeL > maxV) maxV = vEdgeL;

    // 내부 정수 인덱스
    for (int i = a + 1; i < b - 1; i++) {
      final v = src[i];
      if (v < minV) minV = v;
      if (v > maxV) maxV = v;
    }

    // 오른쪽 경계 분수
    final rb = b - 1;
    final rightFrac = endIdx - rb; // 0..1
    final vB0 = src[rb];
    final vB1 = (rb + 1 < src.length) ? src[rb + 1] : vB0;
    final vEdgeR = vB0 * (1.0 - rightFrac) + vB1 * rightFrac;
    if (vEdgeR < minV) minV = vEdgeR;
    if (vEdgeR > maxV) maxV = vEdgeR;

    if (minV == double.infinity) minV = 0.0;
    if (maxV == -double.infinity) maxV = 0.0;
    return (minV, maxV);
  }

  // ===== Path-mode용 선형 보간 샘플 =====
  double _sampleLinear(List<double> src, double pos) {
    if (src.isEmpty) return 0.0;
    final p = pos.clamp(0.0, src.length - 1.0);
    final i0 = p.floor();
    final i1 = (i0 + 1).clamp(0, src.length - 1);
    final frac = p - i0;
    final v0 = src[i0];
    final v1 = src[i1];
    return v0 * (1.0 - frac) + v1 * frac;
  }
 
  // 한 픽셀이 덮는 [startIdx, startIdx+span) 구간의
  // signed min / max / mean을 분수 경계 보정해서 구한다.
  (double minV, double maxV, double meanV) _minMaxMeanFracSigned(
    List<double> src,
    double startIdx,
    double span,
  ) {
    if (src.isEmpty || span <= 0) return (0.0, 0.0, 0.0);

    final endIdx = startIdx + span;

    int a = startIdx.floor().clamp(0, src.length - 1);
    int b = endIdx.floor().clamp(0, src.length - 1);

    // 단일 샘플만 덮을 때: 선형보간
    if (a == b) {
      final frac = startIdx - a;
      final v0 = src[a];
      final v1 = (a + 1 < src.length) ? src[a + 1] : v0;
      final v = v0 * (1.0 - frac) + v1 * frac;
      return (v, v, v);
    }

    double minV = double.infinity;
    double maxV = -double.infinity;
    double sum = 0.0;
    double count = 0.0;

    // 좌측 분수 조각
    final leftFrac = 1.0 - (startIdx - a);
    final vA0 = src[a];
    final vA1 = (a + 1 < src.length) ? src[a + 1] : vA0;
    final vEdgeL = vA0 * (1.0 - (startIdx - a)) + vA1 * (startIdx - a);
    minV = (vEdgeL < minV) ? vEdgeL : minV;
    maxV = (vEdgeL > maxV) ? vEdgeL : maxV;
    sum += vEdgeL * leftFrac;
    count += leftFrac;

    // 내부 정수 구간
    for (int i = a + 1; i <= b - 1; i++) {
      final v = src[i];
      if (v < minV) minV = v;
      if (v > maxV) maxV = v;
      sum += v;
      count += 1.0;
    }

    // 우측 분수 조각
    final rightFrac = (endIdx - b).clamp(0.0, 1.0);
    final vB0 = src[b];
    final vB1 = (b + 1 < src.length) ? src[b + 1] : vB0;
    final vEdgeR = vB0 * (1.0 - rightFrac) + vB1 * rightFrac;
    if (vEdgeR < minV) minV = vEdgeR;
    if (vEdgeR > maxV) maxV = vEdgeR;
    sum += vEdgeR * rightFrac;
    count += rightFrac;

    final meanV = (count > 1e-9) ? (sum / count) : 0.0;
    if (minV == double.infinity) minV = 0.0;
    if (maxV == -double.infinity) maxV = 0.0;
    return (minV, maxV, meanV);
  }


    // 픽셀 한 칼럼이 덮는 [startIdx, startIdx+span) 구간의
  // "부호값 평균(박스-필터)"을 분수 경계까지 보정해서 계산.
  // src 값 범위는 -1..+1 가정.
  


  // ===== Shapes & labels =====
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
    )..layout(maxWidth: 80.0);
    const padH = 6.0, padV = 2.5;
    final pillW = tp.width + padH * 2;
    final pillH = tp.height + padV * 2;
    final dx = (tx - pillW / 2).clamp(2.0, w - pillW - 2.0);
    final dy = (railH - pillH - 6).clamp(2.0, railH - pillH - 2.0);
    return Rect.fromLTWH(dx, dy, pillW, pillH);
  }

    @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;


    // Background
    final bg = Paint()..color = colorBarBg;
    final outerRRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, w, h),
      const Radius.circular(6),
    );
    canvas.drawRRect(outerRRect, bg);

    if (peaksL.isEmpty || duration == Duration.zero) return;

    // LOD pick
    final pixelBars = (w * devicePixelRatio).floor().clamp(1, 200000);
    final useL0 = _chooseLOD(
      peaksL,
      peaksLowL,
      peaksMidL,
      peaksHighL,
      pixelBars,
    );
    final useR0 = peaksR == null
        ? null
        : _chooseLOD(peaksR!, peaksLowR, peaksMidR, peaksHighR, pixelBars);

    // === (A) 저배율 요동 억제 (옵션 B)
    // 부호 파형(useSignedAmplitude=true)에서는 픽셀 박스-필터 평균을 쓰므로
    // 여기서의 사전 smoothing 은 끈다(왜곡 방지).
    // Signed(ECG)는 aliasing과 왜곡 방지를 위해 항상 smoothing OFF
    final bool smoothingAllowed = !useSignedAmplitude;
    final int smoothRadius = smoothingAllowed
        ? WaveformTuning.I.smoothingRadiusForViewWidth(viewWidth)
        : 0;

    final useL = (smoothRadius > 0) ? _smooth(useL0, smoothRadius) : useL0;
    final useR = (smoothRadius > 0 && useR0 != null)
        ? _smooth(useR0, smoothRadius)
        : useR0;

    final nL = useL.length;
    final nR = useR?.length ?? 0;

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

    final railTop = 0.0;
    final waveTop = railHeight + 2.0;
    final waveHeight = (h - waveTop).clamp(0.0, h);

    // === 파형을 그리기 직전에만 Clip 시작 ===
    final waveClip = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, waveTop, w, waveHeight),
      const Radius.circular(6),
    );
    canvas.save();
    canvas.clipRRect(waveClip);


    // 기본(겹침) 레이아웃
    final halfAll = waveHeight / 2.0;
    final centerAll = waveTop + halfAll;
    final gapAll = (halfAll * 0.08).clamp(2.0, 8.0);

    // NEW: 분할 레이아웃 (위=L, 아래=R)
    late double centerYL, centerYR, halfBand, gapL, gapR, bandTopL, bandTopR;
    if (splitStereoQuadrants && peaksR != null) {
      halfBand = waveHeight / 2.0;
      bandTopL = waveTop;
      bandTopR = waveTop + halfBand;
      centerYL = bandTopL + halfBand / 2.0;
      centerYR = bandTopR + halfBand / 2.0;
      gapL = (halfBand * 0.08).clamp(2.0, 8.0);
      gapR = (halfBand * 0.08).clamp(2.0, 8.0);
    } else {
      // 기존(겹침)처럼 동일 센터
      halfBand = halfAll;
      centerYL = centerAll;
      centerYR = centerAll;
      gapL = gapAll;
      gapR = gapAll;
    }


    // Selection / Loop
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
      final l = math.min(left, right);
      final r = math.max(left, right);
      if (r > 0 && l < w) {
        canvas.drawRect(
          Rect.fromLTWH(l, waveTop, (r - l).abs(), waveHeight),
          selPaint,
        );
      }
    }
        if (splitStereoQuadrants && peaksR != null) {
      final linePaint = Paint()
        ..color = colorBar
            .withValues(alpha: 0.36) // +0.06
        ..strokeWidth = _hair;
      // L 0선
      canvas.drawLine(
        Offset(0, _pxAlign(centerYL)),
        Offset(w, _pxAlign(centerYL)),
        linePaint,
      );
      // R 0선
      canvas.drawLine(
        Offset(0, _pxAlign(centerYR)),
        Offset(w, _pxAlign(centerYR)),
        linePaint,
      );
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

    // Pens
    final strokeL = Paint()
      ..color = colorBar
      ..style = PaintingStyle.stroke
      ..strokeWidth = _hair
      ..isAntiAlias = true;
    final strokeR = Paint()
      ..color = colorBar.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = _hair
      ..isAntiAlias = true;
    final fill = Paint()
      ..color = colorBar.withValues(alpha: 0.14)
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    // Steps
    final stepL = visCountL / pixelBars;
    final stepR = (nR > 0) ? (visCountR / pixelBars) : 0.0;

    // AutoGain: signed 파형(ECG 모드)에서는 OFF (형상 왜곡 방지)
    final bool signedMode = useSignedAmplitude;
    final agClamp = visualExact ? 1.0 : _zoomGainClamp(pixelBars);
    final agL = signedMode
        ? 1.0
        : (_autoGainScale(useL, startIdxL, endIdxL) * agClamp);
    final agR = (nR > 0)
        ? (signedMode
              ? 1.0
              : (_autoGainScaleR(useR!, startIdxR, endIdxR) * agClamp))
        : 1.0;

    // Draw mode 결정
    final barsPerPixel = (visCountL / pixelBars).clamp(0.000001, 9999.0);
    final mode = _decideDrawMode(barsPerPixel);

    // NEW: fill 투명도 가변 — 줌아웃일수록 더 채워 보이게
    final double fillAlpha = WaveformTuning.I.fillAlphaByBarsPerPixel(
      barsPerPixel,
    );
    fill.color = colorBar.withValues(alpha: fillAlpha);


    

        // === Render ===
    if (splitStereoQuadrants && useR != null) {
      // 상단(L) 1패스
      switch (mode) {
        case WaveDrawMode.bars:
          _drawBars(
            canvas,
            w,
            centerYL,
            gapL,
            halfBand,
            useL,
            null, // R 없음
            startIdxL,
            stepL,
            0,
            0.0, // R 인덱스/스텝 무시
            agL,
            1.0,
            strokeL,
            strokeR,
            fill,
          );
          break;
        case WaveDrawMode.candles:
          _drawCandles(
            canvas,
            w,
            centerYL,
            gapL,
            halfBand,
            useL,
            null,
            startIdxL,
            stepL,
            0,
            0.0,
            agL,
            1.0,
            strokeL,
            strokeR,
          );
          break;
        case WaveDrawMode.path:
        case WaveDrawMode.auto:
          _drawPath(
            canvas,
            w,
            centerYL,
            gapL,
            halfBand,
            useL,
            null,
            startIdxL,
            stepL,
            0,
            0.0,
            agL,
            1.0,
            strokeL,
            strokeR,
            fill,
          );
          break;
      }

      // 하단(R) 1패스 — L 파라미터 자리에 R 데이터를 넣는다
      switch (mode) {
        case WaveDrawMode.bars:
          _drawBars(
            canvas,
            w,
            centerYR,
            gapR,
            halfBand,
            useR,
            null,
            startIdxR,
            stepR,
            0,
            0.0,
            agR,
            1.0,
            strokeR,
            strokeR,
            fill,
          );
          break;
        case WaveDrawMode.candles:
          _drawCandles(
            canvas,
            w,
            centerYR,
            gapR,
            halfBand,
            useR,
            null,
            startIdxR,
            stepR,
            0,
            0.0,
            agR,
            1.0,
            strokeR,
            strokeR,
          );
          break;
        case WaveDrawMode.path:
        case WaveDrawMode.auto:
          _drawPath(
            canvas,
            w,
            centerYR,
            gapR,
            halfBand,
            useR,
            null,
            startIdxR,
            stepR,
            0,
            0.0,
            agR,
            1.0,
            strokeR,
            strokeR,
            fill,
          );
          break;
      }
    } else {
      // 기존(겹침) 모드 — 동일 센터로 L/R 함께
      switch (mode) {
        case WaveDrawMode.bars:
          _drawBars(
            canvas,
            w,
            centerAll,
            gapAll,
            halfAll,
            useL,
            useR,
            startIdxL,
            stepL,
            startIdxR,
            stepR,
            agL,
            agR,
            strokeL,
            strokeR,
            fill,
          );
          break;
        case WaveDrawMode.candles:
          _drawCandles(
            canvas,
            w,
            centerAll,
            gapAll,
            halfAll,
            useL,
            useR,
            startIdxL,
            stepL,
            startIdxR,
            stepR,
            agL,
            agR,
            strokeL,
            strokeR,
          );
          break;
        case WaveDrawMode.path:
        case WaveDrawMode.auto:
          _drawPath(
            canvas,
            w,
            centerAll,
            gapAll,
            halfAll,
            useL,
            useR,
            startIdxL,
            stepL,
            startIdxR,
            stepR,
            agL,
            agR,
            strokeL,
            strokeR,
            fill,
          );
          break;
      }
    }


    // === 파형 클립 해제 후 상단 레일 오버레이 ===
    canvas.restore();

    // Marker Rail overlay
    final railPaint = Paint()..color = colorBarBg.withValues(alpha: 0.92);
    canvas.drawRect(Rect.fromLTWH(0, 0, w, railHeight), railPaint);

    double txFor(Duration d) {
      final t = (d.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
      return ((t - viewStart) / viewWidth).clamp(0.0, 1.0) * w;
    }

    // START ▼
    if (duration > Duration.zero) {
      final txStart = txFor(startCue);
      final topY = railTop + 8.0;
      final bottomY = railHeight - 4.0;
      _drawFilledDownTriangle(
        canvas: canvas,
        tx: txStart,
        w: w,
        topY: topY,
        bottomY: bottomY,
        fill: startCueColor,
        stroke: Colors.black.withValues(alpha: 0.35),
        widthPx: 22,
      );
      _drawTopLabel(canvas, txStart, w, railTop, startCueLabel);
    }

    // LOOP ▽ + bracket
    if (loopA != null && duration > Duration.zero) {
      final txA = txFor(loopA!);
      final topY = railTop + 10.0;
      final bottomY = railHeight - 5.0;
      _drawStrokedDownTriangle(
        canvas: canvas,
        tx: txA,
        w: w,
        topY: topY,
        bottomY: bottomY,
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
      final bottomY = railHeight - 5.0;
      _drawStrokedDownTriangle(
        canvas: canvas,
        tx: txB,
        w: w,
        topY: topY,
        bottomY: bottomY,
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

    // Markers
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
            ..strokeWidth = _hair * 3.0;
          canvas.drawLine(
            Offset(_pxAlign(tx), railHeight - 6),
            Offset(_pxAlign(tx), railHeight),
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
            )..layout(maxWidth: 80.0);
            tp.paint(canvas, Offset(rect.left + 6, rect.top + 2.5));
          }
        }
      }
    }

    // Cursor
    final t = (position.inMilliseconds / duration.inMilliseconds).clamp(
      0.0,
      1.0,
    );
    final cx = ((t - viewStart) / viewWidth).clamp(0.0, 1.0) * w;

    final shadow = Paint()
      ..color = Colors.black.withValues(alpha: 0.12)
      ..strokeWidth = _hair * 4.0;
    canvas.drawLine(
      Offset(_pxAlign(cx), waveTop),
      Offset(_pxAlign(cx), waveTop + waveHeight),
      shadow,
    );

    final cursor = Paint()
      ..color = colorCursor
      ..strokeWidth = _hair * 3.0;
    canvas.drawLine(
      Offset(_pxAlign(cx), waveTop),
      Offset(_pxAlign(cx), waveTop + waveHeight),
      cursor,
    );
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
        old.loopEndLabel != loopEndLabel ||
        old.forceDrawMode != forceDrawMode ||
        old.candleSwitchBarsPerPixel != candleSwitchBarsPerPixel ||
        old.pathSwitchBarsPerPixel != pathSwitchBarsPerPixel ||
        old.pathCurviness != pathCurviness ||
        old.visualExact != visualExact ||
        old.peaksLowL != peaksLowL ||
        old.peaksMidL != peaksMidL ||
        old.peaksHighL != peaksHighL ||
        old.peaksLowR != peaksLowR ||
        old.peaksMidR != peaksMidR ||
        old.peaksHighR != peaksHighR ||
        // 새 필드 2개
        old.splitStereoQuadrants != splitStereoQuadrants ||
        old.useSignedAmplitude != useSignedAmplitude;
  }


  // ===== Helpers =====

  List<double> _chooseLOD(
    List<double> base,
    List<double>? low,
    List<double>? mid,
    List<double>? high,
    int pixelBars,
  ) {
    // 확대일수록 high
    if (high != null && pixelBars < 24) return high;
    if (mid != null && pixelBars < 64) return mid;
    if (low != null) return low;
    return base;
  }

  double _zoomGainClamp(int pixelBars) {
    return WaveformTuning.I.zoomGainClamp(pixelBars, visualExact: visualExact);
  }

  WaveDrawMode _decideDrawMode(double barsPerPixel) {
    if (forceDrawMode != WaveDrawMode.auto) return forceDrawMode;
    if (barsPerPixel <= 0.30) return WaveDrawMode.path; // 고배율(조금 더 일찍 path)
    if (barsPerPixel <= 0.90) return WaveDrawMode.candles; // 중간
    return WaveDrawMode.bars; // 저배율
  }


    // ===== Simple moving average smoothing (옵션 B) =====
  List<double> _smooth(List<double> src, int radius) {
    if (radius <= 0 || src.length < (radius * 2 + 1)) return src;
    final out = List<double>.from(src);
    double acc = 0.0;
    // 초기 누산
    for (int i = 0; i < radius; i++) {
      acc += src[i];
    }
    // 메인 구간
    for (int i = radius; i < src.length - radius; i++) {
      // i-radius..i+radius 합
      if (i == radius) {
        for (int k = i - radius; k <= i + radius; k++) {
          acc += src[k];
        }
      } else {
        acc += src[i + radius];
      }

      final prevLeft = i - radius - 1;
      if (prevLeft >= 0) acc -= src[prevLeft];
      out[i] = acc / (radius * 2 + 1);
    }
    // 양 끝단: 원본 유지(시각적 artifact 최소화)
    for (int i = 0; i < radius; i++) {
      out[i] = src[i];
      out[src.length - 1 - i] = src[src.length - 1 - i];
    }
    return out;
  }


  double _limitH(double hVal, double half, double gap) =>
      hVal.clamp(0.0, (half - gap - 0.5));
  double _limitHInBand(double hVal, double halfBand, double gap) =>
      hVal.clamp(0.0, (halfBand - gap - 0.5));


  // --------- Renderers ---------

  void _drawBars(
    Canvas canvas,
    double w,
    double centerY,
    double gap,
    double half,
    List<double> L,
    List<double>? R,
    int startIdxL,
    double stepL,
    int startIdxR,
    double stepR,
    double agL,
    double agR,
    Paint strokeL,
    Paint strokeR,
    Paint fill,
  ) {
    final pixelBars = (w * devicePixelRatio).floor().clamp(1, 200000);
    final topPathL = Path();
    final botPathL = Path();
    final topPathR = Path();
    final botPathR = Path();

    bool started = false;
    Offset? prevTopL, prevBotL, prevTopR, prevBotR;

    for (int i = 0; i < pixelBars; i++) {
      final startL = startIdxL + i * stepL;
      final (minL, maxL) = _pickMinMaxFrac(L, startL, stepL);
      final pL = (maxL * agL).clamp(0.0, 1.0);
      final loudL = _loud(pL);
      final hL = _limitH((half - gap) * loudL, half, gap);

      double hR = 0.0;
      if (R != null) {
        final startR = startIdxR + i * stepR;
        final (minR, maxR) = _pickMinMaxFrac(R, startR, stepR);
        final pR = (maxR * agR).clamp(0.0, 1.0);
        hR = _limitH((half - gap) * _loud(pR), half, gap);
      }

      final x = _pxAlign(i / devicePixelRatio);
      final yTL = centerY - gap - hL;
      final yBL = centerY + gap + hL;
      final yTR = centerY - gap - hR;
      final yBR = centerY + gap + hR;

      if (!started) {
        topPathL.moveTo(x, yTL);
        botPathL.moveTo(x, yBL);
        if (R != null) {
          topPathR.moveTo(x, yTR);
          botPathR.moveTo(x, yBR);
        }
        prevTopL = Offset(x, yTL);
        prevBotL = Offset(x, yBL);
        if (R != null) {
          prevTopR = Offset(x, yTR);
          prevBotR = Offset(x, yBR);
        }
        started = true;
      } else {
        final dx = (x - prevTopL!.dx).abs();
        final sharpL =
            (yTL - prevTopL.dy).abs() > (half * 0.24).clamp(3.0, 20.0) ||
            (yBL - prevBotL!.dy).abs() > (half * 0.24).clamp(3.0, 20.0);

        if (sharpL || dx < 1e-6) {
          topPathL.lineTo(x, yTL);
          botPathL.lineTo(x, yBL);
        } else {
          final cTL = Offset(
            (prevTopL.dx + x) * 0.5,
            (prevTopL.dy + yTL) * 0.5,
          );
          final cBL = Offset(
            (prevBotL.dx + x) * 0.5,
            (prevBotL.dy + yBL) * 0.5,
          );
          topPathL.quadraticBezierTo(_pxAlign(cTL.dx), cTL.dy, x, yTL);
          botPathL.quadraticBezierTo(_pxAlign(cBL.dx), cBL.dy, x, yBL);
        }

        if (R != null) {
          final sharpR =
              (yTR - prevTopR!.dy).abs() > (half * 0.24).clamp(3.0, 20.0) ||
              (yBR - prevBotR!.dy).abs() > (half * 0.24).clamp(3.0, 20.0);
          if (sharpR || dx < 1e-6) {
            topPathR.lineTo(x, yTR);
            botPathR.lineTo(x, yBR);
          } else {
            final cTR = Offset(
              (prevTopR.dx + x) * 0.5,
              (prevTopR.dy + yTR) * 0.5,
            );
            final cBR = Offset(
              (prevBotR.dx + x) * 0.5,
              (prevBotR.dy + yBR) * 0.5,
            );
            topPathR.quadraticBezierTo(_pxAlign(cTR.dx), cTR.dy, x, yTR);
            botPathR.quadraticBezierTo(_pxAlign(cBR.dx), cBR.dy, x, yBR);
          }
        }

        prevTopL = Offset(x, yTL);
        prevBotL = Offset(x, yBL);
        if (R != null) {
          prevTopR = Offset(x, yTR);
          prevBotR = Offset(x, yBR);
        }
      }
    }

    // Fill under top L (mono fill for stability)
    final fillPath = Path()
      ..addPath(topPathL, Offset.zero)
      ..lineTo(_pxAlign(w), centerY + gap)
      ..lineTo(_pxAlign(0.0), centerY + gap)
      ..close();
    canvas.drawPath(fillPath, fill);

    canvas.drawPath(topPathL, strokeL);
    canvas.drawPath(botPathL, strokeL);
    if (R != null) {
      canvas.drawPath(topPathR, strokeR);
      canvas.drawPath(botPathR, strokeR);
    }
  }

  double _loud(double a) {
    return WaveformTuning.I.loud(a, visualExact: visualExact);
  }

  double _ampSigned(double x) {
    // 입력 x는 -1..+1 가정, 시각용 보정
    final a = x.abs().clamp(0.0, 1.0);
    return visualExact ? a : WaveformTuning.I.loud(a, visualExact: false);
  }


  void _drawCandles(
    Canvas canvas,
    double w,
    double centerY,
    double gap,
    double half,
    List<double> L,
    List<double>? R,
    int startIdxL,
    double stepL,
    int startIdxR,
    double stepR,
    double agL,
    double agR,
    Paint strokeL,
    Paint strokeR,
  ) {
    final pixelBars = (w * devicePixelRatio).floor().clamp(1, 200000);

    final pL = Paint()
      ..color = colorBar.withValues(alpha: 0.85)
      ..strokeWidth = _hair * 2.0
      ..strokeCap = StrokeCap.butt;

    final pR = Paint()
      ..color = colorBar.withValues(alpha: 0.65)
      ..strokeWidth = _hair * 2.0
      ..strokeCap = StrokeCap.butt;

    for (int i = 0; i < pixelBars; i++) {
      final x = _pxAlign(i / devicePixelRatio);

      final startL = startIdxL + i * stepL;
      final (minL0, maxL0) = _pickMinMaxFrac(L, startL, stepL);

      if (useSignedAmplitude) {
        final scale = WaveformTuning.I.signedVisualScale.clamp(0.5, 1.0);
        final hiL = _limitHInBand(
          (half - gap) * (_ampSigned(maxL0 * agL) * scale),
          half,
          gap,
        );
        final loL = _limitHInBand(
          (half - gap) * (_ampSigned(minL0 * agL) * scale),
          half,
          gap,
        );
        final yHi = (maxL0 >= 0)
            ? (centerY - gap - hiL)
            : (centerY + gap + hiL);
        final yLo = (minL0 >= 0)
            ? (centerY - gap - loL)
            : (centerY + gap + loL);
        canvas.drawLine(Offset(x, yLo), Offset(x, yHi), pL); // ← L은 pL로
      } else {
        final hiL = _limitHInBand(
          (half - gap) * _loud((maxL0 * agL).clamp(0.0, 1.0)),
          half,
          gap,
        );
        final loL = _limitHInBand(
          (half - gap) * _loud((minL0.abs() * agL).clamp(0.0, 1.0)),
          half,
          gap,
        );
        canvas.drawLine(
          Offset(x, centerY - gap - hiL),
          Offset(x, centerY - gap - loL),
          pL,
        );
        canvas.drawLine(
          Offset(x, centerY + gap + loL),
          Offset(x, centerY + gap + hiL),
          pL,
        );
      }

      if (R != null) {
        final startR = startIdxR + i * stepR;
        final (minR, maxR) = _pickMinMaxFrac(R, startR, stepR);

        if (useSignedAmplitude) {
          final hiR = _limitHInBand(
            (half - gap) * _ampSigned(maxR * agR),
            half,
            gap,
          );
          final loR = _limitHInBand(
            (half - gap) * _ampSigned(minR * agR),
            half,
            gap,
          );
          final yHi = (maxR >= 0)
              ? (centerY - gap - hiR)
              : (centerY + gap + hiR);
          final yLo = (minR >= 0)
              ? (centerY - gap - loR)
              : (centerY + gap + loR);
          canvas.drawLine(Offset(x, yLo), Offset(x, yHi), pR);
        } else {
          final hiR = _limitHInBand(
            (half - gap) * _loud((maxR * agR).clamp(0.0, 1.0)),
            half,
            gap,
          );
          final loR = _limitHInBand(
            (half - gap) * _loud((minR.abs() * agR).clamp(0.0, 1.0)),
            half,
            gap,
          );
          canvas.drawLine(
            Offset(x, centerY - gap - hiR),
            Offset(x, centerY - gap - loR),
            pR,
          );
          canvas.drawLine(
            Offset(x, centerY + gap + loR),
            Offset(x, centerY + gap + hiR),
            pR,
          );
        }
      }
    }
  }


  void _drawPath(
    Canvas canvas,
    double w,
    double centerY,
    double gap,
    double half,
    List<double> L,
    List<double>? R,
    int startIdxL,
    double stepL,
    int startIdxR,
    double stepR,
    double agL,
    double agR,
    Paint strokeL,
    Paint strokeR,
    Paint fill,
  ) {
    final pixelBars = (w * devicePixelRatio).floor().clamp(1, 200000);

    // ============================================
    // [NEW] Signed waveform path (ECG style)
    // ============================================
    if (useSignedAmplitude) {
      final pathL = Path();
      bool startedL = false;
      double? smoothYL;

      

      for (int i = 0; i < pixelBars; i++) {
        final x = _pxAlign(i / devicePixelRatio);
        final startL = startIdxL + i * stepL;

        // 구간 평균/극값
        final (minL, maxL, meanL) = _minMaxMeanFracSigned(L, startL, stepL);
        final absMaxL = (maxL.abs() >= minL.abs()) ? maxL : minL;

        // 줌(픽셀당 포함 샘플 수 ≈ stepL)에 따른 가중 자동화
        final meanW = WaveformTuning.I.signedBlendWeight(stepL);
        final repL = (meanL * meanW) + (absMaxL * (1.0 - meanW));

        // amplitude → y좌표
        final vL = repL.clamp(-1.0, 1.0);
        // visualExact면 선형(그대로), 아니면 기존 _loud 사용
        double ampL = vL.abs().clamp(0.0, 1.0);
        if (!visualExact) ampL = _loud(ampL);

        // signed 전용 시각 스케일(프리셋): cache 측과 톤 일치
        final scale = WaveformTuning.I.signedVisualScale.clamp(0.5, 1.0);
        final hL = _limitHInBand((half - gap) * (ampL * scale), half, gap);

        final yRaw = (vL >= 0) ? (centerY - gap - hL) : (centerY + gap + hL);

        // EMA smoothing (줌아웃시 미세 떨림 방지)
        smoothYL = (smoothYL == null) ? yRaw : (smoothYL * 0.8 + yRaw * 0.2);

        if (!startedL) {
          pathL.moveTo(x, smoothYL);
          startedL = true;
        } else {
          pathL.lineTo(x, smoothYL);
        }
      }
      canvas.drawPath(pathL, strokeL);

      // R채널도 동일 처리
      if (R != null) {
        final pathR = Path();
        bool startedR = false;
        double? smoothYR;
        for (int i = 0; i < pixelBars; i++) {
          final x = _pxAlign(i / devicePixelRatio);
          final startR = startIdxR + i * stepR;
          final (minR, maxR, meanR) = _minMaxMeanFracSigned(R, startR, stepR);
          final absMaxR = (maxR.abs() >= minR.abs()) ? maxR : minR;
          final repR = (meanR * 0.75) + (absMaxR * 0.25);
          final vR = repR.clamp(-1.0, 1.0);
          double ampR = vR.abs().clamp(0.0, 1.0);
          if (!visualExact) ampR = _loud(ampR);
          final hR = _limitHInBand((half - gap) * ampR, half, gap);
          final yRaw = (vR >= 0) ? (centerY - gap - hR) : (centerY + gap + hR);
          smoothYR = (smoothYR == null) ? yRaw : (smoothYR * 0.8 + yRaw * 0.2);

          if (!startedR) {
            pathR.moveTo(x, smoothYR);
            startedR = true;
          } else {
            pathR.lineTo(x, smoothYR);
          }
        }
        canvas.drawPath(pathR, strokeR);
      }

      // signed 모드는 여기서 끝
      return;
    }



    // 기존(절댓값 기반) 부드러운 상/하 대칭 경로
    final pathTopL = Path(), pathBotL = Path();
    final pathTopR = Path(), pathBotR = Path();
    bool started = false;
    Offset? prevTL, prevBL, prevTR, prevBR;
    final curve = pathCurviness.clamp(0.0, 1.0);

    for (int i = 0; i < pixelBars; i++) {
      final x = _pxAlign(i / devicePixelRatio);

      final posL = startIdxL + i * stepL;
      final vL = (_sampleLinear(L, posL) * agL).clamp(0.0, 1.0);
      final hL = _limitHInBand((half - gap) * _loud(vL), half, gap);

      double hR = 0.0;
      if (R != null) {
        final posR = startIdxR + i * stepR;
        final vR = (_sampleLinear(R, posR) * agR).clamp(0.0, 1.0);
        hR = _limitHInBand((half - gap) * _loud(vR), half, gap);
      }

      final yTL = centerY - gap - hL;
      final yBL = centerY + gap + hL;
      final yTR = centerY - gap - hR;
      final yBR = centerY + gap + hR;

      if (!started) {
        pathTopL.moveTo(x, yTL);
        pathBotL.moveTo(x, yBL);
        if (R != null) {
          pathTopR.moveTo(x, yTR);
          pathBotR.moveTo(x, yBR);
        }
        prevTL = Offset(x, yTL);
        prevBL = Offset(x, yBL);
        if (R != null) {
          prevTR = Offset(x, yTR);
          prevBR = Offset(x, yBR);
        }
        started = true;
      } else {
        final cxL = (prevTL!.dx + x) * 0.5;
        final cyTL = (prevTL.dy + yTL) * 0.5 * (1 - curve) + yTL * curve;
        final cyBL = (prevBL!.dy + yBL) * 0.5 * (1 - curve) + yBL * curve;
        pathTopL.quadraticBezierTo(_pxAlign(cxL), cyTL, x, yTL);
        pathBotL.quadraticBezierTo(_pxAlign(cxL), cyBL, x, yBL);

        if (R != null) {
          final cxR = (prevTR!.dx + x) * 0.5;
          final cyTR = (prevTR.dy + yTR) * 0.5 * (1 - curve) + yTR * curve;
          final cyBR = (prevBR!.dy + yBR) * 0.5 * (1 - curve) + yBR * curve;
          pathTopR.quadraticBezierTo(_pxAlign(cxR), cyTR, x, yTR);
          pathBotR.quadraticBezierTo(_pxAlign(cxR), cyBR, x, yBR);
        }

        prevTL = Offset(x, yTL);
        prevBL = Offset(x, yBL);
        if (R != null) {
          prevTR = Offset(x, yTR);
          prevBR = Offset(x, yBR);
        }
      }
    }

    // 얇은 베이스 fill (L만)
    final fillPath = Path()
      ..addPath(pathTopL, Offset.zero)
      ..lineTo(_pxAlign(w), centerY + gap)
      ..lineTo(_pxAlign(0.0), centerY + gap)
      ..close();
    canvas.drawPath(fillPath, fill);

    canvas.drawPath(pathTopL, strokeL);
    canvas.drawPath(pathBotL, strokeL);
    if (R != null) {
      canvas.drawPath(pathTopR, strokeR);
      canvas.drawPath(pathBotR, strokeR);
    }
  }


  // --- small shape helpers for markers/labels ---

  void _drawFilledDownTriangle({
    required Canvas canvas,
    required double tx,
    required double w,
    required double topY,
    required double bottomY,
    required Color fill,
    Color? stroke,
    double strokeWidth = 1.2,
    required double widthPx,
  }) {
    final halfW = (widthPx / 2.0).clamp(4.0, 28.0);
    final path = Path()
      ..moveTo(_pxAlign(tx), bottomY)
      ..lineTo((_pxAlign(tx - halfW)).clamp(0.0, w), topY)
      ..lineTo((_pxAlign(tx + halfW)).clamp(0.0, w), topY)
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

  void _drawStrokedDownTriangle({
    required Canvas canvas,
    required double tx,
    required double w,
    required double topY,
    required double bottomY,
    required Color stroke,
    double strokeWidth = 1.6,
    required double widthPx,
  }) {
    final halfW = (widthPx / 2.0).clamp(4.0, 24.0);
    final path = Path()
      ..moveTo(_pxAlign(tx), bottomY)
      ..lineTo((_pxAlign(tx - halfW)).clamp(0.0, w), topY)
      ..lineTo((_pxAlign(tx + halfW)).clamp(0.0, w), topY)
      ..close();
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = stroke;
    canvas.drawPath(path, p);
  }

  void _drawBracket(
    Canvas canvas, {
    required double x,
    required double topY,
    required bool left,
    required Color color,
  }) {
    final len = 7.0;
    final p = Paint()
      ..strokeWidth = _hair * 2.0
      ..color = color;
    final dx = left ? (x - 10.0) : (x + 10.0);
    canvas.drawLine(
      Offset(_pxAlign(dx), topY),
      Offset(_pxAlign(dx), topY + len),
      p,
    );
  }

  void _drawTopLabel(
    Canvas canvas,
    double tx,
    double w,
    double railTop,
    String text,
  ) {
    if (!showLabels || text.isEmpty) return;

    const style = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      color: Colors.black,
    );

    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 120.0);

    const padH = 6.0, padV = 2.5;
    final pillW = tp.width + padH * 2;
    final pillH = tp.height + padV * 2;

    final dx = (tx - pillW / 2).clamp(2.0, w - pillW - 2.0);
    final dy = railTop + 2.0;

    final rect = Rect.fromLTWH(dx, dy, pillW, pillH);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(10));

    final pillBg = colorBar.withValues(alpha: 0.16);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _hair * 2.0
      ..color = colorBar.withValues(alpha: 0.32);
    final fill = Paint()..color = pillBg;

    canvas.drawRRect(rrect, fill);
    canvas.drawRRect(rrect, stroke);
    tp.paint(canvas, Offset(rect.left + padH, rect.top + padV));
  }

}
