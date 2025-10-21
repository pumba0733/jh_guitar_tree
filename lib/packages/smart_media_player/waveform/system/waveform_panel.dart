// lib/packages/smart_media_player/waveform/system/waveform_panel.dart
// v3.31.4 | 파형 상호작용 복원: 클릭/드래그로 A/B 설정, 핸들 드래그, 더블탭 해제

import 'dart:async';
import 'package:flutter/material.dart';
import '../waveform_cache.dart';
import '../waveform_view.dart';
import 'waveform_system.dart';

class WaveformPanel extends StatefulWidget {
  final WaveformController controller;
  final String mediaPath;
  final String mediaHash;
  final String cacheDir;
  final VoidCallback? onStateDirty;

  const WaveformPanel({
    super.key,
    required this.controller,
    required this.mediaPath,
    required this.mediaHash,
    required this.cacheDir,
    this.onStateDirty,
  });

  @override
  State<WaveformPanel> createState() => _WaveformPanelState();
}

class _WaveformPanelState extends State<WaveformPanel> {
  List<double> _rmsL = const [], _rmsR = const [];
  double _progress = 0.0;
  Future<void>? _loadFut;

  // 드래그 상태
  bool _draggingA = false;
  bool _draggingB = false;
  bool _dragSelecting = false;

  // 제스처 파라미터
  static const double _handleHitPx = 10; // 핸들 클릭 판정 반경

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureLoaded());
  }

  void _ensureLoaded() {
    if (_loadFut != null) return;
    _loadFut = _load().whenComplete(() => _loadFut = null);
  }

  Future<void> _load() async {
    setState(() => _progress = 0.03);
    final durHint = widget.controller.duration.value;
    final res = await WaveformCache.instance.loadOrBuildStereoVectors(
      mediaPath: widget.mediaPath,
      cacheDir: widget.cacheDir,
      cacheKey: widget.mediaHash,
      durationHint: durHint,
      onProgress: (p) {
        if (!mounted) return;
        setState(() => _progress = p.clamp(0.0, 1.0));
      },
    );
    if (!mounted) return;
    setState(() {
      _rmsL = res.rmsL;
      _rmsR = res.rmsR;
      _progress = 1.0;
    });
  }

  // === 좌표 <-> 시간 변환 ===
  Duration _dxToTime(Offset localPos, Size size) {
    final c = widget.controller;
    final width = size.width;
    if (width <= 0 || c.duration.value <= Duration.zero) return Duration.zero;

    final f = (localPos.dx / width).clamp(0.0, 1.0);
    final viewStart = c.viewStart.value.clamp(0.0, 1.0);
    final viewWidth = c.viewWidth.value.clamp(0.0, 1.0);
    final g = (viewStart + f * viewWidth).clamp(0.0, 1.0);
    final ms = (g * c.duration.value.inMilliseconds).round();
    return Duration(milliseconds: ms);
  }

  double _timeToDx(Duration t, Size size) {
    final c = widget.controller;
    final width = size.width;
    final f =
        t.inMilliseconds /
        (c.duration.value.inMilliseconds > 0
            ? c.duration.value.inMilliseconds
            : 1);
    final v = ((f - c.viewStart.value) / c.viewWidth.value).clamp(0.0, 1.0);
    return v * width;
  }

  bool _isNear(double x, double targetX) => (x - targetX).abs() <= _handleHitPx;

  void _setA(Duration t) {
    final c = widget.controller;
    c.selectionA.value = t;
    if (c.selectionB.value != null && c.selectionB.value! < t) {
      // A가 B보다 뒤라면 스왑
      final b = c.selectionB.value!;
      c.selectionB.value = t;
      c.selectionA.value = b;
    }
    widget.onStateDirty?.call();
  }

  void _setB(Duration t) {
    final c = widget.controller;
    if (c.selectionA.value == null) {
      c.selectionA.value = t;
    } else {
      c.selectionB.value = t;
      if (c.selectionB.value! < c.selectionA.value!) {
        final a = c.selectionA.value!;
        c.selectionA.value = c.selectionB.value;
        c.selectionB.value = a;
      }
    }
    widget.onStateDirty?.call();
  }

  void _clearAB() {
    final c = widget.controller;
    c.selectionA.value = null;
    c.selectionB.value = null;
    widget.onStateDirty?.call();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;

    return LayoutBuilder(
      builder: (ctx, box) {
        final ready = _rmsL.isNotEmpty;
        final vs = c.viewStart.value.clamp(0.0, 1.0);
        final vw = c.viewWidth.value.clamp(0.02, 1.0);

        if (!ready) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LinearProgressIndicator(
                value: (_progress > 0 && _progress <= 1.0) ? _progress : null,
                minHeight: 2,
              ),
              const SizedBox(height: 12),
              const Center(child: Text('파형 로딩 중…')),
            ],
          );
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: () {
            _clearAB();
            setState(() {}); // 뷰 리드로우
          },
          onTapDown: (d) {
            final local = d.localPosition;
            final size = Size(box.maxWidth, 160);
            final t = _dxToTime(local, size);
            // 탭: 재생 위치 이동 + 시작점(A) 지정
            c.position.value = t;
            _setA(t);
            // 외부 플레이어(있다면)로 seek는 컨트롤러 바인딩 쪽에서 처리됨
            setState(() {});
          },
          onPanStart: (d) {
            final size = Size(box.maxWidth, 160);
            final dx = d.localPosition.dx;

            // 핸들 근접 검사
            _draggingA = false;
            _draggingB = false;
            _dragSelecting = false;

            final a = c.selectionA.value;
            final b = c.selectionB.value;
            if (a != null) {
              final ax = _timeToDx(a, size);
              if (_isNear(dx, ax)) _draggingA = true;
            }
            if (!_draggingA && b != null) {
              final bx = _timeToDx(b, size);
              if (_isNear(dx, bx)) _draggingB = true;
            }
            if (!_draggingA && !_draggingB) {
              // 새 구간 선택 시작
              _dragSelecting = true;
              final t = _dxToTime(d.localPosition, size);
              c.selectionA.value = t;
              c.selectionB.value = null;
            }
            setState(() {});
          },
          onPanUpdate: (d) {
            final size = Size(box.maxWidth, 160);
            final t = _dxToTime(d.localPosition, size);

            if (_draggingA) {
              _setA(t);
            } else if (_draggingB) {
              _setB(t);
            } else if (_dragSelecting) {
              _setB(t);
            }
            setState(() {});
          },
          onPanEnd: (_) {
            _draggingA = _draggingB = _dragSelecting = false;
            widget.onStateDirty?.call();
            setState(() {});
          },
          child: SizedBox(
            height: 160,
            child: WaveformView(
              // 호환 필드
              peaks: _rmsL,
              peaksRight: null,
              // 타임라인
              duration: c.duration.value,
              position: c.position.value,
              loopA: c.selectionA.value,
              loopB: c.selectionB.value,
              loopOn:
                  (c.selectionA.value != null && c.selectionB.value != null),
              markers: const [],
              // 뷰포트 (오토줌 없음)
              viewStart: vs,
              viewWidth: vw,
              // 렌더 옵션
              splitStereoQuadrants: false,
              // 실제 데이터
              rmsLeft: _rmsL,
              rmsRight: null,
              // 핸들 표시 옵션 (뷰 내부에서 그림)
              showHandles: true,
            ),
          ),
        );
      },
    );
  }
}
