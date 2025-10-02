// lib/packages/smart_media_player/widgets/waveform_view.dart
// v1.87.0 | viewport(zoom/scroll) + markers render
//
// - NEW: viewStart/viewWidth(0..1)로 구간 확대/스크롤
// - NEW: markers(List<Duration>) 표시
// - KEEP: 탭/드래그 시킹, 루프 강조, 커서 표시

import 'package:flutter/material.dart';

class WaveformView extends StatelessWidget {
  final List<double> peaks; // 0..1
  final Duration duration;
  final Duration position;
  final Duration? loopA;
  final Duration? loopB;
  final bool loopOn;
  final List<Duration> markers;
  final double viewStart; // 0..1
  final double viewWidth; // 0..1
  final ValueChanged<Duration>? onSeek;

  const WaveformView({
    super.key,
    required this.peaks,
    required this.duration,
    required this.position,
    this.loopA,
    this.loopB,
    this.loopOn = false,
    this.markers = const [],
    this.viewStart = 0.0,
    this.viewWidth = 1.0,
    this.onSeek,
  });

  @override
  Widget build(BuildContext context) {
    final vs = viewStart.clamp(0.0, 1.0);
    final vw = viewWidth.clamp(0.02, 1.0);
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final h = c.maxHeight;

        void _seekAtDx(double dx) {
          if (duration == Duration.zero) return;
          final tRel = (dx / w).clamp(0.0, 1.0);
          final absT = (vs + tRel * vw).clamp(0.0, 1.0);
          onSeek?.call(
            Duration(milliseconds: (duration.inMilliseconds * absT).round()),
          );
        }

        return GestureDetector(
          onTapDown: (d) => _seekAtDx(d.localPosition.dx),
          onHorizontalDragUpdate: (d) => _seekAtDx(d.localPosition.dx),
          child: CustomPaint(
            size: Size(w, h),
            painter: _WavePainter(
              peaks: peaks,
              duration: duration,
              position: position,
              loopA: loopA,
              loopB: loopB,
              loopOn: loopOn,
              viewStart: vs,
              viewWidth: vw,
              markers: markers,
              colorBar: Theme.of(context).colorScheme.primary,
              colorBarBg: Theme.of(context).colorScheme.surfaceVariant,
              colorCursor: Theme.of(context).colorScheme.tertiary,
              colorLoop: Theme.of(
                context,
              ).colorScheme.secondary.withOpacity(0.25),
              colorMarker: Theme.of(context).colorScheme.error,
            ),
          ),
        );
      },
    );
  }
}

class _WavePainter extends CustomPainter {
  final List<double> peaks;
  final Duration duration;
  final Duration position;
  final Duration? loopA;
  final Duration? loopB;
  final bool loopOn;
  final double viewStart;
  final double viewWidth;
  final List<Duration> markers;

  final Color colorBar;
  final Color colorBarBg;
  final Color colorCursor;
  final Color colorLoop;
  final Color colorMarker;

  _WavePainter({
    required this.peaks,
    required this.duration,
    required this.position,
    required this.loopA,
    required this.loopB,
    required this.loopOn,
    required this.viewStart,
    required this.viewWidth,
    required this.markers,
    required this.colorBar,
    required this.colorBarBg,
    required this.colorCursor,
    required this.colorLoop,
    required this.colorMarker,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final bg = Paint()..color = colorBarBg;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, w, h),
        const Radius.circular(6),
      ),
      bg,
    );
    if (peaks.isEmpty) return;

    // viewport index 범위
    final n = peaks.length;
    final startIdx = (n * viewStart).floor().clamp(0, n - 1);
    final endIdx = (n * (viewStart + viewWidth)).ceil().clamp(startIdx + 1, n);
    final visCount = endIdx - startIdx;

    // 루프 영역 페인트 (뷰포트 내 투영)
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
          Rect.fromLTWH(left, 0, (right - left).abs(), h),
          loopPaint,
        );
      }
    }

    // 막대 렌더
    final barPaint = Paint()..color = colorBar;
    final barW = (w / visCount).clamp(1.0, 4.0);
    final spacing = (barW > 2) ? 1.0 : 0.0;

    var x = 0.0;
    for (int i = startIdx; i < endIdx; i++) {
      final peak = peaks[i].clamp(0.0, 1.0);
      final bh = (h * (0.15 + 0.85 * peak)); // 15% 바닥 여백
      final top = (h - bh) / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, top, barW - spacing, bh),
          const Radius.circular(2),
        ),
        barPaint,
      );
      x += barW;
      if (x > w) break;
    }

    // 마커 렌더 (뷰포트 내)
    if (duration > Duration.zero && markers.isNotEmpty) {
      final mPaint = Paint()
        ..color = colorMarker
        ..strokeWidth = 2.0;
      for (final m in markers) {
        final t = (m.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
        final tx = ((t - viewStart) / viewWidth) * w;
        if (tx >= 0 && tx <= w) {
          canvas.drawLine(Offset(tx, 0), Offset(tx, h), mPaint);
        }
      }
    }

    // 커서
    if (duration != Duration.zero) {
      final t = (position.inMilliseconds / duration.inMilliseconds).clamp(
        0.0,
        1.0,
      );
      final cx = ((t - viewStart) / viewWidth).clamp(0.0, 1.0) * w;
      final cursor = Paint()
        ..color = colorCursor
        ..strokeWidth = 2.0;
      canvas.drawLine(Offset(cx, 0), Offset(cx, h), cursor);
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) {
    return old.peaks != peaks ||
        old.position != position ||
        old.loopA != loopA ||
        old.loopB != loopB ||
        old.loopOn != loopOn ||
        old.viewStart != viewStart ||
        old.viewWidth != viewWidth ||
        old.markers != markers ||
        old.colorBar != colorBar ||
        old.colorCursor != colorCursor ||
        old.colorLoop != colorLoop ||
        old.colorBarBg != colorBarBg ||
        old.colorMarker != colorMarker;
  }
}
