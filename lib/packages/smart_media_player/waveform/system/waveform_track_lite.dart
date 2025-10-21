// ========================= WaveformTrackLite =========================
// DAW 오디오트랙 스타일의 단순 파형 뷰 (라이트)
// - 탭/드래그 탐색, 영역 선택, 루프 음영, 커서, 마커, 스테레오 오버레이
// - 마커 드래그 이동 지원
// - A/B(시작/끝) 핸들 드래그 지원
// - 클릭 시 시작점도 함께 갱신(옵션)
//
// © JHGuitarTree

import 'dart:math' as math;
import 'package:flutter/material.dart';

class WaveformTrackLite extends StatefulWidget {
  // 필수: 좌측(모노) 피크 0..1 또는 -1..+1
  final List<double> peaksL;
  // 선택: 우측 피크. 제공되면 스테레오로 상/하 대칭 합성
  final List<double>? peaksR;

  final Duration duration;
  final Duration position;

  // 뷰 윈도우(0..1): pan/zoom
  final double viewStart; // 0..1
  final double viewWidth; // 0.02..1

  // 선택/루프/마커
  final bool selectionMode;
  final Duration? selectionA;
  final Duration? selectionB;

  final Duration? loopA;
  final Duration? loopB;
  final bool loopOn;
  final List<Duration> markers;
  final Duration startCue;
  final List<String>? markerLabels;
  final List<Color?>? markerColors;

  // 탐색/선택 콜백
  final ValueChanged<Duration>? onSeek;
  final ValueChanged<Duration>? onSelectStart;
  final ValueChanged<Duration>? onSelectUpdate;
  final void Function(Duration? a, Duration? b)? onSelectEnd;

  // 마커 드래그 콜백
  final void Function(int index, Duration t)? onMarkerDragStart;
  final void Function(int index, Duration t)? onMarkerDragUpdate;
  final void Function(int index, Duration t)? onMarkerDragEnd;

  // A/B 핸들 드래그 콜백
  final ValueChanged<Duration>? onLoopAChanged;
  final ValueChanged<Duration>? onLoopBChanged;

  // 클릭 시 시작점도 함께 갱신할지
  final ValueChanged<Duration>? onTapSetStartCue;

  const WaveformTrackLite({
    super.key,
    required this.peaksL,
    this.peaksR,
    required this.duration,
    required this.position,
    this.viewStart = 0.0,
    this.viewWidth = 1.0,
    this.selectionMode = true,
    this.selectionA,
    this.selectionB,
    this.loopA,
    this.loopB,
    this.loopOn = false,
    this.markers = const [],
    this.startCue = Duration.zero,
    this.markerLabels,
    this.markerColors,
    this.onSeek,
    this.onSelectStart,
    this.onSelectUpdate,
    this.onSelectEnd,
    this.onMarkerDragStart,
    this.onMarkerDragUpdate,
    this.onMarkerDragEnd,
    this.onLoopAChanged,
    this.onLoopBChanged,
    this.onTapSetStartCue,
  });

  @override
  State<WaveformTrackLite> createState() => _WaveformTrackLiteState();
}

class _WaveformTrackLiteState extends State<WaveformTrackLite> {
  double get _vs => widget.viewStart.clamp(0.0, 1.0);
  double get _vw => widget.viewWidth.clamp(0.02, 1.0);

  // 드래그 상태
  int? _dragMarkerIndex;
  _DragHandle? _dragHandle;

  Duration _dxToDuration(double dx, double width) {
    if (widget.duration == Duration.zero) return Duration.zero;
    final tRel = (dx / width).clamp(0.0, 1.0);
    final absT = (_vs + tRel * _vw).clamp(0.0, 1.0);
    final ms = (widget.duration.inMilliseconds * absT).round();
    return Duration(milliseconds: ms);
  }

  double _durationToX(Duration d, double width) {
    if (widget.duration == Duration.zero) return 0.0;
    final t = (d.inMilliseconds / widget.duration.inMilliseconds).clamp(
      0.0,
      1.0,
    );
    return ((t - _vs) / _vw).clamp(0.0, 1.0) * width;
  }

  _HitResult _hitTest(double dx, double width) {
    const tol = 9.0; // px
    if (widget.loopA != null) {
      final xA = _durationToX(widget.loopA!, width);
      if ((xA - dx).abs() <= tol) return _HitResult.handleA;
    }
    if (widget.loopB != null) {
      final xB = _durationToX(widget.loopB!, width);
      if ((xB - dx).abs() <= tol) return _HitResult.handleB;
    }

    if (widget.markers.isNotEmpty && widget.duration > Duration.zero) {
      for (var i = 0; i < widget.markers.length; i++) {
        final x = _durationToX(widget.markers[i], width);
        if ((x - dx).abs() <= tol) {
          _dragMarkerIndex = i;
          return _HitResult.marker(i);
        }
      }
    }
    return _HitResult.none;
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final h = c.maxHeight;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) {
            final t = _dxToDuration(d.localPosition.dx, w);
            widget.onSeek?.call(t);
            widget.onTapSetStartCue?.call(t);
          },
          onDoubleTapDown: (_) {
            widget.onSeek?.call(Duration.zero);
            widget.onTapSetStartCue?.call(Duration.zero);
          },
          onHorizontalDragStart: (d) {
            final hit = _hitTest(d.localPosition.dx, w);
            switch (hit.kind) {
              case _HitKind.handleA:
                _dragHandle = _DragHandle.a;
                widget.onLoopAChanged?.call(
                  _dxToDuration(d.localPosition.dx, w),
                );
                return;
              case _HitKind.handleB:
                _dragHandle = _DragHandle.b;
                widget.onLoopBChanged?.call(
                  _dxToDuration(d.localPosition.dx, w),
                );
                return;
              case _HitKind.marker:
                _dragMarkerIndex = hit.index;
                if (_dragMarkerIndex != null) {
                  final t = _dxToDuration(d.localPosition.dx, w);
                  widget.onMarkerDragStart?.call(_dragMarkerIndex!, t);
                }
                return;
              case _HitKind.none:
                _dragHandle = null;
                _dragMarkerIndex = null;
                if (!widget.selectionMode) return;
                final t = _dxToDuration(d.localPosition.dx, w);
                widget.onSelectStart?.call(t);
                return;
            }
          },
          onHorizontalDragUpdate: (d) {
            final t = _dxToDuration(d.localPosition.dx, w);
            if (_dragHandle != null) {
              if (_dragHandle == _DragHandle.a) {
                widget.onLoopAChanged?.call(t);
              } else {
                widget.onLoopBChanged?.call(t);
              }
              return;
            }
            if (_dragMarkerIndex != null) {
              widget.onMarkerDragUpdate?.call(_dragMarkerIndex!, t);
              return;
            }
            if (widget.selectionMode) {
              widget.onSelectUpdate?.call(t);
            } else {
              widget.onSeek?.call(t);
            }
          },
          onHorizontalDragEnd: (_) {
            if (_dragHandle != null) {
              _dragHandle = null;
              return;
            }
            if (_dragMarkerIndex != null) {
              final i = _dragMarkerIndex!;
              _dragMarkerIndex = null;
              final t = (i >= 0 && i < widget.markers.length)
                  ? widget.markers[i]
                  : null;
              if (t != null) widget.onMarkerDragEnd?.call(i, t);
              return;
            }
            if (widget.selectionMode) {
              widget.onSelectEnd?.call(widget.selectionA, widget.selectionB);
            }
          },
          child: CustomPaint(
            size: Size(w, h),
            painter: _LitePainter(
              dpr: dpr,
              L: widget.peaksL,
              R: widget.peaksR,
              duration: widget.duration,
              position: widget.position,
              viewStart: _vs,
              viewWidth: _vw,
              selectionA: widget.selectionA,
              selectionB: widget.selectionB,
              loopA: widget.loopA,
              loopB: widget.loopB,
              loopOn: widget.loopOn,
              markers: widget.markers,
              markerLabels: widget.markerLabels,
              markerColors: widget.markerColors,
              startCue: widget.startCue,
              theme: Theme.of(context),
              draggingHandle: _dragHandle,
            ),
          ),
        );
      },
    );
  }
}

enum _HitKind { none, marker, handleA, handleB }

class _HitResult {
  final _HitKind kind;
  final int? index;
  const _HitResult._(this.kind, [this.index]);
  static const none = _HitResult._(_HitKind.none);
  static const handleA = _HitResult._(_HitKind.handleA);
  static const handleB = _HitResult._(_HitKind.handleB);
  static _HitResult marker(int i) => _HitResult._(_HitKind.marker, i);
}

enum _DragHandle { a, b }

class _LitePainter extends CustomPainter {
  final double dpr;
  final List<double> L;
  final List<double>? R;

  final Duration duration;
  final Duration position;
  final double viewStart;
  final double viewWidth;

  final Duration? selectionA;
  final Duration? selectionB;
  final Duration? loopA;
  final Duration? loopB;
  final bool loopOn;
  final List<Duration> markers;
  final List<String>? markerLabels;
  final List<Color?>? markerColors;

  final Duration? startCue;
  final ThemeData theme;
  final _DragHandle? draggingHandle;

  _LitePainter({
    required this.dpr,
    required this.L,
    required this.R,
    required this.duration,
    required this.position,
    required this.viewStart,
    required this.viewWidth,
    required this.selectionA,
    required this.selectionB,
    required this.loopA,
    required this.loopB,
    required this.loopOn,
    required this.markers,
    required this.markerLabels,
    required this.markerColors,
    required this.startCue,
    required this.theme,
    required this.draggingHandle,
  });

  double _px(double x) => (x * dpr).round() / dpr;
  double get _hair => (1 / dpr);

  (double minV, double maxV) _pickMinMaxFrac(
    List<double> src,
    double a,
    double span,
  ) {
    if (src.isEmpty || span <= 0) return (0.0, 0.0);
    final b = a + span;

    int ia = a.floor().clamp(0, src.length - 1);
    int ib = b.ceil().clamp(ia + 1, src.length);

    double minV = double.infinity;
    double maxV = -double.infinity;

    final leftFrac = a - ia;
    final va0 = src[ia];
    final va1 = (ia + 1 < src.length) ? src[ia + 1] : va0;
    final vL = va0 * (1 - leftFrac) + va1 * leftFrac;
    minV = math.min(minV, vL);
    maxV = math.max(maxV, vL);

    for (int i = ia + 1; i < ib - 1; i++) {
      final v = src[i];
      if (v < minV) minV = v;
      if (v > maxV) maxV = v;
    }

    final rb = ib - 1;
    final rightFrac = b - rb;
    final vb0 = src[rb];
    final vb1 = (rb + 1 < src.length) ? src[rb + 1] : vb0;
    final vR = vb0 * (1 - rightFrac) + vb1 * rightFrac;
    minV = math.min(minV, vR);
    maxV = math.max(maxV, vR);

    if (!minV.isFinite) minV = 0;
    if (!maxV.isFinite) maxV = 0;
    return (minV, maxV);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    final colorTrack = theme.colorScheme.primary;
    final colorBg = theme.colorScheme.surfaceContainerHighest;
    final colorCursor = theme.colorScheme.tertiary;
    final colorSelection = theme.colorScheme.primary.withValues(alpha: 0.18);
    final colorLoop = theme.colorScheme.secondary.withValues(alpha: 0.22);
    final colorMarker = theme.colorScheme.onSurface;
    final colorStartCue = theme.colorScheme.error;

    final bg = Paint()..color = colorBg;
    final r = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, w, h),
      const Radius.circular(6),
    );
    canvas.drawRRect(r, bg);

    if (L.isEmpty || duration == Duration.zero) return;

    final centerY = h * 0.5;
    final half = (h * 0.5) - 2.0;
    final gap = math.min(half * 0.06, 6.0);

    void drawSpanShade(Color c, Duration a, Duration b) {
      final tA = (a.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
      final tB = (b.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
      final l = ((tA - viewStart) / viewWidth).clamp(0.0, 1.0) * w;
      final rr = ((tB - viewStart) / viewWidth).clamp(0.0, 1.0) * w;
      final left = math.min(l, rr), right = math.max(l, rr);
      if (right > 0 && left < w) {
        canvas.drawRect(
          Rect.fromLTWH(left, 0, right - left, h),
          Paint()..color = c,
        );
      }
    }

    if (selectionA != null && selectionB != null) {
      drawSpanShade(colorSelection, selectionA!, selectionB!);
    }
    if (loopA != null && loopB != null && loopOn) {
      drawSpanShade(colorLoop, loopA!, loopB!);
    }

    final fillL = Paint()
      ..color = colorTrack.withValues(alpha: 0.24)
      ..style = PaintingStyle.fill;
    final strokeL = Paint()
      ..color = colorTrack.withValues(alpha: 0.95)
      ..style = PaintingStyle.stroke
      ..strokeWidth = _hair;
    final strokeR = Paint()
      ..color = colorTrack.withValues(alpha: 0.65)
      ..style = PaintingStyle.stroke
      ..strokeWidth = _hair;

    final zeroLine = Paint()
      ..color = colorTrack.withValues(alpha: 0.18)
      ..strokeWidth = _hair;
    canvas.drawLine(Offset(0, _px(centerY)), Offset(w, _px(centerY)), zeroLine);

    final nL = L.length;
    final startIdx = (nL * viewStart).floor().clamp(0, nL - 1);
    final endIdx = (nL * (viewStart + viewWidth)).ceil().clamp(
      startIdx + 1,
      nL,
    );
    final visCount = endIdx - startIdx;
    final pixelCols = (w * dpr).floor().clamp(1, 200000);
    final step = visCount / pixelCols;

    final pathTopL = Path(), pathBotL = Path();
    final pathTopR = Path(), pathBotR = Path();

    bool startedL = false;
    bool startedR = false;

    int sR = 0, eR = 0;
    double stepR = 1.0;
    if (R != null && R!.isNotEmpty) {
      final nR = R!.length;
      sR = (nR * viewStart).floor().clamp(0, nR - 1);
      eR = (nR * (viewStart + viewWidth)).ceil().clamp(sR + 1, nR);
      stepR = (eR - sR) / pixelCols;
    }

    for (int i = 0; i < pixelCols; i++) {
      final x = _px(i / dpr);

      final aL = startIdx + i * step;
      final (minL, maxL) = _pickMinMaxFrac(L, aL, step);
      final hi = (half - gap) * (maxL.abs().clamp(0.0, 1.0));
      final lo = (half - gap) * (minL.abs().clamp(0.0, 1.0));
      final yT = centerY - gap - math.max(hi, lo);
      final yB = centerY + gap + math.max(hi, lo);

      if (!startedL) {
        pathTopL.moveTo(x, yT);
        pathBotL.moveTo(x, yB);
        startedL = true;
      } else {
        pathTopL.lineTo(x, yT);
        pathBotL.lineTo(x, yB);
      }

      if (R != null && R!.isNotEmpty) {
        final aR = sR + i * stepR;
        final (minR, maxR) = _pickMinMaxFrac(R!, aR, stepR);
        final hiR = (half - gap) * (maxR.abs().clamp(0.0, 1.0));
        final loR = (half - gap) * (minR.abs().clamp(0.0, 1.0));
        final yTR = centerY - gap - math.max(hiR, loR);
        final yBR = centerY + gap + math.max(hiR, loR);

        if (!startedR) {
          pathTopR.moveTo(x, yTR);
          pathBotR.moveTo(x, yBR);
          startedR = true;
        } else {
          pathTopR.lineTo(x, yTR);
          pathBotR.lineTo(x, yBR);
        }
      }
    }

    final fillPath = Path()
      ..addPath(pathTopL, Offset.zero)
      ..lineTo(_px(w), centerY + gap)
      ..lineTo(_px(0.0), centerY + gap)
      ..close();
    canvas.drawPath(fillPath, fillL);

    canvas.drawPath(pathTopL, strokeL);
    canvas.drawPath(pathBotL, strokeL);
    if (pathTopR.computeMetrics().iterator.moveNext()) {
      canvas.drawPath(pathTopR, strokeR);
      canvas.drawPath(pathBotR, strokeR);
    }

    if (markers.isNotEmpty) {
      for (var i = 0; i < markers.length; i++) {
        final m = markers[i];
        final t = (m.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
        final x = ((t - viewStart) / viewWidth).clamp(0.0, 1.0) * w;

        final color =
            (markerColors != null &&
                i < markerColors!.length &&
                markerColors![i] != null)
            ? markerColors![i]!
            : theme.colorScheme.onSurface;

        final p = Paint()
          ..color = color
          ..strokeWidth = _hair * 3.0;
        canvas.drawLine(
          Offset(_px(x), _px(centerY - half + 2)),
          Offset(_px(x), _px(centerY + half - 2)),
          p,
        );

        final label = (markerLabels != null && i < markerLabels!.length)
            ? markerLabels![i]
            : '';
        if (label != null && label.isNotEmpty) {
          final tp = TextPainter(
            text: TextSpan(
              text: label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          final flagW = tp.width + 10, flagH = tp.height + 6;
          final rr = RRect.fromRectAndRadius(
            Rect.fromLTWH(_px(x) - flagW / 2, 4, flagW, flagH),
            const Radius.circular(4),
          );
          final flagPaint = Paint()..color = theme.colorScheme.primaryContainer;
          canvas.drawRRect(rr, flagPaint);
          tp.paint(
            canvas,
            Offset(_px(x) - tp.width / 2, 4 + (flagH - tp.height) / 2),
          );
        }
      }
    }

    void drawHandle(Duration d, {required bool isA, required bool active}) {
      final x = _px(
        ((d.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0) -
                viewStart) /
            viewWidth *
            w,
      );
      final line = Paint()
        ..color =
            (active
                    ? theme.colorScheme.secondary
                    : theme.colorScheme.onSurfaceVariant)
                .withValues(alpha: active ? 1.0 : 0.85)
        ..strokeWidth = _hair * 3.0;
      canvas.drawLine(Offset(x, 0), Offset(x, h), line);

      final grip = Paint()
        ..color = line.color.withValues(alpha: 0.9)
        ..strokeWidth = _hair * 2.0
        ..strokeCap = StrokeCap.round;
      final gripY = centerY;
      const gripHalf = 12.0;
      canvas.drawLine(
        Offset(x - 6, gripY - gripHalf),
        Offset(x - 6, gripY + gripHalf),
        grip,
      );
      canvas.drawLine(
        Offset(x + 6, gripY - gripHalf),
        Offset(x + 6, gripY + gripHalf),
        grip,
      );

      final txt = isA ? '시작' : '끝';
      final tp = TextPainter(
        text: TextSpan(
          text: txt,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSecondaryContainer,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final boxW = tp.width + 8, boxH = tp.height + 4;
      final rr = RRect.fromRectAndRadius(
        Rect.fromLTWH(x - boxW / 2, 4, boxW, boxH),
        const Radius.circular(4),
      );
      final boxPaint = Paint()..color = theme.colorScheme.secondaryContainer;
      canvas.drawRRect(rr, boxPaint);
      tp.paint(canvas, Offset(x - tp.width / 2, 4 + (boxH - tp.height) / 2));
    }

    if (loopA != null)
      drawHandle(loopA!, isA: true, active: draggingHandle == _DragHandle.a);
    if (loopB != null)
      drawHandle(loopB!, isA: false, active: draggingHandle == _DragHandle.b);

    if (startCue != null) {
      final t = (startCue!.inMilliseconds / duration.inMilliseconds).clamp(
        0.0,
        1.0,
      );
      final sx = ((t - viewStart) / viewWidth).clamp(0.0, 1.0) * w;
      final path = Path()
        ..moveTo(_px(sx), 0)
        ..lineTo(_px(sx - 6), 10)
        ..lineTo(_px(sx + 6), 10)
        ..close();
      canvas.drawPath(path, Paint()..color = theme.colorScheme.error);
      final tp = TextPainter(
        text: TextSpan(
          text: '시작점',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(_px(sx) - tp.width / 2, 12));
    }

    final posT = (position.inMilliseconds / duration.inMilliseconds).clamp(
      0.0,
      1.0,
    );
    final cx = ((posT - viewStart) / viewWidth).clamp(0.0, 1.0) * w;
    final cursorShadow = Paint()
      ..color = Colors.black.withValues(alpha: 0.12)
      ..strokeWidth = _hair * 4.0;
    canvas.drawLine(Offset(_px(cx), 0), Offset(_px(cx), h), cursorShadow);
    final cursor = Paint()
      ..color = theme.colorScheme.tertiary
      ..strokeWidth = _hair * 3.0;
    canvas.drawLine(Offset(_px(cx), 0), Offset(_px(cx), h), cursor);
  }

  @override
  bool shouldRepaint(covariant _LitePainter old) {
    return old.dpr != dpr ||
        old.L != L ||
        old.R != R ||
        old.duration != duration ||
        old.position != position ||
        old.viewStart != viewStart ||
        old.viewWidth != viewWidth ||
        old.selectionA != selectionA ||
        old.selectionB != selectionB ||
        old.loopA != loopA ||
        old.loopB != loopB ||
        old.loopOn != loopOn ||
        old.markers != markers ||
        old.markerLabels != markerLabels ||
        old.markerColors != markerColors ||
        old.startCue != startCue ||
        old.theme.colorScheme != theme.colorScheme ||
        old.draggingHandle != draggingHandle;
  }
}
