// lib/packages/smart_media_player/video/sticky_video_overlay.dart
// v1.0.0 — Reusable sticky video overlay widget (scroll-aware)

import 'dart:ui' show lerpDouble;
import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// A stacked floating video view that shrinks & moves to bottom-right
/// as the associated [scrollController] scrolls down.
///
/// Usage:
/// Stack(
///   children:[
///     SingleChildScrollView(controller: scrollCtl, child: ...),
///     StickyVideoOverlay(
///       controller: videoController,
///       scrollController: scrollCtl,
///       viewportSize: Size(w, h),
///     ),
///   ],
/// )
class StickyVideoOverlay extends StatelessWidget {
  const StickyVideoOverlay({
    super.key,
    required this.controller,
    required this.scrollController,
    required this.viewportSize,
    this.collapseScrollPx = 480.0,
    this.miniWidth = 360.0,
    this.cornerRadius = 14.0,
    this.margin = const EdgeInsets.all(16.0),
    this.ignorePointer = true,
  });

  final VideoController controller;
  final ScrollController scrollController;
  final Size viewportSize;
  final double collapseScrollPx;
  final double miniWidth;
  final double cornerRadius;
  final EdgeInsets margin;
  final bool ignorePointer;

  @override
  Widget build(BuildContext context) {
    final viewportWidth = viewportSize.width;
    final viewportHeight = viewportSize.height;

    final raw = scrollController.hasClients ? scrollController.offset : 0.0;
    final t = Curves.easeOut.transform(
      (raw / collapseScrollPx).clamp(0.0, 1.0),
    );

    final maxWidth = viewportWidth;
    final hMax = maxWidth * 9 / 16;
    final hMin = miniWidth * 9 / 16;

    final w = lerpDouble(maxWidth, miniWidth, t)!;
    final h = lerpDouble(hMax, hMin, t)!;

    final leftAt0 = (viewportWidth - w) / 2.0;
    const topAt0 = 0.0;

    final leftAt1 = viewportWidth - w - margin.right;
    final topAt1 = viewportHeight - h - margin.bottom;

    final left = lerpDouble(leftAt0, leftAt1, t)!;
    final top = lerpDouble(topAt0, topAt1, t)!;

    return Positioned(
      top: top,
      left: left,
      width: w,
      height: h,
      child: IgnorePointer(
        ignoring: ignorePointer,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(cornerRadius),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.25 * (0.5 + 0.5 * t)),
                blurRadius: lerpDouble(8, 18, t) ?? 12,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(cornerRadius),
            child: Video(controller: controller),
          ),
        ),
      ),
    );
  }
}
