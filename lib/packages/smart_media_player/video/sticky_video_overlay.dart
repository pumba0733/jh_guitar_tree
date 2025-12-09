// lib/packages/smart_media_player/video/sticky_video_overlay.dart
// v1.3.0 — pip UI 완전 복구 + textureReady 적용 (Stateful)

import 'dart:async';
import 'dart:ui' show lerpDouble;
import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

class StickyVideoOverlay extends StatefulWidget {
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
  State<StickyVideoOverlay> createState() => _StickyVideoOverlayState();
}

class _StickyVideoOverlayState extends State<StickyVideoOverlay> {
  StreamSubscription? _widthSub;
  StreamSubscription? _heightSub;

  @override
  void initState() {
    super.initState();

    // width/height 변화 → overlay 재렌더
    _widthSub = widget.controller.player.stream.width.listen((_) {
      if (mounted) setState(() {});
    });

    _heightSub = widget.controller.player.stream.height.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _widthSub?.cancel();
    _heightSub?.cancel();
    super.dispose();
  }

  bool _isTextureReady() {
    final w = widget.controller.player.state.width;
    final h = widget.controller.player.state.height;
    return (w != null && w > 0 && h != null && h > 0);
  }

  @override
  Widget build(BuildContext context) {
    final viewportWidth = widget.viewportSize.width;
    final viewportHeight = widget.viewportSize.height;

    // 스크롤 비율
    final offset = widget.scrollController.hasClients
        ? widget.scrollController.offset
        : 0.0;

    final t = Curves.easeOut.transform(
      (offset / widget.collapseScrollPx).clamp(0.0, 1.0),
    );

    // pip 확장/축소 계산
    final maxWidth = viewportWidth;
    final maxHeight = maxWidth * 9 / 16;
    final minWidth = (widget.miniWidth > viewportWidth)
        ? viewportWidth * 0.6
        : widget.miniWidth;
    final minHeight = minWidth * 9 / 16;

    final w = lerpDouble(maxWidth, minWidth, t)!;
    final h = lerpDouble(maxHeight, minHeight, t)!;

    // 위치 보간
    final leftAt0 = (viewportWidth - w) / 2.0;
    const topAt0 = 0.0;

    final leftAt1 = viewportWidth - w - widget.margin.right;
    final topAt1 = viewportHeight - h - widget.margin.bottom;

    final left = lerpDouble(leftAt0, leftAt1, t)!;
    final top = lerpDouble(topAt0, topAt1, t)!;

    final ready = _isTextureReady();

    return Positioned(
      top: top,
      left: left,
      width: w,
      height: h,
      child: IgnorePointer(
        ignoring: widget.ignorePointer,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(widget.cornerRadius),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.25 * (0.5 + 0.5 * t)),
                blurRadius: lerpDouble(8, 18, t) ?? 12,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(widget.cornerRadius),
            child: ready
                ? Video(controller: widget.controller)
                : const ColoredBox(color: Colors.black),
          ),
        ),
      ),
    );
  }
}
