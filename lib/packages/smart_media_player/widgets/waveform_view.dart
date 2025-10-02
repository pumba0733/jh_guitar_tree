// lib/packages/smart_media_player/widgets/waveform_view.dart
// v1.85.1 | 간단 파형 렌더 + 탭/드래그 시킹

import 'package:flutter/material.dart';

class WaveformView extends StatelessWidget {
  final List<double> peaks; // 0..1
  final Duration duration;
  final Duration position;
  final Duration? loopA;
  final Duration? loopB;
  final bool loopOn;
  final ValueChanged<Duration>? onSeek;

  const WaveformView({
    super.key,
    required this.peaks,
    required this.duration,
    required this.position,
    this.loopA,
    this.loopB,
    this.loopOn = false,
    this.onSeek,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final h = c.maxHeight;

        void _seekAtDx(double dx) {
          if (duration == Duration.zero) return;
          final t = (dx / w).clamp(0.0, 1.0);
          onSeek?.call(
            Duration(milliseconds: (duration.inMilliseconds * t).round()),
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
              colorBar: Theme.of(context).colorScheme.primary,
              colorBarBg: Theme.of(context).colorScheme.surfaceVariant,
              colorCursor: Theme.of(context).colorScheme.tertiary,
              colorLoop: Theme.of(
                context,
              ).colorScheme.secondary.withOpacity(0.25),
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

  final Color colorBar;
  final Color colorBarBg;
  final Color colorCursor;
  final Color colorLoop;

  _WavePainter({
    required this.peaks,
    required this.duration,
    required this.position,
    required this.loopA,
    required this.loopB,
    required this.loopOn,
    required this.colorBar,
    required this.colorBarBg,
    required this.colorCursor,
    required this.colorLoop,
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

    if (loopOn && loopA != null && loopB != null && duration != Duration.zero) {
      final a = loopA!.inMilliseconds / duration.inMilliseconds;
      final b = loopB!.inMilliseconds / duration.inMilliseconds;
      final left = (a.clamp(0.0, 1.0)) * w;
      final right = (b.clamp(0.0, 1.0)) * w;
      final loopPaint = Paint()..color = colorLoop;
      canvas.drawRect(
        Rect.fromLTWH(left, 0, (right - left).abs(), h),
        loopPaint,
      );
    }

    final n = peaks.length;
    final barPaint = Paint()..color = colorBar;
    final barW = (w / n).clamp(1.0, 4.0);
    final spacing = (barW > 2) ? 1.0 : 0.0;

    var x = 0.0;
    for (var i = 0; i < n; i++) {
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

    if (duration != Duration.zero) {
      final t = position.inMilliseconds / duration.inMilliseconds;
      final cx = (t.clamp(0.0, 1.0)) * w;
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
        old.colorBar != colorBar ||
        old.colorCursor != colorCursor ||
        old.colorLoop != colorLoop ||
        old.colorBarBg != colorBarBg;
  }
}
