// lib/packages/smart_media_player/waveform/system/waveform_panel.dart
// v3.31.7-hotfix | 말풍선 밴드=마커 전용 / 시킹·구간선택 배제 + 높이 100
// - 상단 _markerBandPx(28px): 마커만 픽업/드래그, 클릭 시킹 무시
// - 그 외 영역: 클릭=즉시 시킹+loopOff, 드래그=구간선택(loopOn)
// - 핸들 드래그 A/B 이동, 더블탭 A/B 해제
// - AnimatedBuilder로 외부 상태 변경 즉시 반영

import 'dart:async';
import 'package:flutter/material.dart';
import '../waveform_cache.dart';
import '../waveform_view.dart';
import 'waveform_system.dart';
import '../../audio/soundtouch_audio_chain.dart';


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
  // --- hit params & layout ---
  static const double _handleHitPx = 10; // A/B 핸들 판정 반경
  static const double _markerHitPx = 22; // 말풍선 근처 X 허용치
  static const double _markerBandPx = 28; // 상단 말풍선 전용 밴드 높이
  static const double _viewHeight = 100; // 파형 높이

  double _progress = 0.0;

  List<double> _rmsL = const [];

  // 드래그 상태
  bool _draggingA = false;
  bool _draggingB = false;
  bool _dragSelecting = false;
  int _draggingMarkerIndex = -1;

  // 외부 변경에 즉시 반응
  Listenable get _mergedListenable => Listenable.merge([
    widget.controller.selectionA,
    widget.controller.selectionB,
    widget.controller.loopOn,
    widget.controller.position,
    widget.controller.duration,
    widget.controller.viewStart,
    widget.controller.viewWidth,
    widget.controller.markers,
    widget.controller.startCue,
  ]);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureLoaded());
  }

  void _ensureLoaded() async {
    await _load(); // ✅ 실제 존재하는 함수명으로 수정

    // 🔹 오디오 체인 연결 (재생 위치 자동 반영)
    widget.controller.bindToAudioChain(SoundTouchAudioChain.instance);

    setState(() {});
  }



  Future<void> _load() async {
    setState(() => _progress = 0.03);
    final chain = SoundTouchAudioChain.instance;

    // 기본 fallback 길이 (5분) — 파일에서 읽기 전 안전값
    Duration durHint = chain.duration.inMilliseconds > 0
        ? chain.duration
        : const Duration(seconds: 300);

    // WaveformCache가 실제 duration을 반환한다면 업데이트



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

    // 🔥🔥🔥 여기! — duration 업데이트
    if (res.durationMs > 0) {
      SoundTouchAudioChain.instance.setDuration(
        Duration(milliseconds: res.durationMs),
      );
    }

    setState(() {
      _rmsL = res.rmsL;
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
    final f = (c.duration.value.inMilliseconds > 0)
        ? (t.inMilliseconds / c.duration.value.inMilliseconds)
        : 0.0;
    final v =
        ((f - c.viewStart.value) /
                (c.viewWidth.value <= 0 ? 1.0 : c.viewWidth.value))
            .clamp(0.0, 1.0);
    return (v * width).clamp(0.0, width);
  }

  bool _near(double x, double targetX, double tol) =>
      (x - targetX).abs() <= tol;

  // === 마커 히트 테스트: "상단 말풍선 밴드"에서만 픽업 ===
  int _hitMarkerIndex(Offset local, Size size) {
    if (local.dy > _markerBandPx) return -1; // 밴드 밖이면 픽업 금지
    final markers = widget.controller.markers.value;
    if (markers.isEmpty) return -1;

    int bestIdx = -1;
    double bestDx = double.infinity;
    for (int i = 0; i < markers.length; i++) {
      final mx = _timeToDx(markers[i].time, size);
      final dist = (local.dx - mx).abs();
      if (dist < bestDx) {
        bestDx = dist;
        bestIdx = i;
      }
    }
    return (bestDx <= _markerHitPx) ? bestIdx : -1;
  }

  void _setA(Duration t) {
    final c = widget.controller;
    c.selectionA.value = t;
    if (c.selectionB.value != null && c.selectionB.value! < t) {
      final b = c.selectionB.value!;
      c.selectionB.value = t;
      c.selectionA.value = b;
    }
    _enforceStartCueLoopRules();
    widget.onStateDirty?.call();
  }


  void _setB(Duration t) {
    final c = widget.controller;
    c.selectionB.value = t;
    if (c.selectionA.value != null && c.selectionA.value! > t) {
      final a = c.selectionA.value!;
      c.selectionA.value = t;
      c.selectionB.value = a;
    }
    _enforceStartCueLoopRules();
    widget.onStateDirty?.call();
  }

  void _enforceStartCueLoopRules() {
    final c = widget.controller;
    final a = c.selectionA.value;
    final b = c.selectionB.value;
    var sc = c.startCue.value;

    if (a != null && b != null && sc != null) {
      if (sc < a) sc = a;
      if (sc > b) sc = a;
      if (sc != c.startCue.value) c.setStartCue(sc);
    }
  }



  void _clearAB() {
    final c = widget.controller;
    c.selectionA.value = null;
    c.selectionB.value = null;
    widget.onStateDirty?.call();
  }

  void _loopOff() {
    final c = widget.controller;
    c.loopOn.value = false;
    _clearAB();
  }

  void _updateMarkerTime(int index, Duration t) {
    final c = widget.controller;
    final list = List<WfMarker>.from(c.markers.value);
    final m = list[index];
    list[index] = WfMarker.named(
      time: t,
      label: m.label,
      color: m.color,
      repeat: m.repeat,
    );
    list.sort((a, b) => a.time.compareTo(b.time));
    c.setMarkers(list);
    widget.onStateDirty?.call();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _mergedListenable,
      builder: (context, _) {
        final c = widget.controller;

        return LayoutBuilder(
          builder: (ctx, box) {
            final ready = _rmsL.isNotEmpty;
            if (!ready) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LinearProgressIndicator(
                    value: (_progress > 0 && _progress <= 1.0)
                        ? _progress
                        : null,
                    minHeight: 2,
                  ),
                  const SizedBox(height: 12),
                  const Center(child: Text('파형 로딩 중…')),
                ],
              );
            }

            final vs = c.viewStart.value.clamp(0.0, 1.0);
            final vw = c.viewWidth.value.clamp(0.02, 1.0);
            final Size viewSize = Size(box.maxWidth, _viewHeight);

            return Stack(
              children: [
                // === ① 드래그 / 핸들 / 마커 / 루프 선택 전용 ===
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (d) {
                    final dx = d.localPosition.dx;
                    final dy = d.localPosition.dy;

                    _draggingA = _draggingB = _dragSelecting = false;
                    _draggingMarkerIndex = -1;

                    // 핸들 히트
                    final a = c.selectionA.value;
                    final b = c.selectionB.value;
                    if (a != null) {
                      final ax = _timeToDx(a, viewSize);
                      if (_near(dx, ax, _handleHitPx)) _draggingA = true;
                    }
                    if (!_draggingA && b != null) {
                      final bx = _timeToDx(b, viewSize);
                      if (_near(dx, bx, _handleHitPx)) _draggingB = true;
                    }

                    // ⬇ 상단 말풍선 밴드에서만 마커 드래그 활성
                    if (!_draggingA && !_draggingB) {
                      final hit = _hitMarkerIndex(d.localPosition, viewSize);
                      if (hit >= 0) _draggingMarkerIndex = hit;
                    }

                    // ⬇ 구간선택은 상단 밴드 금지 (마커 전용), 나머지에서만 시작
                    if (dy > _markerBandPx &&
                        !_draggingA &&
                        !_draggingB &&
                        _draggingMarkerIndex < 0) {
                      _dragSelecting = true;
                      final t = _dxToTime(d.localPosition, viewSize);
                      _setA(t);
                      c.selectionB.value = t;
                      c.loopOn.value = true;
                    }

                    setState(() {});
                  },
                  onPanUpdate: (d) {
                    final t = _dxToTime(d.localPosition, viewSize);
                    if (_draggingA) {
                      _setA(t);
                    } else if (_draggingB) {
                      _setB(t);
                    } else if (_dragSelecting) {
                      c.selectionB.value = t;
                      widget.onStateDirty?.call();
                    } else if (_draggingMarkerIndex >= 0) {
                      _updateMarkerTime(_draggingMarkerIndex, t);

                      // 🔒 Marker 이동 중 LoopOn 유지 & 범위 밖이면 A로 스냅
                      final c = widget.controller;
                      if (c.loopOn.value &&
                          c.selectionA.value != null &&
                          c.selectionB.value != null) {
                        final a = c.selectionA.value!;
                        final b = c.selectionB.value!;
                        final pos = c.position.value;

                        if (pos < a || pos > b) {
                          // 규칙: Loop 범위 밖 → A로 스냅
                          c.position.value = a;
                          final cb = c.onSeek;
                          if (cb != null) scheduleMicrotask(() => cb(a));
                        }
                      }

                    }
                    setState(() {});
                  },
                  onPanEnd: (_) {
                    final a = c.selectionA.value, b = c.selectionB.value;
                    if (_dragSelecting && a != null && b != null) {
                      final aa = a <= b ? a : b;
                      final bb = a <= b ? b : a;
                      c.setLoop(a: aa, b: bb, on: true);
                      final cb = c.onLoopSet;
                      if (cb != null) scheduleMicrotask(() => cb(aa, bb));
                    }
                    _draggingA = _draggingB = _dragSelecting = false;
                    _draggingMarkerIndex = -1;
                    widget.onStateDirty?.call();
                    setState(() {});
                  },
                  onDoubleTap: () {
                    _clearAB();
                    setState(() {});
                  },
                  child: SizedBox(
                    height: _viewHeight,
                    width: double.infinity,
                    child: WaveformView(
                      peaks: _rmsL,
                      peaksRight: null,
                      duration: c.duration.value,
                      position: c.position.value,
                      loopA: c.selectionA.value,
                      loopB: c.selectionB.value,
                      loopOn:
                          c.loopOn.value &&
                          c.selectionA.value != null &&
                          c.selectionB.value != null,
                      viewStart: vs,
                      viewWidth: vw,
                      drawMode: WaveDrawMode.path,
                      dualLayer: true,
                      useSignedAmplitude: false,
                      splitStereoQuadrants: false,
                      markers: c.markers.value.map((m) => m.time).toList(),
                      markerLabels: c.markers.value
                          .map((m) => m.label ?? '')
                          .toList(),
                      markerColors: c.markers.value
                          .map((m) => m.color)
                          .toList(),
                      startCue: widget.controller.startCue.value,
                      showStartCue: true,
                      showHandles: true,
                    ),
                  ),
                ),

                // === ② 클릭(탭) 전용, 드래그와 경쟁 방지 ===
                // === ② 클릭(탭) 전용, 드래그와 경쟁 방지 ===
                Positioned.fill(
                  child: Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: (event) {
                      final local = event.localPosition;

                      // -----------------------------------------------
                      // ① Marker Jump: 상단 말풍선 밴드 클릭
                      // -----------------------------------------------
                      if (local.dy <= _markerBandPx) {
                        final hit = _hitMarkerIndex(local, viewSize);
                        if (hit >= 0) {
                          final c = widget.controller;
                          final m = c.markers.value[hit];
                          Duration jump = m.time;

                          // LoopOn이면 Jump가 Loop 범위 밖일 때 A로 스냅
                          final a = c.selectionA.value;
                          final b = c.selectionB.value;

                          if (c.loopOn.value && a != null && b != null) {
                            if (jump < a || jump > b) jump = a;
                          }

                          // 위치 이동
                          c.position.value = jump;

                          // StartCue 보정 (Loop 중 StartCue 변경 금지 규칙도 자동 적용됨)
                          _enforceStartCueLoopRules();

                          // fire seek
                          final cb = c.onSeek;
                          if (cb != null) scheduleMicrotask(() => cb(jump));


                          return; // 👈 마커 클릭에서 일반 시킹으로 내려가지 않음
                        }

                        // 밴드지만 마커가 없는 경우: 아무 동작도 하지 않음
                        return;
                      }

                      // -----------------------------------------------
                      // ② 일반 클릭 시킹
                      // -----------------------------------------------
                      final t = _dxToTime(local, viewSize);

                      // 재생 위치 즉시 반영
                      c.position.value = t;

                      // 🔒 LoopOn 중 StartCue 변경 금지
                      if (!c.loopOn.value) {
                        final a = c.selectionA.value;
                        final b = c.selectionB.value;
                        Duration adjusted = t;

                        if (a != null && b != null) {
                          if (t < a) adjusted = a;
                          if (t > b) adjusted = a;
                        }
                        c.setStartCue(adjusted);
                        _enforceStartCueLoopRules();
                      }


                      // 일반 클릭 = loopOff
                      _loopOff();

                      final cb = c.onSeek;
                      if (cb != null) scheduleMicrotask(() => cb(t));

                      setState(() {});
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
