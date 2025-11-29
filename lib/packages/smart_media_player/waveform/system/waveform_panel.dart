// lib/packages/smart_media_player/waveform/system/waveform_panel.dart
// v3.31.7-hotfix | 말풍선 밴드=마커 전용 / 시킹·구간선택 배제 + 높이 100
// - 상단 _markerBandPx(28px): 마커만 픽업/드래그, 클릭 시킹 무시
// - 그 외 영역: 클릭=즉시 시킹+loopOff, 드래그=구간선택(loopOn)
// - 핸들 드래그 A/B 이동, 더블탭 A/B 해제
// - AnimatedBuilder로 외부 상태 변경 즉시 반영
//
// v3.8-FF STEP 7 정렬:
// - SoundTouchAudioChain / AudioChain 의존성 제거
// - WaveformController.duration / position (FFmpeg SoT)만 사용
// - withOpacity → withValues(alpha: ...) 교체
//
// P2/P3 정렬 (StartCue / Loop / Space / FR 규칙):
// - WaveformPanel은 "타임라인 제스처 전용" 레이어로 동작
// - StartCue는 여기서 절대 수정하지 않고, Screen/Engine에서만 관리
// - Loop(A/B)는 draw/선택·설정만 담당, seek/marker 이동을 클램프하지 않음
//   (FF/FR/파형 드래그/마커 점프 = 항상 자유 시킹; Loop/StartCue는 단지 값)

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
    await _load();
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _load() async {
    setState(() => _progress = 0.03);

    // 기본 fallback 길이 (5분) — 파일에서 읽기 전 안전값
    Duration durHint = widget.controller.duration.value > Duration.zero
        ? widget.controller.duration.value
        : const Duration(minutes: 5);

    // WaveformCache가 실제 duration을 반환한다면 그 정보만 사용
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

    // duration은 EngineApi / WaveformController.updateFromPlayer()가 관리
    // 이 Panel은 시각화용 RMS 벡터만 보유
    setState(() {
      _rmsL = res.rmsL;
      _progress = 1.0;
    });
  }

  // === 좌표 <-> 시간 변환 ===
  Duration _dxToTime(Offset localPos, Size size) {
    final c = widget.controller;
    final durMs = c.duration.value.inMilliseconds;
    final width = size.width;

    // 안전장치: duration=0, width=0 시 안정적으로 0 반환
    if (width <= 0 || durMs <= 0) return Duration.zero;

    // 0~1 frac in viewport
    final f = (localPos.dx / width).clamp(0.0, 1.0);

    // viewport 안정화: viewWidth 최소폭 0.02 보정
    final vs = c.viewStart.value.clamp(0.0, 1.0);
    final vw = c.viewWidth.value.clamp(0.02, 1.0);

    // global position fraction
    final g = (vs + f * vw).clamp(0.0, 1.0);

    return Duration(milliseconds: (g * durMs).round());
  }

  double _timeToDx(Duration t, Size size) {
    final c = widget.controller;
    final width = size.width;
    final durMs = c.duration.value.inMilliseconds;

    if (width <= 0 || durMs <= 0) return 0.0;

    final f = (t.inMilliseconds / durMs).clamp(0.0, 1.0);

    // viewport 안정화
    final vs = c.viewStart.value.clamp(0.0, 1.0);
    final vw = c.viewWidth.value.clamp(0.02, 1.0);

    final v = ((f - vs) / vw).clamp(0.0, 1.0);

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

    // viewport 확대 시 A가 튀지 않도록 clamp (duration 범위 안으로만)
    final durMs = c.duration.value.inMilliseconds;
    if (durMs > 0) {
      final ms = t.inMilliseconds.clamp(0, durMs);
      t = Duration(milliseconds: ms);
    }

    // ① selectionA/B 업데이트
    c.selectionA.value = t;

    if (c.selectionB.value != null && c.selectionB.value! < t) {
      final b = c.selectionB.value!;
      c.selectionB.value = t;
      c.selectionA.value = b;
    }

    // ② selection 기반으로 실제 loopA/B도 동기화
    final aa = c.selectionA.value;
    final bb = c.selectionB.value;
    if (aa != null && bb != null) {
      c.setLoop(a: aa, b: bb, on: c.loopOn.value);
      final cb = c.onLoopSet;
      if (cb != null) {
        scheduleMicrotask(() => cb(aa, bb));
      }
    }

    // StartCue는 Panel에서 건드리지 않는다 (Screen/Engine 전용)
    widget.onStateDirty?.call();
  }

  void _setB(Duration t) {
    final c = widget.controller;

    // duration 범위 안으로만 clamp
    final durMs = c.duration.value.inMilliseconds;
    if (durMs > 0) {
      final ms = t.inMilliseconds.clamp(0, durMs);
      t = Duration(milliseconds: ms);
    }

    // ① selectionB 업데이트
    c.selectionB.value = t;
    if (c.selectionA.value != null && c.selectionA.value! > t) {
      final a = c.selectionA.value!;
      c.selectionA.value = t;
      c.selectionB.value = a;
    }

    // ② selection 기반으로 실제 loopA/B도 동기화
    final aa = c.selectionA.value;
    final bb = c.selectionB.value;
    if (aa != null && bb != null) {
      c.setLoop(a: aa, b: bb, on: c.loopOn.value);
      final cb = c.onLoopSet;
      if (cb != null) {
        scheduleMicrotask(() => cb(aa, bb));
      }
    }

    widget.onStateDirty?.call();
  }

    // selection만 지우는 헬퍼 (엔진/LoopExecutor에는 영향 없음)
  void _clearSelectionOnly() {
    final c = widget.controller;
    c.selectionA.value = null;
    c.selectionB.value = null;
  }

  void _loopOff() {
    final c = widget.controller;

    // 루프 범위 자체를 제거 = “루프 모드 자체를 끈다”
    c.setLoop(a: null, b: null, on: false);

    final cb = c.onLoopSet;
    if (cb != null) {
      // 임시 프로토콜: 0,0 = "루프 없음"
      scheduleMicrotask(() => cb(Duration.zero, Duration.zero));
    }

    _clearSelectionOnly(); // 파형 위 A/B 강조 제거
    widget.onStateDirty?.call();
  }

  void _clearAB() {
    final c = widget.controller;

    // 더블탭 = A/B 해제 = 루프 자체도 함께 제거하는 쪽으로 통일
    c.setLoop(a: null, b: null, on: false);

    final cb = c.onLoopSet;
    if (cb != null) {
      // 0,0 = 루프 없음
      scheduleMicrotask(() => cb(Duration.zero, Duration.zero));
    }

    _clearSelectionOnly();
    widget.onStateDirty?.call();
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

            // ✅ 실제 루프 표시용 시간: loopA/B 우선, 없으면 selectionA/B 사용
            final Duration? loopA = c.loopA.value ?? c.selectionA.value;
            final Duration? loopB = c.loopB.value ?? c.selectionB.value;
            final bool loopActive =
                c.loopOn.value &&
                loopA != null &&
                loopB != null &&
                loopA < loopB;

            // ✅ Marker 색상 프리셋 (적/청/황/녹) — color가 null인 경우에만 적용
            final markerList = c.markers.value;
            final List<Color?> markerColors = List<Color?>.generate(
              markerList.length,
              (i) {
                final explicit = markerList[i].color;
                if (explicit != null) return explicit;

                const presets = [
                  Colors.red,
                  Colors.blue,
                  Colors.amber,
                  Colors.green,
                ];
                final base = presets[i % presets.length];
                // withOpacity deprecate → withValues(alpha: ...)
                return base.withValues(alpha: 0.85);
              },
            );

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

                      // A=B=t 고정 (초기 프레임 튐 제거)
                      c.selectionA.value = t;
                      c.selectionB.value = t;
                      c.loopOn.value = true;

                      widget.onStateDirty?.call();
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
                      // 드래그 중에는 selectionB만 업데이트, loopA/B는 종료 시 확정
                      c.selectionB.value = t;
                      widget.onStateDirty?.call();
                    } else if (_draggingMarkerIndex >= 0) {
                      // 마커 이동: LoopOn 여부와 관계없이 순수 타임라인 이동
                      _updateMarkerTime(_draggingMarkerIndex, t);
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

                      // ✅ 실제 루프 시각화: loopA/B + loopActive
                      loopA: loopA,
                      loopB: loopB,
                      loopOn: loopActive,

                      viewStart: vs,
                      viewWidth: vw,
                      drawMode: WaveDrawMode.path,
                      dualLayer: true,
                      useSignedAmplitude: false,
                      splitStereoQuadrants: false,

                      markers: markerList.map((m) => m.time).toList(),
                      markerLabels: markerList
                          .map((m) => m.label ?? '')
                          .toList(),
                      markerColors: markerColors,

                      // ✅ StartCue는 Controller 단일 소스 (Screen에서만 설정)
                      startCue: widget.controller.startCue.value,
                      showStartCue: true,
                      showHandles: true,
                    ),
                  ),
                ),

                // === ② 클릭(탭) 전용, 드래그와 경쟁 방지 ===
                Positioned.fill(
                  child: Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: (event) {
                      final local = event.localPosition;

                      // -----------------------------------------------
                      // ① Marker Jump: 상단 말풍선 밴드 클릭
                      //    LoopOn 여부와 무관하게 해당 마커 위치로 점프
                      // -----------------------------------------------
                      if (local.dy <= _markerBandPx) {
                        final hit = _hitMarkerIndex(local, viewSize);
                        if (hit >= 0) {
                          final c = widget.controller;
                          final m = c.markers.value[hit];
                          final jump = m.time;

                          // 위치 이동 (순수 seek)
                          c.position.value = jump;

                          // seek 요청 전달
                          final cb = c.onSeek;
                          if (cb != null) {
                            scheduleMicrotask(() => cb(jump));
                          }

                          // StartCue/Loop는 이 레이어에서 건드리지 않음
                          return; // 마커 클릭에서 일반 시킹으로 내려가지 않음
                        }

                        // 밴드지만 마커가 없는 경우: 아무 동작도 하지 않음
                        return;
                      }

                      // -----------------------------------------------
                      // ② 일반 클릭 시킹 (anywhere else)
                      //    - LoopOn 여부와 무관하게 순수 seek
                      //    - StartCue/Loop는 Screen/Engine에서만 관리
                      // -----------------------------------------------
                      final t = _dxToTime(local, viewSize);
                      final c = widget.controller;

                      // 재생 위치 즉시 반영 (SoT는 EngineApi가 최종 소스)
                      c.position.value = t;

                      // 일반 클릭 = loopOff (기존 UX 유지)
                      _loopOff();

                      final cb = c.onSeek;
                      if (cb != null) {
                        scheduleMicrotask(() => cb(t));
                      }

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
